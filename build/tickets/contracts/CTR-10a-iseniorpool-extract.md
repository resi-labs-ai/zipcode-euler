# CTR-10a — Extract `ISeniorPool`: generalize the senior read behind a venue-neutral interface — DONE 2026-06-19

> Contract-track change (the buildable, zero-guess half of the re-scoped CTR-10). A pure interface
> generalization + no-op re-type: lift the three donation-immune senior views out of the Euler-named
> `IEulerEarnUtil` into a venue-neutral `ISeniorPool`, so a non-Euler venue's senior surface can satisfy the
> SAME read (the structural enabler for federation). Behavior is byte-identical for the Euler silo.
> Spec: `claude-zipcode.md` §4.7 (venue-agnostic) / §8.2 (donation-immune senior read) / §11-B / §12.

## Why (the seam)
The one Euler-specific coupling in the senior solvency read is the interface NAME: `SeniorNavAggregator`
(CTR-05) and `DurationFreezeModule` both read `IEulerEarnUtil(pool)` — three views `{balanceOf,
convertToAssets, maxWithdraw}`. Those three are not Euler-specific; they are the minimal donation-immune
senior-surface contract any venue's senior pool must satisfy. Generalizing the name behind `ISeniorPool`
removes the coupling at zero behavioral cost and is the prerequisite for CTR-10b (a non-Euler venue silo).

## Deliverable
1. NEW `contracts/src/interfaces/supply/ISeniorPool.sol` — `{maxWithdraw(address), convertToAssets(uint256),
   balanceOf(address)}` (the exact three selectors `IEulerEarnUtil` declared), with the donation-immunity
   contract documented generically (real-pool-accounting-backed, never `balanceOf(pool)`).
2. Re-type `SeniorNavAggregator._seniorValue`/`_illiquidValue` from `IEulerEarnUtil(eePool)` → `ISeniorPool(eePool)`.
3. Re-type `DurationFreezeModule.utilization`/`illiquidSeniorValue` from `IEulerEarnUtil(eulerEarn)` →
   `ISeniorPool(eulerEarn)`. Storage slot name `eulerEarn` RETAINED (renaming ripples into `SiloRegistry`'s
   `IFreeze(freeze).eulerEarn()` topology assert — CTR-10b scope).
4. DELETE `contracts/src/interfaces/euler/IEulerEarnUtil.sol` (now orphaned; nothing else imports it).

## Spec §
`claude-zipcode.md` §4.7, §8.2, §11-B, §12. No spec EDIT owed — this is invisible at the spec level (no
mechanism change). The federation §-sync remains owed by CTR-10b (forward, not a precondition).

## Binds to (verified)
- `IEulerEarnUtil` (deleted) declared exactly `{maxWithdraw, convertToAssets, balanceOf}` — the 3 selectors
  `ISeniorPool` reproduces. Verified the casts emit identical calldata → no-op for the Euler silo.
- The ONLY two `src` importers: `SeniorNavAggregator.sol:6,53,62`, `DurationFreezeModule.sol:10,245,296`.
  No test imports `IEulerEarnUtil`. (grep-confirmed.)

## Do NOT
- Do NOT rename the `DurationFreezeModule.eulerEarn` storage slot (CTR-10b scope — touches SiloRegistry assert).
- Do NOT change `SeniorNavAggregator`/`DurationFreezeModule` behavior — selectors and math are identical.
- Do NOT touch `SiloRegistry.addSilo`'s `IAdapter(adapter).eulerEarn()==eePool` clause (CTR-10b).

## Key requirements
1. Identical selector set — `ISeniorPool` ⊆/⊇ `IEulerEarnUtil` (no behavioral change for the Euler silo).
2. Full existing test suite stays green (the no-op proof).
3. Doc-sync: COVERAGE catalog row moves euler→supply (count stays 31); `interfaces-euler.md`,
   `interfaces-supply.md`, `CTR-05-SeniorNavAggregator.md`, `DurationFreezeModule.md` updated.

## Done when (gate — `forge test`)
- `forge build` green; FULL suite green unchanged. **MET: 919 passed / 0 failed / 3 skipped (56 suites).**
- Cold-build with ZERO load-bearing guesses. **MET** (verified-equivalent re-type).

## Depends on / unblocks
- **Depends on:** CTR-05 (the aggregator), the existing freeze module.
- **Unblocks:** CTR-10b (the non-Euler venue adapter reads/wraps to `ISeniorPool`).
