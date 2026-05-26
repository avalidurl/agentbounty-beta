import contractsJson from "../../public/contracts.json";
import bountyEscrowAbi from "./abi/BountyEscrow.json";
import verdictModuleAbi from "./abi/VerdictModule.json";
import settlementModuleAbi from "./abi/SettlementModule.json";
import mockBountyAbi from "./abi/MockBOUNTY.json";
import mockUsdcAbi from "./abi/MockUSDC.json";

export interface DeployedContracts {
  chainId: number;
  chainName: string;
  deployedAt: string | null;
  deployer: string | null;
  admin?: string;
  feeRecipient?: string;
  addresses: {
    BountyEscrow: `0x${string}`;
    VerdictModule: `0x${string}`;
    SettlementModule: `0x${string}`;
    MockBOUNTY: `0x${string}`;
    USDC: `0x${string}`;
  };
  notes?: Record<string, string>;
  explorers: { basescan: string };
}

export const CONTRACTS = contractsJson as unknown as DeployedContracts;

export const ABI = {
  BountyEscrow: bountyEscrowAbi,
  VerdictModule: verdictModuleAbi,
  SettlementModule: settlementModuleAbi,
  BOUNTY: mockBountyAbi,
  USDC: mockUsdcAbi,
} as const;

export const ADDR = CONTRACTS.addresses;
