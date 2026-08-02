# X-Ray — `SzAlpha.sol` (single-contract, test-connected)

> SzAlpha | 277 nSLOC | `main`, working tree | Foundry | 31/07/26 (evening) | **Verdict: ADEQUATE**

> **Update 2026-07-31 evening (the mainnet drill + `migrateTo`):**
> - **`migrateTo(newHotkey)`** — the third recovery lever: a VOLUNTARY validator switch (`retarget`
>   refuses a lower-stake target by design; `migrateFrom` is inbound-only, so the pair could not express
>   "move because we prefer the other validator"). Full-stake `moveStake`, destination-conservation-checked,
>   then re-point. Gap surfaced by the live drill, not review.
> - **`MOVE_ROUNDING_RAO = 1`** — the live 964 pallet credits `moveStake` transfers exactly 1 rao short
>   (integer rounding; measured on mainnet when the strict conservation check FAIL-CLOSED a real
>   `migrateTo`). Both migrate checks tolerate exactly 1 rao; the mock now shaves 1 rao too
>   (runtime-faithful), so every happy-path test exercises the tolerance.
> - **Mainnet execution record:** deposit/UUPS-upgrade(×2)/`migrateTo`/floor-deposit/redeem/`retarget`-refusal
>   all executed against the real 964 runtime (drill instance `0xe5a1Af…`, see `SN46-BRIDGE-MVP-V2.md`
>   drill record). The `moveStake` recovery path is no longer merely tested — it has run in production
>   conditions.
> - **`RubiconIncidentReplay.t.sol`** — the 12 Jun 2026 xSN9 timeline replayed step-for-step as a
>   permanent regression (fake-par → revert; 56x window mint → refused; freeze → exit arithmetic-gated;
>   26-day recovery → one exact-restore `retarget`).
> - Octane-7 pin extended: all three recovery levers now run under a bricked `0x808`.
> - Suites: SzAlphaBridgeTest 65; full bridge run **95/95**.

Dedicated single-contract X-Ray for `contracts/src/bridge/SzAlpha.sol`, superseding its slice of the bundled
`bridge/x-ray/x-ray.md`. Connected to `test/bridge/SzAlphaBridge.t.sol` (mocked precompiles + mocked CCIP).
The other four bridge contracts (rate oracle = own pass; the 3 thin pool/mirror wrappers = shared note) are
out of scope here.

> **Update 2026-07-31 (Phase 0, `bridge/SN46-BRIDGE-MVP-V2.md` — the Rubicon hotkey-drift response,
> uncommitted working tree):** four deltas + 11 tests, derived from `audit/reviewed/rubicon-incident-2026-06-12.md`
> and the Octane dispositions. **SzAlphaBridge suite 63 unit + 2 invariant + 1 fork + 2 handoff green; full
> bridge run 91/91.**
> - **`BackingVanished` guard** (`deposit:211`, `exchangeRate:325`): `supply != 0 && stake == 0` — the exact
>   Rubicon pre-state (validator `swap_hotkey` moved the stake; the configured key correctly reads zero) —
>   halts entry AND the rate view instead of pricing the dead pointer at ~0. A reverting rate cannot be
>   CRE-pushed, so the Base feed goes stale and consumers fail closed on `fresh()` — the staleness machinery
>   IS the cross-chain breaker (no deviation band added). Genesis (`supply == 0`) unaffected; `redeem` and
>   `totalStaked()` (the monitoring probe) untouched.
> - **`retarget(newHotkey)` + `migrateFrom(sourceHotkey)`** (`:386`, `:402`, both `onlyOwner`): the drift
>   recovery Rubicon shipped 26 days into their incident via UUPS upgrade, here at genesis as timelocked
>   transactions. `retarget` is a pure pointer update guarded by `RetargetLosesStake` (new key must hold ≥
>   current); `migrateFrom` consolidates stranded stake via the now-pinned `moveStake` precompile
>   (`ISubtensorPrecompiles.sol`, signature verified against the vendored pallet source), `netuid` pinned on
>   both sides (no AMM routing), conservation-checked (`MigrationLostStake`). **`validatorHotkey` is now a
>   timelock-repointable pointer, not an immutable** — §5 updated below.
> - **`redeemTo(receiver, shares, minTaoOut, deadline)`** (`:259`): the relocated Octane finding, fixed as
>   ratified — shared `_redeemTo` CEI path, shares always burned from `msg.sender`, TAO to the named receiver
>   (for the future 964-side unwind executor that must not hold native TAO). `Redeemed` event now carries the
>   receiver.
> - **X-1 is now characterized in BOTH directions**: the lying-mock over-report test (2× report → 2×
>   issuance) plus the drift sim (under-report to ZERO → `BackingVanished`, then `retarget` recovers the
>   exact rate). The under-report direction was the one the old suite missed — and the one that actually
>   happened in production. Octane-7 is pinned by test: a full deposit/redeem round trip passes with the
>   `0x808` quote precompile bricked.

