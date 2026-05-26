// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { VerdictModule } from "../src/VerdictModule.sol";
import { IBountyEscrow } from "../src/interfaces/IBountyEscrow.sol";
import { IVerdictModule } from "../src/interfaces/IVerdictModule.sol";
import { BaseTest } from "./Base.t.sol";

contract VerdictModuleTest is BaseTest {
    function test_registerReviewer_locksBOUNTY() public {
        uint256 reviewerBalBefore = bounty.balanceOf(reviewer);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);

        IVerdictModule.Reviewer memory r = verdictModule.getReviewer(reviewer);
        assertTrue(r.isRegistered);
        assertEq(r.lockedBond, MIN_REVIEWER_BOND);
        assertEq(bounty.balanceOf(reviewer), reviewerBalBefore - MIN_REVIEWER_BOND);
        assertEq(bounty.balanceOf(address(verdictModule)), MIN_REVIEWER_BOND);
    }

    function test_registerReviewer_revertsBelowMinimum() public {
        vm.startPrank(reviewer);
        bounty.approve(address(verdictModule), MIN_REVIEWER_BOND - 1);
        vm.expectRevert(VerdictModule.InsufficientBond.selector);
        verdictModule.registerReviewer(MIN_REVIEWER_BOND - 1);
        vm.stopPrank();
    }

    function test_registerReviewer_revertsOnDoubleRegister() public {
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);

        vm.startPrank(reviewer);
        bounty.approve(address(verdictModule), MIN_REVIEWER_BOND);
        vm.expectRevert(VerdictModule.AlreadyRegistered.selector);
        verdictModule.registerReviewer(MIN_REVIEWER_BOND);
        vm.stopPrank();
    }

    function test_topUpBond_increasesLocked() public {
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);

        uint256 topUp = 500_000 ether;
        vm.startPrank(reviewer);
        bounty.approve(address(verdictModule), topUp);
        verdictModule.topUpBond(topUp);
        vm.stopPrank();

        IVerdictModule.Reviewer memory r = verdictModule.getReviewer(reviewer);
        assertEq(r.lockedBond, MIN_REVIEWER_BOND + topUp);
    }

    function test_unregisterReviewer_returnsBOUNTY() public {
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);

        uint256 reviewerBalBefore = bounty.balanceOf(reviewer);
        vm.prank(reviewer);
        verdictModule.unregisterReviewer();

        IVerdictModule.Reviewer memory r = verdictModule.getReviewer(reviewer);
        assertFalse(r.isRegistered);
        assertEq(r.lockedBond, 0);
        assertEq(bounty.balanceOf(reviewer), reviewerBalBefore + MIN_REVIEWER_BOND);
    }

    function test_requiredBondForBounty_floorWhenSmall() public view {
        uint256 required = verdictModule.requiredBondForBounty(100 * 10 ** 6);
        assertEq(required, MIN_REVIEWER_BOND);
    }

    function test_requiredBondForBounty_scalesWhenLarge() public view {
        uint256 huge = MIN_REVIEWER_BOND * 200;
        uint256 required = verdictModule.requiredBondForBounty(huge);
        assertEq(required, (huge * 100) / 10_000);
        assertGt(required, MIN_REVIEWER_BOND);
    }

    function test_acceptAssignment_succeedsForProposedReviewer() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);

        vm.prank(reviewer);
        verdictModule.acceptAssignment(bountyId);

        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.InReview));
        assertEq(b.assignedReviewer, reviewer);
        assertTrue(verdictModule.isAssigned(bountyId, reviewer));
    }

    function test_acceptAssignment_revertsForNonProposedReviewer() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer2, MIN_REVIEWER_BOND);

        vm.prank(reviewer2);
        vm.expectRevert(VerdictModule.NotProposedReviewer.selector);
        verdictModule.acceptAssignment(bountyId);
    }

    function test_rejectAssignment_clearsProposedReviewer() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);

        vm.prank(reviewer);
        verdictModule.rejectAssignment(bountyId);

        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(b.proposedReviewer, address(0));
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.Funded));
    }

    function test_claimPoolBounty_succeedsAfterRejection() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer2, MIN_REVIEWER_BOND);

        vm.prank(reviewer);
        verdictModule.rejectAssignment(bountyId);

        vm.prank(reviewer2);
        verdictModule.claimPoolBounty(bountyId);

        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.InReview));
        assertEq(b.assignedReviewer, reviewer2);
    }

    function test_claimPoolBounty_succeedsAfterRejectWindow() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer2, MIN_REVIEWER_BOND);

        vm.warp(block.timestamp + 13 hours);

        vm.prank(reviewer2);
        verdictModule.claimPoolBounty(bountyId);

        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.InReview));
        assertEq(b.assignedReviewer, reviewer2);
    }

    function test_claimPoolBounty_revertsBeforeWindowExpiry() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer2, MIN_REVIEWER_BOND);

        vm.prank(reviewer2);
        vm.expectRevert(VerdictModule.PoolNotOpen.selector);
        verdictModule.claimPoolBounty(bountyId);
    }

    function test_submitVerdict_acceptsValidSignature() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory slashed = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) = _signVerdict(
            reviewerKey, bountyId, sid, slashed, keccak256("evidence-anchor"), verdictModule.reviewerNonce(reviewer)
        );

        verdictModule.submitVerdict(v, sig);

        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.Queued));
        assertEq(b.winningSubmissionId, sid);
        assertEq(verdictModule.reviewerNonce(reviewer), 1);
    }

    function test_submitVerdict_revertsOnExpired() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory slashed = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey, bountyId, sid, slashed, keccak256("e"), 0);

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(VerdictModule.VerdictExpired.selector);
        verdictModule.submitVerdict(v, sig);
    }

    function test_submitVerdict_revertsOnBadNonce() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory slashed = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey, bountyId, sid, slashed, keccak256("e"), 5);

        vm.expectRevert(VerdictModule.VerdictBadNonce.selector);
        verdictModule.submitVerdict(v, sig);
    }

    function test_submitVerdict_revertsOnWrongSigner() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid = _submit(hunter1, bountyId);

        uint256[] memory slashed = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey2, bountyId, sid, slashed, keccak256("e"), 0);

        vm.expectRevert(VerdictModule.VerdictBadSigner.selector);
        verdictModule.submitVerdict(v, sig);
    }

    function test_submitVerdict_recordsSlashedSubmissions() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        uint256 sid1 = _submit(hunter1, bountyId);
        uint256 sid2 = _submit(hunter2, bountyId);
        uint256 sid3 = _submit(hunter3, bountyId);

        uint256[] memory slashed = new uint256[](1);
        slashed[0] = sid3;

        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey, bountyId, sid1, slashed, keccak256("e"), 0);
        verdictModule.submitVerdict(v, sig);

        assertFalse(escrow.getSubmission(sid1).isSlashed);
        assertFalse(escrow.getSubmission(sid2).isSlashed);
        assertTrue(escrow.getSubmission(sid3).isSlashed);
    }
}
