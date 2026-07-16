# X-Ray Report

> supply/lib (Fair Reserves) | 43 nSLOC | 95ed3dd (`main`) | Foundry | 20/06/26

Analyzed branch: `main` at `95ed3dd`. Scope: `contracts/src/supply/lib` (1 library).

> ⚠️ **This is manipulation-resistance plumbing, not an economic contract.** `IchiAlgebraFairReserves` holds no
> state, no custody, no admin. Its single job is to value an ICHI vault's reserves at a **TWAP tick** so an in-block
> swap can't move the number. The two things outside this file that matter most: (1) the **Algebra plugin's TWAP
> integrity** (observation cardinality / window), and (2) the **vendored UniV3 tick math** (`ConcentratedLiquidity`)
> it builds on. Both are out of scope; both are load-bearing.

---

## 1. Protocol Overview

**What it does:** Reconstructs an ICHI vault's `(amount0, amount1)` reserves at the pool's TWAP tick — the
manipulation-resistant replacement for `IICHIVault.getTotalAmounts()` — and returns the mean tick.

- **Users**: none. A pure `internal view` library linked into `AlgebraIchiFairLpOracle` and `SzipNavOracle`'s LP leg.
- **Core flow**: `fairReserves(vault, window)` → read TWAP tick from the Algebra plugin → for base + limit positions, value `L` at the TWAP `sqrtP` via `LiquidityAmounts` → add idle vault balances → return `(amount0, amount1, meanTick)`.
- **Key mechanism**: position liquidity `L` (changes only on vault mint/burn) and the TWAP tick (time-average) are **both immune to in-block swaps** — so the reconstruction is too. `getTotalAmounts()` values the split at the *current* tick, which a swap moves.
- **Token model**: reads only; computes amounts. No transfers, no custody.
- **Admin model**: none. No owner, no setters, no state.

For a visual overview, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contract | nSLOC | Role |
|-----------|--------------|------:|------|
| Fair reserves | IchiAlgebraFairReserves | 43 | TWAP-tick reserve reconstruction for an ICHI-on-Algebra vault; the keystone the fair-LP / NAV oracles read |

*Protocol-authored. The vendored `ConcentratedLiquidity` (`TickMath`/`LiquidityAmounts`), the ICHI vault, and the Algebra pool/plugin are out of scope (the TWAP-source integrity and the tick math are load-bearing — see banner).*

### How It Fits Together

```
AlgebraIchiFairLpOracle / SzipNavOracle (LP leg)
   └─ IchiAlgebraFairReserves.fairReserves(vault, window)
        ├─ Algebra plugin.getTimepoints([window, 0]) → mean tick → sqrtP        ◄── TWAP (swap-immune)
        ├─ ICHI vault.getBasePosition()  → L_base, bounds → getAmountsForLiquidity(sqrtP, …)
        ├─ ICHI vault.getLimitPosition() → L_limit, bounds → getAmountsForLiquidity(sqrtP, …)
        └─ + token0/token1 balanceOf(vault)  (idle, composition not price-sensitive)
              → (amount0, amount1, meanTick)
```

The single trick: **value liquidity at a time-averaged price, not the current one.** `L` and the TWAP tick are the
two manipulation-immune inputs; everything price-sensitive is derived from them, never from the spot tick.

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Classified as: **Oracle / price-reconstruction library** with **manipulation-resistance** as its sole design goal.

Signals: reads an AMM pool's TWAP and a vault's position liquidity; its entire reason to exist is to defeat in-block
spot manipulation of LP value.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| Swap attacker | Untrusted (the adversary this exists to defeat) | Can move the pool's *current* tick in-block; **cannot** move `L` or the TWAP tick — so cannot move the reconstruction (proven `test_fork_manipulation_invariance`). |
| Algebra pool / plugin | Trusted (the TWAP source) | Supplies the tick-cumulative timepoints. A low-cardinality or short-window TWAP weakens the guarantee; `NoPlugin` fails closed. |
| Consumer oracle | Trusted (sets `window`) | `AlgebraIchiFairLpOracle` / `SzipNavOracle` choose the averaging window (1h deployed) and must feed in-domain inputs. |

**Adversary Ranking:**

1. **TWAP-source weakness** (X-2) — if the Algebra plugin's observation cardinality is too low or the window too short, a sustained multi-block attack could move the "TWAP." This is the real residual and it lives in pool config, not here.
2. **Vendored-math transcription error** (X-1) — ruled out by the faithfulness diff; the copy carries UniV3's audit assurance.
3. **Out-of-domain inputs** — ticks beyond ±MAX_TICK revert in `TickMath` (fail-closed, not mis-priced).

See [entry-points.md](entry-points.md) — no permissionless or stateful entry points.

### Trust Boundaries

