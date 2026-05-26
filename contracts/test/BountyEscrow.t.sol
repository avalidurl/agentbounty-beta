// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BountyEscrow } from "../src/BountyEscrow.sol";
import { IBountyEscrow } from "../src/interfaces/IBountyEscrow.sol";
import { BaseTest } from "./Base.t.sol";

contract BountyEscrowTest is BaseTest {
    function test_createBounty_success() public {
        vm.prank(sponsor);
        uint256 bountyId = escrow.createBounty(
            DEFAULT_PAYOUT_MAX,
            DEFAULT_BASE_BOND,
            DEFAULT_REVIEW_WINDOW,
            DEFAULT_CHALLENGE_WINDOW,
            DEFAULT_SPEC_HASH,
            reviewer
        );

        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(b.sponsor, sponsor);
        assertEq(b.proposedReviewer, reviewer);
        assertEq(b.payoutMax, DEFAULT_PAYOUT_MAX);
        assertEq(b.baseBond, DEFAULT_BASE_BOND);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.Draft));
        assertEq(b.specHash, DEFAULT_SPEC_HASH);
    }

    function test_createBounty_revertsOnZeroPayout() public {
        vm.prank(sponsor);
        vm.expectRevert(BountyEscrow.InvalidPayoutMax.selector);
        escrow.createBounty(
            0, DEFAULT_BASE_BOND, DEFAULT_REVIEW_WINDOW, DEFAULT_CHALLENGE_WINDOW, DEFAULT_SPEC_HASH, reviewer
        );
    }

    function test_createBounty_revertsOnZeroBaseBond() public {
        vm.prank(sponsor);
        vm.expectRevert(BountyEscrow.InvalidBaseBond.selector);
        escrow.createBounty(
            DEFAULT_PAYOUT_MAX, 0, DEFAULT_REVIEW_WINDOW, DEFAULT_CHALLENGE_WINDOW, DEFAULT_SPEC_HASH, reviewer
        );
    }

    function test_createBounty_revertsOnExcessiveReviewWindow() public {
        vm.prank(sponsor);
        vm.expectRevert(BountyEscrow.InvalidReviewWindow.selector);
        escrow.createBounty(
            DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND, 15 days, DEFAULT_CHALLENGE_WINDOW, DEFAULT_SPEC_HASH, reviewer
        );
    }

    function test_createBounty_revertsOnExcessiveChallengeWindow() public {
        vm.prank(sponsor);
        vm.expectRevert(BountyEscrow.InvalidChallengeWindow.selector);
        escrow.createBounty(
            DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND, DEFAULT_REVIEW_WINDOW, 8 days, DEFAULT_SPEC_HASH, reviewer
        );
    }

    function test_createBounty_revertsOnEmptySpecHash() public {
        vm.prank(sponsor);
        vm.expectRevert(BountyEscrow.InvalidSpecHash.selector);
        escrow.createBounty(
            DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND, DEFAULT_REVIEW_WINDOW, DEFAULT_CHALLENGE_WINDOW, bytes32(0), reviewer
        );
    }

    function test_fundBounty_transfersUSDC() public {
        vm.prank(sponsor);
        uint256 bountyId = escrow.createBounty(
            DEFAULT_PAYOUT_MAX,
            DEFAULT_BASE_BOND,
            DEFAULT_REVIEW_WINDOW,
            DEFAULT_CHALLENGE_WINDOW,
            DEFAULT_SPEC_HASH,
            reviewer
        );

        uint256 sponsorBalBefore = usdc.balanceOf(sponsor);
        uint256 escrowBalBefore = usdc.balanceOf(address(escrow));

        vm.startPrank(sponsor);
        usdc.approve(address(escrow), DEFAULT_PAYOUT_MAX);
        escrow.fundBounty(bountyId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(sponsor), sponsorBalBefore - DEFAULT_PAYOUT_MAX);
        assertEq(usdc.balanceOf(address(escrow)), escrowBalBefore + DEFAULT_PAYOUT_MAX);

        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.Funded));
        assertGt(b.fundedAt, 0);
    }

    function test_fundBounty_revertsForNonSponsor() public {
        vm.prank(sponsor);
        uint256 bountyId = escrow.createBounty(
            DEFAULT_PAYOUT_MAX,
            DEFAULT_BASE_BOND,
            DEFAULT_REVIEW_WINDOW,
            DEFAULT_CHALLENGE_WINDOW,
            DEFAULT_SPEC_HASH,
            reviewer
        );

        vm.startPrank(hunter1);
        usdc.approve(address(escrow), DEFAULT_PAYOUT_MAX);
        vm.expectRevert(BountyEscrow.NotSponsor.selector);
        escrow.fundBounty(bountyId);
        vm.stopPrank();
    }

    function test_cancel_returnsUSDCToSponsor() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);

        uint256 sponsorBalBefore = usdc.balanceOf(sponsor);
        vm.prank(sponsor);
        escrow.cancel(bountyId);

        assertEq(usdc.balanceOf(sponsor), sponsorBalBefore + DEFAULT_PAYOUT_MAX);
        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.Refunded));
    }

    function test_cancel_revertsOnceReviewerAccepts() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        vm.prank(sponsor);
        vm.expectRevert(BountyEscrow.WrongState.selector);
        escrow.cancel(bountyId);
    }

    function test_cancel_revertsAfterSubmissions() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        _submit(hunter1, bountyId);

        vm.prank(sponsor);
        vm.expectRevert(BountyEscrow.WrongState.selector);
        escrow.cancel(bountyId);
    }

    function test_refund_succeedsAfterRefundAfter() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);

        vm.warp(block.timestamp + 31 days);

        uint256 sponsorBalBefore = usdc.balanceOf(sponsor);
        vm.prank(sponsor);
        escrow.refund(bountyId);

        assertEq(usdc.balanceOf(sponsor), sponsorBalBefore + DEFAULT_PAYOUT_MAX);
        IBountyEscrow.Bounty memory b = escrow.getBounty(bountyId);
        assertEq(uint8(b.state), uint8(IBountyEscrow.BountyState.Refunded));
    }

    function test_refund_revertsBeforeRefundAfter() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);

        vm.prank(sponsor);
        vm.expectRevert(BountyEscrow.RefundTooEarly.selector);
        escrow.refund(bountyId);
    }

    function test_submit_revertsInWrongState() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);

        vm.startPrank(hunter1);
        bounty.approve(address(escrow), DEFAULT_BASE_BOND);
        vm.expectRevert(BountyEscrow.WrongState.selector);
        escrow.submit(bountyId, keccak256("a"), keccak256("e"));
        vm.stopPrank();
    }

    function test_submit_succeedsInReview() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        uint256 sid = _submit(hunter1, bountyId);

        IBountyEscrow.Submission memory s = escrow.getSubmission(sid);
        assertEq(s.bountyId, bountyId);
        assertEq(s.submitter, hunter1);
        assertEq(s.paidBond, DEFAULT_BASE_BOND);
        assertFalse(s.isSlashed);
    }

    function test_submit_burnsAboveBaseOnSecondSubmission() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        _submit(hunter1, bountyId);

        (uint256 totalCost2, uint256 baseBond2, uint256 burnAmount2) = escrow.currentBondCost(bountyId);
        assertEq(baseBond2, DEFAULT_BASE_BOND);
        assertEq(totalCost2, (DEFAULT_BASE_BOND * 12_500) / 10_000);
        assertEq(burnAmount2, totalCost2 - baseBond2);

        uint256 burnBalBefore = bounty.balanceOf(address(0xdEaD));
        _submit(hunter2, bountyId);
        uint256 burnBalAfter = bounty.balanceOf(address(0xdEaD));

        assertEq(burnBalAfter - burnBalBefore, burnAmount2);
    }

    function test_submit_revertsAtMaxSubmissions() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        for (uint256 i = 0; i < escrow.MAX_SUBMISSIONS(); ++i) {
            address hunter = address(uint160(0x10000 + i));
            vm.prank(admin);
            bounty.mint(hunter, 100_000_000 ether);
            (uint256 totalCost,,) = escrow.currentBondCost(bountyId);
            vm.startPrank(hunter);
            bounty.approve(address(escrow), totalCost);
            escrow.submit(bountyId, keccak256(abi.encodePacked(i)), keccak256(abi.encodePacked(i, "ev")));
            vm.stopPrank();
        }

        (uint256 finalCost,,) = escrow.currentBondCost(bountyId);
        vm.prank(admin);
        bounty.mint(hunter5, finalCost);
        vm.startPrank(hunter5);
        bounty.approve(address(escrow), finalCost);
        vm.expectRevert(BountyEscrow.MaxSubmissionsReached.selector);
        escrow.submit(bountyId, keccak256("late"), keccak256("late-ev"));
        vm.stopPrank();
    }

    function test_pause_blocksNewBounties() public {
        vm.prank(admin);
        escrow.pause();

        vm.prank(sponsor);
        vm.expectRevert();
        escrow.createBounty(
            DEFAULT_PAYOUT_MAX,
            DEFAULT_BASE_BOND,
            DEFAULT_REVIEW_WINDOW,
            DEFAULT_CHALLENGE_WINDOW,
            DEFAULT_SPEC_HASH,
            reviewer
        );
    }

    function test_unpause_restoresFunctionality() public {
        vm.startPrank(admin);
        escrow.pause();
        escrow.unpause();
        vm.stopPrank();

        vm.prank(sponsor);
        uint256 bountyId = escrow.createBounty(
            DEFAULT_PAYOUT_MAX,
            DEFAULT_BASE_BOND,
            DEFAULT_REVIEW_WINDOW,
            DEFAULT_CHALLENGE_WINDOW,
            DEFAULT_SPEC_HASH,
            reviewer
        );
        assertGt(bountyId, 0);
    }

    function test_setFeeRecipient_admin_only() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(admin);
        escrow.setFeeRecipient(newRecipient);
        assertEq(escrow.feeRecipient(), newRecipient);

        vm.prank(sponsor);
        vm.expectRevert();
        escrow.setFeeRecipient(makeAddr("attempt"));
    }
}
