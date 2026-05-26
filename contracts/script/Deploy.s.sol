// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";

import { BountyEscrow } from "../src/BountyEscrow.sol";
import { MockBOUNTY } from "../src/MockBOUNTY.sol";
import { MockUSDC } from "../src/MockUSDC.sol";
import { SettlementModule } from "../src/SettlementModule.sol";
import { VerdictModule } from "../src/VerdictModule.sol";

/// @notice Deploys the full AgentBounty v0.1 contract suite.
///
///         Usage (Base Sepolia):
///           set -a && source ~/.config/agent-secrets/agentbounty/.env && set +a
///           forge script script/Deploy.s.sol \
///             --rpc-url base_sepolia \
///             --account $DEPLOYER_ACCOUNT_NAME \
///             --keystore-dir $DEPLOYER_KEYSTORE_DIR \
///             --broadcast \
///             --verify
///
///         Optional environment overrides:
///           ADMIN_ADDRESS         — defaults to msg.sender (the deployer key)
///           FEE_RECIPIENT_ADDRESS — defaults to ADMIN_ADDRESS
///           BOUNTY_ADDRESS        — if set, skips MockBOUNTY deploy and uses given address
///           USDC_ADDRESS          — if set, skips MockUSDC deploy and uses given address
contract DeployScript is Script {
    struct Deployment {
        address admin;
        address feeRecipient;
        address bounty;
        address usdc;
        address escrow;
        address verdictModule;
        address settlementModule;
        bool deployedMockBounty;
        bool deployedMockUSDC;
    }

    function run() external returns (Deployment memory d) {
        d.admin = _envAddressOr("ADMIN_ADDRESS", msg.sender);
        d.feeRecipient = _envAddressOr("FEE_RECIPIENT_ADDRESS", d.admin);

        vm.startBroadcast();

        address presetBounty = _envAddressOr("BOUNTY_ADDRESS", address(0));
        if (presetBounty == address(0)) {
            MockBOUNTY mockBounty = new MockBOUNTY(d.admin);
            d.bounty = address(mockBounty);
            d.deployedMockBounty = true;
        } else {
            d.bounty = presetBounty;
        }

        address presetUSDC = _envAddressOr("USDC_ADDRESS", address(0));
        if (presetUSDC == address(0)) {
            MockUSDC mockUSDC = new MockUSDC(d.admin);
            d.usdc = address(mockUSDC);
            d.deployedMockUSDC = true;
        } else {
            d.usdc = presetUSDC;
        }

        BountyEscrow escrow = new BountyEscrow(d.admin, d.bounty, d.usdc, d.feeRecipient);
        d.escrow = address(escrow);

        VerdictModule verdictModule = new VerdictModule(d.admin, d.bounty, d.escrow);
        d.verdictModule = address(verdictModule);

        SettlementModule settlementModule = new SettlementModule(d.admin, d.bounty, d.usdc, d.escrow);
        d.settlementModule = address(settlementModule);

        if (msg.sender == d.admin) {
            escrow.grantRole(escrow.VERDICT_MODULE_ROLE(), d.verdictModule);
            escrow.grantRole(escrow.SETTLEMENT_MODULE_ROLE(), d.settlementModule);
        }

        vm.stopBroadcast();

        _logDeployment(d);
        _writeJson(d);
    }

    function _envAddressOr(
        string memory key,
        address fallbackAddr
    ) internal view returns (address) {
        try vm.envAddress(key) returns (address a) {
            return a;
        } catch {
            return fallbackAddr;
        }
    }

    function _logDeployment(
        Deployment memory d
    ) internal pure {
        console.log("--------- AgentBounty v0.1 deployment ---------");
        console.log("Admin           ", d.admin);
        console.log("Fee recipient   ", d.feeRecipient);
        console.log("BOUNTY          ", d.bounty, d.deployedMockBounty ? "(mock)" : "(preset)");
        console.log("USDC            ", d.usdc, d.deployedMockUSDC ? "(mock)" : "(preset)");
        console.log("BountyEscrow    ", d.escrow);
        console.log("VerdictModule   ", d.verdictModule);
        console.log("SettlementModule", d.settlementModule);
        console.log("-----------------------------------------------");
    }

    function _writeJson(
        Deployment memory d
    ) internal {
        string memory json = string.concat(
            "{\n",
            '  "admin":            "',
            vm.toString(d.admin),
            '",\n',
            '  "feeRecipient":     "',
            vm.toString(d.feeRecipient),
            '",\n',
            '  "BOUNTY":           "',
            vm.toString(d.bounty),
            '",\n',
            '  "USDC":             "',
            vm.toString(d.usdc),
            '",\n',
            '  "BountyEscrow":     "',
            vm.toString(d.escrow),
            '",\n',
            '  "VerdictModule":    "',
            vm.toString(d.verdictModule),
            '",\n',
            '  "SettlementModule": "',
            vm.toString(d.settlementModule),
            '",\n',
            '  "chainId":          ',
            vm.toString(block.chainid),
            ",\n",
            '  "deployedMockBOUNTY": ',
            d.deployedMockBounty ? "true" : "false",
            ",\n",
            '  "deployedMockUSDC":   ',
            d.deployedMockUSDC ? "true" : "false",
            "\n",
            "}\n"
        );
        string memory path = string.concat("out/deployment-", vm.toString(block.chainid), ".json");
        vm.writeFile(path, json);
        console.log("Wrote deployment summary to", path);
    }
}
