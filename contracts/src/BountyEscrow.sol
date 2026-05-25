// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBountyEscrow} from "./interfaces/IBountyEscrow.sol";

/// @title BountyEscrow
/// @notice Holds USDC for funded bounties, custodies BOUNTY bonds for
///         submissions, manages bounty state transitions. The state machine
///         here matches the public surface at agentbounty.dev/how-it-works.
/// @dev Module pattern: this contract is the single custody point. The
///      VerdictModule and SettlementModule consume role-gated primitives
///      (markAssigned, markVerdicted, withdraw*) to drive transitions and
///      release tokens. Audit clarity > flexibility.
contract BountyEscrow is AccessControl, Pausable, ReentrancyGuard, IBountyEscrow {
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant VERDICT_MODULE_ROLE = keccak256("VERDICT_MODULE_ROLE");
    bytes32 public constant SETTLEMENT_MODULE_ROLE = keccak256("SETTLEMENT_MODULE_ROLE");
    bytes32 public constant DISPUTE_RESOLVER_ROLE = keccak256("DISPUTE_RESOLVER_ROLE");

    uint64  public constant MAX_REVIEW_WINDOW       = 14 days;
    uint64  public constant MAX_CHALLENGE_WINDOW    = 7 days;
    uint64  public constant REFUND_AFTER            = 30 days;
    uint64  public constant REVIEWER_REJECT_WINDOW  = 12 hours;
    uint256 public constant BOND_MULTIPLIER_BPS     = 12_500;
    uint256 public constant BOND_CAP_MULTIPLIER     = 10;
    uint256 public constant MAX_SUBMISSIONS         = 50;
    uint256 public constant BPS_DENOMINATOR         = 10_000;
    address public constant BURN_ADDRESS            = address(0xdEaD);

    IERC20 public immutable BOUNTY;
    IERC20 public immutable USDC;

    address public feeRecipient;
    address public challengeContract;

    mapping(uint256 => Bounty)     internal _bounties;
    mapping(uint256 => Submission) internal _submissions;
    mapping(uint256 => uint256)    internal _currentMultiplierBps;
    mapping(uint256 => bool)       internal _disputeResolved;
    mapping(uint256 => bool)       internal _disputeAwardHunter;
    uint256 public nextBountyId;
    uint256 public nextSubmissionId;

    error InvalidPayoutMax();
    error InvalidBaseBond();
    error InvalidReviewWindow();
    error InvalidChallengeWindow();
    error InvalidSpecHash();
    error BountyDoesNotExist();
    error WrongState();
    error NotSponsor();
    error AlreadyHasSubmissions();
    error RefundTooEarly();
    error MaxSubmissionsReached();
    error ReviewerRejectWindowActive();
    error ReviewerAlreadyRejected();
    error ZeroAddress();
    error ChallengeWindowNotElapsed();
    error ChallengeWindowElapsed();
    error InvalidWinningSubmission();
    error InvalidSlashedSubmission();
    error InsufficientBountyBalance();
    error InsufficientUSDCBalance();

    constructor(
        address admin,
        address bountyToken,
        address usdcToken,
        address initialFeeRecipient
    ) {
        if (admin == address(0) || bountyToken == address(0) || usdcToken == address(0) || initialFeeRecipient == address(0)) {
            revert ZeroAddress();
        }
        BOUNTY = IERC20(bountyToken);
        USDC = IERC20(usdcToken);
        feeRecipient = initialFeeRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(DISPUTE_RESOLVER_ROLE, admin);
    }

    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
    }

    function setChallengeContract(address newChallengeContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        challengeContract = newChallengeContract;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function createBounty(
        uint256 payoutMax,
        uint256 baseBond,
        uint64  reviewWindow,
        uint64  challengeWindow,
        bytes32 specHash,
        address proposedReviewer
    ) external whenNotPaused returns (uint256 bountyId) {
        if (payoutMax == 0) revert InvalidPayoutMax();
        if (baseBond == 0) revert InvalidBaseBond();
        if (reviewWindow == 0 || reviewWindow > MAX_REVIEW_WINDOW) revert InvalidReviewWindow();
        if (challengeWindow == 0 || challengeWindow > MAX_CHALLENGE_WINDOW) revert InvalidChallengeWindow();
        if (specHash == bytes32(0)) revert InvalidSpecHash();

        bountyId = ++nextBountyId;

        Bounty storage b = _bounties[bountyId];
        b.sponsor = msg.sender;
        b.proposedReviewer = proposedReviewer;
        b.reviewerProposedAt = uint96(block.timestamp);
        b.payoutMax = payoutMax;
        b.baseBond = baseBond;
        b.reviewWindow = reviewWindow;
        b.challengeWindow = challengeWindow;
        b.specHash = specHash;
        b.state = BountyState.Draft;
        _currentMultiplierBps[bountyId] = BPS_DENOMINATOR;

        emit BountyCreated(bountyId, msg.sender, proposedReviewer, payoutMax, baseBond, specHash);
    }

    function fundBounty(uint256 bountyId) external nonReentrant whenNotPaused {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.Draft) revert WrongState();
        if (msg.sender != b.sponsor) revert NotSponsor();

        b.state = BountyState.Funded;
        b.fundedAt = uint64(block.timestamp);
        b.reviewerProposedAt = uint96(block.timestamp);

        USDC.safeTransferFrom(msg.sender, address(this), b.payoutMax);

        emit BountyFunded(bountyId, b.payoutMax);
    }

    function cancel(uint256 bountyId) external nonReentrant whenNotPaused {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.Funded) revert WrongState();
        if (msg.sender != b.sponsor) revert NotSponsor();
        if (b.submissionIds.length > 0) revert AlreadyHasSubmissions();

        b.state = BountyState.Refunded;
        USDC.safeTransfer(b.sponsor, b.payoutMax);

        emit BountyCancelled(bountyId);
        emit BountyRefunded(bountyId, b.payoutMax);
    }

    function refund(uint256 bountyId) external nonReentrant whenNotPaused {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.Funded && b.state != BountyState.InReview) revert WrongState();
        if (b.submissionIds.length > 0) revert AlreadyHasSubmissions();
        if (block.timestamp < uint256(b.fundedAt) + REFUND_AFTER) revert RefundTooEarly();

        b.state = BountyState.Refunded;
        USDC.safeTransfer(b.sponsor, b.payoutMax);

        emit BountyRefunded(bountyId, b.payoutMax);
    }

    function submit(
        uint256 bountyId,
        bytes32 artifactHash,
        bytes32 evidenceHash
    ) external nonReentrant whenNotPaused returns (uint256 submissionId) {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.InReview) revert WrongState();
        if (b.submissionIds.length >= MAX_SUBMISSIONS) revert MaxSubmissionsReached();

        uint256 multiplierBps = _currentMultiplierBps[bountyId];
        if (multiplierBps == 0) multiplierBps = BPS_DENOMINATOR;
        uint256 totalCost = (b.baseBond * multiplierBps) / BPS_DENOMINATOR;
        uint256 burnAmount = totalCost - b.baseBond;

        BOUNTY.safeTransferFrom(msg.sender, address(this), b.baseBond);
        if (burnAmount > 0) {
            BOUNTY.safeTransferFrom(msg.sender, BURN_ADDRESS, burnAmount);
        }

        submissionId = ++nextSubmissionId;
        Submission storage s = _submissions[submissionId];
        s.bountyId = bountyId;
        s.submitter = msg.sender;
        s.submittedAt = uint64(block.timestamp);
        s.paidBond = b.baseBond;
        s.artifactHash = artifactHash;
        s.evidenceHash = evidenceHash;

        b.submissionIds.push(submissionId);

        uint256 cap = BOND_CAP_MULTIPLIER * BPS_DENOMINATOR;
        uint256 nextMul = (multiplierBps * BOND_MULTIPLIER_BPS) / BPS_DENOMINATOR;
        if (nextMul > cap) nextMul = cap;
        _currentMultiplierBps[bountyId] = nextMul;

        emit SubmissionCreated(bountyId, submissionId, msg.sender, b.baseBond, burnAmount, artifactHash);
    }

    function dispute(uint256 bountyId) external nonReentrant whenNotPaused {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.Queued) revert WrongState();
        if (block.timestamp >= uint256(b.verdictedAt) + b.challengeWindow) revert ChallengeWindowElapsed();

        b.state = BountyState.Disputed;
        emit Disputed(bountyId, msg.sender, 0);
    }

    function resolveDispute(uint256 bountyId, bool awardHunter) external onlyRole(DISPUTE_RESOLVER_ROLE) {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.Disputed) revert WrongState();

        _disputeResolved[bountyId] = true;
        _disputeAwardHunter[bountyId] = awardHunter;
        b.state = BountyState.Queued;

        emit DisputeResolved(bountyId, awardHunter);
    }

    function markAssigned(uint256 bountyId, address reviewer) external onlyRole(VERDICT_MODULE_ROLE) {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.Funded) revert WrongState();
        if (reviewer == address(0)) revert ZeroAddress();

        b.assignedReviewer = reviewer;
        b.state = BountyState.InReview;
        emit ReviewerAssigned(bountyId, reviewer);
    }

    function markRejectedAndPooled(uint256 bountyId) external onlyRole(VERDICT_MODULE_ROLE) {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.Funded) revert WrongState();

        address rejected = b.proposedReviewer;
        b.proposedReviewer = address(0);
        emit ReviewerRejected(bountyId, rejected);
    }

    function markVerdicted(
        uint256 bountyId,
        uint256 winningSubmissionId,
        uint256[] calldata slashedSubmissionIds,
        bytes32 evidenceAnchor
    ) external onlyRole(VERDICT_MODULE_ROLE) {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.InReview) revert WrongState();

        if (winningSubmissionId != 0) {
            Submission storage winning = _submissions[winningSubmissionId];
            if (winning.bountyId != bountyId) revert InvalidWinningSubmission();
        }

        uint256 slashedLen = slashedSubmissionIds.length;
        for (uint256 i = 0; i < slashedLen; ++i) {
            uint256 sid = slashedSubmissionIds[i];
            Submission storage s = _submissions[sid];
            if (s.bountyId != bountyId) revert InvalidSlashedSubmission();
            if (sid == winningSubmissionId) revert InvalidSlashedSubmission();
            s.isSlashed = true;
        }

        b.winningSubmissionId = winningSubmissionId;
        b.state = BountyState.Queued;
        b.verdictedAt = uint64(block.timestamp);

        emit VerdictRecorded(bountyId, winningSubmissionId, slashedSubmissionIds, evidenceAnchor);
    }

    function markSettled(uint256 bountyId) external onlyRole(SETTLEMENT_MODULE_ROLE) {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.Queued) revert WrongState();

        b.state = BountyState.Settled;
        emit BountySettled(bountyId);
    }

    function markClaimed(uint256 bountyId) external onlyRole(SETTLEMENT_MODULE_ROLE) {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.Settled) revert WrongState();

        address hunter;
        if (b.winningSubmissionId != 0) {
            hunter = _submissions[b.winningSubmissionId].submitter;
        }

        b.state = BountyState.Claimed;
        emit BountyClaimed(bountyId, hunter);
    }

    function markRefundedFromQueued(uint256 bountyId) external onlyRole(SETTLEMENT_MODULE_ROLE) {
        Bounty storage b = _bounties[bountyId];
        if (b.sponsor == address(0)) revert BountyDoesNotExist();
        if (b.state != BountyState.Queued) revert WrongState();

        bool rejectAll = b.winningSubmissionId == 0;
        bool disputeOverturned = _disputeResolved[bountyId] && !_disputeAwardHunter[bountyId];
        if (!rejectAll && !disputeOverturned) revert WrongState();

        b.state = BountyState.Refunded;
        emit BountyRefunded(bountyId, b.payoutMax);
    }

    function withdrawUSDC(address to, uint256 amount) external onlyRole(SETTLEMENT_MODULE_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (USDC.balanceOf(address(this)) < amount) revert InsufficientUSDCBalance();
        USDC.safeTransfer(to, amount);
    }

    function withdrawBounty(address to, uint256 amount) external onlyRole(SETTLEMENT_MODULE_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (BOUNTY.balanceOf(address(this)) < amount) revert InsufficientBountyBalance();
        BOUNTY.safeTransfer(to, amount);
    }

    function withdrawBountyToBurn(uint256 amount) external onlyRole(SETTLEMENT_MODULE_ROLE) {
        if (BOUNTY.balanceOf(address(this)) < amount) revert InsufficientBountyBalance();
        BOUNTY.safeTransfer(BURN_ADDRESS, amount);
    }

    function getBounty(uint256 bountyId) external view returns (Bounty memory) {
        return _bounties[bountyId];
    }

    function getSubmission(uint256 submissionId) external view returns (Submission memory) {
        return _submissions[submissionId];
    }

    function getSubmissionIds(uint256 bountyId) external view returns (uint256[] memory) {
        return _bounties[bountyId].submissionIds;
    }

    function bountyExists(uint256 bountyId) external view returns (bool) {
        return _bounties[bountyId].sponsor != address(0);
    }

    function getCurrentMultiplierBps(uint256 bountyId) external view returns (uint256) {
        uint256 m = _currentMultiplierBps[bountyId];
        return m == 0 ? BPS_DENOMINATOR : m;
    }

    function currentBondCost(uint256 bountyId)
        external
        view
        returns (uint256 totalCost, uint256 baseBond, uint256 burnAmount)
    {
        Bounty storage b = _bounties[bountyId];
        baseBond = b.baseBond;
        uint256 multiplierBps = _currentMultiplierBps[bountyId];
        if (multiplierBps == 0) multiplierBps = BPS_DENOMINATOR;
        totalCost = (baseBond * multiplierBps) / BPS_DENOMINATOR;
        burnAmount = totalCost - baseBond;
    }

    function disputeResolved(uint256 bountyId) external view returns (bool resolved, bool awardHunter) {
        return (_disputeResolved[bountyId], _disputeAwardHunter[bountyId]);
    }
}
