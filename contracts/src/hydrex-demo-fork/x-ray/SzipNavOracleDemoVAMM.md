# X-Ray — `SzipNavOracleDemoVAMM.sol` (single-contract, test-connected)

> SzipNavOracleDemoVAMM | 294 nSLOC | e634d9f (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(was EXPOSED — dedicated suite ported from the prod parent)*

Dedicated single-contract X-Ray for `contracts/src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol`. Connected to
`test/hydrex-demo-fork/SzipNavOracleDemoVAMM.t.sol`.

> ⚠️ **Self-declared DEMO/SHOWCASE, outside the audited core** (`:17`). Identical to the prod `SzipNavOracle` in
> every respect EXCEPT the LP-leg valuation: it prices an existing **live Solidly vAMM HYDX/USDC pair**
> (`IVammPair.getReserves()` pro-rata) instead of an ICHI vault, so the auto-compounder's LP can be priced on
> mainnet before the real zipUSD/xALPHA ICHI pool exists. Paired with `LpStrategyModuleDemoVAMM`.

## 1. What it is

The szipUSD junior-vault **NAV-per-share pricing primitive** (the demo variant) — both issuance and exit price
off it. It composes the junior basket NAV on-chain across the main + sidecar Safes, CRE-pushes the off-chain leg
marks (alphaUSD, HYDX/USD) it cannot read on Base, and maintains an on-chain TWAP. Consumers read a bracketed
share price: `navEntry = max(spot, twap)` (issuance, reverts on stale), `navExit = min(spot, twap)` (exit, prices
last good mark). The `DefaultCoordinator` writes an impairment `provision` that `spotNavPerShare` subtracts.

**The fork delta (vs prod):** the LP leg. Prod values an ICHI vault (`getTotalAmounts()` + a farm utility escrow
collateral leg). The demo values the Solidly **pair** directly: `heldShares/totalSupply × getReserves()`, with
the reserve tokens (HYDX/USDC) priced via `_legPriceOfToken` (HYDX = the pushed leg, USDC = `1e30` for the 6→18-dp
$1 fold). The demo has **no farm utility leg**.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `_processReport` (via `onReport`) | Forwarder-gated (CRE) | leg-price push (reportType 7); deviation band + not-future + non-zero + valid-leg guards; advances TWAP |
| `writeProvision(newProvision)` | `defaultCoordinator` only | impairment mark; **unbounded at the oracle** (bound lives in the DC) |
| `poke()` | permissionless | advance the TWAP accumulator before a read |
| `setShareToken` / `setLpPosition` / `setJuniorTrancheEngine` / `setDefaultCoordinator` / `setXAlphaRateOracle` | `onlyOwner` (Timelock) | build-phase re-point (§17); `setXAlphaRateOracle(0)` = use the M1 stand-in |
| `grossBasketValue` / `committedValue` / `freeValue` / `spotNavPerShare` / `twapNavPerShare` / `navEntry` / `navExit` / `fresh` / `valueOf` | view | the consumer surface |

## 3. Invariants — with test connection

| Property | On-chain | Proven by |
|---|---|---|
| `spotNavPerShare == (gross − provision)·1e18 / effectiveSupply`; `GENESIS_NAV` at zero supply | Yes | `test_spotNavPerShare_genesis_and_priced`, **`testFuzz_spotNavFormula`** |
| plain-leg gross = Σ `_bal·mark` (zip/usdc·1e12/xa·rate·alphaUSD/hydx/oHydx) | Yes | `test_grossBasketValue_plain_legs` |
| **vAMM LP leg = heldShares/totalSupply × reserves, priced HYDX/USDC** | Yes | **`test_vamm_lp_leg_valuation`** (1 HYDX@$1 + 2 USDC@$1 = $3), `test_vamm_lp_zero_when_unwired_or_empty` |
| leg push: deviation band, non-zero, not-future, valid-leg, length-match, forwarder-only | Yes | `test_push_deviation_band_rejects`, `_zeroPrice_`, `_futureTimestamp_`, `_invalidLeg_`, `_lengthMismatch_`, `_non_forwarder_`, `_wrong_reportType_` |
| freshness: both required legs within `maxAge` | Yes | `test_fresh_requires_both_legs_within_maxAge` |
| bracket: `navEntry = max`, `navExit = min`; issuance reverts on stale leg / stale rate | Yes | `test_navEntry_max_navExit_min`, `_reverts_on_stale_leg`, `_reverts_on_stale_rate_oracle` |
| provision: DC-only writer; subtracts from gross | Yes (writer) / **No** (value) | `test_writeProvision_only_defaultCoordinator`, `_subtracts_from_gross` |

> **HYDREX-ADV-01 (2026-06-22): three audited parent-guards were silently dropped in the fork and are now
> RESTORED.** The adversarial-review (differential vs the prod parent `SzipNavOracle.sol`) found this fork had
> dropped `obsSpacing` (the poke-spam TWAP throttle), `StaleReport` (strictly-newer leg-push guard), and
> `RateUnseeded` (zero-rate fail-closed) — guards the audited parent has and this X-Ray's prior ADEQUATE
> verdict did NOT account for. All three are now back-ported (with regression tests). The most material was
> `obsSpacing`: without it, permissionless `poke()` spam collapsed the TWAP ring to spot, neutering the
> bracket below — i.e. the "TWAP lag" defense was itself defeatable until this fix.

## 4. Attack surfaces (unchanged by the gap-fill; now exercised)

- **vAMM spot LP valuation** — `grossBasketValue` reads `getReserves()` at spot (manipulable in-block); the
  defense is the `min/max(spot, twap)` bracket. The bracket + the LP pro-rata are tested
  (`test_vamm_lp_leg_valuation`, `test_navEntry_max_navExit_min`); the in-block-push resistance rests on the
  TWAP lag — **now genuinely poke-spam-proof since `obsSpacing` was restored (HYDREX-ADV-01,
  `test_obsSpacing_pokeSpam_cannot_collapse_window`)**; multi-block sustained skew remains a prod-inherited
  residual the bracket is documented not to defend.
- **NAV reads raw Safe balances** — a direct transfer into a counted Safe moves NAV with no deposit; the Gate's
  denominator is the tie-back (Gate is out of this scope). Tested that gross sums the Safe balances as designed.
- **Unbounded provision at the oracle** — `writeProvision` accepts any value from the DC; the bound (down ≤
  atRisk·(1−floor)) lives in the `DefaultCoordinator` (out of scope). Tested: DC-only + applied to NAV.
- **Build-phase mutable wiring** — `setLpPosition`/`setShareToken`/`setDefaultCoordinator`/`setXAlphaRateOracle`
  re-pointable by the Timelock; demo, so disabled after the show.

## 5. Test analysis (gap-filled 2026-06-20)

| Category | Count | Notes |
|---|---|---|
| Dedicated unit (this contract) | 26 | `test/hydrex-demo-fork/SzipNavOracleDemoVAMM.t.sol` — ported from the prod parent + the 3 HYDREX-ADV-01 guard-regression tests (obsSpacing poke-spam, StaleReport, RateUnseeded) |
| Stateless fuzz | **1** | `testFuzz_spotNavFormula` (256 runs) — `(gross−provision)·1e18/supply`, floored at 0 |
| Suite status | **27/27 green** | `forge test` (was 24/24; +3 HYDREX-ADV-01 regression tests) |

Ported the applicable prod coverage (ctor/guards, the full CRE push path, freshness, plain-leg NAV, the spot/twap
bracket, provision gating, `valueOf`, genesis) and wrote fresh tests for the **swapped vAMM LP valuation** — the
one part that differs from the audited parent. Skipped the prod suite's farm utility-leg + ICHI-`getTotalAmounts`
tests (the demo has neither). The vAMM `getReserves()` pro-rata pricing is now covered, including the HYDX/USDC
`_legPriceOfToken` decimal fold and the unwired/empty-LP zero case.

## X-Ray Verdict

**ADEQUATE** *(was EXPOSED; raised 2026-06-20)* — the prior EXPOSED was purely the absence of dedicated tests.
The prod parent's suite has now been ported (ICHI LP mock → vAMM-pair mock) and run green (23 unit + 1 fuzz,
24/24), covering the swapped `getReserves()` LP valuation, the CRE push guards, the spot/twap bracket, freshness,
and the provision gating. Tests axis is ADEQUATE (unit + fuzz). Still a demo fork outside the audited core; the
residuals are the same as prod's NAV hub (raw-balance donation seam, in-block spot-LP defended only by the TWAP
bracket, unbounded provision bounded off-chain in the DC) — none new to the fork, and all either tested or
out-of-scope-by-design.

**Structural facts:**
1. 294 nSLOC; plain (non-upgradeable) `ReceiverTemplate`; one CRE-gated state-changer (`_processReport`) + `writeProvision` (DC) + `poke` (permissionless) + Timelock setters.
2. The fork delta is the LP leg: vAMM `getReserves()` pro-rata (HYDX/USDC), vs prod's ICHI `getTotalAmounts()` + farm utility escrow — no farm utility leg here.
3. Tests: 23 unit + 1 fuzz, **24/24 green** — ported from the prod `SzipNavOracle` suite with the vAMM LP seam swapped in (was 0 dedicated).
4. Both value reads (issuance `navEntry`, exit `navExit`) price off this oracle; the bracket + freshness gate the fail-closed behavior.
5. Self-declared DEMO/SHOWCASE; the NAV-hub residuals (donation seam, spot-LP, unbounded provision) are inherited from the prod design, not introduced by the fork.
