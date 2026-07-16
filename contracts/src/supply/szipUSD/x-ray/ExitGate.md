# X-Ray — `ExitGate.sol` (single-contract, test-connected)

> ExitGate | 133 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/ExitGate.sol`, the **#3 drill** from
`portfolio-map.md` — the custody + issuance + exit core, the **sole szipUSD minter/burner** and **sole Baal `Loot`
custodian**. Connected to `test/ExitGate.t.sol`: **23 base-fork unit + 1 stateful invariant = 24 tests, all
passing** (was 18; +5 from the hardening, +1 pre-existing `setGate` ctor test).

> Drill goal (from the map): *add an invariant test for `szipUSD.totalSupply() == loot.balanceOf(gate)`; confirm no
> `ragequit` path is reachable.* **Both done:** a Foundry stateful invariant
> (`invariant_twoToken_conservation_and_zeroShares`) now fuzzes a multi-actor deposit/transfer/burn handler against
> the real Baal + oracle — **~6,400 calls, 0 reverts, 0 violations** — and the two path gaps (`xALPHA` deposit,
> `burnFor` under-funded engine) are filled. No `ragequit` is reachable: the contract calls only
> `mintLoot`/`burnLoot`, never `ragequit`/`mintShares` (confirmed by reading).

## 1. What it is

The szipUSD junior vault's custody + issuance + exit valve (absorbs the old 8-B2 mint shaman + 8-B3 lock/freeze
shaman). It holds Baal `manager(2)` (granted post-deploy by the team-admin via `setShamans`), is the **sole szipUSD
minter/burner**, and wires **no `ragequit`**. Depositors hold only transferable szipUSD, never raw Loot; the Gate
controls *when* exits happen.

**Two flows only:**
- `depositFor` — NAV-proportional issuance off `navEntry()` (round down, favor the vault): pulls the asset straight
  into the main Safe (basket), then mints Loot to itself + szipUSD to the receiver in **equal, paired** amounts.
- `burnFor` — the §7 / 8-B14 paired buy-and-burn retire (pure supply reduction, no asset payout): the *only* exit
  executor. An exiter rests a CoW sell order, the treasury (`SzipBuyBurnModule`) or an external buyer fills it, and
  the bought szipUSD is retired here. The old forfeiting `requestExit`/`processWindow` queue is **retired** (it
  confiscated `U` of an exiter's equity to stayers; replaced by the CoW rail).

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `depositFor(asset, amount, receiver)` | permissionless + `nonReentrant` | whitelist {zipUSD, xALPHA}; prices via oracle; TVL-cap gated; mints paired Loot+szipUSD |
| `burnFor(amount)` | `windowController` + `nonReentrant` | burns Gate's Loot + engine Safe's szipUSD; no asset payout |
| `previewDeposit(asset, amount)` | `view` | mirrors `depositFor` pricing (no cap/wiring/side-effects) — the zap UI estimate |
| 8 × `setX(...)` | `onlyOwner` (Timelock) | build-phase wiring (shareToken, windowController, juniorTrancheEngine, baal, navOracle, tokens, tvlCap) |

No `ragequit`, no `mintShares`, no asset-payout exit. The only value-moving ops are the paired mint (deposit) and
paired burn (retire).

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **two-token conservation** — `szipUSD.totalSupply() == loot.balanceOf(gate)` always (every Loot mint/burn paired with an equal szipUSD mint/burn) | Yes | **`invariant_twoToken_conservation_and_zeroShares`** (fuzzed multi-actor handler, ~6,400 calls, 0 violations) + `_assertInvariants()` in `test_depositFor_genesis_par`, `_navProportional_roundDown`, `test_burnFor_pure_supply_retire`, `test_invariant_sequence` |
| I-2 | **zero shares forever** — the Gate never calls `mintShares`; `baal.totalShares() == 0` | Yes | **`invariant_twoToken_conservation_and_zeroShares`** (fuzzed) + `_assertInvariants()` (`totalShares == 0`) + source (only `mintLoot`/`burnLoot`) |
| I-3 | **no `ragequit` reachable** — exit is the CoW buy-and-burn rail, not an in-kind drain | Yes (by absence) | source: no `ragequit`/`mintShares` call exists; exit topology is intentional (CoW-only) |
| I-4 | **NAV-proportional issuance, round-down** — `shares = valueOf(asset,amount)·1e18/navEntry`, favors the vault | Yes | `test_depositFor_genesis_par` (par), **`test_depositFor_navProportional_roundDown`** ($1.2 → 10 shares), `test_previewDeposit_matches_depositFor` |
| I-5 | **Gate keeps zero custody** — the deposited asset routes straight to `juniorTrancheSafe`; no residual | Yes | `_assertInvariants()` (`zip.balanceOf(gate) == 0`), `test_depositFor_genesis_par` (asset landed in basket) |
| I-6 | **manager-grant gate** — `depositFor` requires the Gate to hold Baal `manager(2)`; ungranted → `mintLoot` reverts | Yes | **`test_depositFor_reverts_without_manager_grant`** (second substrate, no grant → revert) |
| I-7 | **fail-closed issuance** — a stale/unseeded oracle pauses deposits (`StalePrice`/`RateUnseeded`) | Yes | `test_depositFor_stale_reverts`, **`test_SEC04_unseeded_rate_reverts_deposit`** (fail-before/pass-after), `test_previewDeposit_guards` |
| I-8 | **TVL cap** — `grossBasketValue + value > tvlCap` reverts | Yes | `test_depositFor_tvlCap` |
| I-9 | **`burnFor` is windowController-only, pure supply reduction** (no asset payout) | Yes | `test_burnFor_pure_supply_retire` (basket untouched; auth + zero-amount edges) |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| ctor zero-addr / zero-cap | covered via `test_deploy_and_wiring` (positive); negative ctor paths not separately exercised |
| `onlyOwner` setters + re-point effect | `test_setters_repoint_and_auth` |
| szipUSD `mint`/`burn` only by Gate | `test_szipUSD_mint_burn_onlyGate` |
| `UnsupportedAsset` (deposit + preview) | `test_depositFor_unsupported_asset_reverts`, `test_previewDeposit_guards` |
| `ZeroAmount` (deposit + burn) | `test_depositFor_zero_amount_reverts`, `test_burnFor_pure_supply_retire` |
| `NotWindowController` | `test_burnFor_pure_supply_retire` |
| `xALPHA` deposit branch (`valueOf(xAlpha,…)`) | `test_depositFor_xAlpha_path` (+ fuzzed in the invariant handler) |
| `burnFor` under-funded engine → atomic rollback | `test_burnFor_reverts_when_engine_underfunded` |
| `NotWired` (shareToken / engine unset) | `depositFor` path asserted positive; **`burnFor` now carries an explicit `shareToken != 0 → NotWired` guard** — `test_burnFor_reverts_when_shareToken_unwired` |
| **`TransferShortfall`** — `depositFor` requires the basket to receive exactly `amount` (FoT/rebasing over-issue guard) | `test_depositFor_feeOnTransfer_reverts` (1% FoT leg → revert) |
| **`AlreadyWired`** — `setShareToken`/`setBaal` re-point locked once szipUSD is issued | `test_setShareToken_locked_after_issuance`, `test_setBaal_locked_after_issuance`, `test_setBaal_repoint_allowed_pre_issuance` |

## 5. Attack surfaces

- **The two-token conservation is the core safety property — now under a stateful invariant (I-1)** — every
  `depositFor`/`burnFor` pairs an equal Loot and szipUSD mint/burn, so `totalSupply == loot.balanceOf(gate)` must
  hold under *any* interleaving. `invariant_twoToken_conservation_and_zeroShares` now drives a multi-actor handler
  (deposit zip/xALPHA, transfer-to-engine, burnFor) against the **real** Baal + oracle: **~6,400 calls, 0 reverts,
  0 discards, 0 violations**. The most important conservation property in the subsystem is now fuzzed, not just
  deterministically checked. (Run cost: ~5.7 min at 128×50 — fork invariants are heavy; tune `runs`/`depth` if CI
  time matters.)
- **No `ragequit` is reachable (I-3) — confirmed** — the Gate's Baal powers are deliberately minimal: `mintLoot`,
  `burnLoot`, and the paired szipUSD mint/burn. There is no `ragequit` or `mintShares` call anywhere, so depositors
  cannot in-kind drain the basket; exit is the CoW buy-and-burn rail by design (the forfeiting on-chain queue was
  retired). The danger of a Baal shaman (arbitrary loot mint, ragequit) is bounded by *what the Gate never calls*.
- **The `xALPHA` deposit path — now covered** — `test_depositFor_xAlpha_path` exercises the `valueOf(xAlpha, amount)`
  issuance branch (realized shares == `previewDeposit`, xALPHA lands in the basket, invariant holds), and the
  invariant handler additionally fuzzes it (the `useXAlpha` branch).
- **`burnFor` under-funded engine — now covered** — `test_burnFor_reverts_when_engine_underfunded` proves a burn for
  more than the engine holds reverts and rolls back atomically (the prior `burnLoot` does not leak; supply + engine
  balance intact; invariant survives).
- **Build-phase mutable wiring** — 8 `onlyOwner` setters incl. `setBaal` (re-derives `loot`/`juniorTrancheSafe`).
  Re-pointing the Baal or token mid-life is a Timelock act; `test_setters_repoint_and_auth` covers the access +
  re-point. The standing residual is the deferred pre-prod immutable re-freeze. The
  two *conservation-defining* pointers — `setShareToken` and `setBaal` — are now belt-and-suspanders locked in-contract
  via `_assertPreIssuance()` (revert `AlreadyWired` once `SzipUSD(shareToken).totalSupply() != 0`), so a mid-life
  re-point cannot strand the paired Loot / fork the I-1 identity even before the global re-freeze lands; the other five
  setters are I-1-neutral and stay re-pointable. `burnFor` also gained the explicit `shareToken != 0 → NotWired` guard
  for symmetry with `depositFor`.
- **FoT/rebasing deposit leg** — `depositFor` now snapshots the basket balance around the
  `safeTransferFrom` and reverts `TransferShortfall` unless it rose by exactly `amount`. Closes the latent over-issue
  where a fee-on-transfer leg (introducible only via `setTokens`) would mint szipUSD against backing the basket never
  received. Adopts the in-house `DurationFreezeModule` received-delta pattern.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Base-fork unit | 23 | live Baal substrate (`_summon`) + real `SzipNavOracle` + mock basket assets: wiring, NAV issuance (par + round-down), `previewDeposit` parity + guards, manager-grant gate, TVL cap, stale/unseeded fail-close, paired burn, the `xALPHA` deposit path, the `burnFor` under-funded rollback, and the deterministic two-token `test_invariant_sequence` |
| Stateful invariant | 1 | **`invariant_twoToken_conservation_and_zeroShares`** — multi-actor deposit/transfer/burn handler vs the real Baal + oracle; ~6,400 calls, 0 reverts, 0 violations |
| Stateless fuzz | 0 | issuance arithmetic is exercised inside the stateful invariant (the oracle dependency makes the stateful handler the better tool) |

All **24 pass** (`forge test --match-path test/ExitGate.t.sol`). Fork-grade throughout (real Baal, real oracle), and
the decisive conservation invariant is now fuzzed across arbitrary interleavings. Coverage % uninstrumentable
(project-wide stack-too-deep); green run confirmed.

## X-Ray Verdict

**ADEQUATE** *(a hair from HARDENED)* — the design is sound and the dangerous surface is deliberately minimal: sole
minter/burner with paired Loot↔szipUSD accounting, zero custody, no `ragequit`, no `mintShares`, fail-closed
issuance, `nonReentrant` on both mutators — all tested against the **real** Baal substrate and oracle. With the
gap-fills, the decisive two-token conservation (and zero-shares) is now under a **fuzzed stateful
invariant** (~6,400 calls, 0 violations) rather than deterministic sequences alone, and the two previously-uncovered
paths (`xALPHA` deposit, `burnFor` under-funded engine) are closed. Capped at ADEQUATE (not HARDENED) only by the
residual `NotWired`/negative-ctor revert paths not being directly exercised, and the build-phase mutable wiring
pending the pre-prod immutable re-freeze — neither a correctness concern in the read code.

**Structural facts:**
1. 133 nSLOC; `Ownable` + `ReentrancyGuard`; sole szipUSD minter/burner; sole Baal `Loot` custodian (`manager(2)`); no `ragequit`/`mintShares`.
2. Two value-moving flows: `depositFor` (paired Loot+szipUSD mint, asset → basket, round-down NAV issuance) and `burnFor` (paired burn, no payout, windowController-only).
3. Exit is the CoW buy-and-burn rail; the forfeiting on-chain queue is retired (exit topology intentional).
4. Tests: 17 base-fork unit + **1 stateful invariant** (~6,400 fuzzed calls, 0 violations); the two-token conservation is now fuzzed across arbitrary interleavings, not just fixed sequences.
5. Remaining minor gaps: the `NotWired`/negative-ctor revert paths aren't directly exercised; build-phase wiring awaits the pre-prod re-freeze.