- **The Algebra TWAP (off-chain/pool config)** — `_meanTick:79` trusts `getTimepoints`; no cardinality/staleness check here. The integrity of the average is a pool property.
- **The vendored tick math** — `getAmountsForLiquidity` / `getSqrtRatioAtTick` are frozen UniV3 (`ConcentratedLiquidity`); correctness is upstream Uniswap's.
- **Fail-closed reverts** — `NoPlugin` (`:45`), `PluginNotReady` (`:53`, the ADV-02 `isInitialized()` read-time gate), and `BadTimepoints` (`:92`) reject a missing/uninitialized/malformed TWAP source rather than returning a manipulable spot value.

### Key Attack Surfaces

- **Manipulation invariance is the design goal — and it's proven** &nbsp;[[I-1](invariants.md#i-1)] — `test_fork_manipulation_invariance` lands a 300k-USDC swap on the live pool and shows the fair quote moves <1% while the spot split moves >2%. The decisive control is demonstrated against a real pool.
- **Residual TWAP trust** &nbsp;[[X-2](invariants.md#x-2)] — readiness is now gated on-chain (`PluginNotReady`, ADV-02) and window under-coverage fails closed on the live plugin (fork-proven); the remaining residual is observation-cardinality economics, not on-chain-queryable — only as strong as the deployed pool's TWAP. Worth confirming cardinality + window are economically safe.
- **Fail-closed paths now tested** &nbsp;[[I-3](invariants.md#i-3)] — `NoPlugin`, `PluginNotReady`, and `BadTimepoints` all have mock-plugin unit tests (ADV-02 + ADV-03). Gap closed.

### Upgrade Architecture Concerns

- **None** — a stateless library. A change is a redeploy of the linking consumers. Zero blast radius of its own.

### Protocol-Type Concerns

**As an oracle/price library:**
- TWAP windows trade off manipulation resistance (longer = safer) vs responsiveness (longer = staler marks). 1h is the deployed choice; worth confirming it matches the collateral/liquidation cadence on the farm utility market.
- LP-value oracles are a classic exploit class precisely because of the spot-vs-fair distinction this library exists to close; the fair-reserves approach (value `L` at TWAP) is the correct, well-known mitigation.

### Composability & Dependency Risks

> **ConcentratedLiquidity (`TickMath`, `LiquidityAmounts`)** — vendored UniV3
> - Assumes: in-domain ticks (±MAX_TICK), base amounts ≤ uint128.
> - Validates: `TickMath` reverts out-of-range (fail-closed); faithfulness diff confirmed.
> - Mutability: frozen vendored copy.
> - On failure: reverts; no mis-price path.

> **Algebra pool oracle plugin** — via `getTimepoints`
> - Assumes: a configured plugin with adequate observation cardinality; honest tick-cumulatives.
> - Validates: `NoPlugin` if absent; `PluginNotReady` if not `isInitialized()` (ADV-02); `BadTimepoints` if the set isn't length-2.
> - Mutability: pool-side (the pool's plugin can change).
> - On failure: reverts (fail-closed), never falls back to spot.

> **ICHI vault** — via `getBasePosition`/`getLimitPosition`/`baseLower…limitUpper`/`token0`/`token1`
> - Assumes: standard ICHI two-position layout; `L` only moves on mint/burn.
> - Validates: amounts derived from `L`, not from the spot split.
> - On failure: reverts bubble to the consumer.

**Shared State Exposure:**
- Feeds both the fair-LP collateral oracle (farm utility borrow market) and the NAV oracle's LP leg — a wrong reconstruction would mis-mark senior NAV *and* LP collateral. The manipulation-invariance + faithfulness tests guard exactly this.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> - **3 Enforced Guards** (`NoPlugin`, `PluginNotReady`, `BadTimepoints`) — fail-closed on a missing/uninitialized/malformed TWAP source
> - **5 Single-Contract Invariants** (`I-1` … `I-5`) — manipulation invariance, faithfulness, fail-closed, −∞ rounding, reserve composition
> - **2 Cross-Contract Invariants** (`X-1`, `X-2`) — vendored-math correctness, TWAP-source integrity (both On-chain=No)
> - **0 Economic Invariants** — a reconstruction library; the economic invariants live in the consuming oracles / EVK

> The keystone (`I-1`, manipulation invariance) is **On-chain=Yes and directly fork-tested**. The two residual-trust blocks (`X-1`, `X-2`) are **On-chain=No** — the math is Uniswap's, the TWAP integrity is the pool's.

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Missing (in scope dir) | Design fully in NatSpec |
| NatSpec | Thorough | The "WHY" block (`:14-23`) states the manipulation thesis and records the on-chain validation against vault `0xfF8B…73f7` to the wei |
| Spec/Whitepaper | External | `claude-zipcode.md` (out of dir) |
| Inline Comments | Excellent | base/limit/idle steps and the −∞ rounding convention all annotated |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files (this scope) | 1 shared | `AlgebraIchiFairLpOracle.t.sol` — **base-fork integration** vs the live HYDX/USDC vault |
| Test functions touching this lib | 5 | 2 call `fairReserves` directly; 3 exercise it through the oracle |
| Line coverage | Unavailable — project-wide `Stack too deep` (even under `--ir-minimum`) | Coverage tool |
| Branch coverage | Unavailable — same reason | Coverage tool |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Fork integration | 5 | IchiAlgebraFairReserves (via `AlgebraIchiFairLpOracle`) |
| Mock-plugin fail-closed unit | 4 | `NoPlugin`, `PluginNotReady` (ctor + read), `BadTimepoints` |
| Fork under-coverage | 1 | window ≫ history → fail-closed revert (X-2 empirical settlement) |
| Stateless Fuzz | 0 | none (vendored math) |
| Stateful Fuzz / Formal | 0 | none |

### Gaps

- ~~`NoPlugin` / `BadTimepoints` fail-closed paths untested~~ — **CLOSED** (ADV-02 + ADV-03): all three reverts (`NoPlugin`, `PluginNotReady`, `BadTimepoints`) now have mock-plugin unit tests.
- **No TWAP cardinality/staleness assertion** — the library trusts the plugin's average; worth a consumer-side or library-side check that the deployed pool's observation cardinality supports the chosen window.
- **Single-vault fork coverage** — exercised only against HYDX/USDC `0xfF8B…73f7`. Sound for the deployed market; a second vault (different decimals / two-sided) would broaden assurance.
- **No fuzz/invariant** — correctly omitted: the math is vendored UniV3 `TickMath`/`LiquidityAmounts` (audited/formally-verified upstream; faithfulness diff done). Fuzzing re-proves Uniswap's work.

---

## 6. Developer & Git History

> Repo shape: normal_dev. `IchiAlgebraFairReserves.sol` was introduced as part of the fair-LP oracle + redemption-queue/freeze rework (the manipulation-resistance hardening of the LP valuation path).

### Contributors

| Author | Commits | % of Source Changes |
|--------|--------:|--------------------:|
| rootdraws | (sole) | 100% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 1 | Single-dev |
| Merge commits | 0 | No peer-review trail in git |
| On-chain validation | Yes | NatSpec records a live cross-check vs `getTotalAmounts()` to the wei |

### Security Observations

- **The NatSpec documents an on-chain faithfulness validation** (`:21-23`) — unusual discipline; the reconstruction was checked against the live vault before relying on it.
- **No TODO/FIXME/HACK markers**.
- **Tiny, single-purpose, stateless** — the blast radius is confined to the value it returns; the surrounding oracles consume it.

### Cross-Reference Synthesis

- **The decisive property is fork-proven** (`I-1`) → review effort shifts to the off-chain residuals: the Algebra plugin's TWAP cardinality/window (X-2) and the in-domain-input contract with the vendored math (X-1).
- **The former in-file gap (untested fail-closed reverts) is CLOSED** (ADV-02 + ADV-03) → all three reverts now have mock-plugin unit tests; review effort is fully on the off-chain residual (X-2 cardinality economics).

---

## X-Ray Verdict

**HARDENED** — a 43-nSLOC, stateless, single-purpose manipulation-resistance library whose keystone property (TWAP
invariance) is **directly proven by a live-fork manipulation test**, whose faithfulness-when-calm is proven against
the real vault, whose tick math is vendored/frozen/audited UniV3, and whose **three fail-closed reverts
(`NoPlugin`/`PluginNotReady`/`BadTimepoints`) are now all unit-tested** (ADV-02 + ADV-03). The read-time
`isInitialized()` gate + the empirical under-coverage fork test settle the readiness half of X-2. The only remaining
residual is off-chain and out of scope: the Algebra plugin's TWAP cardinality/window economics (not
on-chain-queryable) — the same class as any oracle's external-feed trust. Single-vault fork coverage is sound for
the deployed market. No fuzz needed — the math is Uniswap's.

**Structural facts:**
1. 43 nSLOC; pure `internal view` library; no storage, no admin, no permissionless surface, no custody.
2. Values position liquidity `L` at the TWAP tick (both swap-immune) instead of the spot-tick `getTotalAmounts()`; idle balances added raw.
3. Two fail-closed reverts: `NoPlugin` (no TWAP source) and `BadTimepoints` (malformed set) — never falls back to spot.
4. Tests: 5 live-fork integration (manipulation invariance + faithfulness + dollar sanity + EVK-router resolution + deploy P5 path); 0 unit, 0 fuzz.
5. Residuals are off-chain: TWAP-source integrity (X-2, pool config) and vendored-math correctness (X-1, upstream Uniswap) — not this bytecode.
