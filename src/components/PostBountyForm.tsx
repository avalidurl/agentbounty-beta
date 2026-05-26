import { useCallback, useState } from "react";
import { type Abi, encodeFunctionData, getAddress, keccak256, parseUnits, toBytes } from "viem";
import { ABI, ADDR } from "../data/contracts";
import { PUBLIC_CLIENT, getWalletClient, shortAddr } from "../data/wallet";

const ESCROW_ABI = ABI.BountyEscrow as unknown as Abi;
const USDC_ABI = ABI.USDC as unknown as Abi;

interface Props {
  account: `0x${string}`;
}

interface FormState {
  payoutMaxUsdc: string;
  baseBondBounty: string;
  reviewWindowDays: string;
  challengeWindowDays: string;
  specMarkdown: string;
  proposedReviewer: string;
}

const DEFAULTS: FormState = {
  payoutMaxUsdc: "100",
  baseBondBounty: "100",
  reviewWindowDays: "5",
  challengeWindowDays: "1",
  specMarkdown: "## Bounty spec\n\nDescribe the work. Include acceptance criteria.\n",
  proposedReviewer: "",
};

export function PostBountyForm({ account }: Props) {
  const [form, setForm] = useState<FormState>(DEFAULTS);
  const [busy, setBusy] = useState(false);
  const [log, setLog] = useState<string[]>([]);

  const set = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    setForm((s) => ({ ...s, [key]: value }));

  const append = (msg: string) => setLog((l) => [...l, `[${new Date().toLocaleTimeString()}] ${msg}`]);

  const submit = useCallback(async () => {
    setBusy(true);
    setLog([]);
    try {
      append("Validating inputs…");
      const payoutMax = parseUnits(form.payoutMaxUsdc, 6);
      const baseBond = parseUnits(form.baseBondBounty, 18);
      const reviewWindow = BigInt(Number(form.reviewWindowDays) * 86_400);
      const challengeWindow = BigInt(Number(form.challengeWindowDays) * 86_400);
      let proposed = "0x0000000000000000000000000000000000000000" as `0x${string}`;
      if (form.proposedReviewer.trim()) {
        proposed = getAddress(form.proposedReviewer.trim()) as `0x${string}`;
      }

      const specBytes = toBytes(form.specMarkdown);
      const specHash = keccak256(specBytes);
      append(`specHash = ${specHash.slice(0, 10)}…`);

      const wallet = getWalletClient(account);

      append("createBounty(...)");
      const createTx = await wallet.sendTransaction({
        to: ADDR.BountyEscrow,
        data: encodeFunctionData({
          abi: ESCROW_ABI,
          functionName: "createBounty",
          args: [payoutMax, baseBond, reviewWindow, challengeWindow, specHash, proposed],
        }),
      });
      append(`createBounty tx: ${createTx}`);
      const createReceipt = await PUBLIC_CLIENT.waitForTransactionReceipt({ hash: createTx });
      append(`createBounty mined in block ${createReceipt.blockNumber}`);

      const bountyCounter = (await PUBLIC_CLIENT.readContract({
        address: ADDR.BountyEscrow,
        abi: ESCROW_ABI,
        functionName: "bountyCount",
      })) as bigint;
      append(`Latest bountyId: ${bountyCounter}`);

      append("Approving USDC for escrow…");
      const approveTx = await wallet.sendTransaction({
        to: ADDR.USDC,
        data: encodeFunctionData({
          abi: USDC_ABI,
          functionName: "approve",
          args: [ADDR.BountyEscrow, payoutMax],
        }),
      });
      await PUBLIC_CLIENT.waitForTransactionReceipt({ hash: approveTx });
      append(`Approved USDC ${form.payoutMaxUsdc}`);

      append(`fundBounty(${bountyCounter})…`);
      const fundTx = await wallet.sendTransaction({
        to: ADDR.BountyEscrow,
        data: encodeFunctionData({
          abi: ESCROW_ABI,
          functionName: "fundBounty",
          args: [bountyCounter],
        }),
      });
      const fundReceipt = await PUBLIC_CLIENT.waitForTransactionReceipt({ hash: fundTx });
      append(`fundBounty mined in block ${fundReceipt.blockNumber}`);

      append(`Done. Bounty #${bountyCounter} is now Funded.`);
    } catch (e) {
      append(`error: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
    }
  }, [form, account]);

  return (
    <div className="stack-md">
      <p className="muted" style={{ margin: 0 }}>
        Posting as <code>{shortAddr(account)}</code>.
      </p>

      <label className="stack-xs">
        <span className="muted">Payout max (USDC)</span>
        <input
          type="number"
          step="0.01"
          min="0"
          value={form.payoutMaxUsdc}
          onChange={(e) => set("payoutMaxUsdc", e.target.value)}
        />
      </label>

      <label className="stack-xs">
        <span className="muted">Base bond (BOUNTY)</span>
        <input
          type="number"
          step="1"
          min="0"
          value={form.baseBondBounty}
          onChange={(e) => set("baseBondBounty", e.target.value)}
        />
      </label>

      <div className="row" style={{ gap: "var(--space-4)" }}>
        <label className="stack-xs" style={{ flex: 1 }}>
          <span className="muted">Review window (days, max 14)</span>
          <input
            type="number"
            min="1"
            max="14"
            value={form.reviewWindowDays}
            onChange={(e) => set("reviewWindowDays", e.target.value)}
          />
        </label>
        <label className="stack-xs" style={{ flex: 1 }}>
          <span className="muted">Challenge window (days, max 7)</span>
          <input
            type="number"
            min="0"
            max="7"
            value={form.challengeWindowDays}
            onChange={(e) => set("challengeWindowDays", e.target.value)}
          />
        </label>
      </div>

      <label className="stack-xs">
        <span className="muted">Proposed reviewer (optional)</span>
        <input
          type="text"
          placeholder="0x..."
          value={form.proposedReviewer}
          onChange={(e) => set("proposedReviewer", e.target.value)}
        />
      </label>

      <label className="stack-xs">
        <span className="muted">Spec (markdown)</span>
        <textarea
          rows={10}
          value={form.specMarkdown}
          onChange={(e) => set("specMarkdown", e.target.value)}
        />
      </label>

      <button className="button button-primary" onClick={submit} disabled={busy}>
        {busy ? "Sending…" : "Create + fund bounty"}
      </button>

      {log.length > 0 ? (
        <pre style={{
          background: "var(--panel-strong)",
          padding: "var(--space-3)",
          borderRadius: 4,
          overflowX: "auto",
          fontSize: 12,
          whiteSpace: "pre-wrap",
        }}>{log.join("\n")}</pre>
      ) : null}
    </div>
  );
}
