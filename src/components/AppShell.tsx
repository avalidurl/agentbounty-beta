import { useCallback, useEffect, useState } from "react";
import { ensureBaseSepolia, shortAddr } from "../data/wallet";
import { CHAIN } from "../data/site";
import type { Eip1193 } from "../data/wallet";

interface Props {
  children?: never;
}

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

export function AppShell(_p: Props) {
  const [status, setStatus] = useState<Status>("loading");
  const [address, setAddress] = useState<`0x${string}` | null>(null);
  const [error, setError] = useState<string | null>(null);

  const connect = useCallback(async () => {
    if (!window.ethereum) return;
    try {
      setStatus("loading");
      setError(null);
      const accounts = (await window.ethereum.request({
        method: "eth_requestAccounts",
      })) as string[];
      const a = accounts[0] as `0x${string}` | undefined;
      if (!a) {
        setStatus("disconnected");
        return;
      }

      const allowlist = await loadAllowlist();
      if (!allowlist.has(a.toLowerCase())) {
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
      setError(e instanceof Error ? e.message : "Connect failed");
      setStatus("disconnected");
    }
  }, []);

  const switchNet = useCallback(async () => {
    if (!window.ethereum) return;
    try {
      await ensureBaseSepolia(window.ethereum as Eip1193);
      await connect();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Switch failed");
    }
  }, [connect]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (!window.ethereum) {
      setStatus("no-wallet");
      return;
    }
    connect();

    const onChange = () => {
      setStatus("loading");
      setAddress(null);
      connect();
    };
    window.ethereum.on?.("accountsChanged", onChange);
    window.ethereum.on?.("chainChanged", onChange);
    return () => {
      window.ethereum?.removeListener?.("accountsChanged", onChange);
      window.ethereum?.removeListener?.("chainChanged", onChange);
    };
  }, [connect]);

  return (
    <div className="stack-md">
      <header className="row" style={{ justifyContent: "space-between", alignItems: "center" }}>
        <nav className="row" style={{ gap: "var(--space-4)" }}>
          <a href="/app">/app</a>
          <a href="/app/post">post</a>
          <a href="/app/reviewer">reviewer</a>
        </nav>
        <div className="row" style={{ gap: "var(--space-3)", alignItems: "center" }}>
          {status === "ready" && address ? (
            <span className="muted" style={{ fontFamily: "var(--font-mono)" }}>
              {shortAddr(address)} · {CHAIN.name}
            </span>
          ) : null}
          <a className="muted" href="/">disconnect</a>
        </div>
      </header>

      {status === "loading" ? <p className="muted">Loading wallet…</p> : null}

      {status === "no-wallet" ? (
        <p className="muted">
          No injected wallet. Install MetaMask, Rabby, or Frame and reload.
        </p>
      ) : null}

      {status === "disconnected" ? (
        <button className="button button-primary" onClick={connect}>
          Connect wallet
        </button>
      ) : null}

      {status === "wrong-network" && address ? (
        <div className="stack-sm">
          <p className="muted">{shortAddr(address)} is connected to the wrong network.</p>
          <button className="button button-primary" onClick={switchNet}>
            Switch to {CHAIN.name}
          </button>
        </div>
      ) : null}

      {error ? (
        <p style={{ color: "var(--warn)", margin: 0 }}>{error}</p>
      ) : null}

      {status === "ready" && address ? (
        <AppHome address={address} />
      ) : null}
    </div>
  );
}

function AppHome({ address }: { address: `0x${string}` }) {
  return (
    <div className="stack-md">
      <section className="stack-sm">
        <h2 style={{ margin: 0 }}>Welcome.</h2>
        <p className="muted">
          You are connected as <code>{shortAddr(address)}</code> on {CHAIN.name}.
          Pick a role below.
        </p>
      </section>

      <section className="grid-3" style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: "var(--space-4)" }}>
        <a className="card card-strong stack-sm" href="/app/post" style={{ textDecoration: "none" }}>
          <h3 style={{ margin: 0 }}>Sponsor</h3>
          <p className="muted" style={{ margin: 0 }}>
            Post a bounty. Fund USDC. Pick a reviewer.
          </p>
        </a>
        <a className="card card-strong stack-sm" href="/app/bounties" style={{ textDecoration: "none" }}>
          <h3 style={{ margin: 0 }}>Hunter</h3>
          <p className="muted" style={{ margin: 0 }}>
            Browse open bounties. Submit work. Claim payouts.
          </p>
        </a>
        <a className="card card-strong stack-sm" href="/app/reviewer" style={{ textDecoration: "none" }}>
          <h3 style={{ margin: 0 }}>Reviewer</h3>
          <p className="muted" style={{ margin: 0 }}>
            Register a bond. Sign verdicts. Earn fees.
          </p>
        </a>
      </section>
    </div>
  );
}
