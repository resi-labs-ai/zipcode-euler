# X-Ray Report

> SzAlpha Bridge | 316 nSLOC | e6a4111 (`main`) | Foundry | 19/06/26

Analyzed branch: `main` at `e6a4111`. Scope: `contracts/src/bridge` (5 contracts).

> **CURRENT STATE (2026-06-20): this scope report is the OVERVIEW; the per-contract X-Rays are authoritative.**
> Every bridge contract now has its own dedicated, test-connected single-contract X-Ray. Each was reviewed
> one-at-a-time and connected to its tests; two had test gaps filled (fuzz + invariant added). All five are now
> **ADEQUATE**. Read the per-contract file for any specific contract; this report stays as the scope-level map.
>
> | Contract | nSLOC | Per-contract X-Ray | Tier |
> |---|---:|---|---|
> | SzAlpha | 201 | [`SzAlpha.md`](SzAlpha.md) | **ADEQUATE** — deep; +invariant suite, round-trip fuzz, X-1 lying-mock, edge guards |
> | SzAlphaRateOracle | 73 | [`SzAlphaRateOracle.md`](SzAlphaRateOracle.md) | **ADEQUATE** — gap-filled; +2 invariants, APR/roll fuzz |
> | SzAlphaLockReleasePool | 21 | [`SzAlphaLockReleasePool.md`](SzAlphaLockReleasePool.md) | ADEQUATE — thin audited-base subclass (2 deploy guards) |
> | SzAlphaTokenPool | 16 | [`SzAlphaTokenPool.md`](SzAlphaTokenPool.md) | ADEQUATE — thin audited-base subclass (2 deploy guards) |
> | SzAlphaMirror | 5 | [`SzAlphaMirror.md`](SzAlphaMirror.md) | ADEQUATE — config-only `BurnMintERC20` |
>
> Test state: `SzAlphaBridge.t.sol` **55/55 green** (incl. SzAlpha fuzz + invariant suite); `SzAlphaRateOracle.t.sol`
> **22/22 green** (incl. RateOracle fuzz + 2 invariants). The bundled `entry-points.md` / `invariants.md` in this
> folder predate the per-contract split — see the per-contract files for the test-connected invariant/entry-point
> detail. The only residual spanning the whole scope is the **deploy-topology seam (S2)** in
> [`docs/wires/SYSTEM-SEAM-MAP.md`](../../../../docs/wires/SYSTEM-SEAM-MAP.md) — which pool lands on which chain.

---

## 1. Protocol Overview

**What it does:** A pooled-staker liquid-staking wrapper over the Subtensor StakingV2 precompile (TAO in → validator alpha → szALPHA shares), bridged to Base via Chainlink CCT while keeping its exchange rate truthful across chains.

- **Users**: Stakers deposit native TAO on Subtensor 964 and mint szALPHA; redeemers burn szALPHA for TAO.
- **Core flow**: `deposit()` stakes via precompile and mints shares against the *measured* stake delta; `redeem()` burns, unstakes, and pays the *measured* TAO balance delta — both with caller slippage bounds.
- **Key mechanism**: ERC-4626-style share math in 18-dp space with an OZ virtual-offset (1/1); validator rewards accrue non-manipulably into `exchangeRate() = stake/supply` read live from the precompile.
- **Token model**: `SzAlpha` (964) = upgradeable 18-dp value-accruing LST receipt; `SzAlphaMirror` (Base) = plain `BurnMintERC20` transport token with no rate surface.
- **Admin model**: `owner()` is a TimelockController from genesis (gates UUPS upgrade + pause); `ccipAdmin` is a separate lower-privilege CCIP registrar (no mint/upgrade/fund power).

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| LST core (964) | SzAlpha | 201 | Pooled-staker wrapper; mint/redeem, exchange rate, upgrade/pause authority |
| Rate transport (Base) | SzAlphaRateOracle | 73 | CRE push-cache of the 964 rate; freshness gate + derived APR view |
| CCT pools | SzAlphaLockReleasePool, SzAlphaTokenPool | 37 | Thin CCIP pool subclasses adding deploy-time decimals/RMN invariants |
| Base mirror | SzAlphaMirror | 5 | Bridged 1:1 transport token (no native backing) |

