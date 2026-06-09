# DurationFreezeModule — the duration-squeeze freeze: autonomous on-chain floor + CRE main↔sidecar rotation (§11-B / §6.4 / §8.2)

> **M1 build · build-only.** The actuator that fills/drains the **non-ragequittable sidecar** so the
> utilization-committed junior equity is **structurally** unreachable by an Exit-Gate window exit (§6.4) — the
> **Duration Bond trigger B** (a *liquidity* squeeze, **no realized loss, no xALPHA premium/slash**, §11). It is the
> seventh engine **Zodiac `Module`** (after 8-B14 buy-and-burn, 8-B5 reservoir loop, 8-B6 LP strategy, 8-B7
> harvest/vote, 8-B8 exercise, 8-B9 sell), but the **first enabled on BOTH Safes** (main + sidecar) because rotation
> moves value across them.
>
> **The load-bearing on-chain logic is the AUTONOMOUS RELEASE FLOOR** — the §11-B "on-chain utilization floor that
> engages the lock automatically, not outsider-manipulable; a CRE report may trip it earlier but cannot un-trip a
> live on-chain breach." Same **bounds-not-validates** shape as `DefaultCoordinator`/`LienXAlphaEscrow`: the CRE
> operator is trusted to *select which assets and how much* to rotate; the contract **autonomously bounds the
> RELEASE direction** so that **even a compromised operator cannot open the run hatch** while utilization is high.
> `commit` (MAIN→SIDECAR, increasing the freeze) is always peg-safe so it is ungated-by-value; `release`
> (SIDECAR→MAIN, shrinking the freeze) reverts unless the sidecar still holds at least `requiredFraction(U) ×
> grossBasketValue`.
>
> **`U` is read donation-immune off the senior pool** (the CRITICAL fix from the security critic, 2026-06-09): `U =
> 1 − maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))` = the **illiquid fraction of the senior
> backing** (how much of the warehouse's EulerEarn position is locked in live loans and cannot be freed now). This
> reads the controller-gated **borrow** side (§4.3), NOT a stray-balance "idle" figure — EulerEarn's `totalAssets()`
> is `Σ expectedSupplyAssets(strategy)` (USDC merely transferred to the pool address is ignored), so a donation to
> the pool moves neither term and the §11-B "not outsider-manipulable" guarantee holds. **Do NOT read `U` from
> `IERC20(usdc).balanceOf(eulerEarn)`** (that is donatable AND ≈0 for a pure-allocator pool → would pin `U≈1` and
> brick releases).
>
> **This is NOT a loss contract, NOT a ragequit gate, NOT a Baal shaman.** It engages **no markdown**, pays **no
> premium**, reads **no default state**, and **does not touch the Exit Gate** — it gates the Gate *structurally*, by
> controlling what sits in the main (ragequit-target) Safe. The Gate's `processWindow` (`ExitGate.sol:218`,
> already-built) ragequits only `mainSafe`, so keeping `requiredFraction(U)` of basket value in the sidecar is the
> whole freeze; **no ExitGate change is needed or allowed.**

**Deliverable**
Two code artifacts under the supply tree, plus one additive oracle view:
- `contracts/src/supply/szipUSD/DurationFreezeModule.sol` — `contract DurationFreezeModule is Module,
  ReentrancyGuard` (zodiac-core `Module` is the base every engine module uses, `LpStrategyModule.sol:4`; OZ
  `ReentrancyGuard` per the `LienXAlphaEscrow` token-agnostic precedent). Clone-deployable via `ModuleProxyFactory`
  (all wired addresses are **set-once storage written in `setUp` under `initializer`, NOT `immutable`** — the §18.6
  clone fact proven on 8-B5/8-B6/8-B14). CRE-`operator`-gated `commit`/`release` move a **whitelisted** basket leg
  across the two Safes; `release` is gated by the autonomous floor. Pure views expose `utilization()`,
  `requiredFraction()`, `committedValue()`, `requiredCommittedValue()`, `freeValue()`.
