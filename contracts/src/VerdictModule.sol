// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { IBountyEscrow } from "./interfaces/IBountyEscrow.sol";
import { IVerdictModule } from "./interfaces/IVerdictModule.sol";

/// @title VerdictModule
/// @notice Reviewer registry, BOUNTY bond accounting, EIP-712 verdict signing,
///         and the hybrid sponsor-proposes / pool-claims assignment flow.
/// @dev Calls into BountyEscrow via VERDICT_MODULE_ROLE for state transitions.
///      Bond floor scales with payoutMax per the strategic-memo addition.
contract VerdictModule is AccessControl, ReentrancyGuard, EIP712, IVerdictModule {
    using SafeERC20 for IERC20;

    bytes32 public constant REVIEWER_ADMIN_ROLE = keccak256("REVIEWER_ADMIN_ROLE");

    bytes32 internal constant VERDICT_TYPEHASH = keccak256(
        "Verdict(uint256 bountyId,uint256 winningSubmissionId,uint256[] slashedSubmissionIds,bytes32 evidenceAnchor,uint256 expiresAt,uint256 nonce)"
    );

    uint256 public constant MIN_REVIEWER_BOND = 1_000_000 ether;
    uint256 public constant BOND_RATIO_BPS = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable BOUNTY;
    IBountyEscrow public immutable bountyEscrow;

    mapping(address => Reviewer) internal _reviewers;
    mapping(address => uint256) internal _reviewerNonces;
    mapping(uint256 => address) internal _bountyAssignedTo;

    error NotRegistered();
    error AlreadyRegistered();
    error InsufficientBond();
    error NotProposedReviewer();
    error AssignmentNotOpen();
    error PoolNotOpen();
    error VerdictExpired();
    error VerdictBadNonce();
    error VerdictBadSigner();
    error WrongBountyState();
    error AssignmentAlreadyHeld();
    error ZeroAddress();

    constructor(
        address admin,
        address bountyToken,
        address escrow
    ) EIP712("AgentBounty Verdict", "1") {
        if (admin == address(0) || bountyToken == address(0) || escrow == address(0)) {
            revert ZeroAddress();
        }
        BOUNTY = IERC20(bountyToken);
        bountyEscrow = IBountyEscrow(escrow);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REVIEWER_ADMIN_ROLE, admin);
    }

    function registerReviewer(
        uint256 bountyBondAmount
    ) external nonReentrant {
        if (_reviewers[msg.sender].isRegistered) revert AlreadyRegistered();
        if (bountyBondAmount < MIN_REVIEWER_BOND) revert InsufficientBond();

        BOUNTY.safeTransferFrom(msg.sender, address(this), bountyBondAmount);

        _reviewers[msg.sender] =
            Reviewer({ isRegistered: true, lockedBond: bountyBondAmount, registeredAt: uint64(block.timestamp) });

        emit ReviewerRegistered(msg.sender, bountyBondAmount);
    }

    function topUpBond(
        uint256 bountyBondAmount
    ) external nonReentrant {
        Reviewer storage r = _reviewers[msg.sender];
        if (!r.isRegistered) revert NotRegistered();

        BOUNTY.safeTransferFrom(msg.sender, address(this), bountyBondAmount);
        r.lockedBond += bountyBondAmount;

        emit ReviewerBondToppedUp(msg.sender, bountyBondAmount, r.lockedBond);
    }

    function unregisterReviewer() external nonReentrant {
        Reviewer storage r = _reviewers[msg.sender];
        if (!r.isRegistered) revert NotRegistered();

        uint256 toReturn = r.lockedBond;
        r.isRegistered = false;
        r.lockedBond = 0;

        BOUNTY.safeTransfer(msg.sender, toReturn);

        emit ReviewerUnregistered(msg.sender, toReturn);
    }

    function acceptAssignment(
        uint256 bountyId
    ) external nonReentrant {
        Reviewer storage r = _reviewers[msg.sender];
        if (!r.isRegistered) revert NotRegistered();

        IBountyEscrow.Bounty memory b = bountyEscrow.getBounty(bountyId);
        if (b.proposedReviewer != msg.sender) revert NotProposedReviewer();
        if (b.state != IBountyEscrow.BountyState.Funded) revert WrongBountyState();
        if (_bountyAssignedTo[bountyId] != address(0)) revert AssignmentAlreadyHeld();

        uint256 required = requiredBondForBounty(b.payoutMax);
        if (r.lockedBond < required) revert InsufficientBond();

        _bountyAssignedTo[bountyId] = msg.sender;
        bountyEscrow.markAssigned(bountyId, msg.sender);

        emit AssignmentAccepted(bountyId, msg.sender);
    }

    function rejectAssignment(
        uint256 bountyId
    ) external {
        IBountyEscrow.Bounty memory b = bountyEscrow.getBounty(bountyId);
        if (b.proposedReviewer != msg.sender) revert NotProposedReviewer();
        if (b.state != IBountyEscrow.BountyState.Funded) revert WrongBountyState();

        bountyEscrow.markRejectedAndPooled(bountyId);
        emit AssignmentRejected(bountyId, msg.sender);
    }

    function claimPoolBounty(
        uint256 bountyId
    ) external nonReentrant {
        Reviewer storage r = _reviewers[msg.sender];
        if (!r.isRegistered) revert NotRegistered();

        IBountyEscrow.Bounty memory b = bountyEscrow.getBounty(bountyId);
        if (b.state != IBountyEscrow.BountyState.Funded) revert WrongBountyState();
        if (_bountyAssignedTo[bountyId] != address(0)) revert AssignmentAlreadyHeld();

        bool windowExpired =
            block.timestamp >= uint256(b.reviewerProposedAt) + uint256(bountyEscrow.REVIEWER_REJECT_WINDOW());
        if (b.proposedReviewer != address(0) && !windowExpired) revert PoolNotOpen();

        uint256 required = requiredBondForBounty(b.payoutMax);
        if (r.lockedBond < required) revert InsufficientBond();

        if (b.proposedReviewer != address(0)) {
            bountyEscrow.markRejectedAndPooled(bountyId);
        }

        _bountyAssignedTo[bountyId] = msg.sender;
        bountyEscrow.markAssigned(bountyId, msg.sender);

        emit PoolBountyClaimed(bountyId, msg.sender);
    }

    function submitVerdict(
        Verdict calldata v,
        bytes calldata signature
    ) external {
        bytes32 structHash = keccak256(
            abi.encode(
                VERDICT_TYPEHASH,
                v.bountyId,
                v.winningSubmissionId,
                keccak256(abi.encodePacked(v.slashedSubmissionIds)),
                v.evidenceAnchor,
                v.expiresAt,
                v.nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);

        if (block.timestamp > v.expiresAt) revert VerdictExpired();
        if (_reviewerNonces[signer] != v.nonce) revert VerdictBadNonce();
        if (_bountyAssignedTo[v.bountyId] != signer) revert VerdictBadSigner();

        IBountyEscrow.Bounty memory b = bountyEscrow.getBounty(v.bountyId);
        if (b.state != IBountyEscrow.BountyState.InReview) revert WrongBountyState();
        if (b.assignedReviewer != signer) revert VerdictBadSigner();

        _reviewerNonces[signer] = v.nonce + 1;

        bountyEscrow.markVerdicted(v.bountyId, v.winningSubmissionId, v.slashedSubmissionIds, v.evidenceAnchor);

        emit VerdictSubmitted(v.bountyId, signer, v.winningSubmissionId, v.slashedSubmissionIds.length);
    }

    function requiredBondForBounty(
        uint256 payoutMax
    ) public pure returns (uint256) {
        uint256 scaled = (payoutMax * BOND_RATIO_BPS) / BPS_DENOMINATOR;
        return scaled > MIN_REVIEWER_BOND ? scaled : MIN_REVIEWER_BOND;
    }

    function getReviewer(
        address reviewer
    ) external view returns (Reviewer memory) {
        return _reviewers[reviewer];
    }

    function reviewerNonce(
        address reviewer
    ) external view returns (uint256) {
        return _reviewerNonces[reviewer];
    }

    function isAssigned(
        uint256 bountyId,
        address reviewer
    ) external view returns (bool) {
        return _bountyAssignedTo[bountyId] == reviewer;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function verdictTypehash() external pure returns (bytes32) {
        return VERDICT_TYPEHASH;
    }
}