## 1. What it is

An upgradeable (UUPS) 18-dp ERC-20 liquid-staking wrapper over the Subtensor StakingV2 precompile: TAO in →
validator alpha → szALPHA shares, minted/redeemed against the **measured** precompile stake delta (never
`msg.value` or an estimate), with caller slippage + deadline bounds. Pooled-staker model (the wrapper is the
single staker under its own cached coldkey). `owner()` = TimelockController (upgrade + pause + hotkey
retarget/migrate); `ccipAdmin` = separate lower-privilege CCIP registrar. Bridged-out supply is *locked, not
burned* on 964, so `exchangeRate() = stake/supply` stays truthful cross-chain — and the rate FAILS CLOSED
(reverts) on both precompile outage and vanished backing rather than serving a false number.

## 2. Entry points

| Function | Access | Value | Notes |
|---|---|---|---|
| `deposit(minSharesOut, deadline)` | permissionless | TAO in | `nonReentrant`, `whenNotPaused`; `BackingVanished` guard before the stake call; mints measured delta; **`minSharesOut` MUST be non-zero except at genesis (supply 0)** — else `SlippageFloorRequired` |
| `redeem(shares, minTaoOut, deadline)` | permissionless | TAO out | `nonReentrant`, **NOT** pausable (S3/S11); **`minTaoOut` MUST be non-zero** — else `SlippageFloorRequired` |
| `redeemTo(receiver, shares, minTaoOut, deadline)` | permissionless | TAO out | same `_redeemTo` path; burns from `msg.sender`, pays `receiver` (≠ 0); a non-payable receiver reverts `NativeTransferFailed` |
| `receive()` | permissionless | TAO in | accepts precompile payout; empty body |
| `setCCIPAdmin(newAdmin)` | `onlyCcipAdmin` | — | rotate registrar |
| `pause()` / `unpause()` | `onlyOwner` (Timelock) | — | pauses deposit only |
| `retarget(newHotkey)` | `onlyOwner` (Timelock) | — | drift recovery: pointer update, no stake movement; `RetargetLosesStake` guard |
| `migrateFrom(sourceHotkey)` | `onlyOwner` (Timelock) | — | consolidate stranded stake via `moveStake`, netuid-pinned both sides; `MigrationLostStake` conservation check (1-rao tolerance) |
| `migrateTo(newHotkey)` | `onlyOwner` (Timelock) | — | VOLUNTARY switch: full-stake `moveStake` + re-point; destination conservation check (1-rao tolerance); mainnet-executed |
| `_authorizeUpgrade(impl)` | `onlyOwner` (Timelock) | — | UUPS; empty body = full impl swap |
| `initialize(...)` | `initializer` | — | one-time; caches `wrapperColdkey` |

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | `exchangeRate = (stake18+1)·1e18/(supply+1)` (virtual-offset 1/1); REVERTS `BackingVanished` at `supply>0 && stake==0` (genesis still serves 1:1) | Yes | `test_rateRisesWithRewards`, `test_firstDeposit_oneToOne_noDivByZero`, **`test_backingVanished_exchangeRateRevertsButGenesisServes`**, **`invariant_rateNeverBelowGenesisAbsentSlash`** |
| I-2 | shares minted/burned only against the measured stake delta; NO mint in the vanished state | Yes | `test_deposit_offParPrice_mintsMeasuredDelta`, `test_redeem_offParPrice_paysMeasuredTao`, **`test_backingVanished_depositReverts`**, **`invariant_supplyEqualsNetMintedBurned`** |
| I-4 | `netuid ≤ uint16.max` (one write site, init) | Yes | `test_initRejectsNetuidOverUint16` |
| I-5 | hotkey repoint conserves stake: `retarget` requires `stakeAtNew ≥ stakeAtCurrent`; both migrates require destination `after + 1 rao ≥ before + amount` (the measured pallet rounding, nothing more) | Yes | **`test_retarget_recoversFromDrift`** (exact rate restore), `test_retarget_losesStakeReverts`, `test_migrateFrom_consolidatesStrandedStake`, `test_migrateFrom_lostStakeReverts`, **`test_migrateTo_switchesValidatorWithFullStake`**, `test_migrateTo_lostStakeReverts_andEmptyReverts`, `test_retargetAndMigrate_onlyOwner`, + the mainnet drill (real `moveStake`, real 1-rao shave) |
| I-6 | `redeemTo` burns from the caller only; receiver is a payout redirect, never a share authority | Yes | `test_redeemTo_paysNamedReceiver`, `test_redeemTo_rejectsZeroAndNonPayableReceiver` |
| I-7 | state paths never read the `0x808` quote precompile (Octane-7 stays not-inherited) | Yes | **`test_statePaths_neverTouchAlphaQuotePrecompile`** (round trip with `0x808` bricked; previews fail closed) |
| X-1 | precompile **magnitude** is trusted (only sign guarded) — now characterized BOTH directions | **No** | **`test_lyingPrecompile_overReportInflatesShares`** (2× over-report → 2× issuance) + **the drift sim** (under-report to ZERO → `BackingVanished`, the direction that fired in production at Rubicon) |
| E-1 | cross-chain conservation (lock-not-burn keeps supply counted) | **No** (deploy-topology) | `test_lane_lockOnSource_supplyAndRateInvariant`, `test_lane_roundTrip_rateInvariant` |
| — | round-trip never pays out more than deposited (rounding favors protocol) | Yes | **`testFuzz_roundTripFavorsProtocol`** |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| G-1 owner/ccipAdmin ≠ 0 | `test_g1_initRejectsZeroOwner`, `test_g1_initRejectsZeroCcipAdmin` |
| G-2 validatorHotkey ≠ 0 | `test_g2_initRejectsZeroHotkey` |
| G-3 netuid ≤ uint16 | `test_initRejectsNetuidOverUint16` |
| G-4 deadline | `test_deadlineExpiredReverts` |
| G-5 amountRao ≠ 0 | `test_deposit_subRaoAmountReverts`, `test_zeroAmountReverts` |
| G-6 AddStakeEffectMissing | `test_depositVerifiesAddStakeEffect` |
| G-7 ZeroSharesOut | `test_donationHonesty_griefingIsValueDestroying` |
| G-8 deposit slippage (floor mandatory, genesis-exempt) | `test_deposit_slippageExceededReverts`, `test_floor_depositZeroFloorRevertsAtSupplyNonZero`, `test_floor_genesisDepositMayPassZero` |
| G-9 NativeTransferFailed | `test_g9_nativeTransferFailed_onRedeemPayout`, `test_g9_nativeTransferFailed_onDepositRefund` |
| G-12 RemoveStakeEffectMissing | `test_redeemVerifiesRemoveStakeEffect` |
| G-14 redeem slippage (floor mandatory) | `test_redeem_slippageExceededReverts`, `test_floor_redeemZeroFloorReverts` |
| G-16 PrecompileCallFailed | `test_g16_precompileCallFailed_onEmptyStakingCode` |
| G-17 AmountOverflowsUint64 | `test_g17_amountOverflowsUint64_onPreview` |
| G-19 BackingVanished (deposit + exchangeRate) | `test_backingVanished_depositReverts`, `test_backingVanished_exchangeRateRevertsButGenesisServes` |
| G-20 RetargetLosesStake / MigrationLostStake / migrate-empty-source | `test_retarget_losesStakeReverts`, `test_migrateFrom_lostStakeReverts`, `test_migrateTo_lostStakeReverts_andEmptyReverts`, `test_migrateFrom_consolidatesStrandedStake` (ZeroAmount re-migrate); RetargetLosesStake also proven LIVE (mainnet drill) |
| G-21 redeemTo receiver ≠ 0 / payable | `test_redeemTo_rejectsZeroAndNonPayableReceiver` |

