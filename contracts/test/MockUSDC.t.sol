// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC internal token;
    address internal owner = makeAddr("owner");
    address internal alice;
    uint256 internal aliceKey;
    address internal bob = makeAddr("bob");

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("alice");
        token = new MockUSDC(owner);
    }

    function test_metadata() public view {
        assertEq(token.name(), "Mock USD Coin");
        assertEq(token.symbol(), "mUSDC");
        assertEq(token.decimals(), 6);
    }

    function test_owner_canMint_sixDecimals() public {
        vm.prank(owner);
        token.mint(alice, 1_500 * 10 ** 6);
        assertEq(token.balanceOf(alice), 1_500 * 10 ** 6);
    }

    function test_nonOwner_cannotMint() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 100 * 10 ** 6);
    }

    function test_transfer_sixDecimalArithmetic() public {
        vm.prank(owner);
        token.mint(alice, 1_500 * 10 ** 6);

        vm.prank(alice);
        token.transfer(bob, 500 * 10 ** 6);
        assertEq(token.balanceOf(alice), 1_000 * 10 ** 6);
        assertEq(token.balanceOf(bob), 500 * 10 ** 6);
    }

    function test_permit_setsAllowance() public {
        vm.prank(owner);
        token.mint(alice, 100 * 10 ** 6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(permitTypehash, alice, bob, uint256(50 * 10 ** 6), uint256(0), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        token.permit(alice, bob, 50 * 10 ** 6, deadline, v, r, s);
        assertEq(token.allowance(alice, bob), 50 * 10 ** 6);
    }
}
