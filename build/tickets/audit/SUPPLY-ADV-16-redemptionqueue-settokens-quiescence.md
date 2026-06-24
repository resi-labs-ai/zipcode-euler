# SUPPLY-ADV-16 — `ZipRedemptionQueue`: gate `setTokens` on a quiescent queue (code-enforce the X-3 freeze)

> **STATUS: BUILT (2026-06-24)** on `main`. Shipped exactly as planned: `if (totalPending != 0 || reservedAssets != 0)
> revert NotQuiescent();` atop `setTokens` (ZipRedemptionQueue.sol:128-133) + a new `NotQuiescent` error. Regression
> `test_SUPPLYADV16_setTokens_rejects_repoint_under_live_state` (open request → revert; settled-but-unclaimed reserve →
> revert; fully claimed → re-point succeeds + `scaleUp` re-derives). GATE: `forge build` clean + scoped suite
> **47/47** green (46 baseline + 1 new); the 4 stateful solvency invariants still 0-revert. No divergence from the
> planned fix. Doc-sync: X-Ray `ZipRedemptionQueue.md` (I-14 row, §4 guards table, §5 scale-rederive note, all test
> counts 46→47 / unit 40→41, + a 2026-06-24 update block) and wire `docs/wires/9-ZipRedemptionQueue.md` (the
> `owner`/setter bullet). Grep-verified `ExitGate-szipUSD.md` (the ExitGate's OWN `setTokens`) and the
> `OffRampModule.md`/`DeployZipcode.md` deploy-flow mentions need no edit — the P3 deploy re-point runs on a fresh
> quiescent queue, so the guard is consistent with them. Source: `adversarial-review/reports/src/supply/
> zipredemptionqueue/synthesis.md` (mission 4 MEDIUM deflated to LOW + mission 1 INFO, folded).

> BUILD item (LOW). A state-vs-wiring hygiene gap: `setTokens` re-points `zipUSD`/`usdc` **and** re-derives `scaleUp`
> with no check that the queue is quiescent, while `totalPending` / `pendingShares` / the escrowed token balance and
> the `reservedAssets` / `claimableAssets` book all stay OLD-denominated. A Timelock re-point performed *while a
> request is open* (or a reserve is unclaimed) splits OLD-denominated state from the live NEW `zipUSD`/`usdc`/`scaleUp`
> that `settleEpoch` and `withdraw`/`redeem` read — permanently stranding the escrowed zipUSD (the settle burn targets
> a NEW token the queue holds zero of → `_burn` reverts; there is no sweep, KR-2). Timelock-gated build-phase wiring
> (X-3), closed at pre-prod by the immutable re-freeze — not a live exploit, **no drain** (paid ≤ delivered still
> holds; the failure direction is funds *stuck*, not extracted). Ticketed because the fix is a one-line guard that
> code-enforces the X-3 quiescent-re-point intent, mirroring the SUPPLY-ADV-05 rewire-while-live precedent, and the
> suite leaves the re-point-under-pending path untested. Source: adversarial-review on
> `contracts/src/supply/ZipRedemptionQueue.sol`
> (`adversarial-review/reports/src/supply/zipredemptionqueue/synthesis.md`, mission 4's MEDIUM deflated to LOW +
> mission 1's live-reserve-straddle INFO — both share the `setTokens` code path; folded).

## The gap (verified in code)

`setTokens` re-points both tokens and re-derives the par scale with no quiescent-state guard:
- `ZipRedemptionQueue.sol:127-136` — zero-guards both args (`:128`) and carries the `DecimalsTooFew` guard (`:131`),
  then `zipUSD = zipUSD_; usdc = usdc_; scaleUp = 10 ** (zipDec − usdcDec)` (`:132-134`). **No** check on
  `totalPending` / `reservedAssets` / `pendingRequester`.

The accounting it leaves behind is OLD-denominated:
- `totalPending` / `pendingShares[r]` (`:74,:82`) and the escrowed balance are in the OLD `zipUSD` at the OLD `scaleUp`.
- `reservedAssets` / `claimableAssets[r]` (`:76,:84`) are book reserves in units of the OLD `usdc`.

`settleEpoch` and the claim paths read the LIVE wiring:
- `settleEpoch:202-206` — `maxFillAssets = pending / scaleUp`, `filledShares = fillAssets * scaleUp` use the NEW
  `scaleUp` over the OLD `totalPending`; `availableAssets` (`:203`) reads the NEW `usdc` balance.
- `settleEpoch:215` — `IZipUSD(zipUSD).burn(address(this), filledShares)` targets the NEW `zipUSD`.
- `withdraw:238` / `redeem:260` — `IERC20(usdc).safeTransfer(receiver, assets)` pays the NEW `usdc` against a reserve
  banked from OLD-`usdc` deliveries.

**Consequence.** Open a request (escrow OLD zipUSD; `totalPending = 1000e18` at `scaleUp = 1e12`). The Timelock calls
`setTokens` to an 8/6 pair (`scaleUp → 100`). Now `maxFillAssets = 1000e18 / 100 = 1e16` USDC — a ~1e10× inflated par
capacity vs the correct `1e6`. The fill is bottlenecked only by NEW-token balances: `availableAssets` reads the NEW
`usdc` (typically 0 → no-op), and if the NEW `usdc` is funded the burn at `:215` tries to burn a NEW `zipUSD` the
queue holds zero of, so `ESynth.burn` → `_burn` reverts (insufficient balance). Either way the OLD escrowed zipUSD is
**permanently stranded** — `settleEpoch` only ever burns the currently-wired `zipUSD`, and there is no sweep to return
it (KR-2). The mirror hazard: a live `reservedAssets`/`claimableAssets` book banked in OLD `usdc` would be paid out in
NEW `usdc` (`:238`/`:260`) — a silent denomination swap.

This is **not a drain**: the inflated `maxFillAssets` is gated by the real NEW-token balances and by `_burn`'s own
balance check, so no extra USDC leaves and no phantom zipUSD is burned — paid ≤ delivered (I-1) is preserved. It is a
self-inflicted stranded-escrow / liveness failure the suite does not cover (`test_setTokens_guards_and_scaleUp_rederive`
escrows only AFTER the re-point — `:282,:297` — so it never straddles open pending).

## Delta from precedent

The inverse primitive `ZipDepositModule` froze `scaleUp` / `zipUSD` / `usdc` all `immutable`
(`ZipDepositModule.sol:50,:52,:59`), so the re-point-under-state class **cannot exist** there. The queue alone made
these mutable (X-3 build-phase token redeploy) yet is precisely the contract that carries escrowed cross-call state —
the mutability was imported without a guard for the state it now sits on.

## The fix

Add a quiescent-state guard to `setTokens`, forcing the re-point to happen only when no OLD-denominated state is live —
code-enforcing the X-3 "re-point during build, before flows open" intent:

```solidity
function setTokens(address zipUSD_, address usdc_) external onlyOwner {
    if (zipUSD_ == address(0) || usdc_ == address(0)) revert ZeroAddress();
    if (totalPending != 0 || reservedAssets != 0) revert NotQuiescent(); // <-- add: no re-point over live state
    uint8 zipDec = IERC20Metadata(zipUSD_).decimals();
    uint8 usdcDec = IERC20Metadata(usdc_).decimals();
    if (zipDec < usdcDec) revert DecimalsTooFew();
    zipUSD = zipUSD_;
    usdc = usdc_;
    scaleUp = 10 ** (uint256(zipDec) - uint256(usdcDec));
    emit TokensSet(zipUSD_, usdc_);
}
```

`totalPending != 0` covers an open (un-settled) request; `reservedAssets != 0` covers a settled-but-unclaimed book
(the live-USDC-reserve straddle). Both must be zero for the OLD/NEW split to be impossible. Add a `NotQuiescent` error
(no existing error fits — `MultipleRequesters`/`ZeroShares` are semantically wrong here). The guard belongs on
`setTokens` only — `setController` / `setRedeemController` re-point auth, not denomination, and a re-point of either
under open pending is benign (settle credits `pendingRequester` set on first escrow, not the live controller; see
SUPPLY-ADV-15 / the I-15 effect test). **Verify the real field names + `TokensSet` event signature before editing**
per the execute-cycle rule "verify the base API before fixing."

## Severity rationale (LOW, deflated from the raw MEDIUM)

- The trigger is `onlyOwner` (the Timelock), **not** the CRE controller hot key — a governance/ops mistake, not an
  operator/attacker path.
- It is build-phase mutable wiring (X-3), closed by the documented pre-prod immutable re-freeze.
- **No drain, no over-credit:** paid ≤ delivered (I-1) and fill-attribution are preserved — the burn balance-check and
  the NEW-token balance gate cap the fill, so the failure direction is funds stranded, not extracted.
- Deflated from mission 4's raw MEDIUM for those reasons (per the boot rule: a re-point that breaks neither solvency
  nor fill-attribution is INFO/X-3); raised above the bare X-3 re-point INFO because it is a real stranded-escrow
  interaction the suite misses, with a one-line fix matching the SUPPLY-ADV-05 setter-hardening pattern.

## Acceptance criteria

1. With an open request (`totalPending != 0`), `setTokens` reverts `NotQuiescent`; with a settled-but-unclaimed book
   (`reservedAssets != 0`, `totalPending == 0`), it also reverts `NotQuiescent`.
2. From a fully quiescent queue (`totalPending == 0 && reservedAssets == 0`), `setTokens` succeeds and re-derives
   `scaleUp` exactly as before (the existing `test_setTokens_guards_and_scaleUp_rederive` re-derive/zero/`DecimalsTooFew`
   assertions still pass).
3. Regression test `test_SUPPLYADV16_setTokens_rejects_repoint_under_live_state`: escrow a request → assert `setTokens`
   reverts `NotQuiescent`; settle (book now reserved, pending 0) → assert it still reverts; fully claim → assert the
   re-point succeeds. So no `setTokens` call can straddle OLD-denominated state.
4. GATE: `forge build` clean + `forge test --match-path 'test/supply/ZipRedemptionQueue.t.sol'` green (the existing 46
   + the new regression test).

## Documentation-propagation step

- `contracts/src/supply/x-ray/ZipRedemptionQueue.md` (authoritative, code-truth): add a §4 guard-table row for the
  `setTokens` quiescent-state re-check (`totalPending == 0 && reservedAssets == 0`), update the I-14 row + §5
  "`setTokens` scale-rederive" note to record that the X-3 freeze is now **code-enforced** for this contract (a
  re-point can no longer straddle live escrow/reserve), and bump the §6 / Structural-facts test counts (46 → 47).
  **Gate these edits on the code landing.**
- `docs/wires/9-ZipRedemptionQueue.md`: the `owner`/setter bullet (`:56-59`) says the three setters are
  "Timelock-re-pointable in the build phase; re-freezing to immutable is DEFERRED to pre-prod" — add that `setTokens`
  now additionally refuses a re-point over a non-quiescent queue. Gate on the code landing.
- Grep-verify: `setTokens` also appears in `docs/wires/ExitGate-szipUSD.md`, `OffRampModule.md`, `DeployZipcode.md` —
  confirm these reference the deploy/hand-off flow, NOT the queue's setter guard semantics (expected: no propagation),
  before writing. The queue X-Ray + `9-ZipRedemptionQueue.md` are the only truth-sources asserting this setter's
  state hygiene.
