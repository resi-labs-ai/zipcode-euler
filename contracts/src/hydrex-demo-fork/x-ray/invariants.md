# Invariant Map

> Hydrex Demo (vAMM) | 17 guards | 6 inferred | 2 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (zipUSD_==0 || usdc_==0 || ... || W_==0 || maxAge_==0) revert ZeroAddress()` · `SzipNavOracleDemoVAMM.sol:167-170` · deploy-time: no NAV leg can be the zero address and the TWAP window/staleness bound must be real.

#### G-2
`if (reportType != NAV_LEG) revert InvalidReportType(reportType)` · `SzipNavOracleDemoVAMM.sol:231` · scopes the forwarder push to reportType 7 (so a coordinator-type push can't land here).

#### G-3
`if (legs.length != prices.length) revert LengthMismatch()` · `SzipNavOracleDemoVAMM.sol:234` · the batch arrays must pair up before iteration.

#### G-4
`if (ts > block.timestamp) revert FutureTimestamp()` · `SzipNavOracleDemoVAMM.sol:235` · rejects a future-stamped mark that would poison freshness math.

#### G-5
`if (leg >= NUM_LEGS) revert InvalidLeg(leg)` · `SzipNavOracleDemoVAMM.sol:240` · only the two defined leg IDs (alphaUSD, HYDX/USD) are writable.

#### G-6
`if (p == 0) revert ZeroPrice()` · `SzipNavOracleDemoVAMM.sol:242` · a zero leg price would zero out a basket leg.

#### G-7
`if (diff * 10_000 / priorP > maxDeviationBps) revert DeviationExceeded(...)` · `SzipNavOracleDemoVAMM.sol:247` · per-push circuit breaker against a single bad/fat-fingered mark.

#### G-8
`if (msg.sender != defaultCoordinator) revert NotDefaultCoordinator()` · `SzipNavOracleDemoVAMM.sol:257` · only the M2 coordinator writes the impairment provision (value bound lives there, not here).

#### G-9
`if (szipUSD_/ichiVault_/gauge_/dc_/... == address(0)) revert ZeroAddress()` · `SzipNavOracleDemoVAMM.sol:191,198,206,213` · wiring setters reject the zero address (except `setXAlphaRateOracle`, where zero = "use fallback").

#### G-10
`if (token == ...) ... else revert UnknownLpToken(token)` · `SzipNavOracleDemoVAMM.sol:442` · LP reserve-token pricing is fail-closed — an unknown reserve token reverts rather than mis-pricing.

#### G-11
`if (owner_==0 || juniorTrancheEngine_==0 || operator_==0 || ichiVault_==0 || gauge_==0) revert ZeroAddress()` · `LpStrategyModuleDemoVAMM.sol:84-87` · clone `setUp` rejects any zero wiring address before the live token reads.

#### G-12
`if (owner_ == operator_) revert OwnerIsOperator()` · `LpStrategyModuleDemoVAMM.sol:88,128` · the Timelock owner and the hot operator key must be distinct (privilege separation).

#### G-13
`if (t0 == address(0) || t1 == address(0)) revert ZeroAddress()` · `LpStrategyModuleDemoVAMM.sol:103` · the pair's live `token0`/`token1` must be real before they become approval targets.

#### G-14
`if (deposit0 == 0 && deposit1 == 0) revert ZeroAmount()` · `LpStrategyModuleDemoVAMM.sol:201` · an LP add must move at least one leg.

#### G-15
`if (minShares == 0) revert ZeroMinShares()` · `LpStrategyModuleDemoVAMM.sol:202` · forces a real slippage floor (a zero floor would no-op the only sandwich protection).

#### G-16
`if (shares < minShares) revert Slippage()` · `LpStrategyModuleDemoVAMM.sol:218` · the LP mint must meet the operator's floor.

#### G-17
`if (!ok) { if (ret.length==0) revert ExecFailed(); else revert(bubble) }` · `LpStrategyModuleDemoVAMM.sol:180-185` · the Safe swallows inner reverts; this hard-reverts (bubbling data) so a failed deposit/stake never reports success.

*The wiring setters' `onlyOwner` and `onlyOperator` modifiers are access guards, not falsifiable predicates — see the Actors table in x-ray.md.*

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`Ratio` · On-chain: **Yes**

> `spotNavPerShare == (grossBasketValue() − provision) · 1e18 / effectiveSupply`, returning `GENESIS_NAV` at zero effective supply.

**Derivation** — Ratio formula at `SzipNavOracleDemoVAMM.sol:347-353`; `grossBasketValue` sums `_bal`/LP marks (`:283-305`); `provision` from `writeProvision` (`:259`); `effectiveSupply = totalSupply − engineBalance` (`:461-466`).

**If violated** — issuance/exit misprice; note the numerator reads raw Safe `balanceOf`, so a direct transfer into a counted Safe moves NAV (this is the design seam the Gate must absorb).

#### I-2

`Conservation` · On-chain: **No**

> The LP leg in NAV equals a held-share pro-rata slice of the pair's reserves: `value += Σ reserveᵢ · heldShares / supplyLp`, valued at spot.

**Derivation** — Δ/formula: `grossBasketValue:294-302` and `_grossValueOf:333-341` (`amt = totalᵢ · heldShares / supplyLp`, then `_tokenValue`). `heldShares` sums pair + gauge balances across the Safes.

**If violated** — On-chain=No because the reserves come from a live external pair (`getReserves()`) with no on-chain bound; an in-block reserve push changes the spot LP mark. The TWAP `min/max` bracket is the mitigation, not an on-chain equality.

#### I-3

`Temporal` · On-chain: **Yes**

> The TWAP accumulator is monotonic: `lastUpdate` only advances and `cumNav += spot · dt` with `dt = now − lastUpdate ≥ 0`; advancing is idempotent within a block (`dt == 0 ⇒ no-op`).

**Derivation** — temporal: `_accumulate:270-279` (`if (dt == 0) return false`; `lastUpdate = nowTs`). All three mutating paths (`_processReport`, `writeProvision`, `poke`) call `_accumulate` before changing inputs.

**If violated** — TWAP could double-count or rewind; the `dt==0` guard + single accumulator entry point prevent it.

#### I-4

`Bound` · On-chain: **No**

> `committedValue() + freeValue() == grossBasketValue()` — exact for the five plain legs; for a split LP it holds only "within ≤2 wei" (per-Safe pro-rata floors twice vs once).

**Derivation** — guard-lift/formula: `committedValue:312` + `freeValue:317` re-derive via `_grossValueOf:324-344`; `grossBasketValue:283-305` floors LP once. Documented drift at `:307-311`.

**If violated** — On-chain=No: the equality is not exact across the LP path (≤2 wei). A consumer (e.g. a freeze module) treating it as exact could be off by the floor drift.

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **No**

> The oracle assumes the `provision` value supplied by `writeProvision` is already bounded (down ≤ atRisk·(1−recoveryFloor), up by realized receipts). The oracle enforces only the *caller*, never the *value*.

**Caller side** — `SzipNavOracleDemoVAMM.sol:256-261` (`writeProvision`): `provision = newProvision` flows directly into `spotNavPerShare:351`.

**Callee side** — the `DefaultCoordinator` (M2) is the sole writer (set via `setDefaultCoordinator:212`) and holds the bound — **out of scope** in this directory.

**If violated** — a compromised/buggy coordinator (or one wired before its bound exists) can set provision arbitrarily, directly moving NAV. On-chain=No because the bound lives in an out-of-scope contract; the in-scope defense is only `msg.sender == defaultCoordinator` + the fail-closed unwired state.

---

## 4. Economic Invariants

#### E-1

On-chain: **Yes**

> Sub-window spot moves cannot be turned into a profitable mint or exit: `navEntry = max(spot, twap)` (a one-block UP spike only makes minting more expensive; a DOWN spike is ignored) and `navExit = min(spot, twap)` (an UP spike is ignored).

**Follows from** — `I-1` (spot ratio) + `I-3` (monotonic TWAP) + the bracket selection at `navEntry:387-389` / `navExit:393-397`.

**If violated** — if the LP leg did NOT propagate into the TWAP (see `I-2`), the bracket would only defend the five plain legs and an in-block reserve push could escape it. The defense is sound only if `spotNavPerShare`'s LP contribution flows through `_accumulate → cumNav` — the load-bearing check for this property.
