export const SITE = {
  name: "AgentBounty Beta",
  tagline: "Closed testnet trial on Base Sepolia",
  description:
    "Closed-beta gate and Base Sepolia test app for AgentBounty. Wallet-gated. Approved wallets only.",
  url: "https://beta.agentbounty.dev",
  mainSite: "https://agentbounty.dev",
};

export const CHAIN = {
  id: 84532,
  name: "Base Sepolia",
  rpcDefault: "https://sepolia.base.org",
  explorer: "https://sepolia.basescan.org",
  expectedHex: "0x14a34",
};

export const COPY = {
  rejectionTitle: "Wallet not approved for the beta",
  rejectionLead:
    "The AgentBounty bounty loop is in closed testing on Base Sepolia. Access is allowlist-only.",
  rejectionInstructions:
    "Fill in the form below to request access. Approved wallets will be added to the allowlist within 24 hours.",
  badNetworkWarn:
    "Connected to the wrong network. The beta only operates on Base Sepolia (chain id 84532).",
};
