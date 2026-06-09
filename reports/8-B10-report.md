# 8-B10 — Recycle module (`RecycleModule`) — report

> **REWORKED 2026-06-08 (user-directed single-sink redesign) — supersedes the builder report below.** After the
> original `RecyclePayoutModule` (recycle + dual payout + distributor) was built and reviewed, the user collapsed
> 8-B10 to a **single recycle sink**: `recycle(usdc)` = `_spendFreeValue` → `ZipDepositModule.deposit` (USDC →
> `CreditWarehouse` senior backing) → backed zipUSD minted **directly into the MAIN-Safe basket** (no
> `gate.depositFor`, no shares); 8-B6 single-sides it into the gauge-staked LP → **NAV-per-share accretes for every
> holder** (the depositor's M1 return; payout/xALPHA/distributor all removed). **DELETED:** `payoutClean`,
> `payoutBoost`, public `spendFreeValue`, `setCompounder`, the `xAlpha`/`distributor`/`compounder` wiring, and the
> entire `SzipRewardsDistributor` (+ its tests). **8-B13 REMOVED** (absorbed here — single-sided LP moots the
> balanced-add compounder). New code: `contracts/src/supply/szipUSD/RecycleModule.sol` +
> `contracts/test/RecycleModule.t.sol`, **19/19 (16 unit + 2 integrated + 1 Base-fork), superintendent-reverified**;
> `RecyclePayoutModule.*` + `SzipRewardsDistributor.*` deleted. Full suite **401/401 GREEN** (re-verified). An 8-B6
> fork non-determinism can intermittently show 2 `LpStrategyModuleForkTest` `DTL` reverts (unpinned `createSelectFork`
> + a fixed 1-WETH deposit into the live WETH/USDC ICHI stand-in `0x07e72…`); the contract passes 5/5 in isolation,
> zero coupling to this rework. Fix = pin the fork block in `ForkConfig`.
> Spec/docs reconciled (`claude-zipcode.md §4.5.1`/§2/§17; `baal-spec`/`auto-sodomizer §6,§11`/`treasury §4.7`).
> **Superintendent verdict: ON-TRACK.** *(The original builder report for the now-deleted `RecyclePayoutModule`
> follows, retained as the design-rationale record.)*

---

# 8-B10 — Recycle/payout module + the pull-claim distributor — builder report (SUPERSEDED)

**Status: DONE — BUILT-VERIFIED + KEPT on disk. 45/45 new (427/427 total, no regression). NOT git-committed (whole
tree untracked — superintendent commit decision pending).**

## TL;DR
Built the **7th engine Zodiac module**, `RecyclePayoutModule` — the auto-sodomizer's **free-value ledger** and its two
*distribute* sinks (Mode A clean USDC / Mode B boosted xALPHA) — plus its companion **`SzipRewardsDistributor`** (a
multi-asset Merkle cumulative-claim pull-claim YIELD distributor). It is the only engine module that carries real
mutable state: the single `uint256 freeValueAccrued` accumulator that 8-B9 credits, 8-B13 (Mode C) will spend, and the
free-value-only invariant (§8 inv. 3) is enforced on. Both inbound obligations discharged; two §4.5.1 spec-gaps fixed;
the spec-fidelity critic returned **zero** further gaps; zero load-bearing guesses; the real `ZipDepositModule.deposit`
backed-mint is proven both fork-free (against a real `ESynth`) and on a Base fork against a **real summoned Gnosis Safe**.

## What the window did
1. **Read** `nextsteps.md` / `PROGRESS.md` / the harness / `baal-spec §10.8` 8-B10 / `claude-zipcode.md §4.5.1` 8-B10 /
   `auto-sodomizer.md §6/§8/§11` / the §3 `RewardsDistributor` reference. Verified the dependency signatures
   (`SellModule._exec`, `ZipDepositModule.deposit`, the reference distributor leaf, OZ/zodiac paths).
2. **Fixed 2 §4.5.1 spec-gaps FIRST** (triage order). See "Spec edits".
3. **Drafted** `tickets/sodo/8-B10-recycle-payout.md`.
4. **Fanned out 5 critics** (junior-developer, spec-fidelity, reference-verifier, qa-engineer, security-engineer — the
   full set; foundational module owning the engine accumulator + a net-new distributor).
5. **Synthesized + triaged:** spec-fidelity found **zero** spec/ticket gaps of substance + confirmed both fixes correct
   (not a §17 reopen); reference-verifier confirmed all sources resolve (minor citation line-drift fixed); junior/qa/
   security surfaced ~30 TICKET-GAP folds (pinning + test-completeness + defensive notes) — **all folded into the
   ticket, no further spec change, no re-fan** (strict additions). Folds captured in a "Critic-hardening folded" ticket
   section.
6. **Built both contracts + both test suites for real and KEPT them.** `forge build` green; 45/45 new; 427/427 total.

## Design decisions to sanity-check (judgment calls)
1. **Built the `SzipRewardsDistributor` IN this window.** §4.5.1 names the Mode-A "pull-claim distributor
   (`RewardsDistributor`-shape)" and I just spec-disambiguated it from the M2 insurance-cohort snapshot distributor
   (§11). It is the natural payout target with no other home in the ledger. Multi-asset (one instance serves USDC +
   xALPHA), clean-room from the cited reference, **no `maxClaimable`/mint machinery** (the held balance is the cap; we
   distribute funded tokens, never a mintable one). If you'd rather split it to its own item, it's cleanly separable —
   but it's small and spec-named, so I folded it.
2. **`creditFreeValue` is single-arg + operator-trusted.** The spec writes `creditFreeValue(uint256 realizedUsdc)`
   (single arg) but the formula is `+= max(0, realized − borrowRepaid)`. The module cannot reconstruct historical
   realized/repaid on-chain, so the CRE passes the already-netted value — consistent with every sibling trusting the
   single immutable operator (§17). **Trust-boundary flagged in NatSpec + as an obligation:** `creditFreeValue` is
   unbounded, so the policy ceiling is operator-trusted (not crypto); the hard guarantee is layer (b), the real Safe
   balance pull. An over-credit could route depositor principal — bounded by §17's single CRE writer + the 8-B11
   fund-discipline / 8-B12 tripwire backstops.
3. **The `compounder` set-once seam for 8-B13.** §4.5.1/8-B13 say "8-B13 calls 8-B10's decrement mutator." I added an
   owner(Timelock)-set-once `compounder` + an `onlyOperatorOrCompounder` gate on `spendFreeValue`. Forward-compatible +
   spec-mandated; zero until wired (so only the operator can spend pre-wire). If you prefer the operator to do the
   Mode-C decrement itself (no compounder address), say so — but that decouples the gate from the spend, which the spec
   explicitly couples.
4. **Module is NOT `nonReentrant`; the distributor IS.** A `ModuleProxyFactory` clone never runs OZ `ReentrancyGuard`'s
   constructor (storage-init subtlety) and the siblings deliberately avoid it — the module's reentrancy safety is
   **effects-before-interaction** (decrement BEFORE the value-moving execs), proven by a mid-call readback test, plus the
   trusted set-once wired targets + `ZipDepositModule`'s own guard. The distributor has a real ctor + a caller-supplied
   `asset`, so it keeps `nonReentrant`.
5. **The decrement-before-exec ordering is OBSERVABLY proven** (qa's most-important catch): a `ReadbackZipDepositModule`
   whose `deposit` reads `module.freeValueAccrued()` mid-call asserts the spend was already applied at exec #2 time — a
   plain rollback test can't distinguish decrement-before from decrement-after.

## Holes surfaced → resolution
- **§4.5.1 "Loot holders"** (Mode A) → **szipUSD holders** (two-token model; `auto-sodomizer §6`). Spec-fixed.
- **§4.5.1 "State: payout-mode flag; distribution checkpoints"** → stateless (mode = entrypoint choice) + checkpoints in
  the distributor. Spec-fixed (same class as 8-B9's "per-epoch accumulator" gap).
- All other findings were TICKET-GAPS (events, guards, modifier, ctor, Merkle rule, fork rig, security negatives) →
  folded into the ticket; the build confirms them (zero discrepancies).

## Authoritative-doc edits
- **`claude-zipcode.md` §4.5.1 8-B10** — the two spec-fixes above (logged in `PROGRESS.md` → Open spec gaps).
- **`tickets/PROGRESS.md`** — 8-B10 row DONE; banner NEXT → 8-B13; 2 inbound obligations DISCHARGED; 6 new obligations
  logged; spec-gap entry.
- **`tickets/LEDGER.md`** — the 8-B10 design digest.
- No `audit/2.md` / `audit/3-results.md` edit (the per-epoch recycle/payout audit sweep is the deferred
  engine-integration pass, logged as an obligation — parity with 8-B5..B9).

## Cross-ticket obligations
- **Discharged:** 8-B9→8-B10 free-value hand-off (`creditFreeValue`); 8-B6 backed-zipUSD invariant (mechanism side —
  Mode-B/C mint only via `ZipDepositModule.deposit`, backed 1:1 by construction).
- **Created:** 8-B13 `spendFreeValue` seam; item-10/8-B11 wiring (atomic clone+setUp + distributor deploy + root
  posting); item-10 engine-integration audit sweep; 8-B11/8-B12 funding-precedes-claim + the NAV-XOR-accumulator + the
  CRE net-computation (all §17-trust-bounded backstops).

## Verification (run it yourself)
- `forge test --match-path test/RecyclePayoutModule.t.sol` → 22 unit + 3 integrated-no-fork (real `ZipDepositModule`/
  `ESynth`) pass; `--fork-url $BASE_RPC_URL` adds 2 Base-fork (real summoned Safe).
- `forge test --match-path test/SzipRewardsDistributor.t.sol` → 18 pass.
- `forge test --fork-url $BASE_RPC_URL` → **427/427** (was 382 after 8-B9; +45).
- Code: `contracts/src/supply/szipUSD/{RecyclePayoutModule,SzipRewardsDistributor}.sol` +
  `contracts/test/{RecyclePayoutModule,SzipRewardsDistributor}.t.sol`.

## NEXT
**8-B13 — Compounder / LP-rebalance (Mode C)** — the recycle loop's GROWTH sink; deps **8-B6 + 8-B10 now both DONE**.
It reuses 8-B10's `ZipDepositModule.deposit` backed-mint + spends `freeValueAccrued` via the new `setCompounder` seam +
8-B6's add/stake + 8-B9's `buyXAlpha`. **8-B11 (CRE robot) + 8-B12 (monitoring) are CRE/off-chain-dominant** (8-B11's
on-chain surface is just the `onlyOperator` gate already in every module — the Go workflow is `spec-clear-CRE.md`, TODO;
8-B12 is the `monitoring.md` dashboard), so 8-B13 is the last on-chain engine CONTRACT.
