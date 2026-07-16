# X-Ray — `EulerVenueAdapter.sol` (single-contract, test-connected)

> EulerVenueAdapter | 354 nSLOC | 8b7c67c (`main`, working tree) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo external-infra trust, the two-key deploy invariant, the pre-prod re-freeze, and no external audit)*

> **Update 2026-06-20:** the I-16 gap (the ~11 build-phase infra wiring setters' `onlyOwner`/`ZeroAddress` untested)
> is **CLOSED** — 3 sweep tests (`test_I16_InfraSetters_RejectNonOwner` / `_RejectZeroAddress` /
> `_OwnerRepointsAndEmits`) cover all 11 setters' auth + zero-guard + re-point/event, and `test_seniorPool_ReturnsEulerEarn`
> closes the `seniorPool` note. 53/53 fork tests green. Every guard, every setter, and the senior surface are now
> exercised; verdict lifted to HARDENED.

First per-contract X-Ray in `contracts/src/venue/` (this dir's x-ray scope). Subject: `EulerVenueAdapter.sol`, the
substantive contract; its two siblings — `IZipcodeVenue.sol` (the venue-neutral seam, 24 nSLOC interface) and
`LineAccount.sol` (8 nSLOC, ctor-only per-line EVC borrower-of-record) — are summarized at the end. Exercised by
`EulerVenueAdapter.t.sol` — a **~52-test Base-fork suite** (real EVK `GenericFactory`, EVC, `EulerRouter`; a
faithful recording `EulerEarn` mock, since EE pins solc 0.8.26 and cannot be deployed under 0.8.24 — the mock
mirrors every seam the adapter crosses: the 30-market cap, the queue removal guards, the full-redeem donation
sweep, the zero-sum reallocate check) plus a `MisWiringAdapter` harness subclass to reach the defensive
`_assertWired` branch; the
farm-utility fund/defund cluster is covered cross-suite in `FarmUtilityLoopModule.t.sol`.

> This is the **most complex contract in the sweep**: a per-line isolated-market **factory**. One `openLine` call
> atomically mints + aligns a fresh EVC borrower account (`LineAccount` + operator grant), an escrow collateral vault
> (holds the lien), an isolated USDC borrow vault, and a dedicated **frozen** per-line `EulerRouter`, then onboards
> the market to the shared `EulerEarn` pool. It holds the per-line market-governor role + each line's EVC operator
> bit. Modeled inline on the verified `EdgeFactory.deploy()`. The security work is all in the **wiring discipline**:
> the draw receiver is pinned to the immutable off-ramp (F2), the curator's `submitCap` is bounded to only the
> freshly-minted vault (F3), reallocate sizing reads the EE's *tracked* balance so a share donation can't grief it
> (SEC-11), and close reclaims both the supply- and withdraw-queue slots so origination can't brick at the 30-market
> cap (SEC-06/CTR-04).

## 1. What it is

A 354-nSLOC `Ownable` (Timelock) + `onlyController` factory implementing `IZipcodeVenue`. Two privileged callers:
the **controller** (drives the line lifecycle) and the **owner/Timelock** (re-points build-phase wiring). A third
gate — `onlyFarmUtilityAllocator` — guards the farm-utility JIT path (two-key separation from the loop operator).

- **`openLine`** (controller): the 7-step cluster mint — LineAccount + operator grant → escrow vault → frozen per-line router (collat→lienToken→registry) → isolated USDC borrow vault (hook `OP_BORROW|OP_LIQUIDATE`, curator feeReceiver) → EE onboarding (submitCap/acceptCap bounded to the new vault + supply-queue append) → custody the 1e18 lien → freeze router → birth-time wire-check.
- **`setLineLimits`/`fund`/`draw`/`closeLine`/`observeDebt`/`liquidate`** (controller): the lifecycle. `draw` pins the receiver to `erebor` (F2), appends the optional CTR-09 fee leg as a second EVC borrow on the same account; `closeLine` reclaims the lien + defunds USDC to base + prunes both EE queue slots.
- **wiring setters** (owner): ~13 `ZeroAddress`-guarded re-points + the fee/curator setters (zero = "off" sentinel) + `setFeeBps` (capped) + `setFarmUtilityVault` (CTR-07 hook-guard).
- **`fundFarmUtility`/`defundFarmUtility`** (`onlyFarmUtilityAllocator`): JIT absolute-target reallocate of resting USDC in/out of the farm-utility vault.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `openLine(lienId, lienToken, 1e18)` | `onlyController` | atomic 7-step cluster mint; reverts on partial collateral / non-zero EE timelock |
| `setLineLimits` / `fund` / `draw` / `closeLine` / `liquidate` | `onlyController` | lifecycle; `draw` pins `erebor`, `liquidate` reverts `NotImplemented` |
| `observeDebt` / `getLine` / `seniorPool` | view | `observeDebt` readable post-close; `seniorPool` = `address(eulerEarn)` |
| `fundFarmUtility` / `defundFarmUtility` | `onlyFarmUtilityAllocator` | JIT reallocate; two-key separation from the loop operator |
| `setController`/`setEvc`/`setEulerEarn`/`setEVaultFactory`/`setOracleRegistry`/`setGatingHook`/`setIrm`/`setUsdc`/`setErebor`/`setUsdcReservoir`/`setFarmUtilityAllocator` | `onlyOwner` | `ZeroAddress`-guarded build-phase re-points |
| `setFarmUtilityVault` | `onlyOwner` | zero-guard + CTR-07 `FarmUtilityHookBlocksReallocate` |
| `setAdminSafe`/`setCuratorSafe` | `onlyOwner` | zero = "fee off" sentinel (no zero-guard, by design) |
| `setFeeBps` | `onlyOwner` | capped at `MAX_FEE_BPS` (5%) |

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **atomic cluster mint** — `openLine` builds LineAccount+operator, escrow vault, frozen router, borrow vault, EE onboarding, lien custody, wire-check; reverts on partial collateral (`!= 1e18`) | Yes | **`test_OpenLine_FullAmount_Succeeds`**, `_InvalidCollateralAmount_Zero`/`_Partial`, **`test_MarketWiring`**, `test_LineAccount_Mechanics` |
| I-2 | **per-line isolation** — two lines get distinct EVC prefixes, both draw independently; a foreign account is hook-rejected | Yes | **`test_TwoLine_DistinctPrefix_BothDraw_Isolation`**, **`test_ForeignAccount_HookRejects`** |
| I-3 | **draw receiver pinned to `erebor` (F2)** — a non-`erebor` receiver reverts `BadReceiver`, even with the fee leg on | Yes | **`test_Draw_BadReceiver_Reverts`**, `test_CTR09_F2_PinIntactWithFeeOn` |
| I-4 | **submitCap bounded to the freshly-minted vault (F3)** — never a caller-supplied market | Yes | **`test_OpenLine_SubmitsCapOnlyForOwnVault`** |
| I-5 | **reallocate sizing is donation-immune (SEC-11/L9)** — sized off EE *tracked* `previewRedeem(config.balance)`, not live balance | Yes | **`test_SEC11_Fund_DonationImmune`**, `_PreFixSizing_Reverts_OnDonation`, `_Fund_NoDonation_StillMoves`, `test_Fund_RecordsTwoItemAbsoluteAllocation` |
| I-6 | **close reclaims both EE queue slots (SEC-06 supply + CTR-04 withdraw)** — origination never bricks at the 30-market cap | Yes | **`test_SEC06_*`** (3: prune, leaves-other-fundable, churn-past-cap), **`test_CTR04_*`** (6: reclaim, cap-zero-empty, leaves-others, bricks-without-close, churn, concurrent-reuse) |
| I-7 | **close defunds USDC to base (SEC-07)** — no strand, no later `fund` underflow; never-funded line no-ops | Yes | **`test_SEC07_CloseLine_DefundsUsdcToBase`**, `_NoLaterFundUnderflow`, `_NeverFundedLine_NoDefund` |
| I-8 | **close guards on repayment + reclaims the 1e18 lien** | Yes | **`test_CloseLine_LineNotRepaid_WhileDebt`**, `_NoDebt_ReclaimsLien` |
| I-9 | **EE-timelock precheck (SEC-08)** — non-zero EE timelock aborts BEFORE any line state (no orphan) | Yes | **`test_SEC08_TimelockPrecheck_RevertsEarly_NoOrphan`**, `_TimelockZero_HappyPath`, `_DeployProbe_PassesLive`/`_Bites` |
| I-10 | **CTR-09 per-draw fee** — financed by the line as a 2nd borrow leg; off when recipient unset / bps zero / dust; F2 preserved | Yes | **`test_CTR09_FeeOn_FinancesAndRoutesFee`**, `_FeeIsPerRevolution`, `_NoOp_WhenRecipientUnset`, `_NoOp_WhenFeeBpsZero`, `_DustDraw_NoFeeLeg`, `_Setters_GatingCapAndEvents` |
| I-11 | **CTR-13 line IRM + curator fee** — real IRM accrues ~7.5% APR vs ZeroIRM zero; curator governor-share routes to the curator vault | Yes | **`test_CTR13_LineIrm_BaseRate_Is_7_5pct_APR_Nominal`**, `_RealLineAccrues7_5pct_While_ZeroIrmLineAccruesZero`, `_CuratorFee_RoutesGovernorShareToCuratorVault` |
| I-12 | **`_assertWired` wire-mismatch fail (W3)** — reachable via a deliberately mis-wiring subclass | Yes | **`test_WireMismatch_ReachableViaMisWiringHarness`** |
| I-13 | **AmountCap encode round-trips + rejects zero** | Yes | **`test_AmountCap_RoundTrip_And_ZeroReverts`** |
| I-14 | **authority gates** — non-controller reverts `NotController`; unknown line reverts; `liquidate` `NotImplemented`; double-open same `lienId` reverts (CREATE2) | Yes | **`test_Authority_NonController_Reverts`**, `_UnknownLine_Reverts`, `_Liquidate_NotImplemented`, `_DoubleOpenLine_SameLienId_Reverts` |
| I-15 | **farm-utility JIT fund/defund** — absolute-target reallocate; two-key `onlyFarmUtilityAllocator` (`NotFarmUtilityAllocator`); `setFarmUtilityVault` CTR-07 hook guard | Yes | **`FarmUtilityLoopModule.t.sol`** (cross-suite): fund/defund happy, `NotFarmUtilityAllocator` gate, `test_ctr07_setFarmUtilityVault_rejects_reallocate_blocking_hook` |
| I-16 | **build-phase wiring setters** — every re-point is `onlyOwner` + `ZeroAddress`-guarded; `setFeeBps` capped; fee setters use the zero-sentinel | Yes | **`test_I16_InfraSetters_RejectNonOwner` / `_RejectZeroAddress` / `_OwnerRepointsAndEmits`** (all 11 infra setters: auth + zero + re-point/`WiringSet`) + `setFeeBps`/`setAdminSafe`/`setCuratorSafe` (CTR-09/CTR-13) + `setIrm` effect (CTR-13) |
| I-17 | **`seniorPool()` = the EulerEarn pool** (CTR-10b venue-agnostic admission surface) | Yes | **`test_seniorPool_ReturnsEulerEarn`** (+ consumer-covered via `SiloRegistry`/`SiloDeployer`) |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `InvalidCollateralAmount` (`!= 1e18`) | `openLine:316` | `test_OpenLine_InvalidCollateralAmount_*` |
| `EulerEarnTimelockNonZero` (SEC-08) | `openLine:323` | `test_SEC08_*` |
| `BadReceiver` (F2) | `draw:444` | `test_Draw_BadReceiver_Reverts` |
| `LineNotRepaid` | `closeLine:519` | `test_CloseLine_LineNotRepaid_WhileDebt` |
| `NotController` / `UnknownLine` / `NotImplemented` | various | `test_Authority_*`, `_UnknownLine_*`, `_Liquidate_*` |
| `WireMismatch` (W3) | `_assertWired:389` | `test_WireMismatch_ReachableViaMisWiringHarness` |
| `ZeroCap` (AmountCap) | `_toAmountCap` | `test_AmountCap_RoundTrip_And_ZeroReverts` |
| `FeeTooHigh` (cap) | `setFeeBps:296` | `test_CTR09_Setters_GatingCapAndEvents` |
| `NotFarmUtilityAllocator` (two-key) | `fundFarmUtility`/`defundFarmUtility` | `FarmUtilityLoopModule.t.sol` |
| `FarmUtilityHookBlocksReallocate` (CTR-07) | `setFarmUtilityVault:264` | `FarmUtilityLoopModule.t.sol` `test_ctr07_*` |
| `ZeroAddress` + `onlyOwner` on the ~11 infra setters | `:185-252,:271` | `test_I16_InfraSetters_RejectNonOwner` / `_RejectZeroAddress` / `_OwnerRepointsAndEmits` |

## 5. Attack surfaces

- **The wiring discipline is the security model, and the hard parts are proven.** F2 (draw pinned to `erebor`), F3
  (submitCap bounded to the minted vault), SEC-11 (donation-immune reallocate sizing), the router freeze (governance
  transferred to `address(0)` so the price source can't be re-pointed), and the birth-time wire-check are all directly
  fork-tested. These are the surfaces where a factory mis-step would leak or mis-price; each is covered.
- **The 30-market EE queue ceiling is the protocol's known scaling wall — and close reclaims both slots (I-6).** The
  supply-queue prune (SEC-06) and the *binding* withdraw-queue slot reclaim (CTR-04) are tested across churn past the
  cap, including concurrent reuse (close frees a slot for a new open). This is the densest test cluster and the right
  one — a leaked slot permanently bricks origination.
- **Per-line isolation + foreign-account rejection (I-2).** Two lines get distinct EVC prefixes and draw
  independently; a foreign borrow account is rejected by the gating hook. The EVC operator-grant mechanics
  (`LineAccount` sub-account-1 code-free prefix) are exercised.
- **The farm-utility two-key separation (I-15) is covered cross-suite.** `fundFarmUtility`/`defundFarmUtility`, the
  `NotFarmUtilityAllocator` gate (distinct from the loop operator), and the CTR-07 hook guard live in
  `FarmUtilityLoopModule.t.sol`. The distinctness of the two keys is a *deploy* invariant (no on-chain handle), proven
  only by the loop-operator key reverting `NotFarmUtilityAllocator` — worth confirming the deploy wires distinct keys.
- **Build-phase wiring setters (I-16) — CLOSED.** The highest-count setter surface in the codebase (re-pointing the
  controller, the EE pool, the factory, the oracle registry) is now swept: all 11 infra setters revert
  `OwnableUnauthorizedAccount` for a non-owner, revert `ZeroAddress` for zero, and re-point + emit `WiringSet` for the
  owner (`test_I16_InfraSetters_*`). With the CTR-09/CTR-13 setters and `setIrm`'s effect already covered, every
  setter on the contract is now exercised.
- **`seniorPool()` (CTR-10b, I-17) — CLOSED.** `test_seniorPool_ReturnsEulerEarn` asserts it returns
  `address(eulerEarn)` directly (it was already consumer-covered via `SiloRegistry`/`SiloDeployer`).
- **Two-key distinctness is a deploy invariant with no on-chain handle.** `farmUtilityAllocator` MUST differ from the
  `FarmUtilityLoopModule.operator` (so draining idle USDC needs both keys), but the adapter has no reference to the
  loop module, so this cannot be asserted on-chain — only proven indirectly (the loop operator key reverts
  `NotFarmUtilityAllocator`). A genuine residual, inherent to the design; confirm the deploy wires distinct keys.
- **External-infra trust** — the EVK `GenericFactory`/`EVault`, EVC, `EulerEarn`, `EulerRouter`, the `CREGatingHook`,
  and the `ZipcodeOracleRegistry` price source are all trusted dependencies (audited once, used per-line). Build-phase
  mutable wiring (frozen pre-prod) is the subsystem-wide residual.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Cluster mint + lifecycle (fork) | ~14 | openLine guards, market wiring, two-line isolation, fund/draw/close, AmountCap, LineAccount mechanics |
| Queue-slot reclaim (SEC-06 + CTR-04) | 9 | supply + binding withdraw queue, churn past 30-cap, concurrent reuse |
| Donation immunity (SEC-11) | 3 | tracked-balance sizing; pre-fix sizing reverts on donation |
| SEC-07 defund / SEC-08 EE-timelock | 6 | no-strand/underflow, orphan-free precheck, deploy probe |
| CTR-09 fee / CTR-13 IRM + curator | 10 | financed fee leg, per-revolution, off-sentinels, dust, real APR accrual, curator routing |
| Authority / wire-mismatch / interface | ~7 | non-controller, unknown line, liquidate, double-open, `MisWiringAdapter` harness, interface impl |
| Infra wiring setters (`onlyOwner`/`ZeroAddress`/effect) + `seniorPool` | 4 | all 11 infra setters swept + the senior surface (added 2026-06-20) |
| Farm-utility fund/defund (cross-suite) | — | in `FarmUtilityLoopModule.t.sol` (fund/defund, two-key gate, CTR-07 hook) |

Coverage % uninstrumentable (project-wide `Stack too deep`); **53 fork tests green**. The suite is fork-integration
against the real EVK/EVC/EulerEarn stack — the right kind of test for a factory whose correctness IS its interaction
with that stack. No code or coverage gap remains; the residuals are inherent (external-infra trust, the two-key
deploy invariant, the pre-prod immutable re-freeze).

## X-Ray Verdict

**HARDENED** *(modulo external-infra trust, the two-key deploy invariant, the pre-prod re-freeze, and no external
audit)* — the most complex contract in the sweep, a per-line isolated-market factory, with its hard surfaces all
fork-proven against the real EVK/EVC/router stack (with a faithful `EulerEarn` mock): the atomic cluster mint, per-line isolation + foreign-account
hook rejection, the F2 draw pin, the F3 submitCap bound, the SEC-11 donation-immune reallocate sizing, the router
freeze, and — densest of all — the SEC-06/CTR-04 dual queue-slot reclaim that keeps origination from bricking at the
30-market ceiling. The farm-utility two-key JIT path is covered cross-suite. The I-16 gap is **closed** — all 11
build-phase infra setters' `onlyOwner`/`ZeroAddress`/effect are now swept, and `seniorPool` is directly asserted
(I-17). No code or coverage gap remains. The residuals are inherent to the design: trust in the audited EVK/EVC/
EulerEarn stack, the two-key distinctness deploy invariant (no on-chain handle on the loop module), the deferred
pre-prod immutable re-freeze of build-phase wiring, and the absence of an external audit.

**Structural facts:**
1. 354 nSLOC; `Ownable` (Timelock) + `onlyController` + `onlyFarmUtilityAllocator`; implements `IZipcodeVenue`; a per-line isolated-market factory modeled on `EdgeFactory.deploy()`.
2. `openLine` atomically mints LineAccount + escrow vault + frozen per-line router + isolated USDC borrow vault, onboards to EulerEarn, custodies the 1e18 lien, and wire-checks — all in one call.
3. Security is wiring discipline: F2 (draw pinned to `erebor`), F3 (submitCap bounded to the minted vault), SEC-11 (tracked-balance reallocate sizing), router freeze, SEC-06/CTR-04 dual queue-slot reclaim on close.
4. CTR-09 per-draw fee (2nd borrow leg, financed by the line); CTR-13 curator governor-fee-share routing; farm-utility JIT fund/defund under a two-key gate distinct from the loop operator.
5. Tests: 53 Base-fork (cluster mint, isolation, queue reclaim, donation immunity, SEC-07/08, CTR-04/09/13, wire-mismatch harness, the full infra-setter sweep + `seniorPool`) + farm-utility cross-suite. No code or coverage gap remains; residuals are inherent (external-infra trust, two-key deploy invariant, pre-prod re-freeze, no audit).

---

## Siblings in `contracts/src/venue/`

- **`IZipcodeVenue.sol`** (24 nSLOC) — the venue-neutral seam (§4.7): only `bytes32`/`address`/`uint*`/opaque `lineRef` cross it (no Euler types), keeping the `ZipcodeController` venue-agnostic. Pure interface; conformance proven by `test_InterfaceImplemented`. No standalone surface.
- **`LineAccount.sol`** (8 nSLOC) — the ctor-only per-line EVC borrower-of-record, CREATE2-deployed by `openLine` (salt = `lienId`). In its constructor it registers its prefix and grants the adapter the EVC operator bit over its code-free sub-account-1 borrow account, then is inert (the §4.4 "graveyard"). No state, no admin, no teardown. Exercised via `test_LineAccount_Mechanics` + `test_TwoLine_DistinctPrefix_BothDraw_Isolation` (distinct prefixes, operator-grant borrow path) and the CREATE2 salt collision (`test_DoubleOpenLine_SameLienId_Reverts`).
