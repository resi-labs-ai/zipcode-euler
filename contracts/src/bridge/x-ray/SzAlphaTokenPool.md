# X-Ray — `SzAlphaTokenPool.sol` (single-contract, test-connected)

> SzAlphaTokenPool | 16 nSLOC | e634d9f (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/bridge/SzAlphaTokenPool.sol`. Connected to
`test/bridge/SzAlphaBridge.t.sol`. The **Base-side twin** of `SzAlphaLockReleasePool` — same two deploy guards
over a different audited base (`BurnMintTokenPool` vs `LockReleaseTokenPool`). Proportionate by design.

## 1. What it is

The Base (8453) CCT pool for szALPHA: **burn-on-source / mint-on-dest**, paired with `SzAlphaMirror`. On Base the
mirror has no rate of its own, so burn/mint is correct (the proven Rubicon shape). The **964 side uses
`SzAlphaLockReleasePool` instead** — burn-on-source on 964 would shrink `SzAlpha.totalSupply()` against unchanged
stake and corrupt `exchangeRate()`. A **thin subclass of the audited `BurnMintTokenPool`**; all operational logic
(`lockOrBurn`=burn / `releaseOrMint`=mint, `applyChainUpdates`, rate limiter, RMN curse, ramp validation) is
inherited and out of scope. No custody (burn/mint holds nothing).

## 2. Authored surface (the entire delta vs the base)

| Element | What it adds |
|---|---|
| `constructor` guard S8 | `if (localTokenDecimals != 18) revert LocalDecimalsNot18` — cross-chain conservation needs equal decimals |
| `constructor` guard S9 | `if (rmnProxy != canonicalRmn) revert RmnNotCanonical` — pins RMN to the chain's canonical ARMProxy |
| `advancedPoolHooks` | pinned to `address(0)` in the base ctor call (no hooks) |
| `typeAndVersion()` | `pure override` → `"SzAlphaTokenPool 1.0.0"` (not operational) |

No new state, no new mutable entry points, no custody. (Mirror of the LockReleasePool's delta, minus the lockbox
arg — burn/mint custodies nothing.)

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| G-S8 | `localTokenDecimals == 18` (constructor-pinned) | Yes | `test_burnMintPoolAssertsStillHold_baseSide` |
| G-S9 | `rmnProxy == canonicalRmn` (`rmnProxy` immutable in `TokenPool` → cannot drift) | Yes | `test_burnMintPoolAssertsStillHold_baseSide` |
| E-1 (Base side) | burn/mint pairs 1:1 with the mirror; mint matches the 964 lock | No (deploy-topology) | mirror role-gating `test_mirror_mintBurnGatedToPool`; the inherited burn/mint logic is audited Chainlink |

**Inherited (audited base) behavior** — `lockOrBurn`/`releaseOrMint`, rate limiter, RMN curse, ramp validation —
is the audited `BurnMintTokenPool`. The mocked lane suite exercises the **964 lock/release** side (its setUp
builds the lockbox); this Base burn/mint pool's guards are covered by the dedicated assert test, and its real
registration is touched by the Base-fork deploy test (`test_fork_deployBase_registersAgainstRealCct`).

## 4. Attack surfaces

- **Deploy-topology correctness (E-1 / S2)** — the mirror image of the LockReleasePool's residual: this
  burn/mint pool must be the one on **Base**, paired with lock/release on 964. Nothing here enforces "I am on
  Base"; it is a deploy choice (item-10) and is seam **S2** in `docs/wires/SYSTEM-SEAM-MAP.md`. Swapping the two
  pools' chains would break cross-chain conservation.
- **Mint authority is the live risk, inherited + deploy-time** — burn/mint means this pool is granted MINTER/
  BURNER on `SzAlphaMirror`; a mis-granted role mints unbacked Base tokens. That lives in the inherited base +
  the deploy-time `grantMintAndBurnRoles` (see the mirror x-ray), not in this contract.
- **RMN rotation = redeploy, not mutate** — `rmnProxy` immutable, so S9 holds for the contract's life.

## 5. Test analysis

| Category | Count | Notes |
|---|---|---|
| Authored-guard unit | 1 | `test_burnMintPoolAssertsStillHold_baseSide` (S8 + S9 together) |
| Inherited / integration | fork | Base-fork registration (`test_fork_deployBase_registersAgainstRealCct`) |
| Fuzz / invariant | 0 | n/a — two constructor equality checks |

*Lighter direct coverage than the 964 LockReleasePool (the mocked lane suite drives the 964 side), but the
authored delta — the two guards — is asserted, and the operational logic is audited Chainlink.*

## X-Ray Verdict

**ADEQUATE** — identical posture to `SzAlphaLockReleasePool`: the entire authored surface is two deploy-time
guards over an audited base, the guards are tested, and there is no authored logic to under-test. The only real
residual is **deploy-topology** (this burn/mint pool on Base, lock/release on 964) — seam S2, asserted by the
item-10 deploy, not by this contract. Mint authority is inherited + deploy-time (see the mirror x-ray).

**Structural facts:**
1. 16 nSLOC; thin subclass of audited `BurnMintTokenPool`; 0 new mutable entry points; no custody.
2. Authored delta = 2 constructor guards (S8 decimals==18, S9 rmn==canonical) + a `pure typeAndVersion`.
3. Guards tested (`test_burnMintPoolAssertsStillHold_baseSide`); Base registration covered by the fork test; part of the 55/55 green suite.
4. `rmnProxy` immutable ⇒ S9 cannot drift; RMN rotation is redeploy-not-mutate.
5. Cross-chain conservation depends on this (burn/mint) pool being on Base, paired with lock/release on 964 — a topology choice (E-1/S2), not code.
