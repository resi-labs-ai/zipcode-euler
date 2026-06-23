# LOSS-ADV-01 — `setEscrow` MAX-allowance is a drain primitive; the X-Ray's safety rationale is unsound

> **STATUS: BUILT + SHIPPED to `main` (2026-06-22).** Removed the standing MAX allowance; `_lock` grants the
> escrow an exact-amount just-in-time allowance (`forceApprove(amount)` → `escrow.lockXAlpha` → `forceApprove(0)`,
> mirroring the WOOF-06 per-zap pattern). `setEscrow`/`setXAlpha` no longer grant any standing allowance and stay
> uniformly re-pointable (set-once REJECTED for X-2 consistency — no lone bolt-down). Deleted the dangling
> `error AlreadyWired()`. Loss suite **118/118 green** (+1 regression: `test_lock_jit_allowance_leaves_no_standing_allowance`;
> 3 allowance tests updated to assert zero standing allowance). X-Rays + `docs/wires/` + deploy-script comments
> synced. Divergence from the original plan: NONE beyond the fix-choice already ratified in this ticket
> (JIT approval, not set-once).
>
> BUILD item (LOW — Timelock-trusted; doc-correction landable immediately). Source: adversarial-review on
> `DefaultCoordinator` (`adversarial-review/reports/src/loss/defaultcoordinator/`, mission 3, verified).
> Within the ratified build-phase trust model the drain is *accepted*; what is actionable is (a) the X-Ray/
> NatSpec states a provably-wrong reason for safety, and (b) the standing MAX allowance makes `setEscrow` the
> one re-point that *drains* rather than grief/redirects. Fix removes the standing allowance (exact JIT
> approval) WITHOUT bolting down the slot — keeping the wiring uniformly Timelock-mutable until the one
> pre-prod re-freeze. (The unused `error AlreadyWired()` at `:106` shows a set-once was once intended, but
> set-once is rejected here for X-2 consistency — see Fix.)

## The gap (source-verified)
- `setEscrow` grants the escrow an unbounded allowance over the coordinator's launch xALPHA reserve:
  `DefaultCoordinator.sol:147` — `xAlpha.forceApprove(escrow_, type(uint256).max);` (and `setXAlpha:162`
  re-grants it). `setEscrow` is `onlyOwner` and **re-pointable** — there is no set-once lock.
- The X-Ray states the rationale for why this is safe, and it is a non-sequitur:
  `contracts/src/loss/x-ray/x-ray.md:106` — *"MAX allowance — `setEscrow:147` grants the escrow
  `type(uint256).max` xALPHA; **safe only because the escrow is non-sweepable** and `onlyCoordinator`, whose
  sole pull is its own `lockXAlpha`."* The same claim is in the contract NatSpec (`:42-43`, `:139-143`) and
  the §13 posture ("the owner ... holds no theft power; ... no sweep", `:17`, `:40-41`).
- **`error AlreadyWired();` is declared at `DefaultCoordinator.sol:106` but is never used** (`grep -rn
  "revert AlreadyWired" contracts/src/loss/` → no hits). The intended set-once guard on `setEscrow` was
  dropped during the §17 build-phase mutability change.

## Mechanism + impact
An ERC-20 allowance authorizes the **spender** to move the **owner's** tokens to **any** destination via
`transferFrom(owner, anyDest, amount)`. The escrow's `lockXAlpha:165` sending to `address(this)` is a
property of the *honest* escrow's bytecode — it is NOT a constraint the allowance imposes. If the Timelock
re-points `escrow` to an attacker-controlled contract via `setEscrow:144`, that contract immediately receives
`forceApprove(attacker, max)` at `:147` and can call `xAlpha.transferFrom(coordinator, attacker,
fullReserve)` — a **direct one-call drain of the launch reserve to an arbitrary address**, with no LOCK, no
lien, and no involvement of the escrow's (irrelevant) non-sweepability. "Non-sweepable" governs tokens
*already inside* the escrow; it says nothing about tokens the escrow is *authorized to pull from* the
coordinator. The true blast-radius bound is solely **who the spender is** — the Timelock that sets it.

