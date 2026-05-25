# AgentBounty contracts — v0.1 design

Working spec for the Phase 5 contract suite. Maps 1:1 to the public state
machine documented at <https://agentbounty.dev/how-it-works> and the object
schemas at <https://agentbounty.dev/reference>. This document is the engineering
source of truth; the public surface is the narrative.

> Every number on this page is provisional. The numbers may move during
> mechanism design but the names, states, and roles are stable.

## Goals

- Hold USDC for funded bounties on Base.
- Admit reviewers who bond BOUNTY against their verdicts.
- Accept **multiple** evidence-backed submissions per bounty with a stake
  mechanism that prices spam out without punishing honest losers.
- Route USDC payouts on acceptance, refund on cancel/reject, and lock in a
  challenge window before settlement is final.
- Expose hooks for v0.2 oracle-driven slashing and underwriting-pool routing.

## Non-goals (v0.1)

- No N-of-M reviewer quorum. Single reviewer per bounty.
- No automated dispute resolution. Manual `DISPUTE_RESOLVER_ROLE`.
- No CAUTIONER / underwriting pool integration. Just a `protocolFeeRecipient`
  address that v0.2 will repoint at the pool.
- No commit-reveal on submissions. Plaintext artifact hashes in v0.1.
- No upgradable proxies. Token contract is immutable; modules can be
  swapped at the BountyEscrow level via role-gated address updates.

## Contracts

| File | Responsibility | Notable parents |
|---|---|---|
| `src/MockBOUNTY.sol` | ERC20 test token, mintable by owner. | OZ `ERC20`, `Ownable` |
| `src/MockUSDC.sol` | ERC20 + EIP-2612 permit, 6 decimals, mintable by owner. | OZ `ERC20Permit`, `Ownable` |
| `src/BountyEscrow.sol` | USDC custody, bounty + submission storage, state transitions. | OZ `AccessControl`, `Pausable`, `ReentrancyGuard`, `SafeERC20` |
| `src/VerdictModule.sol` | Reviewer registry, EIP-712 verdicts, bond accounting. | OZ `AccessControl`, `EIP712`, `ReentrancyGuard` |
| `src/SettlementModule.sol` | Payout splitter, fee routing, claim flow. | OZ `ReentrancyGuard`, `SafeERC20` |

The three core contracts are split for two reasons:

1. **Audit clarity.** Each module has one job, < 300 LOC.
2. **Replaceable mechanism.** v0.2 will swap `SettlementModule` to route the
   protocol fee into the CAUTIONER underwriting pool; `BountyEscrow` and
   `VerdictModule` stay constant.

## Roles (OpenZeppelin `AccessControl`)

| Role | v0.1 holder | v0.2 target | Permission |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | deployer multisig | governance contract | grants/revokes other roles, sets parameters |
| `PAUSER_ROLE` | deployer multisig | governance | pauses bounty creation in emergency |
| `REVIEWER_ADMIN_ROLE` | deployer multisig | reviewer DAO | admits reviewers into the registry |
| `DISPUTE_RESOLVER_ROLE` | deployer multisig | oracle aggregator | resolves Disputed bounties |
| `FEE_RECIPIENT` (admin-settable address) | treasury safe | **Cautio underwriting pool** | receives protocol fee on settlement; v0.2 routes to the Cautio fee router which splits 60% stakers / 25% team / 15% treasury |

## Tunable parameters

