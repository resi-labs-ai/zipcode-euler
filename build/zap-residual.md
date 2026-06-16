# Zap residual — a 1-wei donation permanently bricks the default UX

> **FIXED 2026-06-13.** `ZipDepositModule.zap` now snapshots `zipBefore` and requires the post-pull balance
> to equal it (delta check, not absolute) — a stray donation can no longer brick the zap. Tests added:
> `test_zap_survives_zipusd_donation` + `testFuzz_zap_tolerates_donation`; the existing under-pull regression
> still bites. `forge test --match-contract ZipDepositModule` → 31/31 green. This (the zap brick) was the
> last remaining open supply finding; the TWAP-ring NAV-bracket finding is now resolved (ring-spacing fix +
> fair-LP reserve read both shipped).

## Problem (verified)

`ZipDepositModule.zap` is THE headline supply entrypoint (USDC → szipUSD in one atomic call). It mints
`zipAmount` zipUSD to itself, hands it to the Exit Gate, and then asserts the module is left clean:

```solidity
// ZipDepositModule.sol:129
function zap(uint256 usdcIn) external nonReentrant returns (uint256 shares) {
    ...
    IESynth(zipUSD).mint(address(this), zipAmount);                 // transient — to the module
    ...
    IERC20(zipUSD).forceApprove(gate, zipAmount);                   // exact-amount, per-zap
    shares = IZipExitGate(gate).depositFor(zipUSD, zipAmount, msg.sender);  // Gate pulls zipAmount

    if (shares == 0) revert ZeroShares();
    if (IESynth(zipUSD).balanceOf(address(this)) != 0) revert ResidualBalance();  // :145  <-- the bug
    IERC20(zipUSD).forceApprove(gate, 0);
    ...
}
```

The intent of `:145` (per the F1/F7 comment) is "never trust the Gate to leave the module clean" — i.e.
prove the Gate pulled the FULL `zipAmount`, so no minted zipUSD is left stranded. But it checks an
**absolute** balance (`!= 0`), and the module's *net* zipUSD delta across a zap is exactly zero
(mint `zipAmount` → Gate pulls `zipAmount`). So any zipUSD sitting in the module **before** the zap
survives the pull and trips the check.

zipUSD is a freely transferable `ESynth` ERC20. Anyone holding any (e.g. anyone who ever called
`deposit`) can `transfer(zipDepositModule, 1)`. After that:

```
balanceOf(module) before zap = 1
   ... mint zipAmount, Gate pulls zipAmount ...
balanceOf(module) after pull  = 1   != 0   ->  revert ResidualBalance
```

Every subsequent `zap` reverts. There is **no clearing path**: the module has no sweep, no owner/admin
mutating surface, and the only zipUSD-out path is the Gate's per-zap `transferFrom`, which pulls exactly
the approved `zipAmount` (then resets the allowance to 0). The stray wei is never approved to anyone, so
it stays forever. **1 wei, irreversible, permanently bricks the protocol's default deposit UX.**

`deposit` (the plain mint path) is **unaffected** — it mints zipUSD straight to the user and never holds
a transient balance, so it has no residual check and nothing to grief.

## Severity

- **Availability: HIGH.** Trivial to trigger (1 wei, one `transfer`, no privilege), permanent (no recovery
  short of redeploying the module + re-wiring the Gate seam + migrating the frontend), and it lands on the
  primary entrypoint. Users would fall back to `deposit` + a manual Gate `depositFor`, but the one-tx zap —
  the whole point of the module — is dead.
- **Funds: NONE.** No theft, no accounting corruption. The stray wei is the griefer's own donated dust;
  nothing the module custodies is at risk. Pure denial-of-service.

## Root cause

The check conflates "the Gate pulled everything I minted" (the real invariant) with "my balance is zero"
(an absolute that an outsider can perturb). The module's cleanliness invariant is about the **delta** the
zap causes, not the absolute balance — an external donation is not the module's concern and must not gate
its liveness.

## Fix — delta check, not absolute (self-contained, no new surface)

