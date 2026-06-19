# CTR-09 — The 0.1%-per-revolution protocol fee (in the venue draw)

> Contract-track change (EXPANSION / revenue). Implements the volume-based fee the model depends on: 0.1% of each
> draw, levied **in the venue adapter's borrow path** (NOT the controller — the controller holds no USDC), routed
> to a fee recipient, re-applied per draw so revolving lines pay per revolution. Verified gap: NO per-loan fee
> exists on-chain today (only EE's NAV yield fee, the buy-burn discount, oracle bands).
> Spec: `claude-zipcode.md` §4.x (draw economics) / §17.

## Why (the verified gap + the placement correction)
A grep of `contracts/src` finds no origination/draw/close fee. **And the fee cannot live in the controller:**
`ZipcodeController._origination`/`_draw` call `IZipcodeVenue.draw(lineRef, amount, erebor)`
(`contracts/src/ZipcodeController.sol:207,226`), and the adapter's `draw` borrows USDC **straight to `erebor`** via
`IBorrowing.borrow(amount, erebor)` (`contracts/src/venue/EulerVenueAdapter.sol:350`). The controller never
custodies USDC, and **`erebor` is the off-chain dollar rail — Erebor, the chartered bank handling
offramp/disbursement/collection/onramp** (the 3Jane-style facility model; an EOA stand-in in the local deploy,
`DeployLocal.s.sol:33,71`). Drawn USDC leaves on-chain custody the moment it reaches `erebor` (wired to the
originator as USD), so the protocol cannot skim a fee at or after `erebor`. The only on-chain-enforceable place to
levy is the **adapter's borrow path**, where the USDC is borrowed into existence — before it crosses to the bank.

## Deliverable
Modify `contracts/src/venue/EulerVenueAdapter.sol`:
1. Add `feeRecipient` + `feeBps` slots (default `feeBps = 10` = 0.1%) + Timelock setters (`onlyOwner`, `WiringSet`/
   a `FeeSet` event), mirroring the existing wiring idiom (`:118-185`). Cap `feeBps` (e.g. ≤ 500).
2. In `draw` (`:322-358`), when `feeBps != 0 && feeRecipient != address(0)`, append a FOURTH EVC batch item:
   `IBorrowing.borrow(fee, feeRecipient)` with `fee = amount * feeBps / 10_000`, on behalf of `borrowAccount`
   (same `onBehalfOfAccount` as the principal borrow at `:346-351`). The principal leg keeps `receiver == erebor`
   (F2 preserved); the fee leg sends `fee` USDC to `feeRecipient`. The line's debt becomes `amount + fee`, so the
   fee is financed by the line and repaid with it.
3. Emit `FeeLevied(lineRef, fee)`.

## Spec §
`claude-zipcode.md` §4.x (draw/close economics — fee was intent, never built), §17. Add a fee row to the §8
economics section as a Conclude doc-sync (reflecting what's built — not a precondition).

## Binds to (verified)
- `EulerVenueAdapter.draw` EVC batch (`contracts/src/venue/EulerVenueAdapter.sol:322-358`), the F2 `receiver ==
  erebor` pin (`:325-326`), the `IBorrowing.borrow(amount, receiver)` shape (`:350`), the wiring-setter idiom
  (`:118-185`).
- `erebor` is external (`DeployLocal.s.sol:33,71`) — confirms the fee can't be skimmed downstream of the borrow.
- USDC is the borrow asset (`EulerVenueAdapter.sol:48`).

## Starting state
- No fee anywhere. `draw` borrows `amount` to `erebor` in a 3-item EVC batch (`:330-355`). EE's `setFee`/
  `feeRecipient` is an unrelated NAV-yield fee.

## Do NOT
- Do NOT levy in the controller — it holds no USDC (the draw borrows straight to `erebor`).
- Do NOT break the F2 `receiver == erebor` pin on the PRINCIPAL borrow — only the new fee leg has a different
  receiver (`feeRecipient`), and it is a borrow on the same `borrowAccount`.
- Do NOT route the fee through EE's yield-fee mechanism (that's NAV-growth, not per-loan).
- Do NOT hardcode `feeBps` immutably — Timelock-settable per §17, with a cap.
- Do NOT add a fill-time or close-time fee unless the model wants a symmetric close fee (see Key req 4 — default:
  draw-only).

## Key requirements
1. **Per-revolution.** Every `draw` levies — a revolving line (CTR-08) that draws N times pays N×; a test asserts
   the fee accrues per draw, not once per line.
2. **Financed-fee semantics (the chosen model).** The fee is a fourth borrow leg → line debt = `amount + fee`,
   `feeRecipient` receives `fee` USDC at draw, the borrower repays both. (Alternative — skim-from-principal, where
   the borrower receives `amount − fee` and owes only `amount` — would require borrowing to the adapter then
   forwarding net to `erebor`, changing the F2 pin; NOT chosen. Document the choice.)
3. **Recipient + bps Timelock-settable** (§17), evented, bps-capped.
4. **Exactness** — `amount * feeBps / 10_000`, rounding documented. If the "open AND close .1%" model is confirmed,
   add a symmetric close-fee leg; default is draw-only (open-side), since close has no draw to levy on.

## Done when (gate — `forge test`)
- `forge build` green; `contracts/test/EulerVenueAdapter.t.sol` updated + green: a draw borrows `amount` to `erebor`
  AND `fee` to `feeRecipient` in one batch; line debt == `amount + fee`; an additional `_draw` (revolving) levies
  again; bps/recipient setters gated + evented + capped; `feeBps == 0` is a clean no-op (no fourth leg); F2 intact.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** none hard (operates on the existing draw); composes with CTR-08 (revolving lines maximize fee
  volume) and CTR-03 (the fee fires on every routed draw).
- **Unblocks:** protocol revenue → treasury / `feeRecipient`.
