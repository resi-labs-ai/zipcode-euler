# SP-20 — Engine flywheel end-to-end value conservation (seam S13) [NEW]

**Intent.** Prove basket value is conserved (modulo the realized option-discount gain) across the FULL engine loop —
deposit → LP → harvest → exercise → sell → recycle — not just leg-by-leg (SP-17). The cross-module conservation the
portfolio-map + SEAM-MAP §7 flag as proven node-by-node but never end-to-end.

**Proves.** Across the loop, no value leaks: every module leg either conserves basket value (LP add/stake, harvest,
sell at market) or adds a quantifiable gain (exercise's option discount), and `RecycleModule` routes the realized
free value back into the basket / senior backing — so Σ(basket value out) == Σ(in) + realized option gain, with the
engine module set on the shared Safe as the only authority (S13). Sources: `contracts/src/supply/szipUSD/x-ray/portfolio-map.md`,
`docs/wires/SYSTEM-SEAM-MAP.md` §7.

**Tier.** Needs-forwarder (NAV context) + live-venue legs (as SP-17).

**Binds to** (by name — clones): the five engine module clones (LpStrategy/HarvestVote/Exercise/Sell/Recycle), main
Safe, `SzipNavOracle`, ICHI vault, ALM gauge `0x4328CE8A`, oHYDX, HYDX, Algebra router, USDC, zipUSD.

**Method.** Snapshot `grossBasketValue()` (and per-token Safe balances) at the start; run the full loop from SP-17 in
sequence on one state (no per-leg revert); snapshot NAV again; assert `gross_after == gross_before + realized_gain`
within rounding, and that `RecycleModule.recycle` accreted the gain into backed zipUSD (NAV/share up for holders).

**Assertions** (On-chain=Yes): basket value conserved across the loop modulo the realized option-discount gain;
RecycleModule routes the gain in (backed zipUSD minted, warehouse EE shares up); no module can move value except via
its operator-gated, scope-pinned path (S13 — the module set is the access control).

**Notes.** The end-to-end conservation is the composition of the per-leg proofs (SP-17). The single value INJECTION is
the option-discount gain at `ExerciseModule` (oHYDX bought below intrinsic); everything else is value-neutral transport.
A leak would show as `gross_after < gross_before + gain`.

**Result.** **PASS — single-state loop run live (deposit → exercise → sell → recycle, no per-leg revert).**
- **Deposit:** `zap(1_000e6)` → `grossBasketValue` **gross0 = 1,000e18** (zipUSD basket).
- **Exercise + sell** (the value injection): exercised 100 oHYDX (~$1.06 strike) → 100 HYDX → sold on live Algebra
  (~$3.51); the engine Safe's realized USDC = **4.455609e6** (sell proceeds + buffer − strike). The option discount is
  the gain; LP/sell are market-priced transport.
- **Recycle:** `creditFreeValue` + `recycle(4.455609e6)` → `grossBasketValue` **gross1 = 1,004.455609e18**.
- **Conservation:** the basket grew by **exactly 4.455609** (18-dp) == the recycled USDC (4.455609e6, ×1e12) → the
  realized value converted **1:1 into backed zipUSD with no leak**. Every wei is accounted: oHYDX → HYDX → USDC →
  backed zipUSD / senior EE shares. No leg moved value outside its operator-gated, scope-pinned path (S13). **No flaws.**
- Note: a fully-fed gauge would add a second injection (emissions) at the harvest leg, accreted the same way; the
  conservation invariant is independent of it.
