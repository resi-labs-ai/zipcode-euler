# CTR-13 — Turn on the line APR: a real IRM for the credit-line borrow vaults (~7.5% warehouse rate)

> Contract-track change (EXPANSION / revenue completeness). Spun out of CTR-09's calibration: the per-revolution
> draw FEE shipped (`feeBps = 50`), but the **time-based APR is still 0%** — the per-line borrow vaults run
> `ZeroIRM`. This ticket gives the credit lines a real interest rate (dartboard **~7.5% APR**), leaving the reservoir
> at zero (internal POL). NO new `src/` contract — instantiate EVK's `IRMLinearKink` and re-point the adapter's
> `irm` slot via the Timelock.
> Spec: `build/claude-zipcode.md` §3 (IRM) / §5 (yield routing) / §10 ("the line simply accrues at the fixed
> credit-line rate"). Like CTR-09, the rate is a §17 governance-settable value; spec doc-sync is forward (Conclude).

## Why (the verified gap)
`DeployMainnet.s.sol:101-106` provisions `i.irm` as a **`ZeroIRM`** (0%-rate) by default ("swap a real IRM in later
via the Timelock if desired"), and `EulerVenueAdapter.openLine` installs the adapter's `irm` slot on every per-line
borrow vault (`IEVault(evault).setInterestRateModel(irm)`, `contracts/src/venue/EulerVenueAdapter.sol:323`). So
today **lines accrue no interest** — the CTR-09 draw fee is the only live revenue. The economics settled 2026-06-19
assume a time-based **APR ≈ 7.5%** (SOFR ~3.63% + ~3.9% spread; anchored to bank warehouse lines SOFR+2.25–3.25%
and ≤ the consumer HELOC ~7.5–8.5% so the originator's gain-on-sale margin survives). The protocol's cut of that
interest routes via the EulerEarn perf-fee `f` (§5), lifting senior over-collateralization / treasury.

## Deliverable
1. **Deploy a real IRM** — EVK's `IRMLinearKink` (`reference/euler-vault-kit/src/InterestRateModels/IRMLinearKink.sol`,
   ctor `(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)`). For a single-borrower isolated credit line
   a **FLAT rate is appropriate** (utilization is ~binary per line): `slope1 = slope2 = 0`, `kink = type(uint32).max`,
   so the rate is `baseRate` at all utilizations. `baseRate` = the per-second, 1e27-scaled (RAY) rate for ~7.5% APR.
   **Dartboard value** `baseRate ≈ 2.3766e18` (= `0.075 * 1e27 / SECONDS_PER_YEAR`), but the builder MUST VERIFY the
   exact `SECONDS_PER_YEAR` constant and the per-second-RAY convention against the EVK vault's interest accrual
   (`reference/euler-vault-kit`), and note the APR-vs-APY nuance (EVK compounds per-second, so the effective APY is
   marginally above the nominal 7.5%). Add the deployment to the mainnet/local deploy script (mirror the `ZeroIRM`
   provisioning at `DeployMainnet.s.sol:106`).
2. **Wire it for NEW lines** — `adapter.setIrm(realIRM)` via the Timelock (`EulerVenueAdapter.sol:216`, `onlyOwner`,
   emits `WiringSet("irm", ..)`). Every subsequent `openLine` installs the real IRM (`:323`). No new method needed.
3. **Existing lines** — leave them on `ZeroIRM`; they roll off within ~one quarterly revolution (the warehouse sit
   period) and the redrawn line gets the real rate. **Decision to confirm:** is the roll-off acceptable, or must
   live lines be re-pointed now? Re-pointing a live line needs a governor call `setInterestRateModel` on each line
   vault — the adapter holds the per-line vault governor, with **no exposed passthrough today**, so forcing it on
   live lines would require a NEW adapter method (`setLineIrm(lineRef)` governor-gated). DEFAULT: roll-off (no new
   method); only add the passthrough if the reviewer wants immediate re-pricing of open lines.
4. **Keep the reservoir at zero** — do NOT change the reservoir borrow vault's IRM (`ReservoirMarketDeployer`'s
   `p.irm`); reservoir borrowing is internal POL (§4.5.1) and charging the protocol itself interest is pointless.
   The adapter `irm` slot and the reservoir IRM are independent — `setIrm` does not touch the reservoir.
5. **Perf-fee `f`** — confirm/sets `EulerEarn.setFee(f)` + `setFeeRecipient(warehouseSafe)` so the protocol captures
   its cut of the now-non-zero interest (§5; `f` is a build-time calibration). State the chosen `f` (a dartboard is
   fine; it's the privatized-yield fraction, not the depositor return).

## Spec §
`build/claude-zipcode.md` §3 (the IRM / fixed credit-line rate), §5 (perf-fee routing of the interest), §10 (line
accrual), §17 (Timelock-settable). Add a "line APR (BUILT)" note alongside the §5 CTR-09 per-revolution-draw-fee note
as a Conclude doc-sync (reflecting what's built; not a precondition).

## Binds to (verified 2026-06-19)
- `IRMLinearKink(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)` — `reference/euler-vault-kit/src/InterestRateModels/IRMLinearKink.sol:22`; `is IIRM`; `computeInterestRate(address vault, uint256 cash, uint256 borrows)` (`:31`, reverts `E_IRMUpdateUnauthorized` if `msg.sender != vault`).
- `IIRM` face (what `ZeroIRM` stubs) — `reference/euler-vault-kit/src/InterestRateModels/IIRM.sol`; `ZeroIRM` at `contracts/script/DeployLocal.s.sol:222-229` (the 3-arg `computeInterestRate`/`computeInterestRateView` returning 0).
- `EulerVenueAdapter.irm` slot (`:55`), `setIrm(address) onlyOwner` + `WiringSet("irm", ..)` (`:216-219`), installed per-line at `openLine` (`:323 IEVault(evault).setInterestRateModel(irm)`).
- `IEVault.setInterestRateModel(address)` — governor-gated (the adapter is the per-line vault governor).
- `i.irm` deploy input: `DeployMainnet.s.sol:73,106,187` (adapter ctor) — currently `ZeroIRM`.
- EulerEarn perf-fee: `EulerEarn.setFee`/`setFeeRecipient` (spec §5 cites `:243`/`:258`).

## Starting state
- All borrow vaults (lines + reservoir) run `ZeroIRM` (0%). The adapter `irm` slot points at the `ZeroIRM` instance.
- CTR-09 draw fee is live (`feeBps = 50`, default OFF until `feeRecipient` wired). No interest accrues anywhere.

## Do NOT
- Do NOT change the reservoir borrow vault's IRM (internal POL — zero by design).
- Do NOT add a utilization-based curve unless justified — a flat per-line rate matches the single-borrower isolated
  model; `slope1=slope2=0` is the intent.
- Do NOT renounce or freeze the line-vault governor / the adapter `irm` slot — §17, stays Timelock-settable.
- Do NOT conflate the line APR with the CTR-09 draw fee — separate instruments (time-based vs per-event), separate
  knobs (IRM vs `feeBps`), separate destinations (perf-fee `f` → warehouse Safe vs `feeRecipient` → treasury).
- Do NOT hardcode `baseRate` without verifying the EVK per-second-RAY / `SECONDS_PER_YEAR` units against the
  reference (a units error silently mis-prices every line).

## Key requirements
1. **A real IRM instance** with a verified ~7.5%-APR `baseRate` (units proven against EVK accrual, not assumed).
2. **`setIrm(realIRM)`** wires it for new lines; reservoir untouched (assert reservoir vault IRM still zero-rate).
3. **Roll-off vs re-price decision** for existing lines resolved (default: roll-off, no new method).
4. **Perf-fee `f`** set so the protocol captures its interest cut (state the value).
5. A **fork test** that asserts a line's debt grows at ≈7.5% APR over simulated time (`vm.warp` + `debtOf` before/
   after; tolerance for per-second compounding), and that the reservoir borrow accrues 0 over the same span.

## Done when (gate — `forge test`)
- `forge build` green; a fork test stands up a real line (or extends `EulerVenueAdapter.t.sol` / a deploy fork test)
  proving: (a) a drawn line's `debtOf` accretes at ~7.5% APR over `vm.warp`'d time (within compounding tolerance);
  (b) the reservoir borrow accrues 0 over the same span; (c) `setIrm` re-points and a fresh `openLine` installs the
  real IRM; (d) the perf-fee routes the protocol's interest cut to the warehouse Safe.
- Cold-build with ZERO load-bearing guesses (the `baseRate` units + `SECONDS_PER_YEAR` must be VERIFIED, not guessed).

## Depends on / unblocks
- **Depends on:** none hard (operates on existing wiring); composes with CTR-09 (the fee), CTR-06a (borrow-vault
  governor RETAINED on the Timelock — relevant if the reservoir IRM is ever tuned), CTR-06c (per-silo deploy installs
  the adapter `irm`).
- **Unblocks:** the full warehouse revenue model — interest (APR via IRM → perf-fee) + origination (CTR-09 fee).
  Discharges the PROGRESS "line APR is ZeroIRM" obligation.
