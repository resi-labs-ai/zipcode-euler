# SEC-12 — `ZipRedemptionQueue.redeem()` emits canonical shares (L11)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` L11 (info); audit `findings.md` (L11) ·
**Status:** PROPOSED

> Scope authored 2026-06-15. Event-correctness only — no state/transfer change. `redeem` is effectively dead
> in the single-requester topology, but the emitted figure should still be accurate for off-chain consumers.

## Deliverable
Emit the actually-redeemed zipUSD-equivalent (`assets * scaleUp`) in `redeem`'s `Withdraw` event, instead of
the raw caller-supplied `shares`.

## What it does / what's being fixed (plain language)
`redeem(shares, ...)` pays `assets = shares / scaleUp` USDC at par (floor division). On a sub-unit-excess input
(e.g. `shares = 1.5 × scaleUp`) it pays `assets = 1` but emits the **raw** `shares` (`1.5 × scaleUp`) — so the
`Withdraw` event overstates the redeemed amount and disagrees with `assets`. The sibling `withdraw` already
emits the canonical `assets * scaleUp`; `redeem` should match.

## Binds to (verified file:line — 2026-06-15)
- **Bug:** `contracts/src/supply/ZipRedemptionQueue.sol:248` — `emit Withdraw(msg.sender, receiver, requester,
  assets, shares);` where `shares` is the raw input and `assets = shares / scaleUp` (`:240`, floor).
- **The correct pattern to mirror:** `withdraw` `:221` `shares = assets * scaleUp;` → `:227`
  `emit Withdraw(..., assets, shares);`.

## Key requirements
1. In `redeem`, after the `assets` computation + guards (`:240-242`) and before the emit, set
   `shares = assets * scaleUp;` (reuse the input param as the canonical value), so the event reports the
   zipUSD-equivalent actually redeemed. The function's return value stays `assets` (unchanged).
2. Leave the floor-redeem semantics intact — `redeem(shares < scaleUp)` still reverts via the `assets == 0`
   guard (`:241`); a sub-unit *excess* still redeems the floored whole units (accepted input unchanged).

## Do NOT
- Do NOT add a `shares % scaleUp != 0` revert guard — that would reject currently-accepted inputs (the kill-list
  explicitly prefers the recompute over the guard).
- Do NOT change `assets`, the transfers, `claimableAssets`/`reservedAssets` effects, or the return value — this
  is event-field-only.
- Do NOT widen scope to other kill-list groups.

## Done when
- `cd contracts && forge build` clean.
- `forge test` green, **plus a new `SEC12_*` regression test** that fails before / passes after:
  - **Sub-unit excess:** with a funded requester, `redeem(scaleUp + scaleUp/2, ...)` pays `assets == 1` and emits
    a `Withdraw` whose `shares` field `== scaleUp` (== `assets * scaleUp`), NOT the raw `scaleUp + scaleUp/2`
    (pre-fix the event carries the raw input).
  - **Clean multiple unchanged:** `redeem(k * scaleUp, ...)` still emits `shares == k * scaleUp` (the recompute
    is a no-op for exact inputs).
  - **Return value:** `redeem` still returns `assets` unchanged.
- Quote the actual `forge test` output in this ticket's done note. (Extend the queue test fixture; fund
  `claimableAssets` via the settle path as the single requester.)

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-12".
