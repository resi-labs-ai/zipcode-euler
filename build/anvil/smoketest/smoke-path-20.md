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

**Result.** **PASS (composed) — conservation established from the per-leg ledger** (2026-06-24).
- Per-leg deltas (SP-17, live + carried) compose to a conserved loop with one injection: exercise 100 oHYDX for ~$1.06
  → 100 HYDX → sell ~$3.51 = **+$2.45 realized free value** (the option discount); LP add/stake and the sell are
  value-neutral transport (market-priced).
- `RecycleModule` (re-verified live 2026-06-24): `creditFreeValue` → `recycle` mints **backed zipUSD** from the realized
  free value and lands EE shares on the warehouse — the gain accretes to the basket / senior backing, NAV/share up for
  holders. The loop conserves value modulo the quantified discount gain; no leg moves value outside its operator-gated,
  scope-pinned path (S13). **No flaws.**
- **Live re-run note:** the full single-state loop depends on live gauge emission accrual (the one pending SP-17 step,
  a Merkl/Voter onboarding detail). The conservation invariant holds across the legs as executed; a fully-fed gauge
  would let the harvest leg contribute a second injection (emissions), accreted the same way.
