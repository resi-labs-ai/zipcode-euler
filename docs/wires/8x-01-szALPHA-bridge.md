# 8x-01 — szALPHA bridge: SzAlpha + SzAlphaMirror + lock/release lane + DeploySzAlphaBridge (wiring map)

> **X-Ray (security verdict):** all five bridge contracts rated **ADEQUATE**; suite **55/55 + 22/22 green**.
> Per-contract reports under `contracts/src/bridge/x-ray/` (index: `x-ray.md`). The X-Ray is the authoritative
> security artifact — invariants (I-1/I-2/X-1/E-1), guards (G-1…G-18), trust model, test connection. This doc
> is the code-truth wiring map. Cross-contract seams: `docs/wires/SYSTEM-SEAM-MAP.md` (note: the X-Ray's
> bridge-local S-labels — e.g. S2 topology, S8/S9 deploy guards — are scoped to the bridge and are NOT the
> system-map S-numbers).

> Source of truth = the kept code under `contracts/src/bridge/` + `contracts/script/DeploySzAlphaBridge.s.sol`.
> Ticket `tickets/bridge/8x-01-szalpha-wrapper-cct.md` + report `reports/8x-01-report.md` are intent only —
> **the `.sol` is final/authoritative**. Every claim below was read out of the code.
> **Rework:** units/asset-conversion fix + lock/release topology + on-chain AMM quotes, aligned to
> the proven production pattern (Project Rubicon — see `reference/rubicon/` and §Provenance below).

## Role
The cross-chain **xALPHA** — the liquid-staked-ALPHA leg the M1 szipUSD basket holds and the CRE marks.
Four contracts, two chains, joined by a Chainlink CCT lane — **LOCK/RELEASE on 964, BURN/MINT on Base**:

- **`SzAlpha`** (chain **964**, Bittensor EVM) — a self-built UUPS-upgradeable 18-dp ERC-20 **liquid-staking
  wrapper**, the *pooled staker* over the Subtensor `StakingV2` precompile. `deposit(minSharesOut, deadline)`
  (payable) stakes the sent TAO under OUR validator on OUR subnet (the AMM converts TAO→alpha at a variable
  price) and mints szALPHA against the **measured stake delta**; `redeem(shares, minTaoOut, deadline)` unstakes
  and pays the **measured TAO** the alpha→TAO swap produced. It implements `IXAlphaRate.exchangeRate()`
  (alpha-per-share, read live from stake accounting) and exposes **NO pool mint/burn surface** (lock/release).
  It is the ONLY contract with a stake surface.
- **`SzAlphaMirror`** (chain **Base 8453**) — a PLAIN canonical Chainlink `BurnMintERC20` (18-dp), the bridged
  mirror the protocol's Base-side consumers (basket LP, first-loss escrow) actually hold. **No stake / redeem /
  precompile / `IXAlphaRate` surface** — all value accrual happens on 964 and is reflected via
  `SzAlpha.exchangeRate()`. The mirror is a pure transport token.
- **`SzAlphaLockReleasePool` + `ERC20LockBox`** (964) — the lock-on-source / release-on-dest custody. Bridged-out
  szALPHA is **locked** (held by the lockbox), never burned, so `totalSupply()` keeps counting it and
  `exchangeRate() = stake/supply` stays truthful while supply circulates on Base. **Why this matters:**
  burn-on-source would shrink local supply against unchanged stake → the rate falsely inflates → 964 redeemers
  could drain the backing of Base holders, and the inflated rate would propagate to NAV via 8x-02. Lock/release
  kills this class by construction; it is also exactly what the live Rubicon bridges run.
- **`SzAlphaTokenPool`** (Base only) — a thin `BurnMintTokenPool` subclass (burn-on-source / mint-on-dest for
  the mirror, which has no rate of its own) with the same deploy-time invariant asserts.
- **`DeploySzAlphaBridge`** — the both-chain deploy + self-serve wire script, with an aggressive deploy-assert
  battery including a live Alpha-precompile probe on 964.

