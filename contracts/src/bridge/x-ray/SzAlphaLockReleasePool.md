# X-Ray — `SzAlphaLockReleasePool.sol` (single-contract, test-connected)

> SzAlphaLockReleasePool | 21 nSLOC | e634d9f (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/bridge/SzAlphaLockReleasePool.sol`. Connected to
`test/bridge/SzAlphaBridge.t.sol`. **Proportionate by design:** this is a thin subclass of an audited base, so
the authored attack surface is tiny — the depth here matches that, not the bundled bridge report's length.

## 1. What it is

The 964-side CCT pool for szALPHA: **lock-on-source / release-on-dest**. Bridged-out szALPHA is *locked* in the
wired `ERC20LockBox` (never burned), so `SzAlpha.totalSupply()` keeps counting it and `exchangeRate()` stays
truthful while supply circulates on Base. It is a **thin subclass of Chainlink's audited `LockReleaseTokenPool`**
— all operational logic (`lockOrBurn`/`releaseOrMint`, `applyChainUpdates`, rate limiter, RMN curse gate, ramp
validation, ownership) is **inherited and out of scope**. The Base side uses the burn/mint `SzAlphaTokenPool`.

## 2. Authored surface (the entire delta vs the base)

| Element | What it adds |
|---|---|
| `constructor` guard S8 | `if (localTokenDecimals != 18) revert LocalDecimalsNot18` — cross-chain conservation depends on equal decimals |
| `constructor` guard S9 | `if (rmnProxy != canonicalRmn) revert RmnNotCanonical` — pins the RMN to the chain's canonical ARMProxy |
| `advancedPoolHooks` | pinned to `address(0)` in the base ctor call (no hooks) |
| `typeAndVersion()` | `pure override` returning `"SzAlphaLockReleasePool 1.0.0"` — not an operational entry point |

That is the whole authored logic. No new state, no new mutable entry points, no custody (custody lives in the
`ERC20LockBox`; this pool is an authorized caller).

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| G-S8 | `localTokenDecimals == 18` (constructor-pinned) | Yes | `test_lockReleasePoolRejectsNon18Decimals` |
| G-S9 | `rmnProxy == canonicalRmn` (constructor-pinned; `rmnProxy` immutable in `TokenPool` → cannot drift) | Yes | `test_lockReleasePoolRejectsNonCanonicalRmn` |
| E-1 (this side) | locked supply stays counted ⇒ 1:1 lock/release keeps the rate truthful | No (deploy-topology) | `test_lane_lockOnSource_supplyAndRateInvariant`, `test_lane_roundTrip_rateInvariant`, `test_lane_releaseOnDest_fromLockedLiquidity` |

**Inherited (audited base) behavior — exercised, not authored:** RMN curse blocks
(`test_lane_rmnCursedBlocks`), wrong-source-pool rejection (`test_lane_wrongSourcePoolReverts`), rate-limiter
caps (`test_lane_rateLimiterCaps`), non-ramp rejection (`test_lane_nonRampReverts`), getters
(`test_lockReleasePoolGetters`). These confirm the *wiring*; the logic itself is Chainlink's.

## 4. Attack surfaces

- **Deploy-topology correctness (E-1)** — the truthfulness of the cross-chain rate rests on *this* pool (lock/
  release) being the one deployed on 964, paired with the burn/mint pool on Base. Nothing in this contract
  enforces "I am on 964" — it is a deploy choice (item-10), and it is the S2 seam in `docs/wires/SYSTEM-SEAM-MAP.md`.
- **RMN rotation = redeploy, not mutate** — `rmnProxy` is immutable in the base, so S9 holds for the contract's
  life; an RMN rotation requires a fresh pool + a lockbox authorized-caller swap (no fund migration). Worth
  confirming the runbook does redeploy rather than attempt mutation.
- **Inherited operational surface** — `applyChainUpdates`/rate-limiter config is post-deploy under the Timelock
  (S7); the residual is configuration (lane caps, remote pool address), not code. Audited base.

## 5. Test analysis

| Category | Count | Notes |
|---|---|---|
| Authored-guard unit | 2 | S8 + S9 both covered |
| Lane/integration (inherited wiring) | 7 | lock/release/round-trip + RMN curse + wrong-source + rate-limit + non-ramp |
| Fuzz / invariant | 0 | not applicable — the authored surface is two constructor equality checks |

## X-Ray Verdict

**ADEQUATE** — the entire authored surface is two deploy-time guards, **both tested**, over an audited Chainlink
base whose operational logic is exercised by the lane suite. There is no FRAGILE concern because there is
almost no authored logic to under-test; fuzz/invariant would be theater for two constructor checks. The only
real residual is **deploy-topology** (this pool must land on 964, paired with burn/mint on Base) — outside this
contract, tracked as seam S2 in the system map and asserted by the item-10 deploy.

**Structural facts:**
1. 21 nSLOC; thin subclass of audited `LockReleaseTokenPool`; 0 new mutable entry points; no custody.
2. Authored delta = 2 constructor guards (S8 decimals==18, S9 rmn==canonical) + a `pure typeAndVersion`.
3. Both guards tested; 7 inherited-wiring lane tests green (part of the 55/55 bridge suite).
4. `rmnProxy` immutable ⇒ S9 cannot drift; RMN rotation is redeploy-not-mutate.
5. Cross-chain conservation depends on the deploy placing this (lock/release) pool on 964 — a topology choice, not code.
