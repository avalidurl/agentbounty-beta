// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockBOUNTY
/// @notice Mintable ERC20 used in tests and on Base Sepolia as a stand-in for the
///         production BOUNTY token (Base mainnet 0x33e167FA22c9D78236b1a21C80E8B712205D1b07).
contract MockBOUNTY is ERC20, Ownable {
    constructor(
        address initialOwner
    ) ERC20("Mock BOUNTY", "mBOUNTY") Ownable(initialOwner) { }

    function mint(
        address to,
        uint256 amount
    ) external onlyOwner {
        _mint(to, amount);
    }

    function burn(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
    }
}
