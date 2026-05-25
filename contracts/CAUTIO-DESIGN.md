# Cautio — staking + underwriting design (Phase 7)

Working spec for the Phase 7 contract suite. This is the staking pool that
backs AgentBounty's insurance tier and routes protocol fees to stakers.

> Public source of truth: <https://agentbounty.dev/staking>. The page wins on
> any conflict — this document codifies the contract surface that implements
> what the page promises.

This document is a **skeleton**. It will be filled in during Phase 7 with the
same level of detail as `DESIGN.md` (state machine, storage layout, EIP-712
structs where relevant, gas budget, test plan). For now it pins the
architecture decisions so that Phase 5 (BountyEscrow / VerdictModule /
SettlementModule) can reference it without ambiguity.

## CAUTIONER is the parametric insurance protocol

CAUTIONER is **not** an access pass. It is **not** a governance ornament. It
is the on-chain parametric insurance protocol that backs every settled
bounty, every compute and oracle dependency, and the physical infrastructure
under all of it.

The CAUTIONER token is the on-chain instrument of that insurance. Holders
absorb the loss when oracle-signed events fire (provider outage, datacenter
incident, nat-cat, oracle silence, sponsor griefing, verdict failure). They
are paid in protocol fees and Aave float yield in exchange for bearing that
risk.

The staking action — depositing BOUNTY or USDC into the Cautio pool — is
itself the underwriting. There is no second layer of "stake CAUTIONER on
top." Pool depositors **are** the underwriters. They receive CAUTIONER token
emissions in exchange for the capital they put at risk, and they capture
60% of all AgentBounty protocol fees.

## Tokens

| Token | Spec | Role |
|---|---|---|
| **BOUNTY** | Existing ERC20 at `0x33e167FA22c9D78236b1a21C80E8B712205D1b07` on Base | Work currency. Submission bonds. Reviewer pay. Treasury spend. **Unchanged.** |
| **CAUTIONER** | New ERC20, 100M total supply, capped, immutable. The on-chain instrument of AgentBounty's parametric insurance protocol. | Airdropped to BOUNTY holders + friendly communities at TGE (30% supply). Emitted to underwriting-pool depositors over 18 epochs (15% supply). Captures 60% of protocol fees. Tradable on Aerodrome / Uniswap so the insurance position is liquid. When oracle-signed insurance triggers fire, the pool drains and CAUTIONER market price reflects the realized loss. |

## Cautio pool

```
Cautio pool (USDC + BOUNTY underwriting capital)
   │
   ├── deposit: BOUNTY or USDC
   │   - tier-gated entry windows for the first 24h post-TGE:
   │     • Bench (≥3B BOUNTY at snapshot) → T+0
   │     • Gallery (1B–3B BOUNTY at snapshot) → T+3h
   │     • Public → T+24h
   │
   ├── lock: 6h to 365d (slider-driven UX on the staking page)
   │   - linear multiplier 1× at 6h → 4× at 365d (capped above 365d)
   │   - lock-mature exit; no early withdrawal in v0.1
   │
   ├── yield: paid in USDC, harvested anytime
   │   - 60% of protocol fees from BountyEscrow / SettlementModule
   │   - Aave float yield on idle pool USDC
   │   - slashed reviewer-bond treasury cut
   │   - bootstrap subsidy (first 90 days, decaying linearly)
   │
   └── slash: pool USDC pays out claims when oracle-signed events fire
       - verdict failure / reviewer collusion (dispute-module attestation)
       - compute or cloud outage (AWS Health / Cloudflare via Chainlink Functions)
       - datacenter incident (provider postmortem + Pyth/EAS event)
       - parametric nat-cat (Arbol / Lloyd's-style feed via Chainlink Functions)
       - oracle / data-feed silence (oracle-of-oracles guard + dispute flag)
       - sponsor griefing (settlement-contract state + escrow timeout)
```

## Bootstrap subsidy

The first 90 days post-TGE pay an additional yield stream from a fixed
treasury allocation, denominated in USDC, distributed via linear decay so
Day 1 sees the highest implied APY and Day 90 converges to the steady-state
real-cash-flow yield. Specific budget will be ratified at Phase 7 design
freeze (initial sizing target: 5% of CAUTIONER supply OTC-converted to USDC,
or USDC reserve from the treasury bucket).

## Why the pool deposit is BOUNTY-or-USDC and not CAUTIONER

CAUTIONER is fixed-supply. If we required CAUTIONER as the only deposit
asset, total pool capacity would be capped at ~100M tokens × CAUTIONER
spot price. Underwriting capacity is the protocol's most important resource;
gating it behind a fixed token would hard-cap the protocol's growth.

Accepting BOUNTY or USDC as the deposit asset means the pool can absorb
capital at whatever rate AgentBounty's bounty volume demands. CAUTIONER is
not the deposit asset — it is the **token of the insurance position**:
emitted to depositors as their underwriting reward, freely tradable so the
position can be priced and exited, value-capturing because it earns 60% of
all protocol fees.

## Fee routing (60 / 25 / 15)

Per the public schedule on /staking:

| Recipient | Share |
|---|---|
| CAUTIONER stakers (the Cautio pool) | 60% |
| Team multisig (operational) | 25% |
| Treasury (long-term reserve) | 15% |

The `BountyEscrow` `FEE_RECIPIENT` address points at a **fee router**
contract that performs this split. v0.1 default is the deployer multisig
(simple passthrough); v0.2 deploys the Cautio fee router and the multisig
calls `setFeeRecipient(cautioFeeRouterAddr)` on `BountyEscrow`.

## Slashing module

Out of scope for v0.1. The v0.2 slashing module reads exclusively from a
Chainlink-Functions-native oracle aggregator. A signed event from the
aggregator is the only path that can trigger a payout from the Cautio pool —
no team-signed transactions can drain the pool.

## Lock mechanic: 6h to 365d, multiplier 1× to 4×

```
multiplier(D)  = 1 + 3 × ((D − 6h) / (365d − 6h))      0 ≤ multiplier ≤ 4
weight         = depositedAsset × multiplier             (asset = BOUNTY or USDC)
yieldShare     = weight / totalWeight × periodYield
```

UX: a slider on the /staking page. User drags from 6h to 365d. Live readout
shows multiplier and projected weight. Lock-extension and top-up are allowed
post-deposit.

## Out-of-scope for Phase 7 v0.1

- Early withdrawal with slashing penalty (Convex / Aave Safety Module pattern)
- Lock-extension via NFT positions (per-position semantics — flat per-address tracking is simpler for v0.1)
- veBOUNTY (dropped — see DESIGN.md "Open items still deferred to v0.2")
- Cross-chain CAUTIONER (Base-only at v0.1)
- Liquid staking derivative on top of locked positions

## References

- Public source of truth: <https://agentbounty.dev/staking>
- AgentBounty contracts (the protocol that pays into Cautio): `DESIGN.md`
- AGENTS.md (repo conventions): `~/.factory/droids/` and `agentbounty-beta/AGENTS.md`