- **Additive extension to `contracts/src/supply/SzipNavOracle.sol`** — new `committedValue()` (sidecar-only basket
  value) + `freeValue()` (main-only) external views. **`grossBasketValue()` stays byte-for-byte unchanged** (the
  42-test oracle suite's exact pins must still pass): the two new views are **independent per-Safe re-computations**
  (a private `_grossValueOf(address safe)` whose `mainSafe`+`sidecar` sum equals `grossBasketValue()` exactly for the
  five plain legs and within ≤2 wei for the LP leg — the per-Safe pro-rata floors the LP twice vs once; see KR-9).
  This is the oracle back-pressure this module creates — the oracle owns valuation (§3.4/§7), so the floor reads the
  sidecar's value FROM the oracle (mirrors how the Exit Gate forced `valueOf` onto the oracle, BUILT 2026-06-08).
- `contracts/test/DurationFreezeModule.t.sol` — unit (the floor math, both rotation directions, the operator gate,
  the whitelist, the two-Safe exec, every boundary) + a **stateful invariant** (`committedValue() ≥
  requiredCommittedValue()` after any release, 128k+ calls) + a **Base-fork** test against the **real summoned
  substrate** (`SummonSubstrate._summon`) + the **real `SzipNavOracle`** (`committedValue` parity) proving a real
  cross-Safe rotation and a real floor-breach revert, + the no-sweep/no-freeze-engage/no-Gate ABI-negatives.

**Spec §**
- `claude-zipcode.md` **§11 trigger B** (`:1984-2010`) — the duration-squeeze: liquidity-driven, every loan
  performing, **no realized loss**; **Trigger** = an on-chain utilization floor `U` (the illiquid fraction of the
  senior backing, `U = 1 − maxWithdraw(CreditWarehouse)/convertToAssets(balanceOf(CreditWarehouse))`, donation-immune,
  §8.2) breaching a governed `U_lock` engages the lock automatically, **not outsider-manipulable**; **Sizing** =
  `lockFraction = maxLockFraction × clamp((U − U_lock)/(U_max − U_lock), 0, 1)`; **Stacking** = effective lock
  `max(φ_A, φ_B)` capped at 1.0; **M1 realization** (the `:2003`-area note added this window) = the §6.4 **continuous
  structural floor**, `maxDuration`/`releaseHysteresis` **subsumed** (M1 carries neither), `commit` ungated,
  `maxLockFraction` caps only the escalation term (no separate redeemability cap); **Compensation** = none beyond
  continuing yield.
- **§6.4** (`:1336-1362`) — the structural freeze: only **free** junior equity lives in the main (ragequit-target)
  Safe; the equity **committed to live credit lines — sized to credit-warehouse utilization** — lives in the
  non-ragequittable sidecar; a window exit reaches only free equity; the CRE rotates the committed slice back as
  lines close; `committedFraction = committed backing / basketNAV = utilization`; coverage floor = the freeze itself.
- **§8.2** (`:1556-1571`) — the on-chain trigger host + the **donation-immune `U` read** (the producer spec authored
  this window): `U = 1 − maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))` off the EulerEarn senior pool;
  explicitly **NOT** `IERC20(asset).balanceOf(eulerEarn)`.
- **Locked §17 (do not reopen):** the freeze is **structural** via the Exit Gate + sidecar (`:153`), **not** a
  Baal-ragequit gate; window cadence / floor are governed params; **zipUSD itself never freezes** (junior-only). The
  freeze is owned by the supply side, NOT the `DefaultCoordinator` (`:1088`).

**Model from (VERIFIED against the repo this window — by inspection)**
- **The engine Zodiac Module shape — `contracts/src/supply/szipUSD/LpStrategyModule.sol` (8-B6, BUILT-VERIFIED
  2026-06-08).** VERIFIED: `contract LpStrategyModule is Module` (`@gnosis-guild/zodiac-core/core/Module.sol`, `:4`);
  `Module is FactoryFriendly, Ownable` so **`initializer`, `_transferOwnership`, `onlyOwner`, `owner`, `avatar`,
  `target` already exist — do NOT import OZ Ownable/Initializable** (ref-verifier confirmed). `setUp(bytes
  initParams) public override initializer` body is at **`:69-97`** (the ticket-v1 "`:71-99`" was a minor drift),
  `abi.decode`s the wired addresses, sets `avatar`/`target`, then `_transferOwnership(owner_)`; the `operator` gate is
  `if (msg.sender != operator) revert NotOperator();`; `owner_ == operator_` is rejected (`OwnerIsOperator`, error
  `:49`, check `:77`); the **§18.6 clone fact** (NO `immutable`; mastercopy init-locked) is in the NatSpec `:27-30`.
  **Replicate this structure**; the deviations are the **two-Safe** exec (below), `is ReentrancyGuard`, and the
  whitelist.
- **Cross-Safe exec — `contracts/src/interfaces/safe/ISafe.sol:27-32` `execTransactionFromModule(address to, uint256
  value, bytes data, uint8 operation) returns (bool)`.** VERIFIED present; the interface header states operation `0`
  == Call (`:7`). Because the module is enabled on **both** Safes, the rotation execs against the **source** Safe
  directly via this interface (NOT the inherited `avatar`-bound `execAndReturnData`, which targets one Safe):
  `ISafe(src).execTransactionFromModule(asset, 0, abi.encodeCall(IERC20.transfer, (dst, amount)), 0)`. OZ `IERC20`
  declares `transfer(address,uint256) returns (bool)` so `encodeCall` is type-valid (ref-verifier confirmed). The
  Safe **swallows inner reverts and returns `false`** (the `LpStrategyModule._exec` lesson, `:57-66`) → on `!ok`
  revert `ExecFailed`. The inherited `exec`/`execAndReturnData` are left unused (legal — `internal virtual`); set
  `avatar = target = mainSafe` to satisfy the base and carry the `LpStrategyModule:105-108` "setAvatar/setTarget are
  inherited onlyOwner but **inert for rotation** (rotation uses explicit `ISafe(src)`)" NatSpec note.
- **The basket valuation seam — `contracts/src/supply/SzipNavOracle.sol` (BUILT-VERIFIED 2026-06-07).** VERIFIED:
  `grossBasketValue() public view returns (uint256)` (`:255-275`) sums **both** Safes — `_bal(token) =
  balanceOf(mainSafe) + balanceOf(sidecar)` (`:339-341`) for the five token legs, the LP block sums
  `ichi.balanceOf(main)+ichi.balanceOf(sidecar)+gauge.balanceOf(main)+gauge.balanceOf(sidecar)` (`:262-263`).
  `mainSafe`/`sidecar` immutables (`:59-60`); the five leg addresses are public immutables `zipUSD`/`usdc`/`xAlpha`/
  `hydx`/`oHydx` (`:54-58`) with auto-getters (the module reads them for its whitelist). The pool-globals
  `IICHIVault.totalSupply()` (`:265`) / `getTotalAmounts()` (`:267`) are NOT per-Safe (ref-verifier confirmed) — a
  per-Safe split scales only the held-shares, so `_grossValueOf(main)+_grossValueOf(sidecar)` equals
  `grossBasketValue()` exactly for the five plain legs and within ≤2 wei for the LP (the pro-rata floors once vs
  twice — qa #3). The module reads `committedValue()` + `grossBasketValue()` through a **minimal local
  `ISzipNavBasket` interface** (the two view sigs) — do NOT import the GPL oracle for two view calls.
- **The utilization source — `reference/euler-earn/src/EulerEarn.sol` (the §8.2 EulerEarn).** VERIFIED:
  `maxWithdraw(address owner) public view returns (uint256)` (`:546-548`, accounts for strategy liquidity via
  `_maxWithdraw`→`_simulateWithdrawStrategy`); `totalAssets()` (`:616`) = `_accruedFeeAndAssets().newTotalAssets` =
  `Σ expectedSupplyAssets(strategy)` over the withdrawQueue + `lostAssets` (`:903-918`) — **stray USDC transferred to
  the pool address is NOT counted** (donation-immune; the load-bearing fact). `convertToAssets`/`balanceOf` are
  inherited from OZ `ERC4626`/`ERC20` (`:30,:41` — NOT declared in `EulerEarn.sol`, so the "VERIFIED at :616 for
  asset()" claim in v1 was wrong; they exist via inheritance, fine for a local interface). EulerEarn is `0.8.26` →
  **never imported/compiled** (the `[EXT]` house posture) — use a **minimal local `IEulerEarnUtil` interface**
  (`maxWithdraw(address)`, `convertToAssets(uint256)`, `balanceOf(address)`). Tests use a `MockEulerEarn` exposing
  these three with settable backing (our pool deploys at item-10; WOOF-04/05 mock precedent).
- **The substrate (the two Safes) — `contracts/script/SummonSubstrate.s.sol` (8-B1, BUILT-VERIFIED 2026-06-07).**
  VERIFIED: `_summon(...) internal returns (Substrate memory s)` (`:62`) — a **struct** `s.baal/s.mainSafe/s.sidecar`
  (struct `:27-33`), NOT the bare tuple v1 implied; the fork test inherits the script (or calls a thin wrapper) to
  reach the `internal` `_summon`. The `executeAsBaal → safe.execTransactionFromModule(safe, <owner-auth payload>)`
  idiom EXISTS (`_selfAddOwnerPayload :152-155` driven via `executeAsBaal` in `_buildInitActions :145-147` for main,
  `_addOwnerToSidecar :159-167` for the sidecar). **NOTE (ref-verifier):** the proven payload is
  `addOwnerWithThreshold`, not `enableModule` — the **mechanism is identical** (Baal is an enabled module → can make
  each Safe self-call any owner-auth method, and `enableModule(module)` is one such), so the fork test builds
  `executeAsBaal(safe, 0, abi.encodeCall(ISafe.enableModule, (module)))` for BOTH Safes by the same path; v1
  overstated it as "already proven for `enableModule`." Spell this out in the fork test.
- **OZ `IERC20`/`SafeERC20`/`ReentrancyGuard`** — `@openzeppelin/contracts/...`, the exact imports
  `LienXAlphaEscrow.sol:4-6` uses (`is ReentrancyGuard`, `using SafeERC20 for IERC20`). `IERC20.balanceOf(address)`
  (`:32`) for the delta assert. (Note: the transfers go through `ISafe.execTransactionFromModule` with raw
  `encodeCall(IERC20.transfer,…)`, so `SafeERC20` is only needed if you use it elsewhere — drop the `using` if
  unused, junior #flag.)

**Starting state**
- `contracts/src/supply/szipUSD/DurationFreezeModule.sol` does not exist — create it.
- `SzipNavOracle.sol` is on disk + BUILT-VERIFIED (42-test suite) — extend it **additively** (two new views; the
  `_grossValueOf` private helper; `grossBasketValue` unchanged). The `valueOf` precedent (added 2026-06-08) shows
  additive oracle extensions are in scope. The oracle is **not yet deployed/renounced** (item-10) so adding a view is
  free.
- The scaffold (`forge build` green), zodiac-core / OZ / safe-interface remaps, the six sibling engine modules,
  `SummonSubstrate`, `BaseAddresses`, and the `MockERC20`/handler precedents (`LienXAlphaEscrow.t.sol`,
  `DefaultCoordinator.t.sol`) are all in place.

**Do NOT**
- Do **NOT** read `U` from `IERC20(usdc).balanceOf(eulerEarn)` or any raw token balance of an externally-fundable
  address (the CRITICAL security fix). Read it ONLY as `1 − maxWithdraw(warehouse)/convertToAssets(balanceOf(
  warehouse))` (§8.2). A donation to the pool must not move `U` (assert it — see Tests).
- Do **NOT** allow `commit`/`release` of an asset the oracle does NOT value — gate both on the **whitelist of the
  five oracle leg addresses** read from the oracle at `setUp` (the non-basket-asset leak, security #6 HIGH: releasing
  an unvalued asset leaves the sidecar without moving `committedValue()`, so the floor passes while real value exits
  the freeze). The LP legs (ICHI/gauge) are positions moved by 8-B6 unstake, NOT transferable by this module — they
  are **not** on the movable whitelist. No rebasing/elastic-supply leg may ever be whitelisted without an oracle
  normalization first (security #7).
- Do **NOT** engage any markdown, write the oracle's `provision`, read/route any xALPHA bond, pay any premium, or
  read any default/`DefaultCoordinator`/loss state — trigger B is **liquidity-only** (`:1989`). Do **NOT** call,
  read, or modify the **Exit Gate** (no `setExitGate`, no Gate import) — the freeze gates window exits structurally.
- Do **NOT** add a value gate to **`commit`** (MAIN→SIDECAR). §11 is canonical (the baal-spec §8.8 "redeemability
  cap" phrasing is stale and dies with that file, spec-fidelity-confirmed): the effective lock is capped only at
  `1.0`; `maxLockFraction` caps only the escalation term. An unbounded `commit` can freeze 100% — that is the
  intended squeeze behavior; the residual operator-grief (over-freeze) is accepted (item-10 wires the §12 metric-4
  alarm).
- Do **NOT** let `release` drop the sidecar below `requiredFraction(U) × grossBasketValue` — that floor IS the
  trigger-B lock. The operator chooses *which* whitelisted asset; the contract bounds *how much value* may leave.
- Do **NOT** make the trigger CRE-pushed / operator-discretionary / governance-flippable, and do **NOT** carry
  `maxDuration`/`releaseHysteresis` on-chain (the continuous-floor model subsumes them, §11-B M1-realization note —
  spec-fidelity FAITHFUL). An optional CRE early-trip is post-M1 and can only *raise* the floor.
- Do **NOT** add a sweep/rescue/skim, a pause, a generic `exec(target,data)` passthrough, a delegatecall, or any
  `value != 0` exec. The module holds **no custody**; both the source and destination of every transfer are the
  literal set-once `mainSafe`/`sidecar` — **no recipient parameter** (the destination-integrity thesis).
- Do **NOT** size the floor off any single default's at-risk amount (§6.4 `:1345-1346`) or off `navEntry`/`navExit`
  per-share prices — the floor is a **value ratio** (`committedValue` vs `grossBasketValue`, same `_grossValueOf`
  basis, ratio-consistent even if a pushed leg is stale; do not add a staleness revert into the comparison).

**Key requirements**
1. **Inheritance + clone discipline.** `contract DurationFreezeModule is Module, ReentrancyGuard` with no `immutable`
   wired state (every wired address/param is set-once `setUp` storage; the mastercopy is init-locked). Pragma
   **`0.8.24`**. (OZ `ReentrancyGuard` non-upgradeable is storage-safe under `ModuleProxyFactory` clones — junior
   #confirmed.)
2. **`setUp(bytes initParams) public override initializer`** decodes
   `(address owner, address mainSafe, address sidecar, address operator, address navOracle, address eulerEarn,
   address warehouse, uint256 uLock, uint256 uMax, uint256 maxLockFraction)`:
   - revert `ZeroAddress` on any zero address; `OwnerIsOperator` if `owner == operator`.
   - **`BadParams` if `mainSafe == sidecar`** (qa #6 — distinctness is load-bearing: equal Safes make rotation a
     self-transfer that trivially passes the floor).
   - `BadParams` unless `uLock < uMax && uMax <= 1e18 && maxLockFraction != 0 && maxLockFraction <= 1e18`.
   - **Read the five movable basket-leg addresses LIVE from the oracle** (`ISzipNavBasket(navOracle).zipUSD()` /
     `.usdc()` / `.xAlpha()` / `.hydx()` / `.oHydx()`) and store them as the whitelist (the `LpStrategyModule`
     "read token0/token1 live" idiom — guarantees the whitelist == exactly what the oracle prices, no drift).
   - Set `avatar = mainSafe; target = mainSafe;` (satisfies the base; the inherited single-avatar exec is **not used**
     — both rotations go through explicit `ISafe(src)` calls). Store all wired values. `_transferOwnership(owner)`.
   - 18-dp convention: `uLock`/`uMax`/`maxLockFraction`/all fractions are `1e18 = 100%`.
3. **Whitelist gate (the leak fix).** `modifier onlyValued(address asset)` / inline check:
   `if (asset != zipUSD && asset != usdc && asset != xAlpha && asset != hydx && asset != oHydx) revert
   UnvaluedAsset(asset);` applied to BOTH `commit` and `release`.
4. **Utilization (on-chain, donation-immune, §8.2/§11-B):**
   `function utilization() public view returns (uint256 u) { IEulerEarnUtil e = IEulerEarnUtil(eulerEarn); uint256
   sa = e.convertToAssets(e.balanceOf(warehouse)); if (sa == 0) return 0; uint256 free = e.maxWithdraw(warehouse); if
   (free >= sa) return 0; u = (sa - free) * 1e18 / sa; }` — the illiquid fraction, 18-dp, in `[0, 1e18]`.
5. **Required floor fraction (§11-B sizing + §6.4 structural baseline):**
   `function requiredFraction() public view returns (uint256 f) { uint256 u = utilization(); uint256 esc; if (u >
   uLock) { esc = u >= uMax ? maxLockFraction : maxLockFraction * (u - uLock) / (uMax - uLock); } uint256 r = u > esc
   ? u : esc; f = r > 1e18 ? 1e18 : r; }` — `min(1e18, max(U, escalation))`. **`max` not sum** (§11-B `:1998`); φ_A =
   utilization is the liquidity-path identity (spec-fidelity FAITHFUL — trigger A's `atRisk/juniorNAV` is the
   DefaultCoordinator's lane). All divisions truncate **down** (sub-wei; document the direction — qa #2).
6. **Value views (read FROM the oracle):** `committedValue()`/`grossBasketValue()` via `ISzipNavBasket`;
   `requiredCommittedValue() = requiredFraction() * grossBasketValue() / 1e18`; `freeValue() = grossBasketValue() -
   committedValue()`.
7. **`commit(address asset, uint256 amount) external nonReentrant onlyValued(asset)` (MAIN→SIDECAR — increase the
   freeze):**
   - `if (msg.sender != operator) revert NotOperator(); if (amount == 0) revert ZeroAmount();`
   - `uint256 before = IERC20(asset).balanceOf(sidecar);`
   - `bool ok = ISafe(mainSafe).execTransactionFromModule(asset, 0, abi.encodeCall(IERC20.transfer, (sidecar,
     amount)), 0); if (!ok) revert ExecFailed();`
   - `if (IERC20(asset).balanceOf(sidecar) - before != amount) revert TransferShortfall();` (the FoT/false-return
     defense)
   - `emit Committed(asset, amount, committedValue());` **No value floor/ceiling** (KR / Do-NOT).
8. **`release(address asset, uint256 amount) external nonReentrant onlyValued(asset)` (SIDECAR→MAIN — shrink the
   freeze; THE autonomous floor):**
   - operator + `amount==0` guards as above.
   - `uint256 before = IERC20(asset).balanceOf(mainSafe);`
   - `ISafe(sidecar).execTransactionFromModule(asset, 0, abi.encodeCall(IERC20.transfer, (mainSafe, amount)), 0)` →
     `!ok` revert `ExecFailed`; balance-delta on `mainSafe` else `TransferShortfall`.
   - **THE FLOOR (checked AFTER the move; the revert atomically rolls the transfer back):** `uint256 floor =
     requiredCommittedValue(); uint256 c = committedValue(); if (c < floor) revert FreezeFloorBreach(c, floor);`
   - `emit Released(asset, amount, c, floor);` `grossBasketValue` is invariant under a rotation (value moves between
     Safes, total constant — proven by a test), so the floor is a pure "did the sidecar keep enough value" check
     with `U` read live → an over-release reverts regardless of operator intent.
9. **The `SzipNavOracle` additive extension (behavior-preserving — `grossBasketValue` UNCHANGED):**
   - Add a private `_grossValueOf(address safe) internal view returns (uint256)` that values ONE Safe's holdings:
     the five legs via `IERC20(token).balanceOf(safe)` × the same per-leg marks; the LP block via `ichi.balanceOf(
     safe) + gauge.balanceOf(safe)` over the same pool-globals (`totalSupply`/`getTotalAmounts`), with the same
     `supplyLp == 0` / `ichiVault == address(0)` guards.
   - Add `committedValue() external view { return _grossValueOf(sidecar); }` and `freeValue() external view { return
     _grossValueOf(mainSafe); }`. **Do NOT rewrite `grossBasketValue()`** — leave it exactly as-is (the 42-test
     suite's exact `grossBasketValue` pins must not move). The two new views are independent reads.
   - Parity is a REQUIRED test: `grossBasketValue() == committedValue() + freeValue()` **exactly** when no LP leg is
     held, and within **≤2 wei** when the LP is split across both Safes (the per-Safe pro-rata floors twice vs once).
     The floor check tolerates the ≤2-wei LP slack (economically nil). Since the module only moves the five **plain**
     legs (never the LP), `grossBasketValue` is **exactly** invariant under every rotation this module performs.
10. **Residual-trust NatSpec block (REQUIRED, top of the contract):**
    > This module **rotates and bounds**; it does NOT decide the liquidity regime. Under §13 the CRE operator
    > (single, trusted, the same authority every engine module trusts) is trusted for *which* whitelisted asset to
    > move, *how much*, the timing, and whether to `commit`. The on-chain guarantees are narrow and exact: (a) value
    > can only move between the two wired Safes — no recipient parameter, no third destination, no custody; (b)
    > `release` cannot drop the sidecar below `requiredFraction(U) × grossBasketValue`, where `U` is read live and
    > donation-immune from EulerEarn and is not outsider-manipulable (§4.3/§8.2) — so a compromised operator cannot
    > open the run hatch while utilization is breached; (c) `requiredFraction` only ever *rises* with utilization (no
    > off-chain floor input exists in M1); (d) only the five oracle-valued legs are movable (no unvalued-asset leak).
    > A compromised operator can **grief** (over-commit free equity, delaying exits; §12 metrics + governance watch
    > it) but **cannot steal** and **cannot under-freeze**. zipUSD never freezes (junior-only, §17). The floor read is
    > sound under the single-operator invariant (no concurrent sibling-module rotation mid-`release`).
11. **Events:** `Committed(address indexed asset, uint256 amount, uint256 committedValueAfter)`, `Released(address
    indexed asset, uint256 amount, uint256 committedValueAfter, uint256 floor)`. (No engage/disengage event — the
    freeze is continuous.)
12. **Custom errors** (no string reverts): `NotOperator`, `ZeroAddress`, `OwnerIsOperator`, `BadParams`,
    `ZeroAmount`, `UnvaluedAsset(address asset)`, `ExecFailed`, `TransferShortfall`, `FreezeFloorBreach(uint256
    committed, uint256 floor)`.

**Done when**
`forge build` green + `forge test --match-contract DurationFreezeModule` green + the **full suite has no regression**
(`forge test` — the report MUST state the `SzipNavOracle` suite count is still ≥42 and all green, and that the
existing `grossBasketValue` exact pins are unchanged, qa #11). Test fixtures:
- `MockEulerEarn`: settable `convertToAssets(shares)` / `maxWithdraw(owner)` / `balanceOf(owner)` so any `U` is
  drivable; the donation test sends USDC to the mock address and asserts `U` is unchanged (the donation-immunity
  proof). `MockERC20(uint8 d)` open `mint` (the `LienXAlphaEscrow.t.sol` mock) for the legs.
- `MockNavBasket` (unit): settable `committedValue()`/`grossBasketValue()` + the five leg getters (`zipUSD()`… so
  `setUp` reads the whitelist) — exercises the floor math independent of basket composition. The **fork** suite uses
  the **real `SzipNavOracle`**.
- `MockFeeOnTransferERC20` for the `TransferShortfall` test.

Tests:
- **setUp/ctor:** rejects each zero address (`ZeroAddress`), `owner == operator` (`OwnerIsOperator`), `mainSafe ==
  sidecar` (`BadParams`), each param `BadParams` boundary (`uLock >= uMax`, `uMax > 1e18`, `maxLockFraction == 0/ >
  1e18`); accepts `uMax == 1e18` and `maxLockFraction == 1e18`; reads the five leg addresses into the whitelist; a
  clone re-`setUp` reverts (`initializer`); the mastercopy is init-locked.
- **utilization() (donation-immune):** `sa == 0` → 0; `free >= sa` → 0; mid value (`sa=100, free=30`) → `0.7e18`; a
  **USDC donation to the eulerEarn mock address leaves `U` unchanged** (the CRITICAL-fix proof); `free == sa` → 0
  exactly.
- **requiredFraction() (the §11-B math, table-driven):** with `uLock=0.8e18, uMax=0.95e18, maxLockFraction=1e18`:
  `U=0.6`→`0.6e18`; `U=0.8`(==uLock)→`0.8e18`; `U=0.875`→`0.875e18`; **`U=0.95`(==uMax, exact-equality branch)**→`max(
  0.95e18, 1e18)=1e18`; `U=1.0`→`1e18`(min cap). **Escalation-bites vector** (`uLock=0.1e18, uMax=0.2e18,
  maxLockFraction=1e18, U=0.19e18`) → `esc=0.9e18 > U` → `0.9e18` (the case the design exists for). LOW maxLockFraction
  (`0.5e18`, `U=0.95`) → `max(0.95e18,0.5e18)=0.95e18` (structural U dominates). `uLock==0` always-escalating.
- **truncation-pin vector (qa #2):** non-dividing values (e.g. `sa=3, free=1` → `U=333333333333333333`; a prime-ish
  `gross`) asserting the **exact** integer `requiredCommittedValue()` so a future rounding-direction flip is caught.
  Plus `gross == 0` → floor 0, any release allowed (no div-by-zero); `requiredFraction == 1e18` with sidecar == gross
  → release of 1 wei reverts.
- **whitelist:** `commit`/`release` of a non-leg `MockERC20` → `UnvaluedAsset` (the leak fix); each of the five legs
  is accepted.
- **commit (happy + negatives):** non-operator → `NotOperator`; `amount == 0` → `ZeroAmount`; happy commit moves
  `amount` main→sidecar (balances ±amount), `committedValue` rises, `Committed` emitted; an over-freeze commit (all
  free equity) **succeeds** (no ceiling — the grief-not-theft point); a `MockFeeOnTransferERC20` → `TransferShortfall`;
  a Safe-rejected transfer (module not enabled / insufficient balance) → `ExecFailed`. Symmetric note-test: committing
  an unvalued asset is barred by the whitelist (so the asymmetry with release is moot).
- **release (the floor, happy + the load-bearing revert):** above-floor release within slack succeeds (`Released`,
  sidecar still ≥ floor, **error args `(committed, floor)` populated correctly**); a release that would drop the
  sidecar **below** `requiredCommittedValue()` reverts `FreezeFloorBreach` AND **the transfer rolls back** (assert
  the released asset's `mainSafe` AND `sidecar` balances AND `committedValue()` are byte-for-byte the pre-call values
  — qa #5); raising `U` flips a previously-legal release to `FreezeFloorBreach` (operator call fixed — the autonomous
  trigger); non-operator/`amount==0` guards; at `U` low enough that `requiredFraction == 0`, the sidecar may be fully
  drained.
- **gross-invariant-under-rotation (qa #4):** snapshot `grossBasketValue()`, `commit` then `release` a plain leg,
  assert `grossBasketValue()` **unchanged** (the linchpin of the floor's conservation argument; exact since the
  module never moves the LP).
- **the autonomous-trigger thesis (security test, concrete flip-point — qa #9):** seed the sidecar at the floor for a
  mid-`U`; loop walking `U` up via the mock; call the **identical** `release(asset, fixedAmount)` each step; assert
  the boundary `U` at which it flips allowed→`FreezeFloorBreach` is exactly where `requiredCommittedValue()` first
  exceeds the post-release `committedValue()`. A "compromised operator" (arbitrary leg/amount) can never push committed
  value below the live floor.
- **oracle parity (additive extension):** over a fuzzed basket (random balances of each leg across both Safes,
  optional LP), `grossBasketValue() == committedValue() + freeValue()` **exactly with no LP** and **≤2 wei with a
  split LP** (pin an explicit LP-split vector with a non-dividing `totalSupply`); the pre-refactor `grossBasketValue`
  exact pins are unchanged; the 42-test oracle suite re-runs green.
- **no-sweep / no-freeze-engage / no-Gate / no-markdown ABI-negatives:** low-level `call` each forbidden selector —
  `sweep(address,uint256)`, `rescue(address,uint256)`, `pause()`, `exec(address,bytes)`, `setExitGate(address)`,
  `engageFreeze()`, `writeProvision(uint256)`, `slashXAlphaToCohort(bytes32)` — assert `!success`; assert `setTarget`
  by a non-owner reverts (the inherited inert-redirect note, security #1).
- **stateful invariant (qa #10 — mirror `LienXAlphaEscrow.t.sol`'s `EscrowHandler`):** a `FreezeHandler` exposing
  `commit`, `release`, `bumpUtilization` (set the mock's `maxWithdraw`/backing to walk `U`) over the five legs + an
  unvalued token; invariant `committedValue() >= requiredCommittedValue()` after any successful `release` (the core
  safety property), `fail_on_revert = false`, ≥128k calls. (The handler naturally also exercises the whitelist path.)
- **Base-fork (the real rotation):** `vm.createSelectFork(base)`; summon the real substrate (inherit
  `SummonSubstrate`, call `_summon` → `Substrate s`); deploy the real `SzipNavOracle` (with `s.mainSafe`/`s.sidecar`)
  + a clone of this module via `ModuleProxyFactory`; team-`enableModule` on **BOTH** Safes via
  `executeAsBaal(safe, 0, abi.encodeCall(ISafe.enableModule, (module)))` (the `_addOwnerToSidecar` Baal idiom with
  `enableModule` substituted — spell out the calldata); seed the sidecar + main with `MockERC20` stand-ins for the
  five legs (passed as the oracle's leg ctor args so `committedValue()` is non-zero — `grossBasketValue` is a pure
  balance sum, no leg-staleness needed); a `MockEulerEarn` for `U`; drive a real `commit` then `release`, asserting
  the cross-Safe `IERC20.transfer` lands and the **real `committedValue()`** moves; force a `FreezeFloorBreach` by
  setting `U` high. (EulerEarn stays a mock even on fork — our pool deploys at item-10, WOOF-04/05 precedent.)

Integration-layer mapping (for item-10 / CRE, **not** built here — recorded below): the rotation joins `audit/2.md`
as the §6.4 freeze-sizing step (CRE-05 drives `commit`/`release` per utilization, `:1685` step 5); the trigger-B
squeeze trace + the `audit/3-results.md` authority rows author at item-10.

**Depends on**
- The scaffold (WOOF-00), zodiac-core / OZ / `safe` remaps, `MockERC20` + the handler precedents (`contracts/test`).
- The **real `SzipNavOracle`** (BUILT-VERIFIED 2026-06-07) — extended additively here (the basket-value seam).
- The **real substrate** (8-B1 `SummonSubstrate`, BUILT-VERIFIED 2026-06-07) — the two Safes (fork only).
- The six sibling engine modules (the `is Module` / clone / operator pattern) — style precedent only.

**Cross-ticket obligations this item DISCHARGES** (mark `DISCHARGED` in PROGRESS at Conclude):
- **the freeze/rotation module · sidecar rotation/funding** (PROGRESS row 289, owed by THIS module) — `commit` is the
  only path that funds the sidecar and it routes value there only via a Safe the team owns + has enabled the module on
  (item-10 wiring order); `release` is the controlled drain. The "do NOT fund the sidecar until `isOwner(team)==true`"
  precondition is structurally enforced (`execTransactionFromModule` fails closed until the module is enabled on the
  team-owned sidecar) + re-recorded as an item-10 wiring assert below.

**Cross-ticket obligations this item CREATES** (record in PROGRESS at Conclude — discharged by item-10 / CRE later):
- **Item 10 (deploy/wiring):** deploy the module mastercopy + clone via `ModuleProxyFactory`; `setUp(owner=Timelock,
  mainSafe, sidecar, operator=CRE-05, navOracle, eulerEarn=OUR senior pool, warehouse=the CreditWarehouse Safe
  holding the EE shares, uLock, uMax, maxLockFraction)`; **`enableModule(module)` on BOTH Safes** (sidecar only
  **after** `isOwner(team)` — row 289); assert the module is enabled on both + the five whitelist legs == the oracle's
  + the governed params before going live.
- **Item 10 / security — the live-pool utilization verification (the CRITICAL's residual):** assert the wired
  `eulerEarn` is OUR senior pool AND that `U` is derived from `maxWithdraw/convertToAssets` (the controller-gated
  borrow side), never an idle `balanceOf`. Verify against the **live** deployed pool that (a) a USDC donation to the
  pool address does not move `U`, and (b) the residual "donate into a strategy vault's cash to raise `maxWithdraw`"
  surface is acceptably bounded for the production EVK credit-line vaults (EulerEarn is mocked until item-10, so the
  live read is unverifiable now — same deferral as 8-Bx's xALPHA / WOOF-04/05's EulerEarn).
- **CRE-05 (§8.2/§8.7 operator):** the operator workflow reads `requiredFraction()`/`committedValue()` and issues
  `commit`/`release` to keep `committedValue ≈ requiredFraction(U) × gross` as lines draw/repay (`:1685` step 5),
  decomposing the staked LP via 8-B6 unstake first when it must move LP value (this module moves only the five liquid
  legs).
- **Governance params (§17):** `uLock`, `uMax`, `maxLockFraction` are governed VALUES set at deploy (no live setter —
  a re-tune is a redeploy/clone, mirroring `recoveryFloor`). `maxDuration`/`releaseHysteresis` are subsumed by the
  continuous floor (§11-B M1 note) — re-decide only if a binary lock is reintroduced.
- **Optional CRE early-trip (§8.4, post-M1):** a "secondaries-down" report that *raises* the floor earlier than
  on-chain `U` — additive, can only raise; NOT in M1 scope.
- **`audit/2.md` / `audit/3-results.md` (item-10):** author the freeze-sizing rotation step + the trigger-B squeeze
  trace + the authority rows, deferred like the escrow/coordinator audit sweeps.
