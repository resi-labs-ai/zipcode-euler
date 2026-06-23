# SUPPLY-ADV-05 — `SzipBuyBurnModule`: gate the value-load-bearing wiring setters on no-live-bid

> **STATUS: BUILT (2026-06-23)** on `main`. Shipped: the `currentUid.length != 0 → BidAlreadyLive` no-live-bid
> re-check on the three value-load-bearing wiring setters (`setSettlement`/`setVaultRelayer`/`setUsdc` — the ones
> `_cancelBid` dereferences), reusing the existing `BidAlreadyLive` error; regression test
> `test_SUPPLYADV05_wiring_setters_reject_rewire_under_live_bid` (each setter reverts under a live bid; after cancel
> each re-points; existing onlyOwner/zero-guard test still green). GATE: `forge build` clean + scoped suite
> **53/53** green (52 baseline + 1 new). Doc-sync: wire doc `8-B14-SzipBuyBurnModule.md` setter list + X-Ray
> `SzipBuyBurnModule.md` §4 guard row, §3 X-1 row, §6 counts (52→53). No divergence from the planned fix — guard
> scoped to the three setters whose re-point actually strands (verified `setJuniorTrancheEngine`/`setNavOracle`/
> `setSzipUSD`/`setCoverageGate` do NOT strand a live bid, so they are left unguarded); the engine↔free-Safe
> binding stays an accepted X-1 doc note. Source: adversarial-review on
> `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol`
> (`adversarial-review/reports/src/supply/szipbuyburnmodule/synthesis.md`, mission 5's MEDIUM deflated to LOW +
> mission 4's engine-binding INFO — both share the wiring-setter code path).

> BUILD item (LOW). A state-vs-wiring hygiene gap: `_cancelBid` retracts the live bid against the *current*
> `settlement`/`vaultRelayer`/`usdc`, but the only live-bid state (`currentUid`/`currentSellAmount`, `:124-126`)
> records nothing about which wiring the bid was posted on. So a Timelock re-point of `settlement` **and**
> `vaultRelayer` (or `usdc`) between post and cancel makes `cancelBid` flip the presign / zero the allowance on
> the NEW wiring, leaving the OLD presign LIVE and the OLD allowance dangling — a stranded resting bid the owner
> believes was cancelled, fillable until its `validTo` (≤ now + `MAX_BID_TTL` = 1 day). Timelock-gated build-phase
> wiring (X-1), closed by the pre-prod immutable re-freeze — not a live exploit, no drain (the receiver/owner is
> still the engine Safe, so value stays inside the perimeter). Ticketed because the fix is a one-line guard reusing
> the existing `BidAlreadyLive` error, mirroring the SUPPLY-ADV-04 setter-hardening precedent, and the X-Ray flags
> the setters' post-rewire interaction as untested.

## The gap (verified in code)

`_postBid` posts against the cached wiring and stores only the uid + sellAmount:
- `SzipBuyBurnModule.sol:371-372` — `approve(vaultRelayer, sellAmount)` on `usdc` (the spender = the CURRENT
  `vaultRelayer`, the token = the CURRENT `usdc`).
- `:374-379` — `setPreSignature(uid, true)` on the CURRENT `settlement`.
- `:381-382` — `currentUid = uid; currentSellAmount = order.sellAmount;` — no record of `settlement`/`vaultRelayer`/`usdc`.

`_cancelBid` retracts against the CURRENT wiring:
- `:400-405` — `setPreSignature(uid, false)` on the CURRENT `settlement`.
- `:406` — `approve(vaultRelayer, 0)` on the CURRENT `usdc` to the CURRENT `vaultRelayer`.

The six wiring setters (`:250-289`) and `setCoverageGate` (`:293`) guard only `== address(0)` (or nothing); none
checks `currentUid.length == 0`:
- `setSettlement` (`:278-282`), `setVaultRelayer` (`:285-289`), `setUsdc` (`:271-275`) are the value-load-bearing
  ones — they change where `_cancelBid` flips the presign / zeroes the allowance.

**Consequence.** Post a bid (presign on settlement A, USDC-A allowance to relayer A). The Timelock calls
`setSettlement(B)` and `setVaultRelayer(B')`. Now `cancelBid` sets the (never-signed) uid false on B and approves 0
to B', then `delete currentUid`. The presign on A stays `true` and the USDC allowance to relayer A stays at
`sellAmount`, so a CoW solver settling on A can still fill the original bid from the engine Safe — while the module
reports no live bid and has no function to retract A. (Re-pointing `settlement` *alone* leaves the relayer at A, so
`_cancelBid` still zeroes the A allowance and the bid cannot fill — the live-fill case needs both the settlement
and the relayer/usdc re-point. The `setUsdc` variant strands the OLD-token allowance symmetrically.)

This is not a drain: the order `receiver`/uid-`owner` is the pinned `juniorTrancheEngine` (`_orderUid:427,440`), so a
fill buys szipUSD into the Safe (value stays in-perimeter) at the bid's original gated price, and it expires within
`MAX_BID_TTL` (`:89`). It is a self-inflicted stranded-bid the suite does not cover (`test_wiring_setters_onlyOwner_
effect_and_zeroGuard:358` re-points with NO live bid).

## The fix

Add a no-live-bid guard to the value-load-bearing wiring setters, reusing the existing `BidAlreadyLive` error
(`:144`) — force a cancel-before-rewire so the live bid is always retracted on the wiring it was posted on:

```solidity
function setSettlement(address settlement_) external onlyOwner {
    if (settlement_ == address(0)) revert ZeroAddress();
    if (currentUid.length != 0) revert BidAlreadyLive();   // <-- add: cannot rewire under a live bid
    settlement = settlement_;
    emit WiringSet("settlement", settlement_);
}
// mirror in setVaultRelayer (:285) and setUsdc (:271)
```

Cleanest is to apply the same guard to ALL six wiring setters + `setCoverageGate` (these are build-phase setters
not meant to be touched while a bid rests anyway); at MINIMUM `setSettlement` / `setVaultRelayer` / `setUsdc`, the
three `_cancelBid` dereferences. `BidAlreadyLive` already exists — no new error. **Verify the real setter bodies
before editing** (exact field names, the `WiringSet` event signature) per the execute-cycle rule "verify the base
API before fixing."

The mission-4 engine-binding INFO (`setJuniorTrancheEngine` to the sidecar invalidating the free-side-USDC
fill-window argument) shares this surface but needs no separate guard here — a `juniorTrancheEngine` re-point does
not strand a live bid (the live uid's owner is the old engine; `_cancelBid` targets settlement/relayer, unaffected),
and the cross-binding to the oracle's free Safe has no cheap on-chain interlock; it remains an accepted X-1
residual closed by the re-freeze. Documenting it in the X-Ray X-1 note is sufficient.

## Severity rationale (LOW, deflated from the raw MEDIUM)

- The trigger is `onlyOwner` (the Timelock), **not** the CRE operator hot key — a governance/ops mistake, not an
  operator/attacker path.
- It is build-phase mutable wiring (X-1), closed by the documented pre-prod immutable re-freeze.
- No drain: the receiver/owner is the pinned engine Safe, so any stranded fill keeps value in-perimeter at the
  bid's original gated price, and it self-expires within `MAX_BID_TTL` (1 day).
- Deflated from mission 5's raw MEDIUM for those reasons (per the boot rule: a re-point that does not DRAIN is at
  most LOW); raised above the generic X-1 re-point INFO because it is a real `cancelBid`-silently-fails-to-retract
  interaction the suite misses, with a one-line fix matching the SUPPLY-ADV-04 setter-hardening pattern.

## Acceptance criteria

1. After `postBid`, calling `setSettlement`/`setVaultRelayer`/`setUsdc` reverts `BidAlreadyLive`; after `cancelBid`
   (no live bid) each re-point succeeds.
2. The zero-guard and onlyOwner behavior of every setter is unchanged (existing
   `test_wiring_setters_onlyOwner_effect_and_zeroGuard` still passes).
3. Regression test: post a bid, assert a settlement/relayer re-point reverts, cancel, then the re-point succeeds —
   so no setter sequence can leave a presign/allowance stranded on stale wiring under a live bid.
4. GATE: `forge build` clean + `forge test --match-path test/supply/szipUSD/SzipBuyBurnModule.t.sol` green
   (the 52 existing + the new regression test).

## Documentation-propagation step

- `contracts/src/supply/szipUSD/x-ray/SzipBuyBurnModule.md` (authoritative, code-truth): add a §4 guard-table row
  for the wiring-setter no-live-bid re-check, and a note in §5 / the X-1 row that the value-load-bearing setters now
  refuse a re-point under a live bid (closing the stranded-presign hazard) and that the `setJuniorTrancheEngine`
  free-Safe cross-binding remains an accepted off-chain wiring convention. **Gate these edits on the code landing.**
- Grep-verify: no `docs/wires/` doc asserts the buy-burn setter internals (the wire docs describe the 8-B14
  topology, not setter guards) — confirm before writing; expect nothing else to propagate. The buy-burn X-Ray is
  the only truth-source that asserts the single-resting-bid state hygiene.
