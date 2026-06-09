# Exit Gate + szipUSD — authoring-window report to the superintendent

**From:** the builder Claude (ticket-authoring harness). **To:** the superintendent.
**Item:** `Exit Gate + szipUSD` (absorbs the old 8-B2 mint shaman + 8-B3 lock/freeze shaman) — the junior share +
the windowed exit valve (§6.4/§7 / `baal-spec.md §4/§5/§7`).
**Date:** 2026-06-08. **Branch:** `main`.

> **UPDATE 2026-06-08 (user-directed rework — read this first).** The **exit mechanism in this report is superseded.**
> I first built the windowed exit as a **zipUSD-numeraire payout** (ragequit `[zipUSD]` only → pay `shares × navExit`
> → sweep surplus → forfeit the volatile legs), and flagged it as judgment-call #1. **The user overruled it: the exit
> is plain in-kind ragequit — "you leave, you get your share."** `processWindow` now does
> `ragequit(exiter, 0, shares, [zipUSD, xALPHA] sorted)` straight to the leaver (their pro-rata slice of the free
> basket, in-kind) + burn the loot. **No oracle, cap, numeraire, sweep, or fundability check on exit** — the slice
> self-prices to NAV. JC1 (and its "M1 zipUSD-sufficiency" caveat) is **dissolved**; the `NavZero` guard is removed;
> `valueOf` stays (issuance only). The xALPHA→zipUSD dump is a separate new ticket (`tickets/sodo/8-B-exit-autodump.md`);
> zipUSD→USDC is the existing `ZipRedemptionQueue`. Code reworked, `forge test` **174/174 still green**. The sections
> below that describe the zipUSD-numeraire exit (TL;DR exit bullet, §6.4 edit, "what's fork-proven" exit lines, JC1)
> are the old design — kept for the audit trail, corrected by this note.

## TL;DR
- Authored + **BUILT-VERIFIED** the two-token junior surface: `SzipUSD` (transferable 18-dp ERC-20, `onlyGate`
  mint/burn) + `ExitGate` (the sole Baal `Loot` custodian holding `manager`=2, the sole szipUSD minter/burner, the
  sole `ragequit` caller). Flows: `depositFor` (NAV-proportional issuance), `requestExit`/`cancelExit` (intent
  queue), `processWindow` (keeper-driven windowed ragequit, paid zipUSD at `navExit`, partial-fill = the freeze),
  `burnFor` (the §7/8-B14 paired buy-and-burn retire).
- Code on disk, kept, `forge test` green: **17/17 new tests on a LIVE Base-mainnet fork** (real Baal substrate via
  `SummonSubstrate._summon`, the real `SzipNavOracle`, mock basket assets); **174/174 total, no regression**.
  Files: `contracts/src/supply/szipUSD/ExitGate.sol` (~270 LOC) + `SzipUSD.sol` + `contracts/test/ExitGate.t.sol`.
  Run: `forge test --match-contract ExitGateTest --fork-url $BASE_RPC_URL`.
- **2 spec gaps fixed in `claude-zipcode.md`** (both critic-confirmed; no §17 reopened) + **`valueOf` added to the
  kept `SzipNavOracle`** (the issuance valuation seam; 42/42 oracle suite, 39 prior un-regressed).
- **Both inbound obligations DISCHARGED** (8-B1 F4.2 manager-grant/zero-Shares; the `SzipNavOracle` NAV-pricing seam).
- **NEXT = cold-build WOOF-06** (the zap, re-authored 2026-06-07) against the now-real `gate.depositFor` seam.

