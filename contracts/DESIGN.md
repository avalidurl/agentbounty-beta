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
| `FEE_RECIPIENT` (immutable address) | treasury safe | underwriting pool | receives protocol fee on settlement |

## Tunable parameters

| Param | Default | Meaning |
|---|---|---|
| `MIN_REVIEWER_BOND` | 1_000_000 × 10¹⁸ BOUNTY | Min BOUNTY a reviewer must lock to register. |
| `PROTOCOL_FEE_BPS` | 100 (1%) | Skim of `payoutMax` to FEE_RECIPIENT on accepted bounty. |
| `REVIEWER_FEE_BPS` | 300 (3%) | Skim of `payoutMax` to reviewer on accepted bounty. |
| `MAX_REVIEW_WINDOW` | 14 days | Sponsor's review_window cap. |
| `MAX_CHALLENGE_WINDOW` | 7 days | Sponsor's challenge_window cap. |
| `REFUND_AFTER` | 30 days | After this with no acceptance, sponsor can refund. |
| `BASE_BOND` | 100 × 10¹⁸ BOUNTY | Default per-submission base bond. Sponsor-configurable per bounty. |
| `BOND_MULTIPLIER_BPS` | 12_500 (1.25×) | Per-submission bond escalator. |
| `BOND_CAP_MULTIPLIER` | 10 | Hard ceiling on cumulative multiplier. |
| `MAX_SUBMISSIONS` | 50 | Cap to bound gas. |
| `REVIEWER_REJECT_WINDOW` | 12 hours | Time sponsor's proposed reviewer has to reject the assignment. |

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
| **Slashed (spam)** | split 50% reviewer / 50% FEE_RECIPIENT | gone |
| **Reject-all verdict** | all bonds returned (no slash) | gone |

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
payoutMax          = 1000 USDC
PROTOCOL_FEE_BPS   = 100   (1%)
REVIEWER_FEE_BPS   = 300   (3%)

protocolFee        = 1000 × 100 / 10_000 = 10 USDC → FEE_RECIPIENT
reviewerFee        = 1000 × 300 / 10_000 = 30 USDC → reviewer
hunterPayout       = 1000 − 10 − 30      = 960 USDC → winning submitter
```

On reject-all, full refund to sponsor; reviewer earns nothing. v0.2 adds an
"honest reject" fee paid from a different pool.

## Settlement math (spam slashed)

Continuing the 5-submission example, reviewer picks #3 as winner, slashes
#5 as spam:

| Pool of base bonds (500 total) | To |
|---|---|
| #1, #2, #3, #4 (= 400) | returned to submitters in full |
| #5 (100) | 50 to reviewer, 50 to FEE_RECIPIENT |

Reviewer total v0.1 earnings on this bounty:
- 30 USDC (REVIEWER_FEE_BPS skim of payoutMax)
- 50 BOUNTY (half of slashed #5 base)

The above-base 320 BOUNTY was burned at submission time and never re-enters
circulation.

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
| `test/BountyEscrow.MultiSubmission.t.sol` | bond escalator, burn accounting, slash mechanics, gas at MAX_SUBMISSIONS |
| `test/VerdictModule.t.sol` | reviewer registry, bond accounting, EIP-712 verify, pool assignment |
| `test/SettlementModule.t.sol` | payout splits, fee routing, claim flow |
| `test/E2E.t.sol` | post → fund → submit (×5) → assign → verdict → settle → claim |
| `test/E2E.Disputed.t.sol` | post → fund → submit → verdict → dispute → resolve |

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

## Open items deferred to v0.2

1. Oracle-driven slashing (Chainlink Functions trigger from off-chain events).
2. CAUTIONER underwriting pool routing for `FEE_RECIPIENT`.
3. N-of-M reviewer quorum.
4. Commit-reveal on submissions (prevent reviewer collusion).
5. Reviewer reputation scoring / pause-via-stale-bond.
6. Submission slot reservations (a separate Dutch-auction mechanism for high-demand bounties).
7. Permit-based fundBounty (one-tx USDC funding via EIP-2612).

## References

- State machine + role definitions: <https://agentbounty.dev/how-it-works>
- Object schemas (Bounty, Submission, Review, Reviewer): <https://agentbounty.dev/reference>
- Public copy on the staking page: <https://agentbounty.dev/staking>
- AGENTS.md (repo conventions): `~/.factory/droids/` and `agentbounty-beta/AGENTS.md`
