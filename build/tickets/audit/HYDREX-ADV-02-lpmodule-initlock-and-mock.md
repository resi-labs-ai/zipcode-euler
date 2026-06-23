# HYDREX-ADV-02 — LpStrategyModuleDemoVAMM: dropped MastercopyInitLock (false invariant) + a mock that doesn't model Solidly mint

> **STATUS: BUILT + SHIPPED to `main` (2026-06-22).** Issue 1: the fork now inherits `MastercopyInitLock`
> (was plain `Module`) — the mastercopy is genuinely init-locked, the false docstring/X-Ray claim is now
> true (proven by `test_mastercopy_cannot_be_setUp`). Issue 2: `MockVammPair.mint` now faithfully models
> real Solidly `mint` — `min(in0·S/r0, in1·S/r1)` with the larger side's excess donated (was a non-donating
> leg-sum); the share-math suite + fuzz were rewritten to the real formula against a seeded pool, and gained
> `test_addLiquidity_donatesExcessOfMisSizedSide` + `test_addLiquidity_singleSided_mintsZero_revertsOnFloor`.
> Hydrex suite **51/51 green** (24 LP + 27 NAV), `forge build` clean. X-Ray corrected. (Optional on-chain
> ratio-band guard not added — the no-custody grief-bound makes it unnecessary for the demo.)

> BUILD item (LOW + an assurance MED). Source: adversarial-review on
> `contracts/src/hydrex-demo-fork/LpStrategyModuleDemoVAMM.sol` (synthesis under
> `adversarial-review/reports/src/hydrex-demo-fork/lpstrategymoduledemovamm/`). Diff baseline = the audited
> prod parent `contracts/src/supply/szipUSD/LpStrategyModule.sol`. The on-chain seam swap is **sound** (the
> grief-bound held — see synthesis); these are the two real issues.

## Issue 1 — `MastercopyInitLock` dropped → the X-Ray's "init-locked" claim is FALSE (source-verified)
- Parent: `contracts/src/supply/szipUSD/LpStrategyModule.sol:37` `contract LpStrategyModule is MastercopyInitLock`.
- Fork: `LpStrategyModuleDemoVAMM.sol:39` `contract LpStrategyModuleDemoVAMM is Module` — plain `Module`,
  **no constructor**, so the deployed mastercopy's `_initialized` stays false → anyone can `setUp` the bare
  mastercopy. Yet the fork docstring (`:36-38`) AND the X-Ray (`SzipNavOracleDemoVAMM`'s sibling,
  `LpStrategyModuleDemoVAMM.md:43-44`) claim "mastercopy init-locked." **A false documented invariant.**
- **Impact: LOW.** The mastercopy is never `enableModule`'d (only the clone is — `DeployShowcaseVAMM.s.sol`),
  so a `setUp`-hijacked mastercopy has no Safe wired to it and can `exec` nothing → orphan, no value path.
  But it's a dropped audited base class + a false invariant, and the clone-only test suite never catches it.
- **Fix:** inherit `MastercopyInitLock` (as the parent does — changes nothing for clones), OR strike the
  "init-locked" claim from the docstring (`:38`) and the X-Ray (`:43-44`). Inheriting is the faithful fix.
  Add `test_mastercopy_cannot_be_setUp()`.

## Issue 2 — `MockVammPair.mint` does NOT model real Solidly mint → share-math suite validates a wrong formula (assurance MED)
- The mock (`test/hydrex-demo-fork/LpStrategyModuleDemoVAMM.t.sol:124`) computes
  `shares = (in0 + in1) * 1e18 / pricePerShare` — it **sums** both legs and **never donates**.
- Real Solidly `mint` returns `min(amount0·supply/reserve0, amount1·supply/reserve1)` and **donates the
  excess of the larger side to the pool** (documented in `IVammPair.sol`). So every share-math test
  (`test_addLiquidity_*_share_math`, the slippage-floor test) AND the fuzz (`testFuzz_addLiquidityShareMathAndFloor`)
  assert a formula the live pair does not implement — e.g. the both-sided `sb == (d0+d1)/2` case is
  unreachable on a real pair. The **donate-excess economics and single-sided behavior are untested**.
- **Impact:** no on-chain bug — `addLiquidity` faithfully floors on `mint`'s real return via `minShares`,
  and the worst case stays **grief** (no custody, donate-back-to-self on a Safe-dominated pool). The defect
  is **false assurance**: the green suite implies the build economics are characterized; they aren't.
- **Fix:** make `MockVammPair.mint` model `min(...)`+donate-excess so the floor/fuzz are honest; add a
  mis-ratioed donate case + a single-sided case (which on a real pair mints ~0 and donates the whole leg,
  reverting on `minShares≥1`). Optionally add an on-chain `getReserves()` ratio-band guard in `addLiquidity`
  to cap donated excess directly rather than leaving it to operator sizing + `minShares`.

## Why demo-scoped — fix-before-promotion
Same promotion path as HYDREX-ADV-01: `docs/hydrex-demo-fork.md` plans a mainnet version. Restore fidelity
before promoting; current demo risk is bounded (no custody, grief-only).

## Gate
`forge build` clean + `forge test --match-path 'test/hydrex-demo-fork/*.t.sol'` green, with the mock now
modelling real mint + the new regression tests (mastercopy lock, donate-excess, single-sided).

## Next step — documentation propagation (after code lands)
- `contracts/src/hydrex-demo-fork/x-ray/LpStrategyModuleDemoVAMM.md` — strike/replace the false
  "mastercopy init-locked" claim (`:43-44`); record the mock now models real Solidly mint and the
  share-math suite is honest.
- `docs/wires/SHOWCASE-VAMM.md` — note the donate-excess hazard + the ratio-sizing operator obligation.

## Acceptance criteria
- Fork inherits `MastercopyInitLock` (or the false claim is struck everywhere); mastercopy-lock test added.
- `MockVammPair.mint` models `min(...)`+donate; share-math suite + fuzz pass against the real formula;
  donate-excess + single-sided regression tests added.
- X-Ray no longer over-claims.
