// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IBountyEscrow } from "../src/interfaces/IBountyEscrow.sol";
import { IVerdictModule } from "../src/interfaces/IVerdictModule.sol";
import { BaseTest } from "./Base.t.sol";

contract E2ETest is BaseTest {
    function test_fullHappyPath_5submissions_winner3_slashed5() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);

        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        IBountyEscrow.Bounty memory bAfterAccept = escrow.getBounty(bountyId);
        assertEq(uint8(bAfterAccept.state), uint8(IBountyEscrow.BountyState.InReview));
        assertEq(bAfterAccept.assignedReviewer, reviewer);

        uint256 burnBountyBefore = bounty.balanceOf(address(0xdEaD));

        uint256 sid1 = _submit(hunter1, bountyId);
        uint256 sid2 = _submit(hunter2, bountyId);
        uint256 sid3 = _submit(hunter3, bountyId);
        uint256 sid4 = _submit(hunter4, bountyId);
        uint256 sid5 = _submit(hunter5, bountyId);

        uint256 expectedAboveBaseBurn;
        uint256 mul = 10_000;
        for (uint256 i = 0; i < 5; ++i) {
            uint256 totalCost = (DEFAULT_BASE_BOND * mul) / 10_000;
            expectedAboveBaseBurn += (totalCost - DEFAULT_BASE_BOND);
            mul = (mul * 12_500) / 10_000;
        }
        assertEq(bounty.balanceOf(address(0xdEaD)) - burnBountyBefore, expectedAboveBaseBurn);

        uint256[] memory slashed = new uint256[](1);
        slashed[0] = sid5;

        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey, bountyId, sid3, slashed, keccak256("citations+reasoning"), 0);
        verdictModule.submitVerdict(v, sig);

        IBountyEscrow.Bounty memory bAfterVerdict = escrow.getBounty(bountyId);
        assertEq(uint8(bAfterVerdict.state), uint8(IBountyEscrow.BountyState.Queued));
        assertEq(bAfterVerdict.winningSubmissionId, sid3);
        assertTrue(escrow.getSubmission(sid5).isSlashed);

        vm.warp(block.timestamp + DEFAULT_CHALLENGE_WINDOW + 1);

        uint256 sponsorUsdcBefore = usdc.balanceOf(sponsor);
        uint256 reviewerUsdcBefore = usdc.balanceOf(reviewer);
        uint256 feeRecipUsdcBefore = usdc.balanceOf(feeRecipient);
        uint256 burnUsdcBefore = usdc.balanceOf(address(0xdEaD));

        uint256 reviewerBountyBefore = bounty.balanceOf(reviewer);
        uint256 feeRecipBountyBefore = bounty.balanceOf(feeRecipient);
        uint256 burnBountyMid = bounty.balanceOf(address(0xdEaD));

        settlementModule.settle(bountyId);

        assertEq(usdc.balanceOf(sponsor), sponsorUsdcBefore);
        assertEq(usdc.balanceOf(address(0xdEaD)) - burnUsdcBefore, 5 * 10 ** 6);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipUsdcBefore, 5 * 10 ** 6);
        assertEq(usdc.balanceOf(reviewer) - reviewerUsdcBefore, 30 * 10 ** 6);

        (address claimableTo, uint256 claimableAmt) = settlementModule.getClaimable(bountyId);
        assertEq(claimableTo, hunter3);
        assertEq(claimableAmt, 960 * 10 ** 6);

        uint256 expectedSlashReviewer = (DEFAULT_BASE_BOND * 4000) / 10_000;
        uint256 expectedSlashTreasury = (DEFAULT_BASE_BOND * 3000) / 10_000;
        uint256 expectedSlashBurn = DEFAULT_BASE_BOND - expectedSlashReviewer - expectedSlashTreasury;

        assertEq(bounty.balanceOf(reviewer) - reviewerBountyBefore, expectedSlashReviewer);
        assertEq(bounty.balanceOf(feeRecipient) - feeRecipBountyBefore, expectedSlashTreasury);
        assertEq(bounty.balanceOf(address(0xdEaD)) - burnBountyMid, expectedSlashBurn);

        IBountyEscrow.Bounty memory bSettled = escrow.getBounty(bountyId);
        assertEq(uint8(bSettled.state), uint8(IBountyEscrow.BountyState.Settled));

        uint256 hunterUsdcBefore = usdc.balanceOf(hunter3);
        vm.prank(hunter3);
        settlementModule.claim(bountyId);

        assertEq(usdc.balanceOf(hunter3) - hunterUsdcBefore, 960 * 10 ** 6);

        IBountyEscrow.Bounty memory bClaimed = escrow.getBounty(bountyId);
        assertEq(uint8(bClaimed.state), uint8(IBountyEscrow.BountyState.Claimed));

        sid1;
        sid2;
        sid4;
    }

    function test_e2e_poolClaim_afterReject() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);

        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _registerReviewer(reviewer2, MIN_REVIEWER_BOND);

        vm.prank(reviewer);
        verdictModule.rejectAssignment(bountyId);

        vm.prank(reviewer2);
        verdictModule.claimPoolBounty(bountyId);

        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory slashed = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey2, bountyId, sid, slashed, keccak256("a"), 0);
        verdictModule.submitVerdict(v, sig);

        vm.warp(block.timestamp + DEFAULT_CHALLENGE_WINDOW + 1);
        settlementModule.settle(bountyId);

        uint256 expectedReviewerFee = (DEFAULT_PAYOUT_MAX * 300) / 10_000;
        assertEq(usdc.balanceOf(reviewer2), expectedReviewerFee);

        vm.prank(hunter1);
        settlementModule.claim(bountyId);
    }

    function test_e2e_disputeOverturned_refundsSponsor() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory empty = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey, bountyId, sid, empty, keccak256("a"), 0);
        verdictModule.submitVerdict(v, sig);

        vm.prank(challenger);
        escrow.dispute(bountyId);

        IBountyEscrow.Bounty memory bDisputed = escrow.getBounty(bountyId);
        assertEq(uint8(bDisputed.state), uint8(IBountyEscrow.BountyState.Disputed));

        vm.prank(admin);
        escrow.resolveDispute(bountyId, false);

        uint256 sponsorBalBefore = usdc.balanceOf(sponsor);
        uint256 hunterBondBefore = bounty.balanceOf(hunter1);

        settlementModule.settle(bountyId);

        assertEq(usdc.balanceOf(sponsor) - sponsorBalBefore, DEFAULT_PAYOUT_MAX);
        assertEq(bounty.balanceOf(hunter1) - hunterBondBefore, DEFAULT_BASE_BOND);

        IBountyEscrow.Bounty memory bRefunded = escrow.getBounty(bountyId);
        assertEq(uint8(bRefunded.state), uint8(IBountyEscrow.BountyState.Refunded));
    }

    function test_e2e_disputeUpheld_paysHunter() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory empty = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey, bountyId, sid, empty, keccak256("a"), 0);
        verdictModule.submitVerdict(v, sig);

        vm.prank(challenger);
        escrow.dispute(bountyId);

        vm.prank(admin);
        escrow.resolveDispute(bountyId, true);

        settlementModule.settle(bountyId);

        (address claimableTo, uint256 amount) = settlementModule.getClaimable(bountyId);
        assertEq(claimableTo, hunter1);
        assertEq(amount, 960 * 10 ** 6);

        vm.prank(hunter1);
        settlementModule.claim(bountyId);

        assertEq(usdc.balanceOf(hunter1), 960 * 10 ** 6);
    }
}
