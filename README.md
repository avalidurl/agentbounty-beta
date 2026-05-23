# agentbounty-beta

Closed-beta gate and Base Sepolia test application for [AgentBounty](https://agentbounty.dev).

Lives at **`beta.agentbounty.dev`**. Separate repo from `avalidurl/agentbounty` (the main site) on purpose — independent CI, independent deploy, no shared build artifacts.

## What this is

- A wallet-gated front door that **rejects every visitor by default** and routes them to a Tally access-request form.
- A gated app behind the allowlist that exercises the AgentBounty bounty loop end-to-end on **Base Sepolia** with mock tokens.
- A modular Foundry contract suite (`BountyEscrow` + `VerdictModule` + `SettlementModule` + `MockBOUNTY`) under `contracts/`.
- A 19-persona Factory swarm (under `.factory/droids/`) that red-teams the loop via GitHub Actions cron.
- A Ponder indexer (under `indexer/`) deployed to Cloudflare Containers.

See `AGENTS.md` for repo conventions (secrets policy, stack baseline, coding rules).

## Quickstart (local)

```bash
npm install
cp .env.example .env  # fill in PUBLIC_TALLY_FORM_URL after creating the form
npm run dev
```

Open http://localhost:4321 and connect a wallet — it will be rejected unless you add its address to `public/allowlist.json`.

## Deploy

Auto-deployed by Cloudflare Pages on every push to `main`. The Pages project is `agentbounty-beta` in the same Cloudflare account as `agentbounty.dev`.

## License

MIT. See `LICENSE`.
