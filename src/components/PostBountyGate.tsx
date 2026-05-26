import { useCallback, useEffect, useState } from "react";
import { CHAIN } from "../data/site";
import { ensureBaseSepolia } from "../data/wallet";
import type { Eip1193 } from "../data/wallet";
import { PostBountyForm } from "./PostBountyForm";

type Status = "loading" | "no-wallet" | "disconnected" | "wrong-network" | "ready";

const ALLOWLIST_URL = "/allowlist.json";

async function loadAllowlist(): Promise<Set<string>> {
  try {
    const res = await fetch(ALLOWLIST_URL, { cache: "no-store" });
    if (!res.ok) return new Set();
    const data = (await res.json()) as unknown;
    if (!Array.isArray(data)) return new Set();
    return new Set(
      data.filter((x): x is string => typeof x === "string").map((a) => a.toLowerCase().trim()),
    );
  } catch {
    return new Set();
  }
}

export function PostBountyGate() {
  const [status, setStatus] = useState<Status>("loading");
  const [address, setAddress] = useState<`0x${string}` | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reconcile = useCallback(async () => {
    if (!window.ethereum) {
      setStatus("no-wallet");
      return;
    }
    try {
      setError(null);
      const accounts = (await window.ethereum.request({
        method: "eth_accounts",
      })) as string[];
      const a = accounts[0] as `0x${string}` | undefined;
      if (!a) {
        setStatus("disconnected");
        return;
      }
      const allow = await loadAllowlist();
      if (!allow.has(a.toLowerCase())) {
        window.location.href = "/";
        return;
      }
      setAddress(a);
      const cid = (await window.ethereum.request({ method: "eth_chainId" })) as string;
      if (cid.toLowerCase() !== CHAIN.expectedHex.toLowerCase()) {
        setStatus("wrong-network");
        return;
      }
      setStatus("ready");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Wallet error");
      setStatus("disconnected");
    }
  }, []);

  const connect = useCallback(async () => {
    if (!window.ethereum) return;
    try {
      await window.ethereum.request({ method: "eth_requestAccounts" });
      reconcile();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Connect failed");
    }
  }, [reconcile]);

  const switchNet = useCallback(async () => {
    if (!window.ethereum) return;
    try {
      await ensureBaseSepolia(window.ethereum as Eip1193);
      reconcile();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Switch failed");
    }
  }, [reconcile]);

  useEffect(() => {
    reconcile();
    const onChange = () => reconcile();
    window.ethereum?.on?.("accountsChanged", onChange);
    window.ethereum?.on?.("chainChanged", onChange);
    return () => {
      window.ethereum?.removeListener?.("accountsChanged", onChange);
      window.ethereum?.removeListener?.("chainChanged", onChange);
    };
  }, [reconcile]);

  if (status === "loading") return <p className="muted">Loading…</p>;
  if (status === "no-wallet")
    return <p className="muted">No injected wallet. Install one and reload.</p>;
  if (status === "disconnected")
    return (
      <button className="button button-primary" onClick={connect}>
        Connect wallet
      </button>
    );
  if (status === "wrong-network")
    return (
      <div className="stack-sm">
        <p className="muted">Wrong network.</p>
        <button className="button button-primary" onClick={switchNet}>
          Switch to {CHAIN.name}
        </button>
      </div>
    );
  if (status === "ready" && address) return <PostBountyForm account={address} />;

  return error ? <p style={{ color: "var(--warn)" }}>{error}</p> : null;
}
