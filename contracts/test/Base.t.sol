// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockBOUNTY} from "../src/MockBOUNTY.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {BountyEscrow} from "../src/BountyEscrow.sol";
import {VerdictModule} from "../src/VerdictModule.sol";
import {SettlementModule} from "../src/SettlementModule.sol";
import {IBountyEscrow} from "../src/interfaces/IBountyEscrow.sol";
import {IVerdictModule} from "../src/interfaces/IVerdictModule.sol";

/// @notice Base test scaffolding: deploys the full contract suite, mints
///         test tokens to canonical actors, and wires roles so tests can
///         focus on behaviour, not setup.
abstract contract BaseTest is Test {
    MockBOUNTY internal bounty;
    MockUSDC internal usdc;
    BountyEscrow internal escrow;
    VerdictModule internal verdictModule;
    SettlementModule internal settlementModule;

    address internal admin = makeAddr("admin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal sponsor = makeAddr("sponsor");
    address internal sponsor2 = makeAddr("sponsor2");
    address internal hunter1 = makeAddr("hunter1");
    address internal hunter2 = makeAddr("hunter2");
    address internal hunter3 = makeAddr("hunter3");
    address internal hunter4 = makeAddr("hunter4");
    address internal hunter5 = makeAddr("hunter5");

    address internal reviewer;
    uint256 internal reviewerKey;
    address internal reviewer2;
    uint256 internal reviewerKey2;
    address internal challenger = makeAddr("challenger");

    uint256 internal constant MIN_REVIEWER_BOND = 1_000_000 ether;
    uint256 internal constant DEFAULT_PAYOUT_MAX = 1_000 * 10 ** 6;
    uint256 internal constant DEFAULT_BASE_BOND = 100 ether;
    uint64  internal constant DEFAULT_REVIEW_WINDOW = 7 days;
    uint64  internal constant DEFAULT_CHALLENGE_WINDOW = 1 days;
    bytes32 internal constant DEFAULT_SPEC_HASH = keccak256("spec://test/v1");

    function setUp() public virtual {
        (reviewer, reviewerKey) = makeAddrAndKey("reviewer");
        (reviewer2, reviewerKey2) = makeAddrAndKey("reviewer2");

        vm.startPrank(admin);

        bounty = new MockBOUNTY(admin);
        usdc = new MockUSDC(admin);

        escrow = new BountyEscrow(admin, address(bounty), address(usdc), feeRecipient);
        verdictModule = new VerdictModule(admin, address(bounty), address(escrow));
        settlementModule = new SettlementModule(admin, address(bounty), address(usdc), address(escrow));

        escrow.grantRole(escrow.VERDICT_MODULE_ROLE(), address(verdictModule));
        escrow.grantRole(escrow.SETTLEMENT_MODULE_ROLE(), address(settlementModule));

        bounty.mint(sponsor, 200_000_000 ether);
        bounty.mint(sponsor2, 50_000_000 ether);
        bounty.mint(hunter1, 10_000_000 ether);
        bounty.mint(hunter2, 10_000_000 ether);
        bounty.mint(hunter3, 10_000_000 ether);
        bounty.mint(hunter4, 10_000_000 ether);
        bounty.mint(hunter5, 10_000_000 ether);
        bounty.mint(reviewer, 5_000_000 ether);
        bounty.mint(reviewer2, 5_000_000 ether);
        bounty.mint(challenger, 5_000_000 ether);

        usdc.mint(sponsor, 10_000_000 * 10 ** 6);
        usdc.mint(sponsor2, 10_000_000 * 10 ** 6);

        vm.stopPrank();
    }

    function _createAndFund(
        address bountySponsor,
        address proposedReviewer,
        uint256 payoutMax,
        uint256 baseBond
    ) internal returns (uint256 bountyId) {
        vm.startPrank(bountySponsor);
        bountyId = escrow.createBounty(
            payoutMax,
            baseBond,
            DEFAULT_REVIEW_WINDOW,
            DEFAULT_CHALLENGE_WINDOW,
            DEFAULT_SPEC_HASH,
            proposedReviewer
        );
        usdc.approve(address(escrow), payoutMax);
        escrow.fundBounty(bountyId);
        vm.stopPrank();
    }

    function _registerReviewer(address reviewerAddr, uint256 bondAmount) internal {
        vm.startPrank(reviewerAddr);
        bounty.approve(address(verdictModule), bondAmount);
        verdictModule.registerReviewer(bondAmount);
        vm.stopPrank();
    }

    function _acceptAssignment(address reviewerAddr, uint256 bountyId) internal {
        vm.prank(reviewerAddr);
        verdictModule.acceptAssignment(bountyId);
    }

    function _submit(address hunter, uint256 bountyId) internal returns (uint256 submissionId) {
        (uint256 totalCost,,) = escrow.currentBondCost(bountyId);
        vm.startPrank(hunter);
        bounty.approve(address(escrow), totalCost);
        submissionId = escrow.submit(
            bountyId,
            keccak256(abi.encodePacked("artifact", hunter, bountyId)),
            keccak256(abi.encodePacked("evidence", hunter, bountyId))
        );
        vm.stopPrank();
    }

    function _signVerdict(
        uint256 reviewerPrivKey,
        uint256 bountyId,
        uint256 winningSubmissionId,
        uint256[] memory slashedSubmissionIds,
        bytes32 evidenceAnchor,
        uint256 nonce
    ) internal view returns (IVerdictModule.Verdict memory v, bytes memory sig) {
        v = IVerdictModule.Verdict({
            bountyId: bountyId,
            winningSubmissionId: winningSubmissionId,
            slashedSubmissionIds: slashedSubmissionIds,
            evidenceAnchor: evidenceAnchor,
            expiresAt: block.timestamp + 1 hours,
            nonce: nonce
        });
        sig = _signedVerdictDigest(reviewerPrivKey, v);
    }

    function _signedVerdictDigest(uint256 reviewerPrivKey, IVerdictModule.Verdict memory v)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _verdictDigest(v);
        (uint8 vSig, bytes32 r, bytes32 s) = vm.sign(reviewerPrivKey, digest);
        return abi.encodePacked(r, s, vSig);
    }

    function _verdictDigest(IVerdictModule.Verdict memory v) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                verdictModule.verdictTypehash(),
                v.bountyId,
                v.winningSubmissionId,
                keccak256(abi.encodePacked(v.slashedSubmissionIds)),
                v.evidenceAnchor,
                v.expiresAt,
                v.nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", verdictModule.domainSeparator(), structHash));
    }
}