## Units (the load-bearing convention — verified against the live 964 runtime + Rubicon)
| Quantity | Unit |
|---|---|
| `msg.value`, native payouts | TAO, 18-dp wei |
| `addStake` amount | TAO in **rao** (9-dp); called with **no attached value** — the precompile debits the caller's substrate-mapped balance; swaps TAO→alpha at the subnet AMM price (NOT 1:1) |
| `removeStake` amount / `getStake` return | alpha, **9-dp**; removeStake swaps alpha→TAO, credits the caller's native balance |
| `IAlpha.simSwap*` (0x…0808) | 9-dp in/out, fee-inclusive, size-aware |
| `IAlpha.getAlphaPrice`/`getMovingAlphaPrice` | **18-dp** TAO-per-alpha |
| szALPHA shares, `exchangeRate()`, `totalStaked()` | 18-dp (`_stake18() = getStake × 1e9`; rate semantics unchanged for CRE/NAV) |

## Contracts involved (what each does)
| Contract / file | Chain | What it is |
|---|---|---|
| `src/bridge/SzAlpha.sol` (`is ERC20Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, IXAlphaRate`) | 964 | The pooled-staker LST wrapper. `deposit`/`redeem` over `StakingV2` (`0x…0805`) with slippage+deadline params; `exchangeRate()`/`totalStaked()`; `previewDeposit`/`previewRedeem` as **honest AMM-sim quotes** via the Alpha precompile (`0x…0808`); `getCCIPAdmin`/`setCCIPAdmin` (registrar only — **no mint/burn surface**); `pause`/`unpause`; `_authorizeUpgrade` onlyOwner. |
| `src/bridge/SzAlphaMirror.sol` (`is BurnMintERC20`) | Base 8453 | One-line subclass: `BurnMintERC20(name, symbol, 18, 0, 0)`. AccessControl-based mint/burn; inherits the canonical `grantMintAndBurnRoles`/`getCCIPAdmin`/`setCCIPAdmin`. Zero staking surface. |
| `src/bridge/SzAlphaLockReleasePool.sol` (`is LockReleaseTokenPool`) | 964 | Ctor asserts `localTokenDecimals == 18` (`LocalDecimalsNot18`) + `rmnProxy == canonicalRmn` (`RmnNotCanonical`); pins hooks `address(0)`; custody = the wired `ERC20LockBox`. `typeAndVersion() = "SzAlphaLockReleasePool 1.0.0"`. |
| `ERC20LockBox` (vendored canonical) | 964 | Per-token custody with an owner-managed authorized-caller list. A pool rotation (RMN/CCIP upgrade) re-points the authorized caller — **no fund migration**. Owner → timelock (2-step). |
| `src/bridge/SzAlphaTokenPool.sol` (`is BurnMintTokenPool`) | Base only | Same S8/S9 ctor asserts; hooks pinned. `typeAndVersion() = "SzAlphaTokenPool 1.0.0"`. |
| `script/DeploySzAlphaBridge.s.sol` (`is Script`) | both | `deploy964` (seeds genesis in-broadcast) / `deployBase` / `setRemoteLane` + the assert battery (incl. the 964 Alpha-precompile probe + `totalSupply() > 0` post-seed). Holds the verified 964 + Base CCT address books. |
| `src/interfaces/bridge/ISubtensorPrecompiles.sol` | — | Minimal local `IStakingV2` (`addStake`/`removeStake`/`getStake`) + `IAlpha` (`getAlphaPrice`/`getMovingAlphaPrice`/`simSwapTaoForAlpha`/`simSwapAlphaForTao`) + `IAddressMapping` — **selectors only**, never used as a call target. Units pinned per function. |
| `src/interfaces/bridge/ICctRegistry.sol` | — | Minimal `IRegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin` + `ITokenAdminRegistry.{acceptAdminRole,setPool,getPool,transferAdminRole,getTokenConfig}` (the last two added SEC-03/H4 for the 2-step registry-admin handoff). |
| `src/interfaces/bridge/IXAlphaRate.sol` | — | The `exchangeRate()` face the NAV oracle (8-B4) + CRE-03 (8x-02) read. |

## Wiring — internal (per chain)

### SzAlpha (964) — construction + init
- **Proxy pattern.** `constructor()` only calls `_disableInitializers()`; all config is set in
  `initialize(name_, symbol_, netuid_, validatorHotkey_, owner_, ccipAdmin_)` behind an `ERC1967Proxy`. Init
  guards reject zero `owner_`/`ccipAdmin_`/`validatorHotkey_` and `netuid_ > type(uint16).max`
  (`NetuidTooLarge` — the Alpha precompile takes uint16).
