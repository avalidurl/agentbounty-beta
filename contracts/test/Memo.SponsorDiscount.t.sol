// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SettlementModule } from "../src/SettlementModule.sol";
import { IBountyEscrow } from "../src/interfaces/IBountyEscrow.sol";
import { IVerdictModule } from "../src/interfaces/IVerdictModule.sol";
import { BaseTest } from "./Base.t.sol";

/// @notice Memo invariant: sponsor BOUNTY discount is admin-flippable and
///         applied at settlement based on sponsor's BOUNTY balance at the
///         moment of settle().
contract MemoSponsorDiscountTest is BaseTest {
    function _runBountyAndCaptureFee(
        address theSponsor
    ) internal returns (uint256 hunterPayout) {
        uint256 bountyId = _createAndFund(theSponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory empty = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey, bountyId, sid, empty, keccak256("a"), 0);
        verdictModule.submitVerdict(v, sig);
        vm.warp(block.timestamp + DEFAULT_CHALLENGE_WINDOW + 1);
        settlementModule.settle(bountyId);

        (, hunterPayout) = settlementModule.getClaimable(bountyId);
    }

    function test_setSponsorDiscount_revertsForNonAdmin() public {
        vm.prank(sponsor);
        vm.expectRevert();
        settlementModule.setSponsorDiscount(50_000 ether, 50);
    }

    function test_invariant_default_discountDisabled() public view {
        assertEq(settlementModule.sponsorDiscountThreshold(), 0);
        assertEq(settlementModule.sponsorDiscountedFeeBps(), 50);
    }

    function test_discount_appliesWhenSponsorAboveThreshold() public {
        vm.prank(admin);
        settlementModule.setSponsorDiscount(100_000_000 ether, 50);

        uint256 hunterPayoutDiscounted = _runBountyAndCaptureFee(sponsor);

        uint256 expectedFeeAtDiscount = (DEFAULT_PAYOUT_MAX * 50) / 10_000;
        uint256 expectedReviewerFee = (DEFAULT_PAYOUT_MAX * 300) / 10_000;
        uint256 expected = DEFAULT_PAYOUT_MAX - expectedFeeAtDiscount - expectedReviewerFee;

        assertEq(hunterPayoutDiscounted, expected);
    }

    function test_discount_skippedWhenSponsorBelowThreshold() public {
        vm.prank(admin);
        settlementModule.setSponsorDiscount(1_000_000_000 ether, 50);

        uint256 hunterPayoutFull = _runBountyAndCaptureFee(sponsor);

        uint256 expectedFee = (DEFAULT_PAYOUT_MAX * 100) / 10_000;
        uint256 expectedReviewerFee = (DEFAULT_PAYOUT_MAX * 300) / 10_000;
        uint256 expected = DEFAULT_PAYOUT_MAX - expectedFee - expectedReviewerFee;

        assertEq(hunterPayoutFull, expected);
    }

    function test_discount_flipReenable_changesBehavior() public {
        vm.startPrank(admin);
        settlementModule.setSponsorDiscount(100_000_000 ether, 50);
        settlementModule.setSponsorDiscount(0, 100);
        vm.stopPrank();

        uint256 hunterPayoutFullAgain = _runBountyAndCaptureFee(sponsor);

        uint256 expectedFee = (DEFAULT_PAYOUT_MAX * 100) / 10_000;
        uint256 expectedReviewerFee = (DEFAULT_PAYOUT_MAX * 300) / 10_000;
        uint256 expected = DEFAULT_PAYOUT_MAX - expectedFee - expectedReviewerFee;

        assertEq(hunterPayoutFullAgain, expected);
    }
}