*Only protocol-authored contracts. Inherited Chainlink CCIP pool logic and OZ upgradeable bases are out of scope.*

### How It Fits Together

The core trick: szALPHA is minted/redeemed against **measured precompile stake deltas** (never against `msg.value` or an estimate), so a variable AMM price between TAO and alpha never desyncs shares from backing — and because bridged-out supply is *locked* (not burned) on 964, `exchangeRate()` stays truthful on every chain.

### Deposit (964)

```
User.deposit{value: TAO}(minSharesOut, deadline)
  ├─ amountRao = msg.value / 1e9                      (sub-rao remainder refunded last, CEI)
  ├─ stakeBefore = _readStake()                       getStake staticcall
  ├─ _callStaking(addStake)                           STAKING_V2.call  ◄── interaction
  ├─ require(stakeAfter > stakeBefore)                S4: AddStakeEffectMissing
  ├─ shares = _previewDeposit(measured delta @ pre-rate)
  ├─ require(shares != 0 && shares >= minSharesOut)   ZeroSharesOut / SlippageExceeded
  └─ _mint(msg.sender, shares)                        *state change: totalSupply += shares*
```

### Redeem (964)

```
User.redeem(shares, minTaoOut, deadline)
  ├─ alphaOutRao = _previewRedeem(...) / 1e9          floor: dust stays staked
  ├─ _burn(msg.sender, shares)                        *effect first (CEI)*
  ├─ balBefore = address(this).balance
  ├─ _callStaking(removeStake)                        STAKING_V2.call  ◄── interaction
  ├─ require(stakeAfter < stakeBefore)                S4: RemoveStakeEffectMissing
  ├─ taoOut = balance delta; require(>= minTaoOut)    measured payout, not estimate
  └─ payable(msg.sender).call{value: taoOut}          *native transfer, last*
```

### Cross-chain rate transport

```
CRE workflow reads SzAlpha.exchangeRate() on 964 (RPC/precompile)
  └─ Forwarder → ReceiverTemplate.onReport → SzAlphaRateOracle._processReport
       ├─ require(reportType == RATE) / rate != 0 / ts <= now / ts > latest.ts
       ├─ roll trailing anchors if ts - curAnchor.ts >= window
       └─ latest = Sample(rate, ts)                   *Base NAV reads exchangeRate(), gates on fresh()*
```

### Bridge custody (CCT)

