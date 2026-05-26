// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IBountyEscrow } from "../src/interfaces/IBountyEscrow.sol";
import { IVerdictModule } from "../src/interfaces/IVerdictModule.sol";
import { BaseTest } from "./Base.t.sol";

/// @notice Memo invariant: BOUNTY at the burn address (0xdEaD) is
///         monotonically non-decreasing across the protocol's lifecycle,
///         and a settled bounty with multiple submissions burns at least
///         the above-base submission bonds.
contract MemoSinkAccountingTest is BaseTest {
    address internal constant BURN = address(0xdEaD);

    function _initialBurn() internal view returns (uint256) {
        return bounty.balanceOf(BURN);
    }

    function test_invariant_burnOnlyGrows_acrossLifecycle() public {
        uint256 b0 = _initialBurn();
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);

        uint256 b1 = bounty.balanceOf(BURN);
        assertGe(b1, b0, "burn must not decrease at fund");

        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        uint256 b2 = bounty.balanceOf(BURN);
        assertGe(b2, b1, "burn must not decrease at registerReviewer");

        _acceptAssignment(reviewer, bountyId);
        uint256 b3 = bounty.balanceOf(BURN);
        assertGe(b3, b2, "burn must not decrease at acceptAssignment");

        _submit(hunter1, bountyId);
        _submit(hunter2, bountyId);
        _submit(hunter3, bountyId);
        uint256 b4 = bounty.balanceOf(BURN);
        assertGe(b4, b3, "burn must not decrease across multi-submit");
        assertGt(b4, b3, "above-base submissions must contribute to burn");

        uint256[] memory slashed = new uint256[](1);
        slashed[0] = 3;
        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey, bountyId, 1, slashed, keccak256("a"), 0);
        verdictModule.submitVerdict(v, sig);
        uint256 b5 = bounty.balanceOf(BURN);
        assertGe(b5, b4, "burn must not decrease at verdict");

        vm.warp(block.timestamp + DEFAULT_CHALLENGE_WINDOW + 1);
        settlementModule.settle(bountyId);
        uint256 b6 = bounty.balanceOf(BURN);
        assertGe(b6, b5, "burn must not decrease at settle");
        assertGt(b6, b5, "slash share + USDC fee burn must contribute");
    }

    function test_invariant_supplyContraction_onAcceptedBounty() public {
        uint256 totalBefore = bounty.totalSupply();
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);

        _submit(hunter1, bountyId);
        _submit(hunter2, bountyId);

        uint256[] memory slashed = new uint256[](1);
        slashed[0] = 2;
        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey, bountyId, 1, slashed, keccak256("a"), 0);
        verdictModule.submitVerdict(v, sig);
        vm.warp(block.timestamp + DEFAULT_CHALLENGE_WINDOW + 1);
        settlementModule.settle(bountyId);

        uint256 burnedDelta = bounty.balanceOf(BURN);
        assertGt(burnedDelta, 0, "some BOUNTY must be at burn after settle");

        assertEq(
            bounty.totalSupply(), totalBefore, "ERC20 totalSupply unchanged; effective supply tracked via burn balance"
        );
    }

    function test_invariant_burnNeverShrinks_underRefund() public {
        uint256 b0 = _initialBurn();
        uint256 bountyId = _createAndFund(sponsor, reviewer, DEFAULT_PAYOUT_MAX, DEFAULT_BASE_BOND);
        _registerReviewer(reviewer, MIN_REVIEWER_BOND);
        _acceptAssignment(reviewer, bountyId);
        _submit(hunter1, bountyId);

        uint256 bMid = bounty.balanceOf(BURN);
        assertGe(bMid, b0);

        uint256[] memory empty = new uint256[](0);
        (IVerdictModule.Verdict memory v, bytes memory sig) =
            _signVerdict(reviewerKey, bountyId, 0, empty, keccak256("rejectall"), 0);
        verdictModule.submitVerdict(v, sig);
        vm.warp(block.timestamp + DEFAULT_CHALLENGE_WINDOW + 1);
        settlementModule.settle(bountyId);

        uint256 bAfter = bounty.balanceOf(BURN);
        assertGe(bAfter, bMid, "refund branch must not give back any burn");
    }
}