| Param | Default | Meaning |
|---|---|---|
| `MIN_REVIEWER_BOND` | 1_000_000 × 10¹⁸ BOUNTY | Floor under any reviewer bond. |
| `BOND_RATIO_BPS` | 100 (1%) | Per-bounty stake floor: `requiredBond = max(MIN_REVIEWER_BOND, payoutMax × BOND_RATIO_BPS / 10_000)`. High-value bounties require proportionally higher reviewer skin in the game. |
| `PROTOCOL_FEE_BPS` | 100 (1%) | Skim of `payoutMax` on accepted bounty. **Split 50/50 between burn (0x…dEaD) and FEE_RECIPIENT.** |
| `PROTOCOL_FEE_BURN_BPS` | 5_000 (50%) | Of the protocol fee, what fraction permanently burns. The rest goes to FEE_RECIPIENT. |
| `REVIEWER_FEE_BPS` | 300 (3%) | Skim of `payoutMax` to reviewer on accepted bounty. |
| `SPONSOR_DISCOUNT_THRESHOLD` | 100_000 × 10¹⁸ BOUNTY | Sponsor BOUNTY balance at `fundBounty` time that triggers the protocol-fee discount. **v0.1: scaffolded, default-disabled.** |
| `SPONSOR_DISCOUNTED_FEE_BPS` | 50 (0.5%) | Discounted protocol fee for qualifying sponsors. |
| `MAX_REVIEW_WINDOW` | 14 days | Sponsor's review_window cap. |
| `MAX_CHALLENGE_WINDOW` | 7 days | Sponsor's challenge_window cap. |
| `REFUND_AFTER` | 30 days | After this with no acceptance, sponsor can refund. |
| `BASE_BOND` | 100 × 10¹⁸ BOUNTY | Default per-submission base bond. Sponsor-configurable per bounty. |
| `BOND_MULTIPLIER_BPS` | 12_500 (1.25×) | Per-submission bond escalator. |
| `BOND_CAP_MULTIPLIER` | 10 | Hard ceiling on cumulative multiplier. |
| `MAX_SUBMISSIONS` | 50 | Cap to bound gas. |
| `REVIEWER_REJECT_WINDOW` | 12 hours | Time sponsor's proposed reviewer has to reject the assignment. |
| `SLASH_REVIEWER_BPS` | 4_000 (40%) | Of slashed bond base, what reviewer earns. |
| `SLASH_TREASURY_BPS` | 3_000 (30%) | Of slashed bond base, what FEE_RECIPIENT earns. |
| `SLASH_BURN_BPS` | 3_000 (30%) | Of slashed bond base, what permanently burns. (Sum of three = 10_000.) |

## State machine (per bounty)

```
                ┌─────────────┐
                │    Draft    │  createBounty
                └──────┬──────┘
                       │  fundBounty (USDC.transferFrom)
                       ▼
                ┌─────────────┐  (sponsor can cancel here → Refunded)
                │   Funded    │
                └──────┬──────┘
                       │  reviewer accepts assignment OR pool picks up
                       │  (after REVIEWER_REJECT_WINDOW expires unchallenged)
                       ▼
                ┌─────────────┐
                │  InReview   │  submit() called by 1..N submitters
                └──────┬──────┘
                       │  reviewer signs EIP-712 verdict
                       ▼
                ┌─────────────┐
                │   Queued    │  challenge window opens
                └──────┬──────┘
                       │  no challenge within window → settle()
                       ▼
                ┌─────────────┐
                │   Settled   │  payouts computed, claimable
                └──────┬──────┘
                       │  hunter claim()
                       ▼
                ┌─────────────┐
                │   Claimed   │
                └─────────────┘

Side branches:
  Funded → Refunded         (sponsor cancel before any submission)
  Funded → Refunded         (REFUND_AFTER elapsed with no submission)
  Queued → Disputed         (challenger calls dispute())
  Disputed → Settled        (DISPUTE_RESOLVER_ROLE awards hunter)
  Disputed → Refunded       (DISPUTE_RESOLVER_ROLE awards sponsor)
```

## Multi-submission stake mechanism (EIP-1559-inspired)

The interesting v0.1 mechanism. Sponsor opens the bounty; multiple submitters
can submit work. A bond gates entry, and the bond price rises with each
submission to discourage spam — directly analogous to EIP-1559 base-fee burn.

### Per-submission cost

```
n               = number of submissions already accepted into the pool
multiplier_bps  = min(BOND_MULTIPLIER_BPS^n, BOND_CAP_MULTIPLIER × 10_000)
totalCost       = baseBond × multiplier_bps / 10_000
escrowed        = baseBond                                  (refundable / slashable)
burned          = totalCost − baseBond                       (sent to 0x…dEaD)
```

Worked example, `baseBond = 100`, `BOND_MULTIPLIER_BPS = 12_500`,
`BOND_CAP_MULTIPLIER = 10`:

