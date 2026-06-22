# BRIDGE-ADV-05 — `deployBase` never hands the burn/mint pool's ownership to the timelock

> **STATUS: BUILT (2026-06-22)** on branch `audit/bridge-adv-05-pool-ownership`, awaiting review/merge.
> Shipped: `deployBase` now calls `pool.transferOwnership(timelock)` in-broadcast (`DeploySzAlphaBridge.s.sol`),
> handing the pool's mint-source/rate-limiter authority to the timelock (2-step); the stale `:187` comment is
> replaced. **Divergence from the ticket's fix step:** Chainlink's `Ownable2Step` keeps the pending owner
> PRIVATE (no `pendingOwner()` getter), so the planned in-script `require(pendingOwner == timelock)` and the
> `pendingOwner()` test assert are not possible — instead the handoff is proven *behaviorally* in
> `test_fork_deployBase_registersAgainstRealCct` (timelock `acceptOwnership()` → `owner() == timelock`; only
> the proposed owner can accept). Bridge suite **55/55 green**, `forge build` clean. Doc-sync: X-Ray
> `SzAlphaTokenPool.md` (§4), wire `8x-01`, `RUNBOOK:148`.

> BUILD item (LOW). Source: adversarial-review pilot on `contracts/src/bridge/SzAlphaTokenPool.sol`
> (`adversarial-review/reports/src/bridge/szalphatokenpool/synthesis.md`, mission 1). The mint-authority
> surface the mirror review (`szalphamirror/synthesis.md`) cross-referenced into this contract. The X-Ray
> flagged the MINTER *role* (correctly scoped); this is the adjacent gap it did not pin — the pool's
> `Ownable` *owner*.

## The gap (verified in code)

`SzAlphaTokenPool` is a thin `BurnMintTokenPool` subclass; its base is `Ownable2StepMsgSender`, so its
owner is `msg.sender` at construction. The pool owner controls the mint-source config and the rate
limiter — `applyChainUpdates` / `addRemotePool` / `setRateLimitConfig` are all `onlyOwner` (`TokenPool.sol`).

`deployBase` (`DeploySzAlphaBridge.s.sol:166-202`) hands off everything **except** the pool owner:
- mirror `DEFAULT_ADMIN_ROLE` → timelock, deployer revoked (`:199-201`);
- registry administrator → timelock (2-step, asserted) (`:185,191-195`);
- but the **pool's own ownership is never transferred**. Line `:187` is a bare comment — "the pool
  ownership hand-off to the timelock is asserted by the caller" — and there is no `pool.transferOwnership`
  and no post-condition asserting the owner. Grep confirms the only `transferOwnership` in the script is
  the 964 lockbox (`deploy964:142`), and the only `owner()==timelock` assertion is for `SzAlpha` (`:263`).

So after `deployBase`, the burn/mint pool is owned by the deployer EOA (under `forge script --broadcast`),
not the timelock — inconsistently with the lockbox + registry handoffs, which are done in-script and
asserted.

## Why it's LOW (don't over-rate)

This is a retained-privilege / handoff-consistency gap, **not** a direct unbacked-mint path:
- The deployer cannot mint directly — `grantMintAndBurnRoles` granted MINTER/BURNER only to the pool
  (`:175`), and the mirror's `DEFAULT_ADMIN_ROLE` was revoked from the deployer (`:201`).
- As pool owner, the deployer *can* add an arbitrary remote source pool (`addRemotePool`) or loosen the
  inbound rate limiter — but minting still requires a forged inbound CCIP message that clears the
  canonical Base Router's `_onlyOffRamp` (`TokenPool.sol:931-936`) + the RMN curse, which the deployer
  cannot fake. The inherited mint-path validation (source-pool gate, RMN, offRamp, atomic limiter) is
  intact (confirmed sound in the report).
So exploitation needs the deployer key to remain in control AND a Router-recognized offRamp — a single-key
window, strictly weaker than the SEC-03 2-step handoffs the script already proposes + asserts elsewhere.
It earns a ticket because the deployer EOA should not retain the pool's mint-source/limiter authority, and
the handoff should be in-script + asserted like the other two — not an unenforced comment.

## Fix

1. In `deployBase`, after wiring, transfer the pool to the timelock:
   `pool.transferOwnership(timelock);` (2-step `Ownable2StepMsgSender` — the timelock must
   `pool.acceptOwnership()` post-deploy, a runbook step exactly like the lockbox at `deploy964:142`).
2. Add a post-condition asserting the handoff was proposed:
   `require(SzAlphaTokenPool(pool).pendingOwner() == timelock, "pool owner handoff failed");`
   (mirrors the `:191-195` registry-admin assertion and the `:263` `SzAlpha.owner()` check).
3. Make the `:187` comment true (it currently over-claims) — or delete it once the transfer is in-script.

## Next step — documentation propagation (after the code + tests land)
Code-truth; update only once merged. Grep-verify before each edit; `docs/` house style.
- `contracts/src/bridge/x-ray/SzAlphaTokenPool.md` — §4 "Mint authority is the live risk … inherited +
  deploy-time": add that the pool *owner* (mint-source/limiter authority) is now transferred to the
  timelock in-script + asserted, closing the retained-EOA-privilege residual.
- `contracts/src/bridge/x-ray/x-ray.md` (scope) — if it summarizes the deploy handoffs / SEC-03 windows,
  note the pool-owner handoff now matches the lockbox + registry pattern.
- `docs/wires/8x-01-szALPHA-bridge.md` — only if it describes the Base deploy handoff sequence
  (grep-confirm; likely a one-line addition to the post-deploy/runbook list).

## Acceptance criteria
- `deployBase` transfers the burn/mint pool ownership to the timelock (2-step) and asserts
  `pendingOwner == timelock`; the runbook lists the timelock's `pool.acceptOwnership()` step.
- `test_fork_deployBase_registersAgainstRealCct` (or a sibling) asserts the pool owner / pendingOwner is
  the timelock — the assertion currently missing.
- X-Ray (`SzAlphaTokenPool.md`, `x-ray.md`) updated per the propagation step: the mint-source authority
  now sits behind the timelock, consistent with the lockbox + registry handoffs.
