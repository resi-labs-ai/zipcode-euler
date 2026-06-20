# X-Ray — `SzAlpha.sol` (single-contract, test-connected)

> SzAlpha | 201 nSLOC | e634d9f (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/bridge/SzAlpha.sol`, superseding its slice of the bundled
`bridge/x-ray/x-ray.md`. Connected to `test/bridge/SzAlphaBridge.t.sol` (mocked precompiles + mocked CCIP).
The other four bridge contracts (rate oracle = own pass; the 3 thin pool/mirror wrappers = shared note) are
out of scope here.

## 1. What it is

An upgradeable (UUPS) 18-dp ERC-20 liquid-staking wrapper over the Subtensor StakingV2 precompile: TAO in →
validator alpha → szALPHA shares, minted/redeemed against the **measured** precompile stake delta (never
`msg.value` or an estimate), with caller slippage + deadline bounds. Pooled-staker model (the wrapper is the
single staker under its own cached coldkey). `owner()` = TimelockController (upgrade + pause); `ccipAdmin` =
separate lower-privilege CCIP registrar. Bridged-out supply is *locked, not burned* on 964, so
`exchangeRate() = stake/supply` stays truthful cross-chain.

## 2. Entry points

| Function | Access | Value | Notes |
|---|---|---|---|
| `deposit(minSharesOut, deadline)` | permissionless | TAO in | `nonReentrant`, `whenNotPaused`; mints measured delta |
| `redeem(shares, minTaoOut, deadline)` | permissionless | TAO out | `nonReentrant`, **NOT** pausable (S3/S11) |
| `receive()` | permissionless | TAO in | accepts precompile payout; empty body |
| `setCCIPAdmin(newAdmin)` | `onlyCcipAdmin` | — | rotate registrar |
| `pause()` / `unpause()` | `onlyOwner` (Timelock) | — | pauses deposit only |
| `_authorizeUpgrade(impl)` | `onlyOwner` (Timelock) | — | UUPS; empty body = full impl swap |
| `initialize(...)` | `initializer` | — | one-time; caches `wrapperColdkey` |

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | `exchangeRate = (stake18+1)·1e18/(supply+1)` (virtual-offset 1/1) | Yes | `test_rateRisesWithRewards`, `test_firstDeposit_oneToOne_noDivByZero`, **`invariant_rateNeverBelowGenesisAbsentSlash`** |
| I-2 | shares minted/burned only against the measured stake delta | Yes | `test_deposit_offParPrice_mintsMeasuredDelta`, `test_redeem_offParPrice_paysMeasuredTao`, **`invariant_supplyEqualsNetMintedBurned`** |
| I-4 | `netuid ≤ uint16.max` (one write site, init) | Yes | `test_initRejectsNetuidOverUint16` |
| X-1 | precompile **magnitude** is trusted (only sign guarded) | **No** | **`test_lyingPrecompile_overReportInflatesShares`** — blast radius now characterized (2× over-report → 2× issuance) |
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
| G-8 deposit slippage | `test_deposit_slippageExceededReverts` |
| G-9 NativeTransferFailed | `test_g9_nativeTransferFailed_onRedeemPayout`, `test_g9_nativeTransferFailed_onDepositRefund` |
| G-12 RemoveStakeEffectMissing | `test_redeemVerifiesRemoveStakeEffect` |
| G-14 redeem slippage | `test_redeem_slippageExceededReverts` |
| G-16 PrecompileCallFailed | `test_g16_precompileCallFailed_onEmptyStakingCode` |
| G-17 AmountOverflowsUint64 | `test_g17_amountOverflowsUint64_onPreview` |

Also covered: reentrancy (`test_reentrancyBlocked`), pause asymmetry (`test_pauseBlocksDepositButNotRedeem`,
`test_pauseOnlyOwner`), upgrade gating (`test_upgradeRevertsIfNotTimelock`,
`test_upgradePreservesStateForTimelock`), coldkey immutability (`test_coldkeyImmutable`), CCIP-admin gating
(`test_ccipAdminTransferGated`), donation/first-depositor (`test_donationHonesty…`, `test_roundingFavorsProtocol`,
`test_redeemDust_staysStaked_rateNonDecreasing`).

## 5. Attack surfaces (post-test)

- **Precompile measured-delta trust (X-1)** — the documented runtime trust; now *characterized* by the
  lying-mock test (over-report → proportional over-issuance). Remains On-chain=No by nature (the precompile IS
  the on-chain source of truth); the guard is direction-only. The mitigation is operational (DON/runtime trust),
  not code — so this stays the top conceptual surface, now with a known blast radius.
- **UUPS upgrade blast radius** — `_authorizeUpgrade` empty `onlyOwner`; full mint/redeem/rate logic mutable by
  the Timelock. Gating tested; the residual is governance config (timelock delay + proposer set), not code.
- **Cross-chain conservation (E-1)** — proven at the lane level; the residual is the *deploy choice* that the 964
  side is the lock/release pool (asserted by item-10 deploy, not by this contract).

## 6. Test analysis — the status change

| Metric | Before | Now |
|---|---|---|
| Unit (SzAlpha-relevant) | 44 | 52 |
| Stateless fuzz | 0 | **1** (`testFuzz_roundTripFavorsProtocol`) |
| Stateful invariant | 0 | **2** (`SzAlphaInvariantTest`) |
| Edge-revert guards (G-9/16/17, init) | uncovered | covered |

The full bridge suite runs **green (55 tests, 0 failed)** with these additions.

## X-Ray Verdict

**ADEQUATE** *(up from FRAGILE)* — the bridge-scope x-ray rated this FRAGILE on "unit-only." With a Foundry
invariant suite (conservation + rate-floor) and a round-trip rounding fuzz now present, the Tests axis is
ADEQUATE per the rubric (unit + fuzz + invariant). Access control is HARDENED (roles + Timelock + reentrancy +
pause-asymmetry-by-design); docs are dense NatSpec. Held below HARDENED only by: no formal verification, and the
X-1 precompile-magnitude trust is fundamental (runtime, not closable in code — now characterized, not eliminated).

**Structural facts:**
1. 201 nSLOC, UUPS-upgradeable; 3 permissionless entry points (`deposit`/`redeem`/`receive`).
2. Tests: 52 unit + 1 fuzz + 2 invariant; full bridge suite 55/55 green.
3. The X-1 magnitude seam is now adversarially tested (lying-mock); blast radius = proportional over-issuance.
4. Upgrade + pause gated by a TimelockController `owner()`; `ccipAdmin` is a separate registrar role.
5. Coverage % still uninstrumentable (project-wide stack-too-deep) — test *existence* confirmed by scan + run.
