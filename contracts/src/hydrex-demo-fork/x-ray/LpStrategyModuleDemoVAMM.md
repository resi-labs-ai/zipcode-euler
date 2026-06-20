# X-Ray — `LpStrategyModuleDemoVAMM.sol` (single-contract, test-connected)

> LpStrategyModuleDemoVAMM | 129 nSLOC | e634d9f (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(was EXPOSED — dedicated suite ported from the prod parent)*

Dedicated single-contract X-Ray for `contracts/src/hydrex-demo-fork/LpStrategyModuleDemoVAMM.sol`. Part of the
demo-fork scope (`hydrex-demo-fork/x-ray/x-ray.md` is the scope overview; this is the per-contract file).

> ⚠️ **Self-declared DEMO/SHOWCASE, outside the audited core** (`:12`). It exists to show the auto-compounder on
> mainnet against a live Solidly vAMM HYDX/USDC pair *before* the real zipUSD/xALPHA ICHI pool exists. It is a
> fork of the audited prod `LpStrategyModule` (8-B6) with **one seam swapped** — the LP-mint path.

## 1. What it is

The third engine Zodiac **Module**, CRE-operator-gated, enabled on the szipUSD engine Safe
(`avatar == target == juniorTrancheEngine`). It owns the LP lifecycle: build the LP (`addLiquidity`), gauge-stake
it to farm oHYDX (`stake`), unstake slices for the harvest loop (`unstake`). It holds **no custody** — the Safe
holds the tokens, the LP, and the staked position; the module only makes the Safe `exec` fixed-shape calls.

**The fork delta (vs prod `LpStrategyModule`):** `addLiquidity` builds a **Solidly vAMM pair** LP — `transfer`
both legs straight to the pair (routerless, no approval) then `IVammPair.mint(juniorTrancheEngine)` — instead of
an ICHI vault deposit. `stake`/`unstake` are unchanged (the gauge interface is identical; the pair IS the LP
token). The `ichiVault` slot name is kept so the `setUp` ABI + setters + deploy wiring match prod.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `setUp(initParams)` | `initializer` | clone init; decodes 5 addresses, reads `token0`/`token1` live off the pair, sets `avatar==target==engine` |
| `addLiquidity(deposit0, deposit1, minShares)` | `onlyOperator` | **the swapped vAMM seam**; transfers legs → `IVammPair.mint`; `minShares` slippage floor |
| `stake(lpAmount)` | `onlyOperator` | approve→`IGauge.deposit`→approve(0) |
| `unstake(lpAmount)` | `onlyOperator` | `IGauge.withdraw` |
| `setJuniorTrancheEngine` / `setOperator` / `setIchiVault` / `setGauge` / `setToken0` / `setToken1` | `onlyOwner` (Timelock) | build-phase re-point (§17) |
| `stakedBalance()` / `lpBalance()` | view | live gauge / pair balances |

## 3. Security shape (inherited from prod — sound, but UNVERIFIED for this fork)

- **Operator supplies only scalars** (`deposit0`/`deposit1`/`minShares`/`lpAmount`); the module builds ALL
  calldata to set-once wired targets; the deposit `to` is the literal `juniorTrancheEngine`; every balance read is
  `juniorTrancheEngine`. **No generic call/exec passthrough, no delegatecall, `value == 0`** on every exec
  (`_exec:178-187`). No storage written in any mutating path; no custody.
- **`_exec` bubbles inner revert data** (`:180-185`) — the Gnosis Safe swallows inner reverts and returns
  `(false, data)`; an unchecked exec would silently report a failed deposit as success. This hard-reverts.
- **Clone via `ModuleProxyFactory`** — per-clone config is set-once storage in `setUp` (not `immutable`), mastercopy
  init-locked (`:35-38`).
- `setAvatar`/`setTarget` inherited `onlyOwner` (zodiac-core) — the operator hot key cannot reach them (`:167-170`).

These properties were proven for the prod `LpStrategyModule` (36 unit tests, ICHI path). **As of 2026-06-20 they
are now also proven for this fork**: the prod suite was ported to `test/hydrex-demo-fork/LpStrategyModuleDemoVAMM.t.sol`
with the ICHI mock swapped for a `MockVammPair` (transfer→`mint`) — 20 unit + 1 fuzz, **21/21 green**. The swapped
seam is no longer the untested delta.

## 4. Attack surfaces

- **The swapped `addLiquidity` (vAMM mint)** &nbsp;— `:196-221`. `transfer` both legs to the pair then `mint`.
  Routerless, no approval. *(Now tested: share math, single/both-sided exec discipline, slippage floor, mint-fail
  atomicity rollback, `_exec` bubble — the entire delta over the audited parent is covered, incl. a share-math fuzz.)*
- **Excess-donation on a bad ratio** — `:204-207`: the operator MUST size `deposit0:deposit1` to the live
  `getReserves()` ratio; Solidly `mint` keeps the lesser side and **donates the excess of the other side to the
  pool**. `minShares` is the *only* protection against a bad ratio. Worth confirming the operator sizes against a
  fresh reserve read (also flagged in the paired `SzipNavOracleDemoVAMM` x-ray).
- **Build-phase mutable wiring** — six `onlyOwner` setters re-point engine/operator/pair/gauge/token0/token1;
  to be re-frozen pre-prod (a demo, so this is moot if disabled after the show).
- **Operator (hot CRE key)** — can grief/mis-size the LP build (bounded by `minShares`, no custody), and drive
  stake/unstake. Bounded, but on an untested seam.

## 5. Test analysis (gap-filled 2026-06-20)

| Category | Count | Notes |
|---|---|---|
| Dedicated unit (this contract) | 20 | `test/hydrex-demo-fork/LpStrategyModuleDemoVAMM.t.sol` — ported from the prod parent, ICHI mock → `MockVammPair` |
| Stateless fuzz | **1** | `testFuzz_addLiquidityShareMathAndFloor` (256 runs) — share math + exact `minShares` floor |
| Suite status | **21/21 green** | `forge test` |

The ported suite covers the swapped seam end-to-end: `setUp` wiring + zero-arg guards, operator-only gating,
owner-only `setAvatar`/`setTarget`, single- and both-sided `addLiquidity` share math, the slippage floor, the
exec discipline (single = transfer+mint; both = 2 transfers+mint; stake = approve/deposit/reset; unstake =
withdraw), mint-fail atomicity rollback, and the `_exec` bubble (custom error + no-data → `ExecFailed`). The
inherited no-passthrough / no-delegatecall / no-custody / scalars-only shape is now verified for this fork, not
just its parent.

## X-Ray Verdict

**ADEQUATE** *(was EXPOSED; raised 2026-06-20)* — the prior EXPOSED was purely the absence of dedicated tests.
The prod parent's suite has now been ported (ICHI mock → vAMM-pair mock) and run green (20 unit + 1 fuzz, 21/21),
so the one part that differs from the audited parent — the vAMM `addLiquidity` mint, its exec discipline,
atomicity, and slippage floor — is covered, including a share-math fuzz. Tests axis is ADEQUATE (unit + fuzz).
Still a demo fork outside the audited core; the residual is operational (operator must size the LP against fresh
reserves, since Solidly `mint` donates the excess of a mis-sized side) and no-custody bounds the worst case to
grief, not a drain.

**Structural facts:**
1. 129 nSLOC; Zodiac Module clone (`setUp`-initialized, not immutable); holds no custody.
2. 3 operator-gated ops (`addLiquidity`/`stake`/`unstake`) + 6 Timelock setters + 2 views; no delegatecall, `value==0`.
3. Tests: 20 unit + 1 fuzz, **21/21 green** — ported from the prod `LpStrategyModule` suite with the vAMM mint seam swapped in (was 0 dedicated).
4. Only attacker-influenceable value path is the operator's LP-build ratio (bounded by `minShares`); excess of a mis-sized side is donated to the pool by Solidly `mint`.
5. Self-declared DEMO/SHOWCASE — enable for the show via `enableModule`, `disableModule` after; prod `LpStrategyModule` stays untouched.