| n | Multiplier | Total paid | Escrowed (base) | Burned (above-base) |
|---|---|---|---|---|
| 0 | 1.0000 | 100 | 100 | 0 |
| 1 | 1.2500 | 125 | 100 | 25 |
| 2 | 1.5625 | 156 | 100 | 56 |
| 3 | 1.9531 | 195 | 100 | 95 |
| 4 | 2.4414 | 244 | 100 | 144 |
| 5 | 3.0518 | 305 | 100 | 205 |
| 6 | 3.8147 | 381 | 100 | 281 |
| 7 | 4.7684 | 477 | 100 | 377 |
| 8 | 5.9605 | 596 | 100 | 496 |
| 9 | 7.4506 | 745 | 100 | 645 |
| 10+ | 10.000 (cap) | 1000 | 100 | 900 |

### Reviewer verdict on multi-submission bounty

The reviewer signs an EIP-712 `Verdict` payload that names:

- `winningSubmissionId` — `0` means **reject all** (sponsor refunded, all
  bonds returned to honest submitters).
- `slashedSubmissionIds[]` — submissions the reviewer flags as spam / bad
  faith. Bonds slashed.

### Bond outcomes

| Submission outcome | Base bond | Above-base (already burned) |
|---|---|---|
| **Winner** | returned + USDC payout | gone |
| **Honest non-winner** | returned in full | gone |
| **Slashed (spam)** | split 40% reviewer / 30% FEE_RECIPIENT / **30% burn** | gone |
| **Reject-all verdict** | all bonds returned (no slash) | gone |

The 30% burn on slashed bonds is the v0.1 BOUNTY sink that the strategic memo
flagged. Combined with above-base submission burns and the 50% protocol-fee
burn (below), every spam attempt and every accepted bounty contributes to
permanent supply contraction.

This makes spam costly without punishing honest competitors. A submitter who
puts in real work and loses on quality gets their bond back. A submitter who
spams the pool loses their bond and donates to the reviewer who policed them.

## Hybrid reviewer assignment

```
1. Sponsor calls createBounty() with `proposedReviewer = 0xA`.
2. BountyEscrow opens a REVIEWER_REJECT_WINDOW (12h default).
3. During the window:
   a. Reviewer 0xA can accept → bounty → Funded → InReview.
   b. Reviewer 0xA can reject() → bounty enters "pool" state, any registered
      reviewer can claim() via VerdictModule.claimPoolBounty(bountyId).
   c. Window expires with no action → identical to (b); pool can claim.
4. First registered reviewer to call claimPoolBounty() locks the assignment.
```

The point: sponsors can express preference, but they cannot block bounties by
proposing a reviewer who never responds.

## EIP-712 verdict struct

```solidity
bytes32 internal constant VERDICT_TYPEHASH = keccak256(
    "Verdict(uint256 bountyId,uint256 winningSubmissionId,uint256[] slashedSubmissionIds,bytes32 evidenceAnchor,uint256 expiresAt,uint256 nonce)"
);

struct Verdict {
    uint256   bountyId;
    uint256   winningSubmissionId;   // 0 = reject-all
    uint256[] slashedSubmissionIds;  // empty = nobody slashed
    bytes32   evidenceAnchor;        // hash of citations + reasoning bundle
    uint256   expiresAt;
    uint256   nonce;                 // per-reviewer nonce
}
```

Reviewer signs off-chain. Any party can submit on-chain via
`VerdictModule.submitVerdict(verdict, signature)`. The contract verifies the
sig, checks the reviewer is registered + assigned, advances state.

## Settlement math (accepted, single-winner)

```
payoutMax              = 1000 USDC
PROTOCOL_FEE_BPS       = 100        (1%)
PROTOCOL_FEE_BURN_BPS  = 5_000      (50% of the protocol fee burns)
REVIEWER_FEE_BPS       = 300        (3%)

protocolFeeTotal   = 1000 × 100 / 10_000           = 10 USDC
protocolFeeBurn    = 10 × 5_000 / 10_000           =  5 USDC → 0x…dEaD
protocolFeeKeep    = 10 − 5                         =  5 USDC → FEE_RECIPIENT
reviewerFee        = 1000 × 300 / 10_000           = 30 USDC → reviewer
hunterPayout       = 1000 − 10 − 30                = 960 USDC → winning submitter (hunter)
```

USDC cannot literally be burned (it is a centralized asset; sending to
0x…dEaD just removes it from useful circulation but Circle still mints
the supply). For v0.1 the "burn" address is treated as a write-off equivalent
and the address is configurable so v0.2 can route this fraction into the
CAUTIONER underwriting pool instead.