This is strictly worse than the X-Ray's X-2 framing ("re-point a sink ... grief/redirect, not a drain"). It
does NOT touch NAV (no `writeProvision`) or the bond pool already in the escrow or other users' funds — only
the launch reserve the coordinator custodies.

## Honest severity (LOW, ratified-trust caveat)
- It requires a **malicious/compromised Timelock owner**, who is *trusted* in the build phase (X-2, ratified)
  and is the same admin that owns the engine modules' CRE flows. Within that trust model the drain is
  accepted, exactly like the other X-2 re-points.
- The blast radius is bounded to the single launch reserve (never the escrowed bond pool, NAV, or other
  users), and it is closed by the documented pre-prod immutable re-freeze.
What IS definitive and actionable: the §13 "no sweep / no theft" guarantee is **false on-chain** for as long
as `setEscrow` stays mutable, the X-Ray's stated reason for safety is wrong, and the intended guard exists
(declared) and was dropped. The fix is cheap and clearly intended.

## Fix
**Design constraint (ratified, drives the fix choice):** every loss-wiring slot is *deliberately*
Timelock-re-pointable in the build phase (X-2), and they are all re-frozen to immutable *together* at the
pre-prod lock-down. So the fix must NOT bolt down `setEscrow` alone — a lone immutable slot is inconsistent
with the design and breaks "a redeployed escrow is a one-call re-point, not a redeploy cascade" for exactly
one slot. The fix keeps `setEscrow` re-pointable and instead removes what makes it *special-bad* among the
slots: the **standing MAX allowance** (every other re-point is grief/redirect; only this one is a drain).

1. **Kill the standing allowance — exact-amount just-in-time approval (preferred).** Drop the MAX
   `forceApprove` from `setEscrow:147` (and `setXAlpha:162`). Instead approve exactly the bond amount around
   the pull, inside `_lock` (the `amount` is already in scope at `DefaultCoordinator.sol:207-212`):
   `xAlpha.forceApprove(address(escrow), amount); escrow.lockXAlpha(lienId, originator, amount);
   xAlpha.forceApprove(address(escrow), 0);` — so the coordinator never carries a standing allowance and a
   re-pointed (hostile) escrow has nothing to drain. `setEscrow` stays freely re-pointable, uniform with the
   other slots; the pre-prod re-freeze still bolts the whole wiring set down together. **This is already the
   house pattern** — `docs/wires/WOOF-06.md:80,88` uses exactly `forceApprove(gate, amount)` … then
   `forceApprove(gate, 0)` ("exact-amount per-zap allowance (D1)"); mirror it here.
2. **Doc correction (landable immediately, independent of code).** Correct `x-ray.md:106` and the NatSpec
   (`:42-43`, `:139-143`): the allowance is safe because the **spender (escrow address) is
   Timelock-controlled and re-frozen pre-prod**, NOT because the escrow is non-sweepable. Once fix #1 lands,
   the de-facto-sweep concern is gone entirely (no standing allowance) and the §13 "no sweep" claim holds
   for `setEscrow` like every other slot.
3. (Optional, folds in M3-3) re-push `navOracle.writeProvision(totalProvision)` inside `setNavOracle` so a
   re-point cannot leave a stale-zero sink transiently reading NAV un-impaired.