Also covered: reentrancy (`test_reentrancyBlocked`), pause asymmetry (`test_pauseBlocksDepositButNotRedeem`,
`test_pauseOnlyOwner`), upgrade gating (`test_upgradeRevertsIfNotTimelock`,
`test_upgradePreservesStateForTimelock`), coldkey immutability (`test_coldkeyImmutable`), CCIP-admin gating
(`test_ccipAdminTransferGated`), donation/first-depositor (`test_donationHonesty…`, `test_roundingFavorsProtocol`,
`test_redeemDust_staysStaked_rateNonDecreasing`).

## 5. Attack surfaces (post-test)

- **Precompile measured-delta trust (X-1)** — the documented runtime trust; now *characterized in both
  directions*: over-report → proportional over-issuance (lying mock), under-report-to-zero → `BackingVanished`
  halt + `retarget` recovery (drift sim — the direction that actually fired at Rubicon, 2026-06-12). Remains
  On-chain=No by nature (the precompile IS the on-chain source of truth); the guard is direction-plus-vanished,
  magnitude still trusted. The residual mitigation is operational (Phase C monitoring, `SN46-BRIDGE-MVP-V2.md`).
- **Hotkey drift (was unaddressed-by-omission; now the built response)** — `validatorHotkey` is a pointer, not
  a fact: a substrate `swap_hotkey` empties it while the stake sits at the operator's new key under our own
  coldkey. Detect: `BackingVanished` halts entry + the rate (and stales the Base feed via the failed CRE read).
  Recover: `retarget` (pointer update) / `migrateFrom` (stranded-stake consolidation), both timelocked and
  conservation-guarded. Residual: drift DETECTION latency is off-chain (Phase C alarms); and the CRE job spec
  MUST treat a reverting rate read as no-push, never "push 0" (MVP-V2 §B5 — a spec requirement, not yet a job).
