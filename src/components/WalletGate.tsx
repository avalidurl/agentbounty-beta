import { useCallback, useEffect, useState } from "react";

type GateStatus =
  | "idle"
  | "connecting"
  | "wrong-network"
  | "rejected"
  | "approved";

interface Props {
  tallyUrl: string;
  expectedChainIdHex: string;
  rejectionCta: string;
  badNetworkWarn: string;
}

interface Eip1193Provider {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
  on?: (event: string, handler: (...args: unknown[]) => void) => void;
  removeListener?: (event: string, handler: (...args: unknown[]) => void) => void;
}

declare global {
  interface Window {
    ethereum?: Eip1193Provider;
  }
}

const ALLOWLIST_URL = "/allowlist.json";

async function loadAllowlist(): Promise<Set<string>> {
  const res = await fetch(ALLOWLIST_URL, { cache: "no-store" });
  if (!res.ok) return new Set();
  const data = (await res.json()) as unknown;
  if (!Array.isArray(data)) return new Set();
  return new Set(
    data
      .filter((x): x is string => typeof x === "string")
      .map((a) => a.toLowerCase().trim()),
  );
}

function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function WalletGate({
  tallyUrl,
  expectedChainIdHex,
  rejectionCta,
  badNetworkWarn,
}: Props) {
  const [status, setStatus] = useState<GateStatus>("idle");
  const [address, setAddress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const connect = useCallback(async () => {
    setError(null);
    if (typeof window === "undefined" || !window.ethereum) {
      setError("No injected wallet detected. Install MetaMask, Rabby, or Frame and reload.");
      return;
    }
    setStatus("connecting");
    try {
      const accounts = (await window.ethereum.request({
        method: "eth_requestAccounts",
      })) as string[];
      const account = accounts[0];
      if (!account) {
        setStatus("idle");
        setError("Wallet returned no account.");
        return;
      }
      const chainId = (await window.ethereum.request({
        method: "eth_chainId",
      })) as string;
      const onCorrectChain = chainId.toLowerCase() === expectedChainIdHex.toLowerCase();

      const list = await loadAllowlist();
      const approved = list.has(account.toLowerCase());
      setAddress(account);

      if (!approved) {
        setStatus("rejected");
        return;
      }
      if (!onCorrectChain) {
        setStatus("wrong-network");
        return;
      }
      setStatus("approved");
      window.location.href = "/app";
    } catch (e) {
      setStatus("idle");
      setError(e instanceof Error ? e.message : "Connect failed.");
    }
  }, [expectedChainIdHex]);

  useEffect(() => {
    if (!window.ethereum?.on) return;
    const handleAccountsChanged = () => {
      setStatus("idle");
      setAddress(null);
    };
    window.ethereum.on("accountsChanged", handleAccountsChanged);
    window.ethereum.on("chainChanged", handleAccountsChanged);
    return () => {
      window.ethereum?.removeListener?.("accountsChanged", handleAccountsChanged);
      window.ethereum?.removeListener?.("chainChanged", handleAccountsChanged);
    };
  }, []);

  if (status === "rejected" && address) {
    return (
      <div className="stack-sm">
        <p className="muted" style={{ margin: 0 }}>
          {shortAddr(address)} is not on the allowlist.
        </p>
        <a
          className="button button-primary"
          href={tallyUrl}
          target="_blank"
          rel="noopener noreferrer"
        >
          {rejectionCta}
        </a>
      </div>
    );
  }

  if (status === "wrong-network" && address) {
    return (
      <div className="stack-sm">
        <p className="muted" style={{ margin: 0 }}>
          {shortAddr(address)} is approved but on the wrong network.
        </p>
        <p style={{ margin: 0 }}>{badNetworkWarn}</p>
        <button className="button button-primary" onClick={connect}>
          Retry connection
        </button>
      </div>
    );
  }

  return (
    <div className="stack-sm">
      <button
        className="button button-primary"
        onClick={connect}
        disabled={status === "connecting"}
      >
        {status === "connecting" ? "Connecting…" : "Connect wallet"}
      </button>
      {error ? <p className="muted" style={{ color: "var(--warn)" }}>{error}</p> : null}
    </div>
  );
}
