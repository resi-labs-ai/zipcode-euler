# X-Ray Report

> Hydrex Demo (vAMM) | 423 nSLOC | b240994 (`main`) | Foundry | 19/06/26

Analyzed branch: `main` at `b240994`. Scope: `contracts/src/hydrex-demo-fork` (2 contracts).

> ⚠️ **Both contracts self-declare as DEMO/SHOWCASE forks "outside the audited core"** (`SzipNavOracleDemoVAMM:17`, `LpStrategyModuleDemoVAMM:12`). They exist to display the auto-compounder on mainnet against a live Solidly vAMM HYDX/USDC pair *before* the real zipUSD/xALPHA ICHI pool exists. They are forks of audited prod contracts (`SzipNavOracle`, `LpStrategyModule`) with one seam swapped each (ICHI → vAMM). Treat findings as scoped to the demo fork, not the prod core.

---

## 1. Protocol Overview

**What it does:** A NAV-per-share oracle for the szipUSD junior vault plus a Zodiac module that builds and gauge-stakes a Solidly vAMM LP — the demo prices/operates an existing live HYDX/USDC pair instead of the not-yet-deployed ICHI pool.

- **Users**: A CRE operator (hot key) drives the LP lifecycle; the Forwarder and DefaultCoordinator write oracle inputs; consumers (Exit Gate) read bracketed NAV.
- **Core flow**: `addLiquidity()` builds the vAMM LP into the engine Safe → `stake()` gauge-stakes it to farm oHYDX; the oracle composes basket NAV and exposes `navEntry`/`navExit`.
- **Key mechanism**: NAV = (gross basket value − impairment provision) / effective supply, with an on-chain TWAP accumulator; consumers read `navEntry = max(spot, twap)` (issuance) and `navExit = min(spot, twap)` (exit).
- **Token model**: Values szipUSD (18-dp $1 denominator), USDC, xALPHA, HYDX, oHYDX, and the vAMM LP; the LP token is the pair contract itself.
- **Admin model**: `owner()` is the Timelock (all wiring setters, re-pointable not set-once); the LP module is operated by a separate CRE `operator` hot key.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| NAV oracle | SzipNavOracleDemoVAMM | 294 | Composes junior-basket NAV/share; CRE leg push, TWAP, provision, bracket reads; vAMM LP valuation |
| LP strategy | LpStrategyModuleDemoVAMM | 129 | Zodiac module on the engine Safe; builds vAMM LP + gauge-stakes; operator-gated |

*Both are protocol-authored. Inherited zodiac-core `Module`, OZ, and `ReceiverTemplate` bases are out of scope.*

### How It Fits Together

The core trick: the module never holds funds or builds free-form calldata — it makes the engine **Safe** execute fixed-shape calls to set-once wired targets — and the oracle reads every basket quantity **trustlessly on-chain** (Safe balances, pair reserves, gauge balances), CRE-pushing only the off-chain leg prices it cannot read on Base.

### LP build + stake (operator)

```
Operator.addLiquidity(deposit0, deposit1, minShares)        onlyOperator
  ├─ require(deposit0|deposit1 != 0) / require(minShares != 0)
  ├─ _exec(token0.transfer(pair, deposit0))                 via Safe execAndReturnData (Operation.Call, value 0)
  ├─ _exec(token1.transfer(pair, deposit1))                 *excess of one side is donated to the pool*
  ├─ ret = _exec(pair.mint(juniorTrancheEngine))            LP minted to the Safe
  └─ require(shares >= minShares) else Slippage             *only sandwich/ratio guard*

Operator.stake(lpAmount) → approve(gauge) / gauge.deposit / approve(0)   onlyOperator
Operator.unstake(lpAmount) → gauge.withdraw(lpAmount)                    onlyOperator
```

### NAV composition (consumer reads)

```
navEntry()                                                  issuance price
  ├─ require(!legStale(ALPHA_USD)) / require(!legStale(HYDX_USD))
  ├─ if xAlphaRateOracle set: require(rateOracle.fresh()) else StaleRate
  └─ max(spotNavPerShare(), twapNavPerShare())
        spotNavPerShare = (grossBasketValue() - provision) * 1e18 / effectiveSupply
          grossBasketValue: Σ _bal(token) marks + LP leg via IVammPair.getReserves() pro-rata
        twapNavPerShare: windowed (W) cumulative Σ spot*dt over the observation ring

navExit() = min(spot, twap)                                 *NEVER reverts on staleness (prices off last mark)*
```

