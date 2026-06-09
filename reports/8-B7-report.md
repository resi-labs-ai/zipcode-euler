# 8-B7 report — Harvest/vote module (`HarvestVoteModule`)

**TL;DR.** Authored + built + KEPT the 4th engine Zodiac Module — the per-epoch emissions+governance leg of the
auto-sodomizer. It claims the gauge's oHYDX, takes the free `exerciseVe` vote-floor slice, re-votes our gauge, and
claims the rebase. **26/26 green** (21 unit + 5 Base-fork), **326/326 total no-regression**, **ZERO load-bearing
guesses**. The window's real work was **reverse-verifying the un-open-sourced Hydrex host on live Base** and fixing
**5 spec mis-citations** in §4.5.1 / `baal-spec §10.8` before drafting — the most important being that **Hydrex's
VoterV5 is account-keyed, not tokenId-keyed**, which collapses the module to a stateless (no-tokenId) design.

---

## What the window did
1. **Read the chain before the prose.** The Hydrex core is not open-sourced (the spec citations predate the on-chain
   verification the other legs got). I reverse-read the VoterV5 / veHYDX / oHYDX / Minter / RewardsDistributor
   deployed bytecode + staticalled views on Base 8453, and found the §4.5.1 8-B7 block mis-cited the host on five
   points. **Fixed `claude-zipcode.md §4.5.1` + `baal-spec §10.8` FIRST** (harness: spec-gap → fix spec first).
2. Drafted the build ticket (`tickets/sodo/8-B7-harvest-vote.md`) — build-only (internal engine plumbing; the CRE
   robot drives every entrypoint). Primary model = the sibling `LpStrategyModule` (8-B6), the closest no-EVC/no-oracle
   shape.
3. **5-critic fanout** (junior / spec-fidelity / ref-verifier / qa / security). Spec-fidelity verdict: **FAITHFUL**
   (no §17 reopen, no inbound cross-ticket obligations owed by 8-B7). All other findings were ticket gaps → folded.
4. **Cold-build (fresh subagent), zero load-bearing guesses, independently re-ran green.** Kept on disk.
5. Concluded: ticket filed, PROGRESS + LEDGER updated, spec corrections saved, this report. **NEXT = 8-B8.**

## The 5 spec corrections (all reverse-verified from deployed bytecode, Base 8453, this window)
| # | Spec said | On-chain truth | Evidence |
|---|---|---|---|
| 1 | `Voter.vote(uint256 tokenId, address[], uint256[])` + `Voter.reset(uint256 tokenId)` | **account-keyed**: `vote(address[],uint256[])` `0x6f816a20` + `reset()` `0xd826f88f` — NO tokenId | the tokenId variants `0x7ac09bf7`/`0x310bd74b` are ABSENT in the impl bytecode; `lastVoted(address)` + `ve()` present (account accounting) |
| 2 | "State: the veHYDX `tokenId`" | **no single tokenId** — each `exerciseVe` mints a FRESH account-owned veNFT; the Voter aggregates by account | the team voter `0xd9e966a6…` holds `ve.balanceOf == 40` |
| 3 | floor read = `ve.balanceOfNFT(tokenId)` | floor = **`ve.getVotes(account)`** (account aggregate) `0x9ab24eb0` | `getVotes(team)=2.798e26` **>** `balanceOfNFT(#1)=2.787e26` (proves aggregation across the 40 NFTs) |
| 4 | "Minter rebase claim" | rebase on the **RewardsDistributor** (`Minter._rewards_distributor()`=`0x6FCa200f…`), `claim_many(uint256[])` `0x1f1db043` | `claimable(1)` staticcalled non-zero on the RD |
| 5 | `Voter.getEpochDuration() (=604800)` | **correct** (kept) | staticcall returned 604800 |

None reopen §17 (CRE-permissioned single writer / venue-agnostic / no on-chain liquidation all preserved). These are
mechanism-fidelity corrections of an un-open-sourced host — the build follows the chain, not the prose.