Snapshot the balance before the transient mint and require it unchanged after the Gate pull. That proves
the Gate pulled exactly the minted `zipAmount` (the F1/F7 guarantee, intact) while tolerating any
pre-existing donation.

```solidity
function zap(uint256 usdcIn) external nonReentrant returns (uint256 shares) {
    if (usdcIn == 0) revert ZeroAmount();
    if (gate == address(0)) revert NotWired();

    uint256 zipBefore = IESynth(zipUSD).balanceOf(address(this));   // <-- snapshot (tolerates donations)

    IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);
    uint256 zipAmount = usdcIn * scaleUp;
    IESynth(zipUSD).mint(address(this), zipAmount);

    IERC20(usdc).forceApprove(eePool, usdcIn);
    IEulerEarn(eePool).deposit(usdcIn, warehouse);

    IERC20(zipUSD).forceApprove(gate, zipAmount);
    shares = IZipExitGate(gate).depositFor(zipUSD, zipAmount, msg.sender);

    if (shares == 0) revert ZeroShares();
    // The Gate must have pulled exactly the minted zipAmount: net module zipUSD delta == 0.
    // (Delta, not absolute — a stray external donation must not brick the zap; F1/F7 preserved.)
    if (IESynth(zipUSD).balanceOf(address(this)) != zipBefore) revert ResidualBalance();
    IERC20(zipUSD).forceApprove(gate, 0);

    emit Zapped(msg.sender, usdcIn, zipAmount, shares);
}
```

### Why this keeps the original guarantee

- **Gate under-pulls** (pulls < `zipAmount`, stranding some minted zipUSD): post-balance =
  `zipBefore + (zipAmount - pulled) > zipBefore` → reverts. Caught, exactly as before.
- **Gate over-pulls / pulls a donation too**: post-balance < `zipBefore` → reverts. Also caught (the
  Gate must touch only the approved `zipAmount`).
- **Honest path with a pre-existing donation `X`**: pre = `X`, post = `X` → passes. No brick.

The donation `X` simply remains parked (it is not the module's to move and harms nothing — the module
custodies no per-user state and the zap mints/deposits independently of it). If anyone ever wants to mop
it up, that is a separate, optional concern; it must not be coupled to zap liveness.

## Alternative considered (rejected)

A `sweep`/rescue function to drain stray zipUSD would also unbrick it, but it adds an admin/privileged
mutating surface to a contract whose entire security story is "no owner/admin/pause/upgrade — the lone
privileged action is set-once `setGate`" (`ZipDepositModule.sol:43`). The delta check fixes the bug with
zero new surface and is strictly preferable.

## Test deltas

`ZipDepositModule.t.sol` (or `FE-02`-adjacent zap suite):

- `zap_survives_zipusd_donation`: `transfer(module, 1)` from a funded account, then a normal `zap`
  succeeds and mints the correct `shares`; the donated wei is still parked afterward.
- `zap_reverts_if_gate_underpulls`: a mock Gate that pulls `< zipAmount` ⇒ `zap` reverts `ResidualBalance`
  (regression: the real invariant still bites).
- `zap_reverts_if_gate_overpulls`: a mock Gate that pulls `> zipAmount` (i.e. dips into a donation) ⇒
  `zap` reverts `ResidualBalance`.
- fuzz `zap_clean_with_arbitrary_pre_balance(uint96 donation)`: any pre-existing balance, honest Gate ⇒
  `zap` succeeds and the post-minus-pre delta is exactly zero.

## Status

**FIXED 2026-06-13** (`ZipDepositModule.zap`, the delta-check above). Verified:
`forge test --match-contract ZipDepositModule` → 31/31 green, including `test_zap_survives_zipusd_donation`
and `testFuzz_zap_tolerates_donation`; the under-pull / no-share / atomicity regressions still pass.
With the TWAP-ring finding now resolved (ring-spacing fix + fair-LP reserve read shipped), this doc's zap
brick was the last open supply finding from the review — and it is now fixed too.
