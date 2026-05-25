// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {IBountyEscrow} from "../src/interfaces/IBountyEscrow.sol";
import {IVerdictModule} from "../src/interfaces/IVerdictModule.sol";
import {SettlementModule} from "../src/SettlementModule.sol";

contract SettlementModuleTest is BaseTest {
    function _completeBountyToQueued(uint256 bountyId, uint256[] memory submissionIds, uint256 winningSid)
        internal
    {
        uint256[] memory slashed = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) = _signVerdict(
            reviewerKey,
            bountyId,
            winningSid,
            slashed,
            keccak256("anchor"),
            verdictModule.reviewerNonce(reviewer)
        );
        verdictModule.submitVerdict(v, sig);
        submissionIds; // suppress unused
    }

    function _waitChallengeWindow() internal {
        vm.warp(block.timestamp + DEFAULT_CHALLENGE_WINDOW + 1);
    }

    function test_settle_splitsPayoutCorrectly() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory _submissions = new uint256[](1);
        _submissions[0] = sid;
        _completeBountyToQueued(bountyId, _submissions, sid);
        _waitChallengeWindow();

        uint256 burnUsdcBefore = usdc.balanceOf(address(0xdEaD));
        uint256 feeRecipUsdcBefore = usdc.balanceOf(feeRecipient);
        uint256 reviewerUsdcBefore = usdc.balanceOf(reviewer);

        settlementModule.settle(bountyId);

        uint256 expectedProtocolFee = (DEFAULT_PAYOUT_MAX * 100) / 10_000;
        uint256 expectedBurn = (expectedProtocolFee * 5_000) / 10_000;
        uint256 expectedKeep = expectedProtocolFee - expectedBurn;
        uint256 expectedReviewerFee = (DEFAULT_PAYOUT_MAX * 300) / 10_000;
        uint256 expectedHunter = DEFAULT_PAYOUT_MAX - expectedProtocolFee - expectedReviewerFee;

        assertEq(usdc.balanceOf(address(0xdEaD)) - burnUsdcBefore, expectedBurn);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipUsdcBefore, expectedKeep);
        assertEq(usdc.balanceOf(reviewer) - reviewerUsdcBefore, expectedReviewerFee);

        (address claimable, uint256 amount) = settlementModule.getClaimable(bountyId);
        assertEq(claimable, hunter1);
        assertEq(amount, expectedHunter);

        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.Settled));
    }

    function test_claim_transfersToHunter() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory subs = new uint256[](1);
        subs[0] = sid;
        _completeBountyToQueued(bountyId, subs, sid);
        _waitChallengeWindow();

        settlementModule.settle(bountyId);

        uint256 hunterBalBefore = usdc.balanceOf(hunter1);
        uint256 expectedHunter = DEFAULT_PAYOUT_MAX
            - (DEFAULT_PAYOUT_MAX * 100) / 10_000
            - (DEFAULT_PAYOUT_MAX * 300) / 10_000;

        vm.prank(hunter1);
        settlementModule.claim(bountyId);

        assertEq(usdc.balanceOf(hunter1) - hunterBalBefore, expectedHunter);
        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.Claimed));
    }

    function test_claim_revertsForNonHunter() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory subs = new uint256[](1);
        subs[0] = sid;
        _completeBountyToQueued(bountyId, subs, sid);
        _waitChallengeWindow();

        settlementModule.settle(bountyId);

        vm.prank(hunter2);
        vm.expectRevert(SettlementModule.NotHunter.selector);
        settlementModule.claim(bountyId);
    }

    function test_settle_revertsBeforeChallengeWindow() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory subs = new uint256[](1);
        subs[0] = sid;
        _completeBountyToQueued(bountyId, subs, sid);

        vm.expectRevert(SettlementModule.ChallengeWindowActive.selector);
        settlementModule.settle(bountyId);
    }

    function test_settle_returnsBondsToHonestSubmitters() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        uint256 hunter1BondBefore = bounty.balanceOf(hunter1);
        uint256 hunter2BondBefore = bounty.balanceOf(hunter2);

        uint256 sid1 = _submit(hunter1, bountyId);
        uint256 sid2 = _submit(hunter2, bountyId);

        uint256[] memory slashed = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) = _signVerdict(
            reviewerKey, bountyId, sid1, slashed, keccak256("a"), 0
        );
        verdictModule.submitVerdict(v, sig);
        _waitChallengeWindow();
        settlementModule.settle(bountyId);

        assertEq(bounty.balanceOf(hunter1), hunter1BondBefore - 0);
        assertEq(bounty.balanceOf(hunter2), hunter2BondBefore - ((DEFAULT_BASE_BOND * 12_500) / 10_000) + DEFAULT_BASE_BOND);
        sid2;
    }

    function test_settle_slashedBondSplitsCorrectly() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        uint256 sid1 = _submit(hunter1, bountyId);
        uint256 sid2 = _submit(hunter2, bountyId);

        uint256 reviewerBountyBefore = bounty.balanceOf(reviewer);
        uint256 feeRecipBountyBefore = bounty.balanceOf(feeRecipient);
        uint256 burnBountyBefore = bounty.balanceOf(address(0xdEaD));

        uint256[] memory slashed = new uint256[](1);
        slashed[0] = sid2;
        (IVerdictModule.Verdict memory v, bytes memory sig) = _signVerdict(
            reviewerKey, bountyId, sid1, slashed, keccak256("a"), 0
        );
        verdictModule.submitVerdict(v, sig);
        _waitChallengeWindow();
        settlementModule.settle(bountyId);

        uint256 expectedToReviewer = (DEFAULT_BASE_BOND * 4_000) / 10_000;
        uint256 expectedToTreasury = (DEFAULT_BASE_BOND * 3_000) / 10_000;
        uint256 expectedToBurn = DEFAULT_BASE_BOND - expectedToReviewer - expectedToTreasury;

        assertEq(bounty.balanceOf(reviewer) - reviewerBountyBefore, expectedToReviewer);
        assertEq(bounty.balanceOf(feeRecipient) - feeRecipBountyBefore, expectedToTreasury);
        assertEq(bounty.balanceOf(address(0xdEaD)) - burnBountyBefore, expectedToBurn);
    }

    function test_settle_refundsSponsorOnRejectAll() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        _submit(hunter1, bountyId);

        uint256 sponsorUsdcBefore = usdc.balanceOf(sponsor);

        uint256[] memory empty = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) = _signVerdict(
            reviewerKey, bountyId, 0, empty, keccak256("rejectall"), 0
        );
        verdictModule.submitVerdict(v, sig);
        _waitChallengeWindow();
        settlementModule.settle(bountyId);

        assertEq(usdc.balanceOf(sponsor) - sponsorUsdcBefore, DEFAULT_PAYOUT_MAX);
        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.Refunded));
    }

    function test_setSponsorDiscount_updatesParams() public {
        vm.prank(admin);
        settlementModule.setSponsorDiscount(50_000 ether, 25);

        assertEq(settlementModule.sponsorDiscountThreshold(), 50_000 ether);
        assertEq(settlementModule.sponsorDiscountedFeeBps(), 25);
    }

    function test_settle_appliesSponsorDiscount() public {
        vm.prank(admin);
        settlementModule.setSponsorDiscount(100_000_000 ether, 50);

        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory empty = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) = _signVerdict(
            reviewerKey, bountyId, sid, empty, keccak256("a"), 0
        );
        verdictModule.submitVerdict(v, sig);
        _waitChallengeWindow();
        settlementModule.settle(bountyId);

        uint256 expectedProtocolFee = (DEFAULT_PAYOUT_MAX * 50) / 10_000;
        uint256 expectedReviewerFee = (DEFAULT_PAYOUT_MAX * 300) / 10_000;
        uint256 expectedHunter = DEFAULT_PAYOUT_MAX - expectedProtocolFee - expectedReviewerFee;

        (, uint256 claimable) = settlementModule.getClaimable(bountyId);
        assertEq(claimable, expectedHunter);
    }

    function test_settle_noDiscountWhenSponsorBelowThreshold() public {
        vm.prank(admin);
        settlementModule.setSponsorDiscount(1_000_000_000 ether, 50);

        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory empty = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) = _signVerdict(
            reviewerKey, bountyId, sid, empty, keccak256("a"), 0
        );
        verdictModule.submitVerdict(v, sig);
        _waitChallengeWindow();
        settlementModule.settle(bountyId);

        uint256 expectedProtocolFee = (DEFAULT_PAYOUT_MAX * 100) / 10_000;
        uint256 expectedReviewerFee = (DEFAULT_PAYOUT_MAX * 300) / 10_000;
        uint256 expectedHunter = DEFAULT_PAYOUT_MAX - expectedProtocolFee - expectedReviewerFee;

        (, uint256 claimable) = settlementModule.getClaimable(bountyId);
        assertEq(claimable, expectedHunter);
    }
}