## Spec edits this window (please sanity-check — spec-fidelity + ref-verifier confirmed both faithful, no §17 reopened)
1. **§7** — the `SzipNavOracle` description listed `navEntry`/`navExit`/`poke`/`fresh`/`grossBasketValue` but **no
   per-asset deposit valuation**, yet the Gate must value a deposit without the caller asserting a price (§3.4).
   Added **`valueOf(address asset, uint256 amount) public view`** to the §7 surface AND to the **kept oracle**
   (`contracts/src/supply/SzipNavOracle.sol`) — a public projection of the existing private `_tokenValue`/
   `_legPriceOfToken` (zipUSD→$1, xALPHA→two-layer mark, reverts `UnknownLpToken` off-whitelist). **Additive, no
   behavior change**; +3 unit tests; the 39 prior oracle tests stayed green (42/42). This was the most-blocking item
   (the Gate can't compile without it), so I fixed the dependency FIRST per the harness.
2. **§6.4 item 3** — named the **set-once `windowController`** (the CRE-operator/keeper that opens windows — the
   §4.5 item-0 *operator* tier) and pinned the **window-exit numeraire = zipUSD at `navExit`** with the
   **forfeit-volatile-pro-rata + sweep-surplus** mechanics. The canonical text said "pays at `navExit` NAV" without
   naming the actor or the asset. spec-fidelity confirmed the zipUSD-numeraire exit is **faithful, not an invention**
   (it satisfies the locked "windowed ragequit at min(spot,twap), partial-fill" §17 decision) — the pin prevents drift.

## Critic fanout (5) → folded
junior-dev / spec-fidelity / ref-verifier / qa / security (full set — foundational/intricate contract). Consensus:
the design is faithful (spec-fidelity: 17/17 [OK], 2 [SPEC-GAP] above); ref-verifier confirmed every `reference/`
signature (ragequit arg order `(to, sharesToBurn=0, lootToBurn=s, tokens)`, `_msgSender()`-burns-from-caller at
`:647`, `_safeTransfer`→`execAndReturnData(Call)` = the Safe module path that moves the **main-Safe** treasury,
mintLoot/burnLoot `baalOrManagerOnly`, `isManager`∈{2,3,6,7}, setShamans `baalOnly`); security confirmed every
CRITICAL is PASS with the one structural discipline (the Gate never calls `mintShares` — enforced by code + asserted
`totalShares()==0`). ~20 ticket-clarity items folded in (the `_tokensZipUSDOnly()` helper, exact `queueHead`
advancement + FIFO-no-skip loop termination, empty-queue/`maxClaims==0`/`navExit==0`(→`NavZero`)/`burnFor(0)`/
double-cancel/`NotWired`/unsupported-asset edges, floor-division pins, invariant-after-every-path, reentrancy guards).

## What's fork-proven (the keep-the-build evidence)
- **Manager-grant gate (8-B1 F4.2):** on a *second* fresh substrate with no grant, `depositFor` reverts at
  `mintLoot` (`baalOrManagerOnly`); after `team→mainSafe.execTransaction→setShamans([gate],[2])` it succeeds.
- **Issuance:** genesis-par (12e18→12 shares at $1); NAV-proportional round-down ($1.20→10 shares via a basket
  donation); asset lands in the main Safe, the Gate holds **zero** residual; stale-leg → `StalePrice`; TVL cap.
- **Windowed exit:** paid in zipUSD at `navExit`; the **min(spot,twap) haircut accretes to stayers** (donation
  spikes spot to $2, exiter paid at the ~$1 twap, surplus swept back, stayer NAV rises); the two-token invariant
  `szipUSD.totalSupply()==loot.balanceOf(gate)` + `totalShares()==0` hold after every path.
- **Partial-fill = the freeze:** with free main-Safe zipUSD rotated to the sidecar, `processWindow` fills **nothing**
  (first claim unfundable from free equity, `queueHead` parked, sidecar untouched); after rotating equity back, both
  claims fill. No floor knob — the freeze is purely structural (ragequit reaches only the main Safe).
- **Buy-and-burn:** `burnFor` burns the engine Safe's szipUSD + the Gate's Loot, **basket untouched** (no asset
  payout), supply drops on both sides (invariant held), NAV ticks up.

## Design decisions to sanity-check (judgment calls)
1. **M1 exit numeraire = zipUSD, funded by ragequit (FLAGGED).** `processWindow` funds each claim from the zipUSD
   freed by ragequitting that claim's Loot against the main Safe, paying `shares×navExit` and forfeiting the
   volatile-leg pro-rata (the patient NAV exit is a value claim, not in-kind). It fully pays only while the free
   (main-Safe) basket holds enough zipUSD per share — **true in M1** (zipUSD-dominant pre-engine; the harvest
   unstakes LP→zipUSD into the main Safe before a window). A multi-asset shortfall simply **partial-fills fewer
   claims** (never reverts, never mis-pays). The general numeraire conversion (swap freed volatile legs→zipUSD) is
   the engine's job (8-B9, post-M1). **Is the M1 zipUSD-numeraire scoping acceptable, or should the Gate carry a
   numeraire-conversion hook now?** I judged: scope it to M1 (the engine isn't built; the basket is zipUSD-dominant).
2. **`NavZero` guard.** I made `processWindow` revert at `navExit==0` (fully-impaired/degenerate `provision≥gross`)
   rather than fill claims for 0 — so a recovering provision (§11) can write NAV back up before exits burn shares for
   nothing. Slightly beyond the literal spec; flagged. The queue/freeze holds exiters until recovery.
3. **TVL cap on the Gate.** I kept an immutable `tvlCap` on the Gate (baal-spec §5.1 lists it as a Gate
   responsibility) enforced as `grossBasketValue() + value ≤ tvlCap`. **8-B12 (`baal-spec §10.8`) also describes a
   dynamic measured `maxDeposit`** as the WOOF-06 deposit gate — there's an overlap. I treated the Gate cap as a
   simple hard backstop; the 8-B12 measured cap can layer on top at WOOF-06. Confirm the split is right.
4. **The Gate is a Baal manager-shaman + Loot holder, NOT a Safe Zodiac module.** It mints/burns Loot via
   `baal.mintLoot/burnLoot` (manager) and ragequits as the Loot holder — neither needs the Gate to be an enabled
   Safe module. Simpler + smaller surface. (The deposited asset routes to the main Safe via plain `transferFrom`, not
   a module call.)

## Process caveat — please note (same class as `SzipNavOracle`, non-blocking)
I authored AND built this in one window (no independent fresh-subagent zero-guess rebuild). Under keep-the-build the
kept, fork-green code is the source of truth, and WOOF-06 will consume the Gate's *interface from the real contract
on disk*, not the ticket — so it doesn't depend on the ticket being independently reproducible. A fresh window MAY
re-materialize `ExitGate`/`SzipUSD` from `tickets/sodo/8-B-exit-gate-szipusd.md` alone to formally close the gate if
you want it. The build surfaced no ticket contradiction (the critic fanout hardening held).

## Git
Kept on disk, **NOT committed** (the whole working tree is untracked on `main`, as for 8-B1 / `SzipNavOracle`). This
follows the established per-window pattern + the standing "commit only when the user asks" guidance; the commit
decision for the kept build remains yours/the user's (you flagged it in the `SzipNavOracle` review).

## Status + NEXT
**DONE — `tickets/sodo/8-B-exit-gate-szipusd.md` filed; code kept + 174/174 fork-green; PROGRESS/LEDGER updated.**
**NEXT = cold-build WOOF-06** (the zap — re-authored 2026-06-07 to the `gate.depositFor(zipUSD, amount, user)` seam;
now materialize/verify it against the real Gate on disk) → then **8-B14 buy-and-burn** (calls `gate.burnFor`) → the
engine **8-B5…B13**.