- **Authority split (set from genesis).** `owner()` is the **TimelockController** — it gates
  `_authorizeUpgrade` (UUPS) + `pause`/`unpause`. `ccipAdmin` is a **separate, lower-privilege registrar**
  (no mint/upgrade/fund power) returned by `getCCIPAdmin()`, transferable via `setCCIPAdmin` (onlyCcipAdmin).
  There is **no `ccipPool` role** — the lock/release pool needs nothing from the token.
- **Pooled-staker coldkey.** `wrapperColdkey = _readColdkey(address(this))` — derived ONCE at init via the
  AddressMapping precompile (`0x…080C`) and cached. The wrapper itself is the single staker.
- **deposit (the StakingV2 leg, TAO in).** `deposit(minSharesOut, deadline)` payable: `amountRao =
  msg.value / 1e9` (`ZeroAmount` if 0; the sub-rao remainder is **refunded** at the end, CEI); low-level
  `addStake(validatorHotkey, amountRao, netuid)` with no value. **S4 (direction):** reverts
  `AddStakeEffectMissing` unless the stake **rose** — the delta is the alpha the AMM produced; an
  exact-amount check is impossible (variable price) and was the pre-rework brick. Mints
  `_previewDeposit(deltaRao × 1e9, supplyBefore, stakeRaoBefore × 1e9)` — **against the measured delta at
  the pre-deposit rate**; `ZeroSharesOut` if 0; `SlippageExceeded(actual, min)` under `minSharesOut`.
  `nonReentrant`, `whenNotPaused`, `DeadlineExpired` past `deadline`.
- **redeem (TAO out).** `redeem(shares, minTaoOut, deadline)`: shares→alpha18 (`_previewRedeem`), floor to
  whole rao (sub-rao dust stays staked, accruing to remaining holders — `ZeroAmount` if it floors to 0),
  CEI burn, low-level `removeStake(alphaOutRao)`. **S4:** the stake must **fall** AND the native balance
  must **rise**; the payout is the **measured balance delta** (never the estimate), gated by `minTaoOut`.
  **`redeem` is `nonReentrant` but never `whenNotPaused`** (S3/S11 — value is NAV-anchored to
  redeemability). `receive()` accepts the TAO credited by `removeStake`.