On reject-all, full refund to sponsor; reviewer earns nothing. v0.2 adds an
"honest reject" fee paid from a different pool.

### Sponsor BOUNTY fee discount (v0.1 scaffolded, default-disabled)

If the sponsor holds at least `SPONSOR_DISCOUNT_THRESHOLD` BOUNTY at
`fundBounty` time, `PROTOCOL_FEE_BPS` is replaced by
`SPONSOR_DISCOUNTED_FEE_BPS` (default 50 bps) for that bounty's settlement.

```
discounted protocolFeeTotal  = 1000 × 50 / 10_000  = 5 USDC
discounted protocolFeeBurn   = 5 × 5_000 / 10_000  = 2.5 USDC
discounted protocolFeeKeep   = 5 − 2.5             = 2.5 USDC
discounted hunterPayout      = 1000 − 5 − 30       = 965 USDC
```

The threshold defaults to 0 in v0.1 (i.e. the discount is effectively
disabled at deploy until governance sets it). The mechanism exists so the
admin role can flip it on without redeploying.

## Settlement math (spam slashed)

Continuing the 5-submission example, reviewer picks #3 as winner, slashes
#5 as spam, with the new 40/30/30 split:

| Pool of base bonds (500 total) | To |
|---|---|
| #1, #2, #3, #4 (= 400) | returned to submitters in full |
| #5 (100) | 40 reviewer, 30 FEE_RECIPIENT, 30 burned |

