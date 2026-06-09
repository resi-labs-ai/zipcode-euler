# Report — `DurationFreezeModule` (Duration-Bond trigger B) — BUILT-VERIFIED + KEPT

**Window:** 2026-06-09 · build-only · **full harness loop completed** (ticket → 5 critics → spec fix → cold-build →
independently re-verified green). 48/48 module · 633/633 total no regression · zero load-bearing guesses.

## TL;DR
You picked the duration-squeeze freeze. After clarifying what it actually is (the **rotation/floor actuator** for the
sidecar — the orphan that `baal-spec §8` parked as "item 9 / 8-B11" but never got a build slot), you confirmed
**full-module scope**. I authored the ticket, ran the 5-critic fanout, and **the security critic found a CRITICAL I
verified and fixed**: my first-draft on-chain utilization read was both *wrong* (it would brick every release) and
*exploitable* (a public donation could lower the freeze floor and open the run hatch) — a genuine **spec correction**
(§8.2's "idle" framing was the spec's own error). You then released the cold-build: a fresh subagent built it from the
corrected ticket with **zero load-bearing guesses**, and I **independently re-ran it green from `forge clean`** —
**48/48 module** (incl. a 128k-call invariant / 0 reverts + 2 Base-fork tests against the real substrate) and
**633/633 total, no regression**, with the **`SzipNavOracle` 42-test suite + `grossBasketValue` pins unchanged** (the
oracle extension is additive).

## What this window produced
- **`contracts/src/supply/szipUSD/DurationFreezeModule.sol`** + `contracts/src/interfaces/{euler/IEulerEarnUtil,
  supply/ISzipNavBasket}.sol` + the additive `SzipNavOracle.committedValue()`/`freeValue()` views + `contracts/test/
  DurationFreezeModule.t.sol` — **kept on disk, `forge test` green (run it yourself: `forge test --match-contract
  DurationFreezeModule`).** NOT git-committed (your call, per the recent windows).
- **`tickets/sodo/DurationFreezeModule.md`** — the build-grade, 5-critic-hardened ticket (build-only).
- **Spec edits to `claude-zipcode.md`** (the CRITICAL fix): §8.2 (the donation-immune `U` read) + §11-B (the corrected
  trigger line + the M1 continuous-floor realization note).
- PROGRESS / LEDGER updated; this report.

## The design (for your sanity-check)
A Zodiac `Module` enabled on **both** the main (ragequit-target) Safe and the non-RQ sidecar Safe:
- **`commit(asset, amount)`** main→sidecar — operator-gated, **ungated by value** (raising the freeze is always
  peg-safe).
- **`release(asset, amount)`** sidecar→main — operator-gated, **autonomously floor-gated**: reverts unless
  `committedValue() ≥ requiredFraction(U) × grossBasketValue`, with `requiredFraction = min(1e18, max(U, escalation))`,
  `escalation = maxLockFraction × clamp((U−U_lock)/(U_max−U_lock), 0, 1)` (§11-B).
- It moves only the **five whitelisted liquid legs** (read from the oracle at setUp); the staked LP is moved by 8-B6,
  not here. `value==0`/Call-only, balance-delta asserted, **no recipient parameter** (destinations are the literal
  set-once Safes).

This is the **`DefaultCoordinator` "bounds-not-validates" pattern**: the CRE operator is trusted to choose *which/how
much* to rotate; the contract autonomously bounds the *release value* on-chain, so **even a compromised operator can't
open the run hatch** while utilization is breached. It gates the Exit Gate **structurally** (by what's kept out of the
main Safe) — **no ExitGate change**. Liquidity-only: no markdown, no xALPHA bond/premium, no DefaultCoordinator/Gate
coupling.

## The CRITICAL (the one thing to scrutinize)
My v1 read utilization as `idle = IERC20(usdc).balanceOf(eulerEarn)`, `U = (totalAssets − idle)/totalAssets`. The
security critic verified against the real `EulerEarn.sol` that this is **both broken and exploitable**:
1. **Broken:** EulerEarn is a pure Morpho-style allocator — `totalAssets()` is `Σ expectedSupplyAssets(strategy)` and
   **excludes** the meta-vault's own USDC balance (which is ≈0 anyway, since deposits are immediately pushed to
   strategies). So `idle ≈ 0` → `U ≈ 1e18` permanently → the floor pins at max → **`release` is bricked forever**.
2. **Exploitable:** `balanceOf(eulerEarn)` is **donatable by anyone** — transfer USDC to the pool address → inflate
   `idle` → lower `U` → lower the floor → permit an over-release that drains the sidecar and **opens the run hatch**,
   defeating §11-B's "not outsider-manipulable" guarantee.

**Fix:** read `U = 1 − maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))` — the *illiquid fraction of the
senior backing* (how much of the CreditWarehouse's EulerEarn position is locked in live loans and can't be freed now).
This reads the **controller-gated borrow side** (§4.3), and `totalAssets`/`maxWithdraw` both ignore stray balance, so a
donation to the pool moves neither term. Verified the surface exists (`maxWithdraw` `EulerEarn.sol:546`,
`totalAssets`=Σexpected `:903`, `convertToAssets`/`balanceOf` ERC4626-inherited). This required correcting **spec
§8.2** (whose "U = borrowed/totalAssets … idle" framing was the root error) and §11-B's trigger line.

