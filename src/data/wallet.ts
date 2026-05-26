import { createPublicClient, createWalletClient, custom, http } from "viem";
import { baseSepolia } from "viem/chains";
import { CHAIN } from "./site";

export const TRANSPORT = http(CHAIN.rpcDefault);

export const PUBLIC_CLIENT = createPublicClient({
  chain: baseSepolia,
  transport: TRANSPORT,
});

export interface Eip1193 {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
  on?: (event: string, handler: (...args: unknown[]) => void) => void;
  removeListener?: (event: string, handler: (...args: unknown[]) => void) => void;
}

declare global {
  interface Window {
    ethereum?: Eip1193;
  }
}

export function getWalletClient(account: `0x${string}`) {
  if (!window.ethereum) throw new Error("No injected wallet detected.");
  return createWalletClient({
    account,
    chain: baseSepolia,
    transport: custom(window.ethereum as never),
  });
}

export async function ensureBaseSepolia(provider: Eip1193): Promise<void> {
  const chainId = (await provider.request({ method: "eth_chainId" })) as string;
  if (chainId.toLowerCase() === CHAIN.expectedHex.toLowerCase()) return;
  try {
    await provider.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: CHAIN.expectedHex }],
    });
  } catch (err) {
    const code = (err as { code?: number })?.code;
    if (code === 4902) {
      await provider.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId: CHAIN.expectedHex,
            chainName: CHAIN.name,
            rpcUrls: [CHAIN.rpcDefault],
            blockExplorerUrls: [CHAIN.explorer],
            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
          },
        ],
      });
    } else {
      throw err;
    }
  }
}

export function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}