Reviewer total v0.1 earnings on this bounty:
- 30 USDC (REVIEWER_FEE_BPS skim of payoutMax)
- 5 USDC (half of the 1% protocol fee — actually wait, the protocol fee goes 50% burn / 50% FEE_RECIPIENT, not to reviewer)
- 40 BOUNTY (40% of slashed #5 base)

Burned forever from this bounty:
- 320 BOUNTY (above-base submission portion)
- 30 BOUNTY (slashed #5 burn share)
- 5 USDC (protocol fee burn share — written off)

Permanent BOUNTY supply contraction per accepted, lightly-slashed bounty:
**350 BOUNTY** in this example. At 1k bounties/month with similar dynamics
that is 350k BOUNTY/month sink, against ~100 BOUNTY/bounty new emission
(reviewer fee + reviewer slash share) — net deflationary at scale.

## Storage layout (BountyEscrow)

```solidity
enum BountyState {
    Draft, Funded, InReview, Queued, Settled, Claimed, Refunded, Disputed
}

struct Bounty {
    address sponsor;
    address proposedReviewer;
    address assignedReviewer;       // 0 until accepted from pool
    uint96  reviewerProposedAt;     // for REVIEWER_REJECT_WINDOW
    uint256 payoutMax;              // USDC
    uint256 baseBond;               // BOUNTY per submission
    uint64  reviewWindow;
    uint64  challengeWindow;
    uint64  fundedAt;
    bytes32 specHash;               // IPFS CID of the spec
    BountyState state;
    uint256 winningSubmissionId;    // set on Queued
    uint256[] submissionIds;        // ordered, n_existing = .length
}

struct Submission {
    uint256 bountyId;
    address submitter;
    uint64  submittedAt;
    uint256 paidBond;               // base portion (above-base already burned)
    bytes32 artifactHash;
    bytes32 evidenceHash;
    bool    isSlashed;              // set by SettlementModule on settle()
}

mapping(uint256 => Bounty)     internal bounties;
mapping(uint256 => Submission) internal submissions;
uint256 internal nextBountyId;
uint256 internal nextSubmissionId;
```

## Test plan

| File | Coverage targets |
|---|---|
| `test/MockBOUNTY.t.sol` | mint/burn/transfer; access control on mint |
| `test/MockUSDC.t.sol` | mint/burn/transfer; permit; 6-decimal arithmetic |
| `test/BountyEscrow.t.sol` | full state machine, single-submission happy path, refund branches |
| `test/BountyEscrow.MultiSubmission.t.sol` | bond escalator, burn accounting, 40/30/30 slash mechanics, gas at MAX_SUBMISSIONS |
| `test/VerdictModule.t.sol` | reviewer registry, scaling stake floor, bond accounting, EIP-712 verify, pool assignment |
| `test/SettlementModule.t.sol` | payout splits, fee burn, sponsor discount path, claim flow |
| `test/E2E.t.sol` | post → fund → submit (×5) → assign → verdict → settle → claim |
| `test/E2E.Disputed.t.sol` | post → fund → submit → verdict → dispute → resolve |
| `test/Memo.SinkAccounting.t.sol` | invariant: burn balance only ever grows; supply contraction on accepted bounty |
| `test/Memo.SponsorDiscount.t.sol` | discount flip via `setSponsorDiscount`; balance check at fund time |

`forge coverage` target: ≥90% lines per AGENTS.md.

## Gas budget (target on Base)

| Operation | Target |
|---|---|
| `createBounty` | < 150_000 |
| `fundBounty` (USDC transfer) | < 100_000 |
| `submit` (n=0) | < 200_000 |
| `submit` (n=10, near cap) | < 250_000 |
| `submitVerdict` (single winner) | < 150_000 |
| `submitVerdict` (5 slashed) | < 250_000 |
| `settle` | < 200_000 |
| `claim` | < 80_000 |

Numbers will be ratified by `forge snapshot` once the contracts are written.

## v0.2 hooks scaffolded in v0.1

These are real wiring points in the v0.1 contracts so that v0.2 can ship
without redeployment. Each is gated by an admin role and a default-off
configuration.

| v0.2 capability | v0.1 scaffold | Activation path |
|---|---|---|
| **Chainlink-native optimistic challenge resolver** | `BountyEscrow.challengeContract` address (default `0x0`); `Disputed` state has the same shape v0.2 will need; events carry challenge metadata. The v0.1 manual `DISPUTE_RESOLVER_ROLE` is the human placeholder for the v0.2 Chainlink-Functions-driven resolver. | Deploy `ChallengeResolver` contract that holds a Chainlink Functions subscription, owns `DISPUTE_RESOLVER_ROLE` on `BountyEscrow`, accepts challenger bond, requests off-chain verification (re-run acceptance check, hit verifier endpoints, aggregate N sources), and writes the signed verdict back. `setChallengeContract(addr)` activates it. **Same Chainlink stack that underpins CAUTIONER nat-cat triggers — unified oracle path across the protocol.** |
| **EAS attestations for portable reviewer reputation** | `SettlementModule.easAttester` address; `SettlementModule` emits a `VerdictAttested(bountyId, reviewer, decision, payload)` event whose payload is the EAS-encoded attestation. v0.1 emits the event but does not yet call EAS. | Register the EAS schema on Base; deploy a thin attester contract; `setEasAttester(addr)` flips the call from event-only to event + EAS attestation. |
| **Sponsor BOUNTY fee discount** | All params + math live in `SettlementModule._distribute`; `SPONSOR_DISCOUNT_THRESHOLD` defaults to 0 (effectively disabled). | `setSponsorDiscount(threshold, discountedBps)` enables the discount when governance approves. |
| **Cautio underwriting-pool routing** | `FEE_RECIPIENT` is settable by admin; treasury share + protocol-fee-burn share both route through it. The v0.1 default is the deployer multisig (treasury safe). | When Cautio deploys, `setFeeRecipient(cautioFeeRouterAddr)` redirects all protocol fees to the Cautio fee router. The router splits 60% to stakers / 25% to team / 15% to treasury per the public schedule on /staking. CAUTIONER itself is a separate ERC20 (100M supply, airdropped at snapshot) that confers tier-access + governance — see `CAUTIO-DESIGN.md`. |

## Open items still deferred to v0.2

1. Oracle-driven slashing (Chainlink Functions trigger from off-chain events).
2. N-of-M reviewer quorum (challenge-time panel).
3. Commit-reveal on submissions (prevent sponsor / reviewer collusion).
4. Reviewer reputation scoring / pause-via-stale-bond.
5. Submission slot reservations (a separate Dutch-auction mechanism for high-demand bounties).
6. Permit-based fundBounty (one-tx USDC funding via EIP-2612).
7. veBOUNTY for reviewer admission weighting (longer lock = more concurrent assignments).

## References

- State machine + role definitions: <https://agentbounty.dev/how-it-works>
- Object schemas (Bounty, Submission, Review, Reviewer): <https://agentbounty.dev/reference>
- Public copy on the staking page: <https://agentbounty.dev/staking>
- AGENTS.md (repo conventions): `~/.factory/droids/` and `agentbounty-beta/AGENTS.md`
