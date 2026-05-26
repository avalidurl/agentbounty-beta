// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {IBountyEscrow} from "../src/interfaces/IBountyEscrow.sol";
import {IVerdictModule} from "../src/interfaces/IVerdictModule.sol";
import {BountyEscrow} from "../src/BountyEscrow.sol";

/// @notice Stress + edge-case tests for the multi-submission EIP-1559
///         bond escalator path.
contract BountyEscrowMultiSubmissionTest is BaseTest {
    function _expectedBondAt(uint256 idx) internal pure returns (uint256) {
        uint256 mul = 10_000;
        for (uint256 i = 0; i < idx; ++i) {
            mul = (mul * 12_500) / 10_000;
        }
        return (DEFAULT_BASE_BOND * mul) / 10_000;
    }

    function test_currentBondCost_matchesEscalatorFormula() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        for (uint256 i = 0; i < 5; ++i) {
            (uint256 totalCost, uint256 baseBond, uint256 burnAbove) = escrow.currentBondCost(bountyId);
            assertEq(baseBond, DEFAULT_BASE_BOND);
            assertEq(totalCost, _expectedBondAt(i));
            assertEq(burnAbove, totalCost - DEFAULT_BASE_BOND);

            address h = address(uint160(0x20000 + i));
            vm.prank(admin);
            bounty.mint(h, totalCost * 10);
            vm.startPrank(h);
            bounty.approve(address(escrow), totalCost);
            escrow.submit(bountyId, keccak256(abi.encodePacked("a", i)), keccak256(abi.encodePacked("e", i)));
            vm.stopPrank();
        }
    }

    function test_submit_burnIsCumulativelyAccurate() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        uint256 burnBefore = bounty.balanceOf(address(0xdEaD));
        uint256 expectedTotalAboveBase;

        for (uint256 i = 0; i < 6; ++i) {
            uint256 expected = _expectedBondAt(i);
            address h = address(uint160(0x30000 + i));
            vm.prank(admin);
            bounty.mint(h, expected * 10);
            vm.startPrank(h);
            bounty.approve(address(escrow), expected);
            escrow.submit(bountyId, keccak256(abi.encodePacked("a", i)), keccak256(abi.encodePacked("e", i)));
            vm.stopPrank();
            expectedTotalAboveBase += expected - DEFAULT_BASE_BOND;
        }

        uint256 burnAfter = bounty.balanceOf(address(0xdEaD));
        assertEq(burnAfter - burnBefore, expectedTotalAboveBase, "cumulative burn matches sum of above-base bonds");
    }

    function test_submit_revertsWhenInsufficientBondPosted() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        _submit(hunter1, bountyId);

        (uint256 totalCost,,) = escrow.currentBondCost(bountyId);
        vm.startPrank(hunter2);
        bounty.approve(address(escrow), totalCost - 1);
        vm.expectRevert();
        escrow.submit(bountyId, keccak256("late"), keccak256("late-ev"));
        vm.stopPrank();
    }

    function test_settle_withMultipleSlashed_correctSplit() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        _submit(hunter1, bountyId);
        _submit(hunter2, bountyId);
        _submit(hunter3, bountyId);

        uint256[] memory slashed = new uint256[](2);
        slashed[0] = 2;
        slashed[1] = 3;

        uint256 reviewerBefore = bounty.balanceOf(reviewer);
        uint256 feeRecipBefore = bounty.balanceOf(feeRecipient);
        uint256 burnBefore = bounty.balanceOf(address(0xdEaD));

        (IVerdictModule.Verdict memory v, bytes memory sig) = _signVerdict(
            reviewerKey, bountyId, 1, slashed, keccak256("a"), 0
        );
        verdictModule.submitVerdict(v, sig);
        vm.warp(block.timestamp + DEFAULT_CHALLENGE_WINDOW + 1);
        settlementModule.settle(bountyId);

        uint256 totalSlashedBase = DEFAULT_BASE_BOND * 2;
        uint256 expectedReviewer = (totalSlashedBase * 4_000) / 10_000;
        uint256 expectedTreasury = (totalSlashedBase * 3_000) / 10_000;
        uint256 expectedBurn = totalSlashedBase - expectedReviewer - expectedTreasury;

        assertEq(bounty.balanceOf(reviewer) - reviewerBefore, expectedReviewer);
        assertEq(bounty.balanceOf(feeRecipient) - feeRecipBefore, expectedTreasury);
        assertEq(bounty.balanceOf(address(0xdEaD)) - burnBefore, expectedBurn);
    }

    function test_settle_returnsAllHonestSubmitterBondsAtBaseAmount() public {
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        uint256 h1Before = bounty.balanceOf(hunter1);
        uint256 h2Before = bounty.balanceOf(hunter2);
        uint256 h3Before = bounty.balanceOf(hunter3);

        _submit(hunter1, bountyId);
        _submit(hunter2, bountyId);
        _submit(hunter3, bountyId);

        uint256[] memory slashed = new uint256[](1);
        slashed[0] = 3;

        (IVerdictModule.Verdict memory v, bytes memory sig) = _signVerdict(
            reviewerKey, bountyId, 1, slashed, keccak256("a"), 0
        );
        verdictModule.submitVerdict(v, sig);
        vm.warp(block.timestamp + DEFAULT_CHALLENGE_WINDOW + 1);
        settlementModule.settle(bountyId);

        uint256 e0 = _expectedBondAt(0);
        uint256 e1 = _expectedBondAt(1);

        assertEq(h1Before - bounty.balanceOf(hunter1), e0 - DEFAULT_BASE_BOND, "hunter1 paid only above-base burn");
        assertEq(h2Before - bounty.balanceOf(hunter2), e1 - DEFAULT_BASE_BOND, "hunter2 paid only above-base burn");
        assertGt(h3Before - bounty.balanceOf(hunter3), 0);
    }
}
