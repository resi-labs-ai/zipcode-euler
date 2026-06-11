# SP-03 — DurationFreeze commit (rq → non-rq Safe move)

**Intent.** Answer directly: *can a zodiac module move value from the rq (main) Safe to the non-rq (sidecar) Safe?*
Yes — and only `DurationFreezeModule` can. Exercise the move and its guards.

**Proves.** The single cross-Safe value path (main→sidecar via `commit`); operator gating; the oracle-valued-leg
whitelist; the fee-on-transfer shortfall guard.

**Tier.** Pure on-chain (operator EOA). `release`'s floor read needs the freeze identity (SP-15).

**Binds to.** `DurationFreezeModule` `0x66e0e342…` (enabled on main `0x0B9C95c7…` + sidecar `0x39D22961…`),
`creOperator` `0x3C44CdDd…`, USDC, zipUSD. Source: `contracts/src/supply/szipUSD/DurationFreezeModule.sol`
(`commit` L278-290, `release` L300-317, `onlyValued`/leg whitelist, `TransferShortfall`), wires `DurationFreezeModule.md`.

**Setup.**
- `deal` 100,000e6 USDC into the **main Safe** `0x0B9C95c7…` (the rq Safe holds FREE equity).
- Record `USDC.balanceOf(sidecar)` (likely 0).

**Calls.**
1. `DurationFreezeModule.commit(USDC, 50_000e6) as creOperator` → moves USDC main→sidecar.
2. (negative) `DurationFreezeModule.commit(USDC, 1e6) as attacker` → revert `NotOperator`.
3. (negative) `DurationFreezeModule.commit(<random ERC20 not in {zipUSD,usdc,xAlpha,hydx,oHydx}>, 1e18) as creOperator` → revert `UnvaluedAsset`.

**Assertions.**
- `USDC.balanceOf(sidecar)` increased by exactly 50,000e6; `USDC.balanceOf(mainSafe)` decreased by 50,000e6.
- `committedValue()` reflects the sidecar holding (≈ 50,000e18 USD, 6→18 scaled).
- negatives revert as named.

**Notes.** `commit` does NOT read utilization (only `release` checks the floor). The "does committed == utilization
fraction" question is SP-15. FoT guard can be exercised by committing a fee-on-transfer token if one is staged.

**Result.** **PASS** (2026-06-10, real txs on anvil). The single cross-Safe value path (main→sidecar via `commit`) works and is operator- + whitelist- + FoT-guarded.

Wiring read live: operator = `creOperator`, mainSafe `0x0B9C95c7…`, sidecar `0x39D22961…`. Setup: dealt exactly 100,000e6 USDC into the main Safe (overwriting the 1,000e6 residual from SP-10's claim); sidecar USDC 0, committedValue 0.

1. **commit(USDC, 50,000e6)** as creOperator → 187,367 gas. main USDC 100,000e6 → **50,000e6**; sidecar USDC 0 → **50,000e6** (exact move via `mainSafe.execTransactionFromModule` + the FoT delta-==-amount check); `committedValue()` 0 → **50,000e18** (6→18 scaled, USDC valued $1 by the oracle reading the sidecar). ✓
2. (negative) **commit(USDC, 1e6) as alice** → **`NotOperator` (0x7c214f04)** (asset is valued, so the whitelist modifier passes and the operator check fires). ✓
3. (negative) **commit(WETH, 1e18) as creOperator** → **`UnvaluedAsset(WETH)` (0x205b5d50, arg=0x42…0006)** — the `onlyValued` whitelist {zipUSD, usdc, xAlpha, hydx, oHydx} rejects WETH before the body. ✓

FoT/`TransferShortfall` guard present in code (dest-balance-delta == amount) but **not exercised** (no fee-on-transfer token staged — optional per the spec). `commit` reads no utilization/floor (confirmed — only `release` does), so an unbounded freeze is possible by design (the intended squeeze; over-freeze grief is the accepted §12 metric-4 alarm).

No flaws. Leaves the freeze staged for SP-15 (sidecar 50,000e6 USDC = committedValue 50,000e18; main 50,000e6) — that path tests `release`'s autonomous floor against live utilization.
