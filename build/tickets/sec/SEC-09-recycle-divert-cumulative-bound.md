# SEC-09 — `RecycleModule.divert` cumulative hole bound (M7)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` M7 (FIX, fix-mechanism CORRECTED); audit
`findings.md` (M7); `build/claude-zipcode.md` §8.4/§11 (provision/recovery) · **Status:** PROPOSED

> Scope authored 2026-06-15. The fix MECHANISM matters: do NOT key a tally by the provision value
> (`divertedAgainst[hole]`) — provision is a single re-markable scalar, so a value key is buggy (a
> `$100 → $80 → $100` re-mark would resurrect the stale tally). Use `lastSeenProvision` +
> `divertedSinceProvisionChange`, reset on any change.

## Deliverable
Bound `divert` **cumulatively** against the live hole across calls (not just per-call), via a running tally
that resets whenever the provision is re-marked — so total diverted USDC can never exceed the hole.

## What it does / what's being fixed (plain language)
`divert` supplies free-value USDC into the senior pool to fill the junior **hole** (`provision()`, the §11
markdown). Each call checks `usdcAmount * 1e12 <= hole`, but `divert` never writes `provision` (the CRE reduces
the hole later via `DefaultCoordinator.Recovery`). So between provision re-marks, several diverts that each pass
the per-call check **cumulatively over-fill** the hole (e.g. hole = $100; divert $60, then $60 again → $120 into
a $100 hole). The docstring's "a divert can never over-fill it" is true per-call but false across calls.

## Binds to (verified file:line — 2026-06-15)
- **`divert`:** `contracts/src/supply/szipUSD/RecycleModule.sol:285-310`. Per-call bound at `:290`
  (`if (usdcAmount * 1e12 > hole) revert ExceedsHole();`); hole read fresh at `:287`
  (`ISzipNavProvision(navOracle).provision()`); `:282-283` documents that divert never writes provision.
- **False claim to correct:** docstring `:270-283` ("a divert can never over-fill it", `:272`).
- **Units (verified):** `provision()` is 18-dp USD; `usdcAmount` is USDC 6-dp; `* 1e12` scales to 18-dp (`:275`).
  Keep the tally in 18-dp USD to match `hole`.

## Key requirements
1. **Add state:** `uint256 public lastSeenProvision;` and `uint256 public divertedSinceProvisionChange;`
   (both 18-dp USD).
2. **Reset-on-change + cumulative bound in `divert`,** after reading `hole` (`:287`) and the `hole == 0` check:
   ```solidity
   if (hole != lastSeenProvision) {            // provision was re-marked → fresh budget
       lastSeenProvision = hole;
       divertedSinceProvisionChange = 0;
   }
   uint256 scaled = usdcAmount * 1e12;          // USDC 6-dp -> USD 18-dp
   if (divertedSinceProvisionChange + scaled > hole) revert ExceedsHole();  // strict > → exact fill allowed
   ```
   Reuse the existing `ExceedsHole` error. Keep the original per-call intent subsumed by the cumulative check
   (the cumulative check is strictly tighter; a separate per-call check is redundant — replace `:290`).
3. **Increment the tally in the effects phase** (CEI): `divertedSinceProvisionChange += scaled;` BEFORE the
   external Safe-driven deposit (alongside / right after `_spendFreeValue`), so a reentrant call sees it.
4. **Do NOT have `divert` write `provision`** — preserve the design where the CRE reduces the hole later
   (`:282-283`). Reset is triggered by *observing* a changed `provision()`, never by mutating it.
5. **Update the docstring** (`:270-283`) — the over-fill guard now holds cumulatively; document
   `lastSeenProvision` / `divertedSinceProvisionChange` + reset-on-change.

## Do NOT
- Do NOT key the tally by the provision value (`mapping(uint256 hole => uint256 diverted)`) — re-mark churn
  resurrects stale tallies. Use `lastSeenProvision` (last observed) + a single running counter.
- Do NOT make `divert` write/decrement `provision` — the CRE owns the hole reduction.
- Do NOT change the USDC→USD scaling (`* 1e12`), the `BackingShortfall`/`NoSharesMinted` post-guards, or the
  `_spendFreeValue` CEI ordering — only add the cumulative bound + tally.
- Do NOT widen scope to other kill-list groups.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC09_*` regression test** that fails before / passes after:
  - **Cumulative over-fill blocked:** with `provision() == H`, two diverts that each individually pass
    (`amount*1e12 <= H`) but together exceed `H` — assert the second reverts `ExceedsHole` (pre-fix both pass,
    total diverted > H).
  - **Exact cumulative fill allowed; one wei over reverts.**
  - **Reset on re-mark:** after filling toward `H`, re-mark `provision()` to a new value `H'`; assert the tally
    resets so a fresh divert up to `H'` is allowed (not permanently stuck), AND the stale-value case
    (`H → H'' → H`) does NOT resurrect the old tally.
  - **Divert never writes provision:** assert `provision()` is unchanged across a successful `divert`.
- Quote the actual `forge test` output in this ticket's done note. (Extend the RecycleModule test fixture.)

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-09" with the finding note.