## The design (what to sanity-check)
- **Stateless beyond set-once wiring — NO tokenId.** Because the Voter is account-keyed and `exerciseVe` mints fresh
  NFTs the account aggregates, the module needs no tokenId tracking, no `merge`, no on-chain enumeration. I considered
  a "canonical-tokenId via `merge`" design (which would have rehabilitated the spec's tokenId state) and **rejected
  it** (memory `prefer-simplest-mechanism`): merge semantics on an un-open-sourced contract are unverifiable, and the
  account-keyed reality makes it unnecessary. The rebase array is operator-curated (the only place a tokenId appears,
  as a passthrough arg). **Decision to confirm: stateless/no-merge is the right call.**
- **Scoped out the veHYDX voting bribes/fees** (8-B7 claims only the oHYDX emission via `gauge.getReward()`). Rationale:
  the gauge swap fees auto-compound inside the ICHI ALM vault → captured in the LP/NAV mark; the voting bribes are a
  per-NFT Bribe-contract claim, our gauge isn't whitelisted yet, and it's economically minor in M1. Logged as a
  deferred-extension obligation + flagged to reconcile with the §10.6 #3 / §7 "veHYDX fees" refinery marking.
  **Confirm you're OK deferring this.**
- **Security: `lockVe` is uncapped on-chain and `exerciseVe` is irreversible** (permalocked veHYDX = ~0-principal,
  non-redeemable, NOT exit collateral). The module can't bound it (stateless, no basket-size notion), so I logged a
  hard obligation: **8-B11 must bound `lockVe` to the regime floor `s*`; 8-B12 must tripwire `voteFloor` vs
  `pendingReward`** (detection must precede the irreversible lock). It never touches depositor principal / zipUSD / LP,
  so structural exit collateral is safe — but this is the one residual trust-the-operator surface worth your eyes.
- **`vote` pools are operator-supplied (no on-chain whitelist).** Security critic concurred: pinning a whitelist would
  duplicate 8-B11 policy on-chain and fight §17's single-trusted-writer model; blast radius is one epoch (votes reset
  weekly, `resetVote` unwinds), and assets never move regardless of the vote. **Decision to confirm: trust-operator,
  don't pin.**

## Build-exposed corrections (folded into the ticket)
1. Live `vote` needs the veNFT to **predate the epoch's voting-power snapshot** + `Minter.update_period()` — else
   `InsufficientVotingPower()` / `EpochStale()`. The fork test warps to the next 1-week boundary first. (Module is
   correctly epoch-agnostic; this is 8-B11 CRE sequencing.)
2. The Voter enforces a **per-account ~1h vote-delay** between vote/reset actions → `VoteDelayNotMet()`. Fork test
   warps +1h between vote→reset→re-vote (same epoch).
3. **`exerciseVe` needs NO approval — CONFIRMED on-chain** (burns oHYDX from the Safe directly; the fork asserts the
   balance drops by exactly `amount`). No approval branch added (the ticket's load-bearing claim holds).
4. `HYDREX_VE` is an alias of the existing `VEHYDX` constant (same address).
5. `lastVoted(address)` kept OFF the production `IVoter` (the module never reads it; the fork test uses a test-local
   interface) — keeps the production interface minimal.

## Authoritative-doc edits
- `claude-zipcode.md §4.5.1` — the 8-B7 block rewritten to the account-keyed surface (the 5 corrections).
- `reports/design/baal-spec.md §10.8` — the 8-B7 "Where it lives" + "Source + addresses" lines corrected to match (the staging
  companion the ticket was authored from).
- `tickets/PROGRESS.md` — 8-B7 row DONE, NEXT=8-B8, banner updated, 5 new obligation rows, the spec-gap log entry, the
  session-log line.
- `tickets/LEDGER.md` — the 8-B7 design digest.
- No `audit/*` edits (the engine-integration audit sweep is the deferred item-10 pass, logged as an obligation, like
  8-B5/8-B6/Exit-Gate).

## Judgment calls
- **Kept on disk, NOT git-committed** (the whole tree is untracked — every prior 8-B window left the commit decision to
  you; I followed that norm rather than make an unrequested commit).
- Did **not** author an INFLOW interface ticket (build-only internal plumbing — matches 8-B5/8-B6/8-B14).

## Status
- **8-B7 DONE / BUILT-VERIFIED + KEPT.** Code at `contracts/src/supply/szipUSD/HarvestVoteModule.sol` +
  `contracts/test/HarvestVoteModule.t.sol`, **`forge test [--fork-url $BASE_RPC_URL] --match-contract HarvestVoteModule`
  green (26/26), 326/326 total — run it yourself.**
- **NEXT = 8-B8** (exercise/strike-financing module — LP → reservoir collateral → CRE-borrow USDC → exercise oHYDX →
  HYDX; depends 8-B5 + 8-B7; `reports/design/baal-spec.md §10.8` / §4.5.1 8-B8 block).
