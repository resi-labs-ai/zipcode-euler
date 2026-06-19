# CTR-09 — The 0.1%-per-revolution protocol fee (in the venue draw)

> Contract-track change (EXPANSION / revenue). Implements the volume-based fee the model depends on: 0.1% of each
> draw, levied **in the venue adapter's borrow path** (NOT the controller — the controller holds no USDC), routed
> to a fee recipient, re-applied per draw so revolving lines pay per revolution. Verified gap: NO per-loan fee
> exists on-chain today (only EE's NAV yield fee, the buy-burn discount, oracle bands).
> Spec: `build/claude-zipcode.md` §5/§17 (fee economics) — the 0.1%-per-revolution fee is a PROGRESS-workstream
> decision (scaling/federation finding #2), NOT spec prose; its spec doc-sync is FORWARD-DEFERRED (Conclude step),
> like CTR-07's split-slot-2. This invents no mechanism — it adds one extra borrow leg using the existing primitive.

## Why (the verified gap + the placement correction)
A grep of `contracts/src` finds no origination/draw/close fee. **And the fee cannot live in the controller:**
`ZipcodeController._origination`/`_draw` call `IZipcodeVenue.draw(lineRef, amount, erebor)`, and the adapter's
`draw` borrows USDC **straight to `erebor`** via `IBorrowing.borrow(amount, erebor)`
(`contracts/src/venue/EulerVenueAdapter.sol:405`). The controller never custodies USDC, and **`erebor` is the
off-chain dollar rail — Erebor, the chartered bank handling offramp/disbursement/collection/onramp** (an EOA
stand-in in the local deploy, `DeployLocal.s.sol:33,71`). Drawn USDC leaves on-chain custody the moment it reaches
`erebor`, so the protocol cannot skim a fee at or after `erebor`. The only on-chain-enforceable place to levy is the
**adapter's borrow path**, where the USDC is borrowed into existence — before it crosses to the bank.

## Deliverable
Modify `contracts/src/venue/EulerVenueAdapter.sol` (ONLY; no new files):
1. **Fee config slots + cap.** Add, alongside the wiring slots (`:38-72`):
   - `address public feeRecipient;` — **defaults to `address(0)` (fee OFF until the Timelock wires it)**.
   - `uint16 public feeBps = 50;` — **inline storage initializer, NOT a constructor arg** (the 10-arg ctor at
     `:123-145` is super-called by `MisWiringAdapter` at `test/...:319` and `:976`; adding a ctor arg breaks those
     super-calls — pinned: use the inline default). `50` = 0.50% per draw. **CALIBRATION (dartboard 2026-06-19):**
     50 bps is a market-standard per-origination fee (Maple 0.5% parity; low end of warehouse upfront), and since
     each revolution is a fresh origination it is charged per draw → ≤~2%/yr of drawn volume at a HELOC ≤quarterly
     revolution. Re-address with real velocity. The time-based APR is the borrow vault's IRM (today `ZeroIRM` = 0%;
     a real warehouse rate ~7.5% is a Timelock IRM-swap), NOT this fee.
   - `uint16 internal constant MAX_FEE_BPS = 500;` — 5% ceiling.
2. **Timelock setters** (mirror the `:147-240` `onlyOwner` idiom):
   - `setFeeRecipient(address feeRecipient_) external onlyOwner` — sets the slot and `emit WiringSet("feeRecipient",
     feeRecipient_)`. **Does NOT use the `ZeroAddress` guard** — `address(0)` is the legal "fee disabled" sentinel
     (unlike the other wiring slots). Document that exception in NatSpec.
   - `setFeeBps(uint16 feeBps_) external onlyOwner` — `if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();` then set +
     `emit FeeSet(feeBps_)`. (Cannot reuse `WiringSet` — its 2nd param is typed `address`; a uint needs the new
     `FeeSet` event.)
   - New error `error FeeTooHigh();` and new event `event FeeSet(uint16 feeBps);` (declared in the errors/events
     blocks `:87-108`).
3. **The fee leg in `draw`** (`:377-413`). After computing `fee`, append a FOURTH EVC batch item ONLY when the fee
   is live and non-dust:
   ```solidity
   uint256 fee = amount * feeBps / 10_000;            // round-down (Solidity integer div); documented
   bool levyFee = feeRecipient != address(0) && fee != 0;   // feeBps==0 => fee==0, so this also covers feeBps==0
   IEVC.BatchItem[] memory items = new IEVC.BatchItem[](levyFee ? 4 : 3);
   // items[0..2] unchanged: enableController, enableCollateral, borrow(amount, erebor)  [principal leg keeps erebor — F2]
   if (levyFee) {
       items[3] = IEVC.BatchItem({
           targetContract: lineRef,
           onBehalfOfAccount: borrowAccount,          // SAME account as the principal borrow
           value: 0,
           data: abi.encodeCall(IBorrowing.borrow, (fee, feeRecipient))
       });
   }
   evc.batch(items);
   if (levyFee) emit FeeLevied(lineRef, fee);
   ```
   The line's debt becomes `amount + fee` (financed by the line, repaid with it). The principal leg's receiver stays
   the hardcoded `erebor` constant (F2 preserved, `:405`); only the fee leg's receiver is `feeRecipient`.
4. New event `event FeeLevied(address indexed lineRef, uint256 fee);` — emitted ONLY when the fee leg is appended
   (never `FeeLevied(.., 0)`).

## Spec §
`build/claude-zipcode.md` §5/§17 (fee economics; the fee was model intent, never built code). Add a draw-fee row to
the §5 fee discussion as a Conclude doc-sync (reflecting what's built — NOT a precondition; forward-deferred per the
scaling/federation §-sync note).

## Binds to (verified this window — line numbers refreshed)
- `EulerVenueAdapter.draw` EVC batch (`contracts/src/venue/EulerVenueAdapter.sol:377-413`); principal borrow leg
  `IBorrowing.borrow(amount, erebor)` at `:401-406`; F2 pin `if (receiver != erebor) revert BadReceiver()` at `:381`
  (on the FUNCTION ARG, not the per-leg receiver — confirmed: the fee leg's distinct receiver trips no pin).
- `IBorrowing.borrow(uint256 amount, address receiver) returns (uint256)` @ `reference/euler-vault-kit/src/EVault/IEVault.sol:234` (imported at `EulerVenueAdapter.sol:8`).
- `IEVC.BatchItem{address targetContract; address onBehalfOfAccount; uint256 value; bytes data;}` + `batch(BatchItem[])` @ `reference/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol:12-23,355`.
- Two borrows on the same `onBehalfOfAccount` in one `evc.batch` are mechanically valid — the deferred account-status
  check is set-deduped and runs ONCE at outermost batch end against the final `amount + fee` debt
  (`EthereumVaultConnector.sol:696-702,916-920`).
- `CREGatingHook` (`contracts/src/.../CREGatingHook.sol:110-113`) is op-agnostic, stateless, account-keyed — it
  passes the fee leg on the same `borrowAccount` exactly as the principal (no per-call mark/amount/nonce check).
- Wiring-setter idiom + `event WiringSet(bytes32 indexed slot, address value)` @ `:108,147-240`.
- USDC is the borrow asset (`EulerVenueAdapter.sol:57`).

## Starting state
- No fee anywhere. `draw` borrows `amount` to `erebor` in a 3-item EVC batch (`:385-410`). EE's `setFee`/
  `feeRecipient` is an unrelated NAV-yield fee. Existing draw tests assert `debtOf == drawAmount` EXACTLY
  (`test/EulerVenueAdapter.t.sol:641,642,652,848`) and `erebor` received exactly `drawA + drawB` (`:643`).

## Do NOT
- Do NOT levy in the controller — it holds no USDC (the draw borrows straight to `erebor`).
- Do NOT break the F2 `receiver == erebor` pin on the PRINCIPAL borrow — only the new fee leg has a different
  receiver (`feeRecipient`), and it is a borrow on the same `borrowAccount`.
- Do NOT route the fee through EE's yield-fee mechanism (that's NAV-growth, not per-loan).
- Do NOT hardcode `feeBps` immutably — Timelock-settable per §17, capped at `MAX_FEE_BPS`.
- Do NOT add a `feeBps` constructor arg (breaks `MisWiringAdapter`'s super-call) — use the inline initializer.
- Do NOT append a `borrow(0, feeRecipient)` leg on a dust draw — guard on `fee != 0`.
- Do NOT wire `feeRecipient`/`feeBps` in the test `setUp` — that flips the existing `debtOf == drawAmount`
  assertions to `drawAmount + fee` and breaks the green suite. Wire the recipient LOCALLY in the new fee test only.
- Do NOT add a close-time fee — RESOLVED draw-only: close is a full repay → burn (`§10`), there is no borrow/draw
  leg at close to levy on, and the spec has no symmetric-fee language (spec-fidelity confirmed). Draw-only is final.

## Key requirements
1. **Per-revolution.** Every `draw` levies — a revolving line (CTR-08) that draws N times pays N×; a test asserts
   the fee accrues per draw, not once per line.
2. **Financed-fee semantics (the chosen model, documented).** The fee is a fourth borrow leg → line debt =
   `amount + fee`, `feeRecipient` receives `fee` USDC at draw, the borrower repays both. (Alternative —
   skim-from-principal where the borrower receives `amount − fee` and owes only `amount` — would require borrowing
   to the adapter then forwarding net to `erebor`, changing the F2 pin; NOT chosen.)
3. **Fee default-OFF.** `feeRecipient` defaults `address(0)` ⇒ no fee leg ⇒ the entire pre-existing suite stays
   byte-identical green. The fee turns on only when the Timelock calls `setFeeRecipient`.
4. **Recipient + bps Timelock-settable** (§17), evented (`WiringSet`/`FeeSet`), bps-capped (`MAX_FEE_BPS`, revert
   `FeeTooHigh`). `setFeeRecipient` accepts `address(0)` (the disable sentinel); `setFeeBps` rejects `> MAX_FEE_BPS`.
5. **Exactness + dust.** `fee = amount * feeBps / 10_000`, round-down (integer div). `fee == 0` (dust draw or
   `feeBps == 0`) ⇒ no fee leg, no `FeeLevied`.

## Done when (gate — `forge test`)
- `forge build` green.
- `contracts/test/EulerVenueAdapter.t.sol` updated + the FULL suite green (the pre-existing tests must stay green
  unchanged — proves default-OFF). New tests:
  - fee-on: set `feeRecipient` via the setter, draw `amount`, assert `debtOf(borrowAccount) == amount + fee`,
    `feeRecipient` USDC balance increased by `fee`, `erebor` received exactly `amount`, `FeeLevied(lineRef, fee)`
    emitted. (Size `amount` with LTV headroom so `amount + fee` clears the gate.)
  - per-revolution: a second draw on the same line levies again (debt grows by `amount2 + fee2`).
  - no-op: `feeBps == 0` (or `feeRecipient == 0`) ⇒ batch is 3 items, no fee leg, `debtOf == amount`, no `FeeLevied`.
  - dust: a draw small enough that `amount * feeBps / 10_000 == 0` ⇒ no fee leg.
  - setters: `setFeeBps`/`setFeeRecipient` are `onlyOwner` (revert for non-owner), `setFeeBps(MAX_FEE_BPS+1)` reverts
    `FeeTooHigh`, both emit their events; `setFeeRecipient(address(0))` succeeds (disable).
  - F2 intact: principal leg still sends `amount` to `erebor`; a `draw` with `receiver != erebor` still reverts
    `BadReceiver`.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** none hard (operates on the existing draw); composes with CTR-08 (revolving lines maximize fee
  volume) and CTR-03 (the fee fires on every routed draw).
- **Unblocks:** protocol revenue → treasury / `feeRecipient`.