- **Owner (timelock) authority grew** — beyond upgrade + pause, the owner can now re-point `validatorHotkey`
  and move stake between hotkeys. Both are conservation-guarded (cannot end with less stake than before), so
  the added power is where-the-stake-sits, not how-much — but a hostile timelock could retarget to a
  same-balance key it controls the VALIDATOR side of (yield degradation, not theft). Same trust class as the
  pre-existing full-upgrade power; the timelock delay is the control.
- **UUPS upgrade blast radius** — `_authorizeUpgrade` empty `onlyOwner`; full mint/redeem/rate logic mutable by
  the Timelock. Gating tested; the residual is governance config (timelock delay + proposer set), not code.
- **Cross-chain conservation (E-1)** — proven at the lane level; the residual is the *deploy choice* that the 964
  side is the lock/release pool (asserted by item-10 deploy, not by this contract).

## 6. Test analysis — the status change

| Metric | 20/06/26 | Now (31/07/26) |
|---|---|---|
| Unit (SzAlphaBridgeTest) | 52 | **63** (+11 Phase-0: vanished-state ×2, drift/retarget/migrate ×5, redeemTo ×2, Octane-7 pin, owner gating) |
| Stateless fuzz | 1 | 1 (`testFuzz_roundTripFavorsProtocol`) |
| Stateful invariant | 2 | 2 (`SzAlphaInvariantTest`) |
| Full bridge run | 55 + 22 | **91/91** (incl. fork + handoff + rate-oracle suites) |

Mock additions: `moveStake` (runtime-faithful same-coldkey re-attribution), `driftHotkey` (the `swap_hotkey`
simulation), `breakMoveStake` (silent-failure negative).

## X-Ray Verdict

**ADEQUATE** — access control is HARDENED (roles + Timelock + reentrancy + pause-asymmetry-by-design), the
Tests axis is ADEQUATE (unit + fuzz + invariant), and the Rubicon drift class — the one production failure this
pattern has actually suffered — is now guarded (`BackingVanished`), recoverable (`retarget`/`migrateFrom`), and
adversarially tested in the direction that fired (under-report to zero). Held below HARDENED by: no formal
verification, the X-1 precompile-magnitude trust (fundamental; characterized, not eliminated), and the two
off-chain residuals — drift-detection latency (Phase C monitoring) and the CRE no-push-on-revert job-spec
requirement (MVP-V2 §B5), neither closable in this contract.

**Structural facts:**
1. 277 nSLOC, UUPS-upgradeable; 4 permissionless entry points (`deposit`/`redeem`/`redeemTo`/`receive`); 5 owner functions (pause/unpause/retarget/migrateFrom/migrateTo) + UUPS.
2. Tests: 65 unit + 1 fuzz + 2 invariant in the SzAlpha suites + the Rubicon incident replay; full bridge run 95/95 green.
3. X-1 characterized both directions: over-report → proportional over-issuance; under-report-to-zero → `BackingVanished` halt, `retarget` restores the exact rate — and the full 12 Jun 2026 timeline is a standing regression (`RubiconIncidentReplay.t.sol`).
4. `validatorHotkey` is a timelock-repointable pointer with conservation guards (drift recovery AND voluntary switch); `wrapperColdkey` stays immutable; `ccipAdmin` is a separate registrar role.
5. Fail-closed rate: reverts on precompile outage AND on vanished backing — the CRE-push failure + Base `fresh()` gate form the cross-chain breaker (no deviation band).
6. The `moveStake` recovery path has EXECUTED on 964 mainnet (2026-07-31 drill), including surviving the pallet's measured 1-rao rounding (`MOVE_ROUNDING_RAO`).
7. Coverage % still uninstrumentable (project-wide stack-too-deep) — test *existence* confirmed by scan + run.
