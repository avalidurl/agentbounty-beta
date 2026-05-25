// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBountyEscrow} from "./interfaces/IBountyEscrow.sol";
import {ISettlementModule} from "./interfaces/ISettlementModule.sol";

/// @title SettlementModule
/// @notice Computes payouts on accepted bounties, returns / slashes BOUNTY
///         bonds per the 40/30/30 split, and routes the protocol fee 50%
///         to a burn write-off and 50% to FEE_RECIPIENT (the v0.2 Cautio
///         underwriting pool entry point).
/// @dev Calls into BountyEscrow via SETTLEMENT_MODULE_ROLE for token transfers
///      and state transitions. Hunter payout is pull-based via claim().
contract SettlementModule is AccessControl, ReentrancyGuard, ISettlementModule {
    using SafeERC20 for IERC20;

    bytes32 public constant SPONSOR_DISCOUNT_ADMIN_ROLE = keccak256("SPONSOR_DISCOUNT_ADMIN_ROLE");

    uint256 public constant PROTOCOL_FEE_BPS         = 100;
    uint256 public constant PROTOCOL_FEE_BURN_BPS    = 5_000;
    uint256 public constant REVIEWER_FEE_BPS         = 300;
    uint256 public constant SLASH_REVIEWER_BPS       = 4_000;
    uint256 public constant SLASH_TREASURY_BPS       = 3_000;
    uint256 public constant SLASH_BURN_BPS           = 3_000;
    uint256 public constant BPS_DENOMINATOR          = 10_000;

    IBountyEscrow public immutable bountyEscrow;
    IERC20        public immutable BOUNTY;
    IERC20        public immutable USDC;

    uint256 public sponsorDiscountThreshold;
    uint256 public sponsorDiscountedFeeBps;
    address public easAttester;

    mapping(uint256 => uint256) internal _claimableHunterPayout;
    mapping(uint256 => address) internal _claimableHunter;

    error WrongState();
    error ChallengeWindowActive();
    error AlreadySettled();
    error NotHunter();
    error NothingToClaim();
    error ZeroAddress();
    error AlreadyClaimed();

    constructor(
        address admin,
        address bountyToken,
        address usdcToken,
        address escrow
    ) {
        if (admin == address(0) || bountyToken == address(0) || usdcToken == address(0) || escrow == address(0)) {
            revert ZeroAddress();
        }
        BOUNTY = IERC20(bountyToken);
        USDC = IERC20(usdcToken);
        bountyEscrow = IBountyEscrow(escrow);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SPONSOR_DISCOUNT_ADMIN_ROLE, admin);

        sponsorDiscountedFeeBps = 50;
    }

    function setSponsorDiscount(uint256 threshold, uint256 discountedBps)
        external
        onlyRole(SPONSOR_DISCOUNT_ADMIN_ROLE)
    {
        sponsorDiscountThreshold = threshold;
        sponsorDiscountedFeeBps = discountedBps;
    }

    function setEasAttester(address newAttester) external onlyRole(DEFAULT_ADMIN_ROLE) {
        easAttester = newAttester;
    }

    function settle(uint256 bountyId) external nonReentrant {
        IBountyEscrow.Bounty memory b = bountyEscrow.getBounty(bountyId);
        if (b.state != IBountyEscrow.BountyState.Queued) revert WrongState();

        (bool resolved, bool awardHunter) = bountyEscrow.disputeResolved(bountyId);
        if (!resolved && block.timestamp < uint256(b.verdictedAt) + uint256(b.challengeWindow)) {
            revert ChallengeWindowActive();
        }

        bool refund = (resolved && !awardHunter) || b.winningSubmissionId == 0;

        if (refund) {
            _processRefund(bountyId, b);
        } else {
            _processPayout(bountyId, b);
        }
    }

    function claim(uint256 bountyId) external nonReentrant {
        IBountyEscrow.Bounty memory b = bountyEscrow.getBounty(bountyId);
        if (b.state != IBountyEscrow.BountyState.Settled) revert WrongState();

        address hunter = _claimableHunter[bountyId];
        if (msg.sender != hunter) revert NotHunter();

        uint256 amount = _claimableHunterPayout[bountyId];
        if (amount == 0) revert NothingToClaim();

        _claimableHunterPayout[bountyId] = 0;
        bountyEscrow.markClaimed(bountyId);
        bountyEscrow.withdrawUSDC(hunter, amount);

        emit HunterClaimed(bountyId, hunter, amount);
    }

    function refundSponsor(uint256 /* bountyId */) external pure {
        revert("v0.1: sponsor refund happens automatically inside settle() when verdict is reject-all or dispute-overturned");
    }

    function getClaimable(uint256 bountyId) external view returns (address hunter, uint256 amount) {
        return (_claimableHunter[bountyId], _claimableHunterPayout[bountyId]);
    }

    function _processPayout(uint256 bountyId, IBountyEscrow.Bounty memory b) internal {
        uint256 effectiveFeeBps = _effectiveProtocolFeeBps(b.sponsor);
        if (effectiveFeeBps != PROTOCOL_FEE_BPS) {
            emit SponsorDiscountApplied(bountyId, b.sponsor, effectiveFeeBps);
        }

        uint256 protocolFeeTotal = (b.payoutMax * effectiveFeeBps) / BPS_DENOMINATOR;
        uint256 protocolFeeBurn = (protocolFeeTotal * PROTOCOL_FEE_BURN_BPS) / BPS_DENOMINATOR;
        uint256 protocolFeeKeep = protocolFeeTotal - protocolFeeBurn;
        uint256 reviewerFee = (b.payoutMax * REVIEWER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 hunterPayout = b.payoutMax - protocolFeeTotal - reviewerFee;

        IBountyEscrow.Submission memory winning = bountyEscrow.getSubmission(b.winningSubmissionId);
        address hunter = winning.submitter;

        if (protocolFeeBurn > 0) {
            bountyEscrow.withdrawUSDC(bountyEscrow.BURN_ADDRESS(), protocolFeeBurn);
        }
        if (protocolFeeKeep > 0) {
            bountyEscrow.withdrawUSDC(bountyEscrow.feeRecipient(), protocolFeeKeep);
        }
        if (reviewerFee > 0) {
            bountyEscrow.withdrawUSDC(b.assignedReviewer, reviewerFee);
        }

        _claimableHunter[bountyId] = hunter;
        _claimableHunterPayout[bountyId] = hunterPayout;

        _processBondsForPayout(bountyId, b);

        bountyEscrow.markSettled(bountyId);

        emit BountySettled(bountyId, hunter, hunterPayout, reviewerFee, protocolFeeBurn, protocolFeeKeep);
        emit VerdictAttested(bountyId, b.assignedReviewer, b.winningSubmissionId, "");
    }

    function _processRefund(uint256 bountyId, IBountyEscrow.Bounty memory b) internal {
        bountyEscrow.withdrawUSDC(b.sponsor, b.payoutMax);
        emit SponsorRefunded(bountyId, b.sponsor, b.payoutMax);

        _returnAllBonds(bountyId);

        bountyEscrow.markRefundedFromQueued(bountyId);
    }

    function _processBondsForPayout(uint256 bountyId, IBountyEscrow.Bounty memory b) internal {
        uint256[] memory subIds = bountyEscrow.getSubmissionIds(bountyId);
        uint256 returnedCount;
        uint256 totalReturned;

        for (uint256 i = 0; i < subIds.length; ++i) {
            uint256 sid = subIds[i];
            IBountyEscrow.Submission memory s = bountyEscrow.getSubmission(sid);

            if (s.isSlashed) {
                uint256 toReviewer = (s.paidBond * SLASH_REVIEWER_BPS) / BPS_DENOMINATOR;
                uint256 toTreasury = (s.paidBond * SLASH_TREASURY_BPS) / BPS_DENOMINATOR;
                uint256 toBurn = s.paidBond - toReviewer - toTreasury;

                if (toReviewer > 0) {
                    bountyEscrow.withdrawBounty(b.assignedReviewer, toReviewer);
                }
                if (toTreasury > 0) {
                    bountyEscrow.withdrawBounty(bountyEscrow.feeRecipient(), toTreasury);
                }
                if (toBurn > 0) {
                    bountyEscrow.withdrawBountyToBurn(toBurn);
                }
                emit BondSlashed(bountyId, sid, s.paidBond, toReviewer, toTreasury, toBurn);
            } else {
                bountyEscrow.withdrawBounty(s.submitter, s.paidBond);
                returnedCount++;
                totalReturned += s.paidBond;
            }
        }

        if (returnedCount > 0) {
            emit BondsReturned(bountyId, returnedCount, totalReturned);
        }
    }

    function _returnAllBonds(uint256 bountyId) internal {
        uint256[] memory subIds = bountyEscrow.getSubmissionIds(bountyId);
        uint256 returnedCount;
        uint256 totalReturned;

        for (uint256 i = 0; i < subIds.length; ++i) {
            IBountyEscrow.Submission memory s = bountyEscrow.getSubmission(subIds[i]);
            bountyEscrow.withdrawBounty(s.submitter, s.paidBond);
            returnedCount++;
            totalReturned += s.paidBond;
        }

        if (returnedCount > 0) {
            emit BondsReturned(bountyId, returnedCount, totalReturned);
        }
    }

    function _effectiveProtocolFeeBps(address sponsor) internal view returns (uint256) {
        if (sponsorDiscountThreshold == 0) return PROTOCOL_FEE_BPS;
        if (BOUNTY.balanceOf(sponsor) >= sponsorDiscountThreshold) return sponsorDiscountedFeeBps;
        return PROTOCOL_FEE_BPS;
    }
}