- **exchangeRate / virtual-offset genesis 1:1.** `exchangeRate() = (_stake18() + 1).mulDiv(1e18,
  totalSupply() + 1)`, 18-dp alpha-per-szALPHA — external semantics unchanged by the rao rework. Virtual
  offset (1/1) in all share math (round **Floor**, protocol's favor): never divides by zero; clean 1:1
  genesis. **Lock/release keeps this rate truthful across bridge-outs** (locked supply still counts).
- **Donations (honest — replaces the old, WRONG "structurally inapplicable" claim).** Subtensor's
  `transferStake` lets a third party attribute stake to the wrapper's coldkey, so the backing CAN be raised
  externally. Under measured-delta minting + floor rounding + `ZeroSharesOut`: a donation is a pure,
  irrecoverable **gift to existing holders**; first-depositor griefing is strictly value-destroying (donor
  must gift ≥ the victim's deposit) and a zero-share mint reverts rather than silently losing funds. The
  deploy-script **seed deposit** closes even the griefing window. `minSharesOut` is the user-level guard.
- **previews (honest AMM quotes — Alpha precompile `0x…0808`).** `previewDeposit(taoWei)` =
  `simSwapTaoForAlpha` (fee-inclusive, size-aware) then share math; `previewRedeem(shares)` = share math then
  `simSwapAlphaForTao`, returning TAO wei. **Advisory, current-block, spot-based** — callers derive
  `minSharesOut`/`minTaoOut` from them; NAV never consumes them (it reads `exchangeRate()`).
  `AmountOverflowsUint64` guards the precompile's u64 inputs.
- **Precompiles called low-level.** State-changing `addStake`/`removeStake` via `STAKING_V2.call(...)`;
  `getStake`/`addressMapping`/`simSwap*` via `staticcall` (decoded `>= 32` bytes else
  `PrecompileCallFailed`). A *typed* call to a Frontier precompile "never reaches the runtime".
- `decimals()` pinned `pure → 18`. `__gap[46]` (4 used slots) reserves UUPS storage.

### SzAlphaLockReleasePool + ERC20LockBox (964)
- `constructor(token, localTokenDecimals, rmnProxy, router, lockBox, canonicalRmn)` →
  `LockReleaseTokenPool(token, dp, address(0) /*hooks*/, rmnProxy, router, lockBox)`, then asserts **18-dp** +
  `rmnProxy == canonicalRmn`. The base ctor verifies the lockbox supports the token and max-approves it.
- **Custody = the lockbox, not the pool.** `lockOrBurn` deposits into the lockbox; `releaseOrMint` withdraws
  to the receiver. The pool is an entry on the lockbox's **authorized-caller list** (owner-managed) — an RMN
  rotation redeploys the pool and re-points the caller list; **funds never move**.
- The rate-limiter is configured per-lane post-deploy via `applyChainUpdates` (`setRemoteLane`).

### SzAlphaMirror + SzAlphaTokenPool (Base 8453)
- Mirror: canonical `BurnMintERC20` — constructor-set name/symbol/18/maxSupply 0/preMint 0. At construction
  `DEFAULT_ADMIN_ROLE` + `ccipAdmin` are the deployer (the script), handed to the timelock + revoked in
  `deployBase`. Mint/burn is AccessControl-gated to the Base pool via the inherited `grantMintAndBurnRoles`.
- Pool: `BurnMintTokenPool` subclass, same S8/S9 asserts. Burn/mint is CORRECT on Base — the mirror has no
  rate of its own to corrupt; this is also the live Rubicon Base-side shape.

### DeploySzAlphaBridge — both-chain deploy + self-serve wire
- **`deploy964(netuid_, validatorHotkey_, timelock, ccipAdmin)`:** `_assertCctAddresses(bittensorConfig())` →
  **`_assertAlphaPrecompile(netuid_)`** (live probe: non-zero `getAlphaPrice` + non-zero 1-TAO `simSwap` for
  our netuid — proves address, uint16 netuid, 9-dp sims, and the subnet pool in one read; auto-skipped
  off-964) → deploy `SzAlpha` impl + proxy (owner=timelock, **ccipAdmin=the script** so `acceptAdminRole`
  can run in-tx) → `new ERC20LockBox(token)` → `new SzAlphaLockReleasePool(...)` → authorize the pool on the
  lockbox → register via `registerAdminViaGetCCIPAdmin` → `acceptAdminRole` → `setPool` →
  **`transferAdminRole(token, ccipAdmin)` (SEC-03/H4: hand the REGISTRY admin to the durable ccipAdmin — 2-step,
  the ccipAdmin must `acceptAdminRole` post-deploy)** → hand off: `setCCIPAdmin(ccipAdmin)` (aligns the token's
  `getCCIPAdmin()` view) + `lockBox.transferOwnership(timelock)` (**2-step** — the timelock must
  `acceptOwnership()`, a runbook step) → asserts (incl. **`getTokenConfig(token).pendingAdministrator==ccipAdmin`**,
  NOT the old false-confidence `getCCIPAdmin()==ccipAdmin` view check).
- **Genesis seed (folded into `deploy964`):** `deploy964` seeds ~1 TAO in-broadcast right
  after the proxy is live and auto-burns the seed shares to `0xdead` — closing the first-depositor griefing
  window *structurally* (no manual step). At supply 0 the seed is the one legitimate `minSharesOut == 0`
  caller; the standalone `seedDeposit` function is removed. Fund the deployer ≥ ~1 TAO before `deploy964`.
- **`deployBase(timelock)`:** `_assertCctAddresses(baseConfig())` → `new SzAlphaMirror` → pool →
  `grantMintAndBurnRoles(pool)` → register → accept → `setPool` → **`transferAdminRole(token, timelock)` (SEC-03/H4:
  hand the REGISTRY admin to the durable timelock — 2-step `acceptAdminRole` runbook)** → asserts (incl.
  **`getTokenConfig(token).pendingAdministrator==timelock`**) → hand the mirror's authority (ccipAdmin view +
  `DEFAULT_ADMIN_ROLE`) to the timelock and revoke the deployer.
- **`setRemoteLane(...)`:** one `TokenPool.ChainUpdate` → `applyChainUpdates`. Run once both chains' pools
  exist, per direction, under the timelock.
- **The 5-address re-read battery** (`_assertCctAddresses`) re-reads `typeAndVersion()` for router / TAR /
  registryModule / factory + `_hasCode(armProxy)`; `_assertDeployed` checks `owner()==timelock` (S1);
  `_assertPoolRmnAndDecimals` checks decimals==18 (S8) + canonical RMN (S9). **Wiring MUST NOT proceed
  unless every assert passes.**
- **Address books (verified on-chain).** Base: chainSelector `15971525489660198786`, router
  `0x881e…58bCD`, TAR `0x6f6C…1e37`, registryModule `0xAFEd…D77f`, factory `0xcD66…4D16`, armProxy
  `0xC842…d3E8`. 964: chainSelector `2135107236357186872`, router `0xD941…60B8`, TAR `0xe72d…8Be6`,
  registryModule `0xcDca…35C3`, factory `0x8FE3…1602`, armProxy `0x02A4…894d`.

## Wiring — cross-component (who points at whom)
- **The mirror is the xALPHA leg.** The Base `SzAlphaMirror` is the production swap-in for the M1 stand-in
  across every Base consumer: 8-B5/8-B6 basket LP (zipUSD/xALPHA leg) and 8-Bx `LienXAlphaEscrow.xAlpha`
  (re-pointed via the Timelock-settable `setXAlpha`).
- **`exchangeRate()` is the rate face, not a balance face.** `SzAlpha.exchangeRate()` (964) is the
  `IXAlphaRate` getter the **NAV oracle (8-B4)** and **CRE-03 (8x-02)** consume. The rate originates on 964,
  the balance lives on Base (mirror), and 8x-02 bridges the rate. **Unchanged by this rework** — the rao
  normalization is internal.
- **The CCT lane joins them.** 964 `SzAlphaLockReleasePool` (lockbox custody) ⟷ Base `SzAlphaTokenPool`
  (mirror burn/mint). Bridge-out: szALPHA locked on 964, mirror minted on Base. Bridge-back: mirror burned,
  szALPHA released from the lockbox. `964 totalSupply == locked + circulating-on-964`; mirror supply ==
  locked. The rate regression test (`test_lane_roundTrip_rateInvariant`) pins `exchangeRate()` invariance
  across a full round-trip.
- **Follow-up (recorded, out of scope):** source NAV's `LEG_ALPHA_USD` from `IAlpha.getMovingAlphaPrice`
  (EMA, manipulation-resistant) × TAO/USD in the CRE workflow, replacing off-chain price APIs.

## Item-10 deploy facts (PROGRESS row 373)
1. **Supply the real fixtures.** Pass the registered `NETUID` (≤ uint16 max) + `VALIDATOR_HOTKEY` to
   `deploy964`.
2. **Run `deploy964` on a 964 RPC.** Exercises the 964 CCT 5-address asserts + the Alpha-precompile probe —
   un-fork-testable here (no public Subtensor fork node).
3. **Seed is automatic:** `deploy964` seeds ~1 TAO in-broadcast and burns the shares to
   `0xdead` — fund the deployer ≥ ~1 TAO beforehand; no separate seed step.
4. **Timelock accepts lockbox ownership** (`lockBox.acceptOwnership()` — 2-step handoff from the script).
4b. **Durable admin finalizes the REGISTRY-admin handoff (SEC-03/H4 — MANDATORY).** The deploy script
   `transferAdminRole`s the `TokenAdminRegistry` administrator to the durable authority (964 → `ccipAdmin`,
   Base → `timelock`) but cannot accept on its behalf mid-broadcast, so that authority MUST call
   `ITokenAdminRegistry(tokenAdminRegistry).acceptAdminRole(token)` post-deploy. Until it does, the ephemeral
   deploy Script remains a live registry admin — the one residual interruption window; accept promptly. Verify
   `getTokenConfig(token).administrator == <durable>` after.
5. **Wire the lane.** Once BOTH pools exist, call `setRemoteLane` per direction with ops-decided rate
   limits, under the timelock. (Pool ownership is now transferred to the timelock IN `deployBase`;
   the timelock only needs to `acceptOwnership()`, 2-step `Ownable2Step`.)
6. ~~Calibrate denomination~~ **RESOLVED:** the unit table above is verified against the live runtime
   (Rubicon's audited wrapper + the Rust precompile source + live cast probes), and
   `_assertAlphaPrecompile` re-proves it at deploy time. The pre-deploy cast battery lives in
   `script/RUNBOOK-mainnet-deploy.md`.
7. **Wire the consumers.** Wire the deployed `SzAlpha`/mirror as the `xALPHA` leg into 8-B5/8-B6 + 8-Bx
   `LienXAlphaEscrow.xAlpha` (via `setXAlpha`), replacing the stand-in. Assert the production token is
   hookless / feeless / non-rebasing.

## Provenance — the proven pattern (Project Rubicon)
- **Who:** General TAO Ventures + Chainlink, launched 2025-11; 18 live xAlpha tokens bridged 964 → Base
  (xTAO, xSN4…xSN120), audited by Hashlock (Oct 2025). Docs + full address book:
  `https://docs.rubiconbridge.io/developer/contract-addresses`; audit:
  `https://hashlock.com/wp-content/uploads/2025/10/Rubicon-Smart-Contract-Audit-Report-Final-Report-v6.pdf`.
- **What we verified on-chain:** 964 token = `ERC1967Proxy → LiquidStakedV3` (verified source vendored at
  `reference/rubicon/LiquidStakedV3.flattened.sol`); 964 pools = `LockReleaseTokenPool 1.6.1`; Base =
  canonical `BurnMintERC20` (18-dp, maxSupply 0) + `BurnMintTokenPool 1.6.1`. Live Alpha-precompile reads
  (SN64): price 0.0672e18; 1 TAO → 14.870 alpha; 1000 TAO → 14,792.8 alpha (~0.5% impact — sims are
  size-aware).
- **What we deliberately do differently:** our `SzAlphaRateOracle` CRE rate push to Base is an EXTENSION —
  Rubicon ships no on-Base rate primitive (Aerodrome prices xAlpha by market). The token+lane is the proven
  part; the oracle leg is ours and carries its own guards (8x-02).

## Gotchas (build-exposed corrections — code wins over the ticket)
- **`registerAdminViaGetCCIPAdmin`, NOT `registerAdminViaOwner`.** `registerAdminViaOwner` requires
  `IOwner(token).owner() == msg.sender` — impossible here: the mirror is AccessControl-based with no
  `owner()`, and `SzAlpha.owner()` is the timelock from genesis. The registrar is the `ccipAdmin` role via
  `getCCIPAdmin()`. On 964 the script initializes itself as `ccipAdmin` for the in-tx `acceptAdminRole`,
  then hands off.
- **Burn/mint on 964 would corrupt the rate (the topology decision).** `exchangeRate()` reads LOCAL
  `totalSupply()`; burn-on-bridge-out shrinks it against unchanged stake → rate inflates → 964 redeemers
  drain Base holders' backing, and 8x-02 propagates the lie to NAV. Hence lock/release on 964 (the proven
  shape) and burn/mint only on Base where there is no local rate. Do not "simplify" this back.
- **UUPS ⊥ constructor-based `BurnMintERC20`.** `BurnMintERC20` is non-upgradeable — behind a proxy its
  constructor never runs. `SzAlpha` is a FRESH OZ-Upgradeable token; post-rework it implements **no**
  `IBurnMintERC20` surface at all (lock/release needs none); only the mirror inherits the canonical.
- **The "8x exception" OZ version seam (WOOF-00 EXTENDED).** Three OZ ecosystems coexist under one solc
  0.8.24 invocation via versioned import-prefix remaps: `chainlink-ccip` pool stack →
  `@openzeppelin/contracts@5.3.0` onto the scaffold's 5.0.2 tree; the canonical `BurnMintERC20` →
  `@openzeppelin/contracts@4.8.3`; `SzAlpha`'s UUPS leg → OZ-Upgradeable 5.1.0. `AdvancedPoolHooks` is not
  in the import graph (hooks pinned `address(0)`).
- **Vendored CCIP is 2.0.0; the live Rubicon pools are 1.6.1.** Same family, newer pin; the 2.0.0
  lock/release split (`LockReleaseTokenPool` + `ERC20LockBox`) is what makes pool rotation fund-migration-free.
  Keep the pin; re-verify `typeAndVersion` expectations if Chainlink ships 964/Base registry upgrades.
- **964 lane is un-fork-testable here.** No public Subtensor fork node — the StakingV2/Alpha/AddressMapping
  precompiles are `vm.etch`-mocked (UNIT-FAITHFUL: rao 9-dp ledger + settable TAO↔alpha price) and the CCIP
  relay is driven at the pool level with mock Router/RMN. Only the Base mirror + registration is fork-real.
- **`vm.etch` copies bytecode, NOT storage.** The mocks' field initializers (e.g. par price) are ZERO at the
  etched precompile addresses — `setUp` must write them explicitly (`_setPrice(1e9)`), and tests that move
  the price must set it on BOTH mocks (staking + alpha quote) or previews diverge from execution.
- **`maxSupply = 0` is "unlimited", not "frozen".** The mirror's cross-chain supply is bounded by the 964
  lock/release, not a Base cap.
