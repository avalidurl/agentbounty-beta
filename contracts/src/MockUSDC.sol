// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title MockUSDC
/// @notice 6-decimal mintable ERC20 with EIP-2612 permit. Stand-in for Circle USDC
///         on Base Sepolia (real testnet USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e).
contract MockUSDC is ERC20, ERC20Permit, Ownable {
    constructor(
        address initialOwner
    ) ERC20("Mock USD Coin", "mUSDC") ERC20Permit("Mock USD Coin") Ownable(initialOwner) { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

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