```
964 side:  SzAlphaLockReleasePool  ──locks──> szALPHA held in ERC20LockBox   (supply still counted)
Base side: SzAlphaTokenPool        ──burn/mint──> SzAlphaMirror              (1:1 transport)
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Liquid Staking** with **Bridge** and **Oracle-transport** characteristics

Signals: a derivative token minted against staked backing with a share-based `exchangeRate()` (Liquid Staking); a CCIP CCT lock/release + burn/mint pool pair with cross-chain supply conservation (Bridge); a forwarder-gated push-cache of a single primitive rate consumed by NAV (Oracle transport).

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Staker / Redeemer | Untrusted | `deposit()` (value in, mint), `redeem()` (burn, value out); both permissionless, slippage- and deadline-bounded. `redeem` is NOT pausable by design. |
| `owner()` (TimelockController) | Trusted (timelock-delayed) | UUPS `_authorizeUpgrade` (full implementation swap) + `pause`/`unpause` of `deposit`. Upgrade is the maximal-blast-radius power; subject to timelock delay, not instant. |
| `ccipAdmin` | Bounded (registrar only) | `setCCIPAdmin` (rotate registrar). No mint, no upgrade, no fund access. Not subject to `whenNotPaused`. |
| CRE Forwarder | Bounded (push only) | Sole writer of `SzAlphaRateOracle._processReport`; bounded to non-zero, not-future, strictly-newer rate values. No deviation band. |
| Subtensor precompiles | Trusted (runtime) | `getStake`/`addStake`/`removeStake`/`simSwap*` — the sole source of backing and payout magnitudes. |
| CCIP Router / RMN | Trusted (Chainlink) | Drive inherited `lockOrBurn`/`releaseOrMint` on the pools; RMN pinned to canonical at deploy. |

**Adversary Ranking** (ordered for this protocol type, adjusted by git evidence):

1. **Exchange-rate / precompile-trust manipulator** — anyone who can influence the measured stake/balance deltas or the live `getStake` read that backs every mint, redeem, and the rate.
2. **Bridge validator/relayer-set attacker** — controls CCIP message approval to release or mint unbacked szALPHA across the lane.
3. **Cross-chain conservation breaker** — exploits a decimals or burn-vs-lock topology misconfiguration that desyncs locked-964 supply from minted-Base supply.
4. **Compromised admin** — a timelock/upgrade compromise that swaps the implementation or pauses deposits.
5. **Stale-rate / CRE push adversary** — a frozen or misreported rate feeding Base NAV.
6. **Donation / first-depositor** — share-price skew at genesis (heavily mitigated; see Protocol-Type Concerns).

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **UUPS upgrade (owner)** — `_authorizeUpgrade:331` is the maximal boundary: a new implementation can redefine all mint/redeem/rate logic. Protected only by the timelock delay on `owner()`; no separate upgrade guardian.
- **Precompile boundary** — `SzAlpha._readStake:351` / `_callStaking:393` trust the Subtensor runtime for both *direction* (guarded) and *magnitude* (unguarded) of every stake change. The single most load-bearing external dependency.
- **CRE push boundary** — `SzAlphaRateOracle._processReport:80` trusts the forwarder's reported rate verbatim (no deviation band, by design); the only on-chain defense is monotonic-ts + the consumer's `fresh()` gate.
- **CCT custody boundary** — `SzAlphaLockReleasePool` is an authorized caller of the external `ERC20LockBox`; lane mint/release authority lives in the inherited Chainlink base, out of scope. *Git signal: both pools touched in the 2 source-bearing commits (`c510759`, `5f3706d`).*

### Key Attack Surfaces

- **Precompile measured-delta trust** &nbsp;[[X-1](invariants.md#x-1)] — `SzAlpha.deposit:188-199` and `redeem:238-244` guard only the *sign* of the stake/balance change (`AddStakeEffectMissing`/`RemoveStakeEffectMissing`); the *magnitude* minted/paid comes straight from `getStake`/balance reads. Worth tracing what a hostile or buggy precompile return does to share issuance.

- **Live-rate read with no DEX guard** &nbsp;[[I-1](invariants.md#i-1)] — `exchangeRate:264-265` divides live `_stake18()` by `totalSupply()`; rewards lift it non-manipulably, but worth confirming the `getStake` path cannot be perturbed within a deposit/redeem transaction (it is staticcall-read before and after the staking call).

- **Cross-chain supply conservation** &nbsp;[[E-1](invariants.md#e-1)] — truthfulness of `exchangeRate()` on Base depends on 964 supply being *locked, not burned*; worth confirming the deployed 964 pool is the lock/release variant and both sides enforce `localTokenDecimals == 18` (`SzAlphaLockReleasePool:36`, `SzAlphaTokenPool:27`).

- **Rate oracle has no deviation band** &nbsp;[[I-3](invariants.md#i-3)] — `_processReport:84-86` accepts any non-zero, not-future, strictly-newer value; a single misreported push becomes the headline rate until the next push. Worth confirming NAV consumers always gate on `fresh()` (`exchangeRate()` returns 0 / stale silently otherwise).

- **UUPS upgrade blast radius** — `_authorizeUpgrade:331` is an empty `onlyOwner` body; the entire mint/redeem/rate surface is mutable by the timelock. Worth confirming the timelock delay and proposer/executor set match the intended governance.

- **Redeem is intentionally non-pausable** — `redeem:219` omits `whenNotPaused` (S3/S11 NAV-redeemability); worth confirming this is acceptable under an incident where `deposit` is paused but the precompile path is compromised.

### Upgrade Architecture Concerns

- **Single upgradeable contract** — `SzAlpha` is UUPS (`__gap[46]`, 4 used slots at `:90`); a storage-layout error on upgrade corrupts `netuid`/`validatorHotkey`/`wrapperColdkey`/`ccipAdmin`. Worth verifying the gap accounting and that `_disableInitializers()` (`:121`) protects the implementation.
- **Pools and mirror are immutable** — `SzAlphaLockReleasePool`, `SzAlphaTokenPool`, `SzAlphaMirror` are non-upgradeable; an RMN rotation is handled by redeploy (S9), not mutation.

### Protocol-Type Concerns

**As a Liquid Staking wrapper:**
- Share rounding is floor in both directions (`_previewDeposit:342`, `_previewRedeem:347`) — redeem dust stays staked and accrues to remaining holders; worth confirming no path rounds in the redeemer's favor.
- First-depositor inflation is mitigated three ways (virtual-offset 1/1, `ZeroSharesOut` revert, genesis seed deposit) per the `:36-46` donation note; worth confirming the seed deposit actually executes in the deploy script.

**As a Bridge:**
- Cross-chain conservation rests on equal decimals + the lock-vs-burn topology split; both pool constructors hard-revert on `!= 18` and non-canonical RMN, but lane rate-limits are configured post-deploy (`applyChainUpdates`) — worth confirming they are set under the timelock before lanes open.

### Temporal Risk Profile

**Deployment & Initialization:**
- `initialize:130` is `initializer`-guarded and `_disableInitializers()` runs in the constructor; the live risk is the genesis seed deposit and the timelock/ccipAdmin handoff happening atomically in the deploy script (not on-chain enforced here).
- `wrapperColdkey` is derived once at init (`:153`) from the AddressMapping precompile — worth confirming the mapping is populated for the wrapper before init.

**Market Stress:**
- A validator slash legitimately lowers `exchangeRate()`; the oracle deliberately has no floor/band, so Base NAV must absorb a genuine downward move via `fresh()` rather than a stuck price.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Subtensor StakingV2 / Alpha precompiles** — via `SzAlpha._callStaking` / `_readStake` / `_simSwap*`
> - Assumes: `addStake`/`removeStake` move backing in the expected direction; `getStake` returns the true aggregate alpha; swap sims are advisory only.
> - Validates: direction guards (`AddStake/RemoveStakeEffectMissing`), `ret.length >= 32`, uint64 bound on swap inputs. Magnitude is NOT bounded.
> - Mutability: runtime precompiles (chain-governed); behavior can change with a Subtensor runtime upgrade.
> - On failure: reverts (`PrecompileCallFailed`) — fail-closed.

> **Chainlink CCIP (Router / RMN / pools)** — via `SzAlphaLockReleasePool` / `SzAlphaTokenPool`
> - Assumes: inherited `lockOrBurn`/`releaseOrMint` correctness; RMN is canonical.
> - Validates: `localTokenDecimals == 18`, `rmnProxy == canonicalRmn` at construction; `advancedPoolHooks == address(0)`.
> - Mutability: rate-limiter mutable post-deploy via `applyChainUpdates` (timelock).
> - On failure: inherited revert paths (out of scope).

> **CRE Forwarder** — via `SzAlphaRateOracle._processReport`
> - Assumes: the forwarder delivers an honest 964 rate; DON f+1 consensus catches a misread.
> - Validates: reportType, non-zero, not-future, strictly-newer ts. No deviation band by design.
> - Mutability: forwarder address set at construction (`ReceiverTemplate`, immutable).
> - On failure: reverts on bad envelope; stale feed handled by `fresh()` returning false.

**Token Assumptions** *(unvalidated only)*:
- Native TAO transfer: `deposit` refund and `redeem` payout use low-level `call` with explicit `NativeTransferFailed` checks — handled.

**Shared State Exposure:**
- `SzAlpha.exchangeRate()` is consumed off-chain by CRE and on-chain (via the Base oracle) by `SzipNavOracle`; a wrong rate has NAV blast radius beyond this subsystem.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **18 Enforced Guards** (`G-1` … `G-18`) — per-call preconditions with predicate / location / purpose
> - **4 Single-Contract Invariants** (`I-1` … `I-4`) — Ratio, Temporal, StateMachine, Bound
> - **1 Cross-Contract Invariant** (`X-1`) — precompile-magnitude trust
> - **1 Economic Invariant** (`E-1`) — cross-chain rate truthfulness
>
> The **On-chain=No** blocks are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Missing (in scope dir) | Design lives in NatSpec headers + `claude-zipcode.md` §8.6/§8.8 (out of dir) |
| NatSpec | ~73 annotations | Dense, design-grade headers on every contract; unit/topology rationale inline |
| Spec/Whitepaper | Missing (in scope dir) | References external `reference/rubicon/` precedent |
| Inline Comments | Thorough | Unit tables, CEI ordering, donation analysis, and design-decision notes throughout |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files (bridge) | 2 (+1 mocks) | File scan (always reliable) |
| Test functions (bridge) | 77 | `SzAlphaBridge.t.sol` 53 (+9 gap) · `SzAlphaRateOracle.t.sol` 22 (+3 gap) |
| Suite status | **55/55 + 22/22 green** | `forge test` |
| Line coverage | Unavailable — project-wide `Stack too deep` (fails even with `--ir-minimum`) | Coverage tool |
| Branch coverage | Unavailable — same reason | Coverage tool |

### Test Depth (post gap-fill, 2026-06-20)

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | ~71 | all 5 contracts (incl. pools/mirror guard asserts) |
| Fork | 2 | Base-fork deploy/registration |
| Stateless Fuzz | **2** | SzAlpha round-trip rounding; RateOracle APR/anchor-roll |
| Stateful Fuzz (Foundry invariant) | **4** | SzAlpha (supply conservation, rate≥genesis); RateOracle (ts-monotonic, APR-bounded) |
| Formal Verification | 0 | none |

### Gaps (remaining)

- **No formal verification** — the conservation/rate properties (`I-1`, `E-1`) are good Certora/Halmos candidates; the Foundry invariant suites now assert them under fuzzing, so this is a hardening step, not a hole.
- **Coverage unmeasurable** — the project does not compile under the coverage instrumenter (stack-too-deep); test *existence* (incl. fuzz/invariant) is confirmed by scan + run, but line/branch reach is unknown. Worth a coverage-only build profile.
- *(Resolved 2026-06-20: the prior "no fuzz/invariant" gap — SzAlpha and SzAlphaRateOracle each gained a stateless fuzz + Foundry invariant suite. See their per-contract X-Rays.)*

---

## 6. Developer & Git History

> Repo shape: normal_dev — 100 commits over 29 days, but only **2** touch bridge source (`c510759`, `5f3706d`); the rest are docs/tickets/tests elsewhere.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| rootdraws | 100 | +774 / -130 | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-dev |
| Merge commits | 0 of 100 | No merge commits — no peer-review trail in git |
| Repo age | 2026-05-21 → 2026-06-19 | 29 days |
| Recent source activity (30d) | 2 commits | Both bridge-source commits are within the window (late burst) |
| Test co-change rate | 100% | Both source commits also changed tests (co-modification, not coverage) |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| SzAlpha.sol | 2 | Touched in both source commits; highest-value review target |
| SzAlphaRateOracle.sol | 2 | Both source commits |
| SzAlphaTokenPool.sol | 2 | Both source commits |
| SzAlphaMirror.sol | 2 | Both source commits |
| SzAlphaLockReleasePool.sol | 1 | Added in `c510759` |

### Security-Relevant Commits

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| c510759 | 2026-06-12 | 8x-01 bridge rework: rao units + measured-delta + slippage; lock/release CCIP topology | 15 | spans access_control, fund_flows, liquidation, oracle_price, state_machines |
| 5f3706d | 2026-06-10 | Item-10 deploy orchestrator + protocol wiring map | 13 | tightens access control (+170/-7); large change |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| oracle_price | 2 | SzAlpha.sol, SzAlphaRateOracle.sol |
| state_machines | 2 | SzAlpha.sol, SzAlphaRateOracle.sol |
| access_control | 2 | SzAlpha.sol |
| fund_flows | 2 | SzAlpha.sol |
| liquidation | 2 | SzAlpha.sol |

### Security Observations

- **Single-developer, zero merge commits** — 100% of source by rootdraws; no peer-review signal in git history.
- **All bridge source landed in 2 high-score commits** — `c510759` (15) and `5f3706d` (13); both warrant a manual diff.
- **`SzAlpha.sol` is the universal hotspot** — touched by every source-bearing commit and spans all 5 dangerous areas.
- **No TODO/FIXME/HACK markers** — `tech_debt.total_count == 0` across the scope.
- **No forked dependencies internalized** — all deps are submodules/packages (Chainlink CCIP, OZ).
- **Both source commits co-changed tests** — co-modification rate 100% (note: measures file co-change, not coverage).

### Cross-Reference Synthesis

- **`SzAlpha.sol` is #1 in churn AND attack-surface priority** → highest-leverage review: `deposit`/`redeem` measured-delta paths and `_authorizeUpgrade`.
- **oracle_price + state_machines both flagged on SzAlphaRateOracle** → focus on `_processReport` anchor-roll and `intrinsicAprBps` annualization precision.
- **Late burst (both source commits in-window) + single dev** → no soak time on the current bridge design before this snapshot.

---

## X-Ray Verdict

**ADEQUATE (scope-wide)** *(was FRAGILE; raised 2026-06-20 after the per-contract pass + gap-fills)* — all five
contracts now carry dedicated test-connected X-Rays at ADEQUATE: roles + trust boundaries clear, timelock + pause,
and the two real-logic contracts (SzAlpha, SzAlphaRateOracle) now have fuzz + Foundry invariant coverage of their
load-bearing properties (share conservation, rate-floor, ts-monotonicity, anchor-roll/APR). Held below HARDENED
scope-wide by: no formal verification, single-developer history with no peer-review trail, and the inherent X-1
precompile-magnitude trust (runtime, characterized not eliminated). Per-contract verdicts are authoritative — see
the index at the top.

**Structural facts:**
1. 316 nSLOC across 5 contracts; 1 UUPS-upgradeable (SzAlpha), 2 thin audited-base pool subclasses, 1 config-only mirror, 1 push oracle.
2. 3 permissionless entry points (`deposit`, `redeem`, `receive`); upgrade + pause gated by a TimelockController `owner()`.
3. Tests: 2 stateless fuzz + 4 Foundry invariants + ~71 unit; suites **55/55 + 22/22 green** (was 63 unit / 0 fuzz / 0 invariant pre-gap-fill).
4. 100% of source authored by a single developer; 0 merge commits.
5. Coverage uninstrumentable — project-wide stack-too-deep even under `--ir-minimum`; test existence confirmed by scan + run.
6. Scope-wide residual = deploy-topology seam S2 (lock/release on 964, burn/mint on Base) — in the deploy script, not the contracts.
