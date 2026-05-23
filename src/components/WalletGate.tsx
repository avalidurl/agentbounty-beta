import { useCallback, useEffect, useState } from "react";
import { TallyEmbed } from "./TallyEmbed";

type GateStatus =
  | "idle"
  | "connecting"
  | "wrong-network"
  | "rejected"
  | "approved";

interface Props {
  tallyUrl: string;
  expectedChainIdHex: string;
  rejectionTitle: string;
  rejectionLead: string;
  rejectionInstructions: string;
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
  rejectionTitle,
  rejectionLead,
  rejectionInstructions,
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
      <div className="stack">
        <div className="card stack-sm">
          <span className="tag tag-warn">access denied</span>
          <h2 style={{ marginTop: 0, paddingTop: 0, borderTop: 0 }}>{rejectionTitle}</h2>
          <p className="muted">
            Connected wallet: <code>{shortAddr(address)}</code> — not in the allowlist.
          </p>
          <p>{rejectionLead}</p>
          <p>{rejectionInstructions}</p>
        </div>
        <div className="card card-strong">
          <p className="eyebrow" style={{ margin: 0 }}>Access request form</p>
          <TallyEmbed url={tallyUrl} title="AgentBounty beta access request" />
        </div>
      </div>
    );
  }

  if (status === "wrong-network" && address) {
    return (
      <div className="card stack-sm">
        <span className="tag tag-warn">wrong network</span>
        <p className="muted">
          Wallet <code>{shortAddr(address)}</code> is approved, but is connected to the wrong network.
        </p>
        <p>{badNetworkWarn}</p>
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