### Oracle write paths

```
Forwarder → ReceiverTemplate.onReport → _processReport (reportType 7)
  ├─ _accumulate()  (book OLD spot before new prices apply)
  └─ per leg: require(p != 0), deviation <= maxDeviationBps, legCache[leg] = (p, ts)

DefaultCoordinator → writeProvision(newProvision)          *UNBOUNDED at the oracle; bound lives in the coordinator*
Anyone → poke()                                            permissionless TWAP advance
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Yield Aggregator / Vault (NAV oracle)** with **DEX/AMM** and **Oracle-transport** characteristics

Signals: a share-price oracle for a junior vault with provision/TWAP (Vault); valuation of a Solidly vAMM pair via live `getReserves` + an LP-mint module (DEX/AMM); CRE leg-price push with deviation/staleness guards (Oracle).

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| CRE `operator` | Bounded (hot key) | `addLiquidity`/`stake`/`unstake` — supplies only scalar amounts; module builds all calldata to wired targets; no custody, no passthrough. Bounded by `minShares` floor. |
| Forwarder | Bounded (push only) | Sole writer of `_processReport` (reportType 7); per-leg non-zero + deviation-band + not-future guards. |
| DefaultCoordinator | Bounded (provision) | Sole `writeProvision` caller. The provision value is **unbounded at the oracle** — the bound lives off-chain in the coordinator (M2). Until wired, reverts for everyone. |
| `owner()` (Timelock) | Trusted (timelock) | Re-points ALL wiring on both contracts (`shareToken`, `ichiVault`/pair, `gauge`, `defaultCoordinator`, `xAlphaRateOracle`, module targets). Re-pointable, not set-once. No pause on either contract. |
| Keeper / anyone | Untrusted | `poke()` — advances the TWAP accumulator only. |
| Exit Gate (consumer) | Trusted (reads) | Reads `navEntry`/`navExit`/`fresh`/`valueOf`; is the first minter and the first-depositor guard (oracle delegates this). |

**Adversary Ranking** (ordered for this protocol type, adjusted by git evidence):

1. **Oracle / LP-price manipulator** — moves vAMM spot reserves or donates into a valued Safe to skew the basket NAV that gates issuance/exit.
2. **First-depositor / donation attacker** — exploits zero-supply genesis or direct-transfer into a counted Safe; the oracle explicitly delegates this guard to the Gate.
3. **Compromised admin (Timelock)** — re-points NAV inputs (`shareToken`, pair, `defaultCoordinator`) or module targets.
4. **Compromised operator (hot key)** — grief/loss on the LP build ratio (bounded by `minShares`, no custody).
5. **Stale cross-chain rate** — a stale wired `xAlphaRateOracle` feeding the xALPHA leg (gated at issuance only).

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **NAV reads raw `balanceOf` of the Safes** — `_bal:413`, `grossBasketValue:284-304`, `_grossValueOf:324-344` price whatever sits in `juniorTrancheSafe`/`juniorTrancheSidecar`; a direct transfer into a counted Safe moves NAV with no deposit. The Gate's accounting is the only thing tying balances to issued shares.
- **vAMM spot reserves** — `grossBasketValue:297` values the LP off `IVammPair.getReserves()` (instantaneous), manipulable in-block; the only defense is the `min/max(spot, twap)` bracket flowing the LP leg through `spotNavPerShare → cumNav`.
- **Provision write** — `writeProvision:256-261` trusts the `defaultCoordinator` for the *value*; the oracle enforces only the caller. A compromised/mis-wired coordinator can set provision arbitrarily (fail-closed until wired).
- **Re-pointable wiring (Timelock)** — every NAV input and module target is a one-call re-point (`setLpPosition:197`, `setShareToken:190`, `setDefaultCoordinator:212`, module `setIchiVault:134` …); no set-once lock in this build phase. *Git signal: both files landed/changed in the single source commit `81df630` (score 17).*

### Key Attack Surfaces

- **NAV prices raw Safe balances** &nbsp;[[I-1](invariants.md#i-1)] — `grossBasketValue:284-304` / `_bal:413` sum `balanceOf` of the two Safes for five legs plus a pro-rata LP slice; worth tracing whether a direct token transfer (not via the Gate) into a counted Safe shifts `navEntry`/`navExit` and how the Gate's denominator absorbs it.

- **vAMM spot LP valuation** &nbsp;[[I-2](invariants.md#i-2)] — `grossBasketValue:297` and `_grossValueOf:336` read `getReserves()` at spot; worth confirming the LP leg actually propagates into the TWAP (`spotNavPerShare → _accumulate → cumNav`) so `navEntry=max`/`navExit=min` truly brackets an in-block reserve push, not just the five plain legs.

- **Unbounded provision at the oracle** &nbsp;[[X-1](invariants.md#x-1)] — `writeProvision:256` accepts any `newProvision` from the coordinator and feeds it straight into `spotNavPerShare:351`; worth confirming the coordinator's down/up bound (atRisk·(1−floor) / realized receipts) is the real enforcement and that the oracle is never wired before it exists.

- **committedValue + freeValue vs grossBasketValue drift** &nbsp;[[I-4](invariants.md#i-4)] — `committedValue:312` / `freeValue:317` re-derive per-Safe and are documented to match gross "within ≤2 wei" on a split LP (double pro-rata floor); worth confirming a freeze module reading these tolerates the drift direction.

- **addLiquidity excess-donation** — `addLiquidity:208-216` `transfer`s both legs straight to the pair then `mint`s; any side sized above the live reserve ratio is donated to the pool (Solidly keeps the lesser side). `minShares` is the sole protection; worth confirming the operator sizes against fresh `getReserves()`.

- **Module exec boundary** — `_exec:178-187` uses `execAndReturnData` (Operation.Call, value 0) and bubbles inner revert data; no delegatecall, no generic passthrough. Worth confirming `setAvatar`/`setTarget` (inherited zodiac `onlyOwner`, intentionally not hard-locked, `:167-170`) cannot be reached by the operator.

### Upgrade Architecture Concerns

- **No proxy upgradeability** — the oracle is a plain constructor-config contract; the module is a `ModuleProxyFactory` *clone* (mastercopy + `setUp` initializer, `:80`), so per-clone config is set-once storage, not `immutable`. Worth confirming the mastercopy is init-locked at deploy (claimed `:38`) and `setUp` cannot be re-called.

### Protocol-Type Concerns

**As a Vault NAV oracle:**
- `_effectiveSupply:461` subtracts the engine Safe's transient pre-burn balance; worth confirming the engine Safe wiring is set before issuance so the denominator is correct.
- Genesis: `spotNavPerShare:349` returns `GENESIS_NAV` at zero effective supply and the oracle adds no first-depositor guard by design (`:50-52`) — the Gate must be the first minter.

**As a DEX/AMM integration:**
- 6→18-dp scaling for USDC is folded into the price (`_legPriceOfToken:441` returns `1e30`); worth confirming every LP reserve-token path uses native-dp `amt` exactly once (no double scale) — `_tokenValue:447`.
- `_legPriceOfToken:442` reverts `UnknownLpToken` for any reserve token outside {zipUSD, xAlpha, hydx, usdc} — fail-closed, but means a pair with a different token bricks the LP leg.

### Temporal Risk Profile

**Deployment & Initialization:**
- Wiring is re-pointable by the Timelock during the build phase (`:187-188`); the live risk is operating before `shareToken`/`defaultCoordinator`/`xAlphaRateOracle` are wired — each has a fail-closed path (zero supply ⇒ GENESIS_NAV; zero coordinator ⇒ `writeProvision` reverts; zero rate oracle ⇒ M1 stand-in read).
- The module clone `setUp:80` validates five addresses then reads `token0`/`token1` live off the pair — worth confirming the mastercopy is init-locked so it can't be hijacked.

**Market Stress:**
- `navExit` deliberately never reverts on staleness (prices off the last good mark); staleness pauses issuance only. The TWAP lag is the defense — keepers must `poke()` before reads.

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Solidly vAMM Pair / Gauge** — via `SzipNavOracleDemoVAMM` (read) + `LpStrategyModuleDemoVAMM` (mint/stake)
> - Assumes: `getReserves()` reflects fair reserves; `totalSupply()`/`balanceOf` honest; `mint(to)` credits LP to the Safe.
> - Validates: `supplyLp != 0` and `ichiVault != 0` guards; `minShares` floor on mint. Spot reserves NOT bounded (TWAP bracket is the mitigation).
> - Mutability: external live pair; reserves move every swap.
> - On failure: math guards skip the LP leg (contributes 0); mint revert bubbles via `_exec`.

> **xAlphaRateOracle (SzAlphaRateOracle)** — via `_xAlphaUSD` / `navEntry` / `fresh`
> - Assumes: `exchangeRate()` is the cross-chain rate; `fresh()` gates issuance.
> - Validates: issuance reverts `StaleRate` if wired and not fresh; value (not freshness) read for gross/exit (the §7 asymmetry).
> - Mutability: Timelock-re-pointable (`setXAlphaRateOracle`, zero ⇒ M1 stand-in `IXAlphaRate(xAlpha)`).
> - On failure: stale ⇒ issuance halts; exit prices off last rate.

> **CRE Forwarder** — via `_processReport`
> - Assumes: honest leg marks (alphaUSD, HYDX/USD).
> - Validates: reportType 7, non-zero, deviation band (`maxDeviationBps`), not-future, length match.
> - Mutability: forwarder set in `ReceiverTemplate` (Timelock-re-pointable per `:153`).
> - On failure: reverts the whole batch (all-or-nothing).

**Token Assumptions** *(unvalidated only)*:
- LP reserve / leg tokens are assumed standard ERC20 (`balanceOf`/`transfer`); a fee-on-transfer or rebasing reserve token would desync the pro-rata LP mark. The whitelist (`_legPriceOfToken`) bounds *which* tokens, not their behavior.

**Shared State Exposure:**
- The valued vAMM pair is a public mainnet pool; large third-party swaps move the spot LP mark this oracle reads (bracketed by TWAP).

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **17 Enforced Guards** (`G-1` … `G-17`) — per-call preconditions with predicate / location / purpose
> - **4 Single-Contract Invariants** (`I-1` … `I-4`) — Ratio, Bound, Temporal, Conservation
> - **1 Cross-Contract Invariant** (`X-1`) — unbounded provision trust
> - **1 Economic Invariant** (`E-1`) — bracket non-profitability
>
> The **On-chain=No** blocks are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Missing (in scope dir) | Design lives in NatSpec + `build/wires/SHOWCASE-VAMM.md`, `claude-zipcode.md` §7/§12 |
| NatSpec | ~83 annotations | Dense, design-grade; demo-vs-prod deltas explicitly called out at the top of each file |
| Spec/Whitepaper | Missing (in scope dir) | References `baal-spec.md` §3 (out of dir) |
| Inline Comments | Thorough | Documented invariants, asymmetry rationale, security-boundary notes, demo-fork deltas |

---

## 5. Test Analysis

> **CURRENT STATE (2026-06-20): gap-filled — both forks now have dedicated test-connected X-Rays at ADEQUATE.**
> The prod parents' suites were ported with the swapped seam mocked (ICHI → vAMM pair). See
> [`LpStrategyModuleDemoVAMM.md`](LpStrategyModuleDemoVAMM.md) and [`SzipNavOracleDemoVAMM.md`](SzipNavOracleDemoVAMM.md).

| Metric | Value | Source |
|--------|-------|--------|
| Test files (this scope) | 2 dedicated | `test/hydrex-demo-fork/LpStrategyModuleDemoVAMM.t.sol` + `SzipNavOracleDemoVAMM.t.sol` |
| Test functions (this scope) | 45 (44 unit + **2 fuzz**) | LP module 21 (20u+1f); NAV oracle 24 (23u+1f) |
| Suite status | **21/21 + 24/24 green** | `forge test` |
| Line coverage | Unavailable — project-wide `Stack too deep` (fails even with `--ir-minimum`) | Coverage tool |

### Test Depth (post gap-fill)

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 43 | both forks (ported from the prod `SzipNavOracle`/`LpStrategyModule` suites, vAMM seam swapped in) |
| Stateless Fuzz | 2 | LP share-math; spot-NAV formula |
| Stateful Fuzz (Foundry) | 0 | none (the demo forks are stateless-priced; invariant suites would add little) |
| Formal Verification | 0 | none |

### Gaps

- **No tests at all for this scope** — the demo forks have zero dedicated unit/fuzz/invariant coverage. Their prod parents are tested, but the swapped vAMM seams (LP mint via `IVammPair.mint`, LP valuation via `getReserves`, the `_legPriceOfToken` HYDX/USDC additions) are exactly the un-forked behavior and are untested.
- **Highest-value additions** — unit tests for the vAMM LP valuation path and the `addLiquidity` donation/ratio behavior; fuzz on `spotNavPerShare`/`twapNavPerShare` and the `_legPriceOfToken` dp-scaling.
- **Coverage unmeasurable** — project does not compile under the coverage instrumenter (stack-too-deep).

---

## 6. Developer & Git History

> Repo shape: squashed_import (for this scope) — only **1** commit touches these source files (`81df630`); there is no incremental evolution history to mine. Fix/hotspot analysis is limited.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| rootdraws | 102 | +764 / -46 | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-dev |
| Merge commits | 0 of 102 | No merge commits — no peer-review trail in git |
| Repo age | 2026-05-21 → 2026-06-19 | 29 days |
| Recent source activity (30d) | 1 commit | These forks landed in the latest window |
| Test co-change rate | 100% | The source commit also changed tests — but none target these forks (prod-suite changes) |

### Security-Relevant Commits

> Repo shape is squashed_import for this scope (1 source-touching commit) — fix detection is not meaningfully applicable. For context, the one commit that introduced the current files:

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 81df630 | 2026-06-19 | contracts: standardize Safe identities + CTR-11/CTR-13 + line APR | 17 | loosens access control (+61/-76), removes runtime guards (+1/-7), spans 4 security domains |

*Score 17 reflects a broad standardization diff across many files, not a targeted fix to these two contracts — interpret with the squashed-import caveat.*

### Security Observations

- **Zero tests for this scope** — the demo forks are deployed (via `DeployShowcaseVAMM.s.sol`) but not unit/fuzz tested.
- **Single-developer, zero merge commits** — 100% of source by rootdraws; no peer-review signal in git.
- **Self-declared out-of-audit-scope** — both files open with a DEMO/SHOWCASE disclaimer; the forked seams are the untested delta.
- **No TODO/FIXME/HACK markers** — `tech_debt.total_count == 0` across the scope.
- **No forked-in libraries** — deps are packages (zodiac-core, OZ, ReceiverTemplate, hydrex interfaces).

### Cross-Reference Synthesis

- **Untested vAMM seam = the entire risk delta** → the swapped LP-mint and LP-valuation paths (`addLiquidity`, `grossBasketValue` LP block, `_legPriceOfToken`) carry the prod parents' assurance for everything *except* the parts that changed.
- **NAV reads raw Safe balances + spot reserves, no test** → the donation and in-block-reserve surfaces (I-1/I-2) have neither tests nor on-chain bounds in this scope; the Gate + TWAP are the sole defenses.

---

## X-Ray Verdict

**ADEQUATE (scope-wide)** *(was EXPOSED; raised 2026-06-20 after porting the prod parents' suites)* — both demo
forks now carry dedicated test-connected X-Rays at ADEQUATE. The prior EXPOSED was purely the absence of dedicated
tests; the swapped vAMM seams (LP `mint`, LP `getReserves()` valuation) are now covered by suites ported from the
audited prod parents with the ICHI mock replaced by a vAMM-pair mock — 45 functions incl. 2 fuzz, **21/21 + 24/24
green**. Still demo/showcase forks outside the audited core; the residuals (raw-balance donation seam, in-block
spot-LP defended by the TWAP bracket, off-chain-bounded provision) are inherited from the prod NAV design, not
introduced by the forks, and the no-custody / operator-grief-only blast radius bounds the worst case. Per-contract
files are authoritative: [`LpStrategyModuleDemoVAMM.md`](LpStrategyModuleDemoVAMM.md),
[`SzipNavOracleDemoVAMM.md`](SzipNavOracleDemoVAMM.md).

**Structural facts:**
1. 423 nSLOC across 2 contracts (NAV oracle 294, LP module 129); 0 upgradeable (1 plain, 1 clone-via-`setUp`).
2. 1 permissionless entry point (`poke`); LP ops operator-gated, all wiring Timelock-gated, no pause on either contract.
3. Tests: 45 dedicated functions (43 unit + 2 fuzz), **21/21 + 24/24 green** — ported from the prod parents with the vAMM seam swapped in (was 0 dedicated).
4. 100% of source authored by a single developer; the files landed in 1 source-touching commit; 0 merge commits.
5. Coverage uninstrumentable — project-wide stack-too-deep even under `--ir-minimum`; test existence confirmed by scan + run.