**Rejected: on-chain set-once via `AlreadyWired` (`:106`).** It would make `setEscrow` the lone immutable
slot in a deliberately-uniform mutable set — inconsistent with X-2 and the deferred all-at-once re-freeze.
The right resolution is to remove the drain primitive (fix #1), not to special-case the slot.

4. **Delete the dangling `error AlreadyWired();` (`:106`).** It only has meaning as a set-once guard, which
   X-2 rejects — so it has no valid use in the mutable-until-pre-prod-re-freeze design. Leaving it declared-
   but-unused recreates this very finding's root ambiguity (a reader infers set-once was intended). Remove
   the dead error so the code matches the ratified design; if a set-once is ever wanted, it belongs to the
   pre-prod immutable pass that freezes ALL slots together, not to a lone error left lying in the contract.

## Gate
`forge build` clean + `forge test --match-path 'test/loss/*.t.sol'` green. Add regression tests for the
exact-amount approval: `allowance(coordinator, escrow) == 0` before and after a lock; `lockXAlpha` still
succeeds via the just-in-time approve; a re-pointed escrow has zero standing allowance to pull on
(`test_setEscrow_repoint_no_standing_allowance`).

## Doc-sync (grep-verified — every target carries the MAX-allowance claim or the unused-`AlreadyWired` note)

**Landable NOW (independent of code) — the rationale correction only.** Both x-ray files state the unsound
"safe because non-sweepable" reason; fix the *reasoning* to "safe because the spender is Timelock-controlled
+ re-frozen pre-prod" even before the code lands:
- `contracts/src/loss/x-ray/x-ray.md:106` (the headline wrong rationale), `:88` (trust-table note), `:114`
  (X-2 list — flag the `setEscrow` leg as drain-not-redirect until fix #1 lands), `:138` (circular-deploy note).
- `contracts/src/loss/x-ray/LienXAlphaEscrow.md:66-67` and `:97` — the *escrow-side* restatement of the same
  wrong rationale ("the coordinator's MAX allowance is safe because the escrow is non-sweepable").

**Gated on the code landing (after fix #1 — there is no standing allowance anymore):**
- `contracts/src/loss/x-ray/DefaultCoordinator.md` — `:16` ("granting the escrow a MAX allowance"), `:28`
  (setter table "grants it MAX xALPHA allowance"), `:62` (the "MAX-allowance + re-approve on re-point" guard
  row + the `test_setEscrow_sets_allowance_and_emits` / `test_setXAlpha_repoint_reapproves_escrow` test names
  — those tests change), `:99` (structural-facts "MAX allowance to the escrow"). Rewrite to exact-amount JIT.
- `contracts/src/loss/x-ray/invariants.md:22` (G-3 note "it also receives the MAX allowance").
- `contracts/src/loss/x-ray/entry-points.md:17` and `:67` ("`setEscrow()` … + MAX approve").
- `docs/wires/DefaultCoordinator.md` — the heaviest: `:22-23`, `:40`, `:53-56` (forceApprove(max) + the
  "`AlreadyWired` declared but unused" prose — now deleted), `:101-102`, `:130` (deploy step
  `forceApprove(escrow, max)`), **`:138` (the deploy assertion `xAlpha.allowance(coordinator, escrow) ==
  type(uint256).max` — this becomes `== 0`/no standing allowance; load-bearing, do not miss)**, `:170`
  (the `AlreadyWired` vestige note — gone after deletion).
- `docs/wires/8-Bx-LienXAlphaEscrow.md:103-104`, `docs/wires/interfaces-loss.md:46`,
  `docs/wires/DeployZipcode.md:33`, `docs/wires/README.md:130,193` — all describe the `setEscrow`
  `forceApprove(max)` step; update to the JIT approval.

**False positives (do NOT touch):** `docs/wires/8-B4-SzipNavOracle.md:177` and `docs/wires/WOOF-05.md:178`
(a *different* contract's own declared-but-unused `AlreadyWired` — out of scope; this ticket only deletes the
one in `DefaultCoordinator.sol`); `docs/wires/WOOF-06.md` / `CTR-05` / `8-B1` / `8-B5` `type(uint256).max`
hits (unrelated semantics — quorum sentinel, collateralization sentinel, repay-all). `WOOF-06.md:80,88` is
the *precedent* to cite (see Fix #1), not an edit target.

## Acceptance criteria
- The standing MAX allowance is eliminated (exact just-in-time approval in `_lock`, zero before and after);
  `setEscrow` remains freely re-pointable (uniform with the other X-2 slots — no lone bolt-down); regression
  tests added; `test/loss` suite green.
- The X-Ray + NatSpec no longer claim non-sweepability is the reason the allowance is safe; with the standing
  allowance gone, re-pointing the escrow is grief/redirect like every other slot, and the §13 "no sweep"
  claim holds.
- The dangling `error AlreadyWired();` (`:106`) is deleted (no set-once in the X-2 design); `forge build`
  clean confirms no remaining reference.
