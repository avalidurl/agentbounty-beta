# AGENTS.md — agentbounty-beta repo conventions

This repo inherits all conventions from `avalidurl/agentbounty`'s `AGENTS.md` (secrets policy, stack baseline, networks, coding rules). The additions below are specific to the beta gate / Sepolia test app / swarm.

## Beta-specific structure

```
agentbounty-beta/
├── src/                         Astro site (gate page + gated app)
│   ├── components/              React islands + Astro components
│   ├── layouts/                 BaseLayout.astro
│   ├── pages/
│   │   ├── index.astro          The wallet gate (rejection-by-default)
│   │   └── app/                 Gated UIs (post-allow)
│   ├── styles/                  Copied from main site, kept in sync manually
│   └── data/                    Static config (chain ids, ABIs)
├── public/
│   ├── allowlist.json           Approved wallet addresses (start empty)
│   └── contracts.json           Deployed contract addresses (Sepolia + later mainnet)
├── contracts/                   Foundry suite
│   ├── src/                     Solidity sources + interfaces
│   ├── test/                    forge tests
│   └── script/                  Deploy scripts
├── indexer/                     Ponder indexer (Cloudflare Containers)
├── .factory/                    Persona droids + skill + slash command
│   ├── droids/                  19 persona files
│   ├── skills/agentbounty-test-loop/
│   └── commands/run-bounty-round.md
└── .github/workflows/
    ├── ci.yml                   astro check + lint
    ├── contracts-ci.yml         forge test + coverage + slither
    └── bounty-swarm.yml         */30 cron, fires 9 personas per round
```

## Gate behavior contract

The gate at `/` must:

1. Render with no wallet interaction required (no popups on load).
2. Show a single primary action: "Connect wallet".
3. On connect: read the address from `eth_requestAccounts`, normalize lowercase, check against `public/allowlist.json`.
4. If the address is **not** in the allowlist (every visitor in v0.0), render the rejection card and embed the Tally form.
5. If the address **is** in the allowlist, redirect to `/app`.
6. Never call any backend at the gate. Allowlist enforcement is intentionally client-side — there is no PII collected, no API hit, no analytics ping until the user explicitly submits the Tally form.

## Allowlist update flow

Adding an approved wallet is a PR to `public/allowlist.json`:

```diff
- []
+ ["0xAbC...ddress"]
```

Auto-deploy to Cloudflare Pages on merge. No app-side cache to bust.

## Contract deploy gate

No deploy script runs in CI. Deploys are explicit human actions from the local machine, using a `.env` that lives only on that machine. The deployer key is also stored as a GitHub Actions secret named `TESTNET_DEPLOYER_KEY` so the swarm can have the admin call sites, but is **never** echoed to logs.

## Swarm persona file format

Each `.factory/droids/*.md` follows this skeleton:

```yaml
---
name: <persona-id>
model: inherit
tools: [Read, Write, Edit, Bash, viem-sign, ipfs-pin]
derivation_index: <0-19>   # m/44'/60'/0'/0/<index>
role: sponsor | submitter | reviewer | meta
disposition: charitable | adversarial | strict | lenient | skeptic | lazy
---

# Persona prompt text...
```

The `derivation_index` is what binds the prompt to a wallet. The swarm controller never asks the persona which address to sign from — it injects the derived account based on the index.
