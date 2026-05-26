// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockBOUNTY} from "../src/MockBOUNTY.sol";

contract MockBOUNTYTest is Test {
    MockBOUNTY internal token;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new MockBOUNTY(owner);
    }

    function test_metadata() public view {
        assertEq(token.name(), "Mock BOUNTY");
        assertEq(token.symbol(), "mBOUNTY");
        assertEq(token.decimals(), 18);
    }

    function test_owner_canMint() public {
        vm.prank(owner);
        token.mint(alice, 1_000 ether);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.totalSupply(), 1_000 ether);
    }

    function test_nonOwner_cannotMint() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 1_000 ether);
    }

    function test_transfer() public {
        vm.prank(owner);
        token.mint(alice, 1_000 ether);

        vm.prank(alice);
        bool ok = token.transfer(bob, 250 ether);
        assertTrue(ok);
        assertEq(token.balanceOf(alice), 750 ether);
        assertEq(token.balanceOf(bob), 250 ether);
    }

    function test_burnableByHolder() public {
        vm.prank(owner);
        token.mint(alice, 1_000 ether);

        vm.prank(alice);
        token.burn(400 ether);
        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.totalSupply(), 600 ether);
    }
}