**Residual (logged as an item-10 obligation):** a much weaker, costly vector remains — donating into a *strategy
vault's* cash to raise `maxWithdraw`. EulerEarn is mocked until item-10, so the live-pool donation-immunity of the
production EVK credit-line vaults is **unverifiable now** and is an explicit item-10 verification (same deferral as
8-Bx's xALPHA / WOOF-04/05's EulerEarn).

## Other critic outcomes
- **spec-fidelity: FAITHFUL** on all five flagged tensions — the autonomous floor is faithful §11-B/§6.4 detailing (the
  §4.6 precedent), `max(U, esc)` with φ_A=utilization is correct for the liquidity path, `commit` ungated +
  `maxLockFraction`-as-escalation-cap is canonical §11 (baal-spec §8.8's "redeemability cap" is **stale** — dies with
  that to-be-deleted file, no kept-file edit needed), and dropping `maxDuration`/`releaseHysteresis` is faithful under
  the continuous floor. **No spec fix was needed for fidelity** — only the security CRITICAL forced spec edits.
- **ref-verifier:** every signature/path resolves; minor drifts folded (`setUp` body `:69-97`; `_summon` returns a
  `Substrate` struct not a tuple; the Baal `enableModule` idiom substitutes the proven `addOwnerWithThreshold` path;
  `EulerEarn.asset()` is ERC4626-inherited, not declared).
- **HIGH (security #6) — non-basket-asset leak:** `release` of an oracle-unvalued asset would drain the sidecar while
  the floor passes → added the **5-leg oracle whitelist** (also closes the rebasing/FoT concern).
- **qa hardening folded (no re-fan — convergent):** the additive oracle `committedValue()`/`freeValue()` with
  **`grossBasketValue` UNCHANGED** (42-test pins hold; parity exact for plain legs, ≤2-wei for a split LP; gross is
  exactly rotation-invariant since the module never moves the LP); the `FreezeHandler` 128k-call invariant
  (`committedValue ≥ requiredCommittedValue` post-release); the `mainSafe != sidecar` guard; the FoT mock +
  atomic-rollback assertion; the truncation-pin vector; the escalation-bites + exact-`U==uMax` vectors; the
  donation-immunity test; the two-Safe `enableModule` fork plumbing.

## Build-surfaced — NOT mine, flag for you (HIGH-attention)
The cold-build found that the branch working-tree **`SzipNavOracle.sol` had already converted its four set-once
wiring setters (`shareToken`/`ichiVault`+`gauge`/`engineSafe`/`defaultCoordinator`) from set-once-then-frozen
(`AlreadyWired`) to Timelock-re-pointable setters** (and `SzipNavOracle.t.sol` was already updated to match the
re-point semantics). This predates my window (working-tree state on `snapshot/recycle-rework`). I left it intact —
but it is a **material authority-model change** that contradicts the item-10 renounce/freeze obligations and the
`DefaultCoordinator`'s "set-once `defaultCoordinator` is the sole provision writer" assumption (PROGRESS DC row /
obligations). **Please confirm whether the set-once→Timelock flip is intended** (a deliberate recycle-rework
decision) or an in-progress edit that needs reconciling before item-10.

## Judgment calls (yours to ratify)
1. **The corrected `U` read** (`maxWithdraw/convertToAssets` off the warehouse position) is my design choice over the
   critic's looser "read `totalBorrows/totalAssets` from the line vaults" suggestion — it directly measures the
   redemption-squeeze ("can the senior backing be freed"), is donation-immune to the primary vector, and avoids
   enumerating per-line vaults on-chain. Sanity-check the semantics.
2. **`commit` has no ceiling** (an operator can over-freeze 100%, a liveness grief). This is spec-faithful (§11-B caps
   only at 1.0) and classified grief-not-theft; item-10 wires the §12 metric-4 alarm as the watch. Confirm you accept
   the unbounded-commit residual rather than a sanity ceiling.

## Authoritative-doc edits
- `claude-zipcode.md` **§8.2** — replaced "U = borrowed/totalAssets" with the donation-immune
  `U = 1 − maxWithdraw(CreditWarehouse)/convertToAssets(balanceOf(CreditWarehouse))`, with the explicit "NOT
  `balanceOf(eulerEarn)`" Do-NOT and the donation-immunity rationale.
- `claude-zipcode.md` **§11-B** — corrected the trigger line to the same read; added the **M1 realization note** (the
  continuous structural floor subsumes `maxDuration`/`releaseHysteresis`; `commit` ungated; `maxLockFraction` =
  escalation-cap only).
- No `audit/2.md` / `audit/3-results.md` edits (the freeze-sizing trace + authority rows are item-10 deferrals, like
  the escrow/coordinator sweeps).

## Status + NEXT
- **`DurationFreezeModule`: BUILT-VERIFIED + KEPT** (48/48 module, 633/633 total, independently re-run from clean).
  Inbound obligation (PROGRESS row 289) **DISCHARGED** (structural fail-closed + fork-proven enable-on-both + item-10
  wiring). Obligations created: item-10 wiring + the live-pool U donation-immunity verification; CRE-05 drives the
  rotation; governed `uLock/uMax/maxLockFraction`; the audit/2+3 sweep.
- **NEXT (superintendent to pick):** `8x-01` cold-build (BUILD-READY) · item 10 (deploy/wiring). **Plus: review the
  surfaced `SzipNavOracle` set-once→Timelock setter change.**
