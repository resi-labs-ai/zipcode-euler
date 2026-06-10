# 8x-01 — `szALPHA` LST wrapper + CCIP CCT transport (Bittensor 964 ↔ Base 8453)

> **NEXT / build-only.** The fork path (self-built `szALPHA`), decided 2026-06-09: a **self-built
> liquid-staking wrapper (`szALPHA`)** over the public Subtensor precompiles, pointed at **our own validator on our
> own subnet** ([[zipcode-subnet-role]]), plus a **self-serve Chainlink CCT `BurnMintTokenPool`** that bridges it
> Bittensor mainnet (964) ↔ Base (8453). This is the token the M1 `szipUSD` basket holds (the `zipUSD/xALPHA`
> Hydrex LP leg, DEC-03) and the one CRE-03 marks (§8.6/§8.8). `DEC-02` is **cleared** — no decision gate remains;
> CCT registration on 964 is open/self-serve (proof + addresses in the §4 deploy table below). **No INFLOW ticket**
> (internal infra; the deposit/zap UI consumes the token, not the bridge).
>
> **Why fork over canonical Rubicon xAlpha:** structural closed-loop control. The cost the fork buys is the
> **audit/upgrade surface** — the wrapper's UUPS upgradeability + owner controls are the trust boundary; govern with
> a **TimelockController from genesis** (§3). The security section below is load-bearing, not advisory.
>
> **Mocked vs fork-real.** **Fork-real:** the live 964 precompiles on a Subtensor EVM fork node, and the deployed
> CCT stack on both chains exercised on a Base fork + `chainlink-local` lane simulation. **Mocked:** the CCIP relay
> itself (`CCIPLocalSimulatorFork` — no real DON in tests). Rewards-validator emissions / pool-seeding / peg-arb
> keeper / `lock_stake` are **out of scope** — treasury/ops wiring (`treasury.md`, removed 2026-06-09, re-author
> post-M1). This ticket builds the **transport + token**, not the economic program.
>
> **Sequencing caveat.** M1 but **not on the contract-spine critical path** — the supply engine (8-B chain) builds
> against an xALPHA **stand-in** until the lane is live. Schedule against 8-B / CRE, not ahead.

---

## Deploy-time prerequisites (real-world, NOT code — resolve before mainnet wire)

- **`NETUID` (uint256)** and **`VALIDATOR_HOTKEY` (bytes32 SS58 pubkey)** — our registered subnet + our validator
  hotkey. **Literal values are pending subnet/validator registration** (a real-world dependency, like a DEC item).
  They are **`initialize` arguments**, not hardcoded constants — the contract is built parameterized; the test uses
  fixtures. Do not block the build on the literals; block only the mainnet deploy.
- **Wrapper coldkey:** the wrapper's own EVM address maps to one SS58 coldkey (via AddressMapping `0x80c`, derived
  once at init and cached). The wrapper is the **single staker** — see the pooled-staker model below.

---

## Build prerequisite — CCIP/Subtensor compat self-check (the "8x exception", WOOF-00 EXTENDED)

Repo pins **solc 0.8.24 / cancun / runs=20000**. Verified by ref-verifier: `BurnMintTokenPool.sol` / `TokenPool.sol`
are `pragma ^0.8.24` (no solc conflict) — **but they import `@openzeppelin/contracts@5.3.0`**, while the scaffold
dedups OZ to the euler-vault-kit copy. **First build step, before any logic:**

1. Add only the remap lines this ticket needs (CCIP pools, chainlink-local, subtensor solidity ABIs). Resolve the
   **OZ-version seam**: CCIP wants OZ 5.3.0; if that clashes with the deduped core OZ, isolate the CCT-pool
   contracts behind their own remap alias / `foundry.toml` profile and bridge via interfaces. **Document the
   resolution in the report; do not silently bump the core OZ/solc.**
2. Compile a probe importing `BurnMintTokenPool.sol` + `TokenPool.sol` + one precompile ABI (`stakingV2.sol`)
   together before writing logic.
3. The `reference/ccip-starter-kit-foundry` fork tests import **OZ 4.8.3** (stale vs the 5.3.0 pools) — use them for
   the **register→setPool→applyChainUpdates call pattern only**, not as a compile dependency.

---

## Deliverable

Two authored contracts (one with two deploy modes), the extended bridge interfaces, one deploy/wire library, one
fork test (+ mocks).

### 1. `contracts/src/bridge/SzAlpha.sol` — the LST wrapper (pooled-staker model)

`contract SzAlpha is ERC20Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, IXAlphaRate, ...`
— an upgradeable ERC-20 (18-dp) liquid-staking receipt. **`SzAlpha` does NOT inherit the canonical `BurnMintERC20`**
(it is constructor-based + OZ-4.8.3-bound — a UUPS proxy can't run its constructor). Instead **implement the
`IBurnMintERC20` surface** (`mint`/`burn`×2/`burnFrom`/`grantMintAndBurnRoles(address)` (MINTER_ROLE/BURNER_ROLE) +
`getCCIPAdmin()`/`setCCIPAdmin`) on top of OZ-Upgradeable, so the CCT face matches the audited one exactly. (Only the
immutable Base mirror inherits the canonical `BurnMintERC20`.) `grantMintAndBurnRoles` is on the *implementation*, NOT
on `IBurnMintERC20` (ref-verifier-confirmed). Exchange-rate
accounting = cToken / wstETH / ERC-4626 pattern. `reference/evm-bittensor/solidity/stakeV2.sol` is the worked
precompile example; build the staking leg fresh (Rubicon's wrapper is not public).

**TWO DISTINCT MINT PATHS — name them, gate them separately (the round-2 build-critical fix):**
- **`deposit(uint256 amount)` (payable) — the user-facing staking leg.** A user supplies alpha; the wrapper stakes
  it and mints szALPHA shares to the user. This path is **open to anyone** but mints **only in proportion to stake
  actually added** (see effect-verification S4) — it does NOT call the privileged ERC-20 `mint`.
- **`mint(address,uint256)` / `burn(uint256)` — the CCT cross-chain leg.** The inherited `IBurnMintERC20` methods,
  callable **ONLY** by `ccipPool` (`grantMintAndBurnRoles(pool)` at init; no other holder). These move existing
  supply across the lane; they never touch stake.
These are different functions. `deposit` is the deposit leg; `mint`/`burn` are the bridge leg. Never expose a public
`mint(amount)` that lets a caller mint shares without adding stake.

**Pooled-staker model (the central architecture decision — was unspecified, now locked):** the **wrapper itself is
the single staker**. All deposited alpha is staked under the **wrapper's own coldkey** (derived once at init via
AddressMapping `0x80c`, cached as immutable/storage). There is **no per-user SS58 mapping** — users hold `szALPHA`
ERC-20 shares; the wrapper holds the aggregate stake. (This is what makes it an LST and removes any per-user
`addressMapping` / CREATE2-grinding surface.)

- **Config (set at `initialize`, not constructor — UUPS):** `NETUID` (uint256), `VALIDATOR_HOTKEY` (bytes32). The
  precompile handles are constants: StakingV2 `0x805`, AddressMapping `0x80c`, BalanceTransfer `0x800`, Metagraph
  `0x802`.
- **`deposit` (stake):** receive alpha as **native value** (`deposit` is `payable`, `msg.value` carries the alpha on
  the Bittensor EVM — **not** an ERC-20 `transferFrom`; follow the `stakeV2.sol` value-flow exactly) →
  `StakingV2.addStake(VALIDATOR_HOTKEY, msg.value, NETUID)` → mint `szALPHA` `shares = amount × totalSupply /
  totalStaked` (round **down**). Shares are minted by the wrapper's own privileged internal path, not the CCT `mint`.
- **`redeem` (unstake):** burn the caller's `szALPHA` → `StakingV2.removeStake(VALIDATOR_HOTKEY, alphaOut, NETUID)` →
  return alpha, where `alphaOut = shares × totalStaked / totalSupply` (round **down**). **Mandatory and always callable**
  (§3) — token value is NAV-anchored to redeemability. **`redeem` is NEVER pausable.** dTAO has no unbonding
  (immediate, slippage-only); no redemption queue at this layer — the duration-lock throttle lives in the szipUSD
  exit machinery (`claude-zipcode.md §11`), not here.
- **Exchange rate / `IXAlphaRate`:** implement `exchangeRate() external view returns (uint256)` (18-dp, alpha-per-
  szALPHA; `1e18` = 1:1) — the exact `contracts/src/interfaces/bridge/IXAlphaRate.sol` shape CRE-03 reads.
  `totalStaked = StakingV2.getStake(VALIDATOR_HOTKEY, wrapperColdkey, NETUID)` read live from the precompile —
  **no DEX/oracle in the path** (§2). The wrapper exposes **rate only**; the **APR** figure (§8.8) is **CRE-computed
  off-chain** from this rate + the §8.6 NAV legs (`tickets/bridge/8x-02-xalpha-apr-cre.md`) — NOT an on-chain method here.
- **First-mint anti-dilution (security HIGH-3):** guard the `totalSupply == 0` case against the donation/inflation
  attack via the **OZ ERC-4626 virtual-offset** (`virtualShares = 1`, `virtualAssets = 1`): `shares = amount × (supply
  + 1) / (stake + 1)`, rounded **down** — NOT "mint `1e3` dead shares to `address(0)`" (minting to `address(0)` reverts
  in OZ and would not prevent the first-deposit div-by-zero). Gives a clean 1:1 genesis (`exchangeRate() == 1e18`), no
  div-by-zero ever, and rounding that always favors the protocol / existing holders. The pooled-staker model makes a
  third-party donation **structurally impossible** (stake is coldkey-attributed; `getStake` reads only the wrapper's
  coldkey), the strongest defense.
- **Post-call effect verification (security HIGH-4) — BOTH directions, distinct errors (round-2 tightening):** the
  StakingV2 precompile may not revert on failure, so verify the *observable* effect via `getStake` delta:
  - After `addStake` in `deposit`: re-read `getStake(VALIDATOR_HOTKEY, wrapperColdkey, NETUID)`; revert
    `AddStakeEffectMissing()` unless it rose by ≥ the deposited amount. (A silent `addStake` failure is **fund
    loss** — alpha accepted, no backing stake — so this is the more critical of the two.)
  - After `removeStake` in `redeem`: assert `getStake` fell by ≥ `alphaOut` **and** the wrapper's native balance
    (`address(this).balance`) rose by ≥ `alphaOut`; revert `RemoveStakeEffectMissing()` otherwise.
- **Fees:** **none in M1.** Value accrues purely via the rate (validator rewards lift `totalStaked`). No fee field,
  no fee accrual. (A fee is a post-M1 treasury decision.)
- **EVM→SS58:** AddressMapping `0x80c` (`addressMapping.sol`), used **only** to derive the wrapper's own coldkey
  once at init. Do not reimplement Blake2b; do not add an owner-settable mapping override (unnecessary — pooled).
- **Reentrancy + CEI (security LOW-11):** `nonReentrant` on `mint`/`redeem`; checks-effects-interactions ordering
  (compute rate + validate, apply share effects, then the precompile call).
- **Authority (security HIGH-1/HIGH-2, MED-6):**
  - **ERC-20 `mint`/`burn` gated to the CCT pool ONLY** — the inherited `BurnMintERC20.mint`/`burn` revert unless
    the caller holds MINTER_ROLE/BURNER_ROLE, granted **only** to `ccipPool` via `grantMintAndBurnRoles(pool)` once
    at init. **No other role holder, no `onlyOwner` mint.** The user `deposit` leg mints shares via the wrapper's
    own internal path (NOT the public `mint`) and only against verified added stake (S4) — so a caller can never
    mint shares without staking, and the pool can never stake (the two paths share no surface).
  - **Owner = OZ `TimelockController` from genesis** (assert `owner() == timelock` in the deploy script before any
    op tx; no bare-EOA window). `_authorizeUpgrade` is `onlyOwner` (⇒ timelock). **Min delay ≥ 48h for ops
    (rate-limiter/pause), ≥ 7d for upgrades** (set at deploy, recorded in the report — not left to assumption).
  - **Validator-delegate change** (if exposed at all in M1 — prefer NOT exposing it; immutable-after-init is
    simplest and matches §3 "set at construction"). If exposed: timelocked (≥7-day delay), emits initiate/cancel
    events, cancellable before expiry, and a zero/`address(0)` delegate is a revert (safety fuse). **Recommend
    deferring delegate-change to a post-M1 upgrade** — flag the decision in the report.
  - **`Pausable`** mint only; redeem exempt (above). Pause is timelock/owner-gated.
  - **No arbitrary call, no delegatecall** anywhere.
- **Storage layout:** UUPS — reserve a storage gap; document the layout so a future upgrade can't collide.

**Base-side deployment — LOCKED to a separate contract `contracts/src/bridge/SzAlphaMirror.sol`** (decided 2026-06-09;
round-2 wanted the choice made). Base (8453) has **no Subtensor precompiles**, so the mirror is a **plain
`BurnMintERC20`** — 18-dp, `mint`/`burn` gated to the Base CCT pool, **zero staking/redeem/precompile/`IXAlphaRate`
surface**. A separate contract (not an init flag on `SzAlpha`) keeps dead precompile code off Base entirely and
shrinks the Base audit surface. Native `deposit`/`redeem` (stake/unstake) exist **only on 964** (`SzAlpha`). NatSpec
on `SzAlphaMirror` states it is a bridged mirror with no native backing on Base.

### 2. `contracts/src/bridge/SzAlphaTokenPool.sol` — the CCT pool

`contract SzAlphaTokenPool is BurnMintTokenPool`. **Real constructor (ref-verifier-confirmed):**
`(IBurnMintERC20 token, uint8 localTokenDecimals, address advancedPoolHooks, address rmnProxy, address router)` —
the 3rd arg is **`advancedPoolHooks` (address; pass `address(0)` if unused)**, NOT an allowlist array. Burn-on-source
/ mint-on-dest; `szALPHA` grants the pool mint/burn (item 1).

- **18-dp invariant (security MED-9):** assert `localTokenDecimals == 18` in the constructor; the deploy script
  asserts `szALPHA.decimals() == 18` on **both** chains. Cross-chain conservation depends on equal decimals.
- **Immutable canonical RMN (security MED-10):** `rmnProxy` is set from the canonical ARMProxy (964
  `0x02A4D69cFfeC00Fbf7F3B60c93e3529Dfc58894d`, Base `0xC842c69d54F83170C42C4d556B4F6B2ca53Dd3E8`) and immutable; if
  Chainlink rotates the RMN the pool is redeployed (deliberate).
- **OffRamp validation:** rely on the **standard CCT `_onlyOffRamp` / `router.isOffRamp`** path (do NOT hardcode
  offRamp addresses — they rotate on legit CCIP upgrades). Document the trust assumption in the report.
- **Rate-limiter:** set per-lane **post-deploy** via `applyChainUpdates` (item 3) under the timelock — do not
  hardcode; the values are an ops decision.

### 3. `contracts/src/interfaces/bridge/` — extend

Alongside `IXAlphaRate.sol` (already exists, `exchangeRate()` — confirmed the CRE-03 shape), add the minimal
interfaces the wire lib calls (verified present in `reference/chainlink-ccip`): `IRegistryModuleOwnerCustom`
(`registerAdminViaGetCCIPAdmin(address)`), `ITokenAdminRegistry` (`setPool(address,address)`, `acceptAdminRole(address)` —
both confirmed to exist). Keep minimal — only the selectors the lib touches.

### 4. `contracts/script/DeploySzAlphaBridge.s.sol` — deploy + wire (both chains, self-serve, no allowlisting)

| Contract (v) | Bittensor mainnet (964) | Base mainnet (8453) |
|---|---|---|
| Router (1.2.0) | `0xD941fBEcD2b971d0F54b4C34286C95faB52B60B8` | `0x881e3A65B4d4a04dD529061dd0071cf975F58bCD` |
| TokenAdminRegistry (1.5.0) | `0xe72d25aDd538E8ef9CeF85622eA8912a6CB98Be6` | `0x6f6C373d09C07425BaAE72317863d7F6bb731e37` |
| RegistryModuleOwnerCustom (1.6.0) | `0xcDca5D374e46A6DDDab50bD2D9acB8c796eC35C3` | `0xAFEd606Bd2CAb6983fC6F10167c98aaC2173D77f` |
| TokenPoolFactory (1.5.1) | `0x8FE3B17E6B0863aeEA3D38DF063AEa39D4Ab1602` | `0xcD66e8e103D05BC3a5059746283949A45C594D16` |
| ARMProxy / RMN (1.0.0) | `0x02A4D69cFfeC00Fbf7F3B60c93e3529Dfc58894d` | `0xC842c69d54F83170C42C4d556B4F6B2ca53Dd3E8` |
| feeTokens | LINK, WTAO | GHO, LINK, WETH |

Selectors (`chain-selectors`): 964 = `2135107236357186872`, Base 8453 = `15971525489660198786`.

Per chain: deploy token (`SzAlpha` on 964 / `SzAlphaMirror` on Base) → deploy pool → `token.grantMintAndBurnRoles(pool)`
→ `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin(token)` → `TokenAdminRegistry.acceptAdminRole(token)` →
`TokenAdminRegistry.setPool(token, pool)` → `pool.applyChainUpdates(uint64[] toRemove, ChainUpdate[] toAdd)` where
`ChainUpdate = {remoteChainSelector, remotePoolAddresses[], remoteTokenAddress, outboundRateLimiterConfig,
inboundRateLimiterConfig}` and `RateLimiter.Config = {isEnabled, capacity, rate}` per direction (struct shapes
ref-verifier-confirmed).
**Deploy-script asserts (ALL required, abort on any mismatch — do NOT wire until all pass):** `owner() == timelock` on
token + pool; `token.decimals() == 18` on both chains; `pool.getRmnProxy() == canonical`; and **re-read and assert
ALL FIVE CCT addresses on-chain match the table** — Router, TokenAdminRegistry, RegistryModuleOwnerCustom,
TokenPoolFactory, ARMProxy (per chain; the table is from a 2026-05-21 clone). A single re-read is insufficient — a
mis-wired registry module passes a router-only check.

### 5. `contracts/test/bridge/SzAlphaBridge.t.sol` — fork test (+ mocks)

Split into a fork-real suite and a mock suite with an explicit gate (so CI errors loudly, never silently passes
mocks-as-real). Subtensor EVM fork RPC + chainId must be wired in `foundry.toml`/`.env.example`; if no public
Subtensor fork node is available, the precompiles are mocked **and the test name/log says MOCK** — state the chosen
fallback in the report.

**Wrapper (Subtensor fork or mock) — each S# below is backed by a named test:**
- `deposit` lands stake on our validator under the wrapper coldkey; correct shares minted at rate. `redeem` unstakes
  + burns + returns alpha; rate moves as `totalStaked` accrues.
- **`test_firstDeposit_oneToOne_noDivByZero` (S3):** at genesis `exchangeRate() == 1e18` and the first `deposit`
  mints `amount × (supply + 1) / (stake + 1)` (virtual-offset) with no divide-by-zero — no `address(0)` dead-share
  mint; an out-of-band stake to the validator before the first depositor does **not** skew the rate in an attacker's
  favor (`test_inflationDefense_*`).
- **`test_roundingFavorsProtocol` (S3):** 100 deposit/redeem cycles at varying rates; assert byte-exact
  `Σ alphaOut ≤ Σ alphaIn` (any dust is the user's loss, never a user gain).
- **`test_mintVerifiesAddStakeEffect` (S4):** mock `addStake` to return success without raising `getStake` →
  `deposit` reverts `AddStakeEffectMissing`, alpha not lost.
- **`test_redeemVerifiesRemoveStakeEffect` (S4):** mock `removeStake` to no-op → `redeem` reverts
  `RemoveStakeEffectMissing`; funds recoverable (atomicity).
- **`test_coldkeyImmutable` (S5):** coldkey derived at init is cached; a later AddressMapping returning a different
  value does not change it.
- **`test_upgradeRevertsIfNotTimelock` (S1):** `_authorizeUpgrade`/`upgradeToAndCall` from a non-timelock caller
  reverts; storage-gap layout holds across a V1→V2 upgrade (no slot collision).
- **Zero-amount** `deposit(0)`/`redeem(0)`: revert or clean no-op, state unchanged.
- **Stake slashed/dropped:** redeem still works at the descended rate (stake not trapped).
- **Reentrancy:** precompile callback into `deposit`/`redeem` → `nonReentrant` reverts.
- **Authority negatives:** non-pool ERC-20 `mint`/`burn` revert; non-owner `grantMintAndBurnRoles` / `_authorizeUpgrade`
  / pause revert; **`redeem` works while paused**.

**Lane (Base fork + `CCIPLocalSimulatorFork`, pattern from `ccip-starter-kit-foundry/test/fork/CCIPv1_5BurnMintPoolFork.t.sol`):**
- Register the pool; send `szALPHA` 964→8453 and 8453→964; assert burn-on-source / mint-on-dest and **supply
  conservation both directions** (exact, since 18-dp both sides — assert equality, no tolerance).
- **Rate-limiter:** at-capacity succeeds; +1 over reverts; refill applied before the next send.
- **Replay:** re-injecting the same CCIP message reverts (no double-mint).
- **RMN:** a cursed RMN blocks mint (`CursedByRMN`).
- Base mirror: confirm it has **no** stake/redeem path (the precompile logic is absent on 8453).

---

## Build constraints / cited facts (ref-verifier-confirmed)

- Precompiles (`reference/subtensor/precompiles/src/solidity/`): **StakingV2 `0x805`** —
  `addStake(bytes32 hotkey, uint256 amount, uint256 netuid)` / `removeStake(bytes32,uint256,uint256)` /
  `getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) returns (uint256)`; **AddressMapping `0x80c`** —
  `addressMapping(address) returns (bytes32)`; **BalanceTransfer `0x800`**; **Metagraph `0x802`**. Addresses match
  the Rust INDEX (2053/2060/2048/2050).
- Selectors (`chain-selectors/selectors.yml`): 964 / `2135107236357186872`; Base 8453 / `15971525489660198786`.
  Live lane exists (GTV's xSN* tokens) — onRamp `0xf09AFe78d3c7d359b334d7cB88995751F7eC5E13`, offRamp
  `0xA27056438FfA1f286AB197488808692F0db93F8B` (v1.6.0).
- No native unbonding in dTAO; `lock_stake` (~365-day decay) = treasury policy, not built here.

## Security requirements (load-bearing — from the security critic; HIGH must block sign-off)

| # | Sev | Requirement |
|---|---|---|
| S1 | HIGH | Owner = TimelockController from genesis; no bare-EOA upgrade window. Deploy-script asserts `owner()==timelock`. |
| S2 | HIGH | `mint`/`burn` revert unless `msg.sender == ccipPool` (immutable). No generic role / onlyOwner mint. |
| S3 | HIGH | First-mint anti-dilution (dead-shares); rounding favors protocol on mint AND redeem. |
| S4 | HIGH | Verify the observable alpha-balance effect after every `addStake`/`removeStake`; revert if missing. |
| S5 | MED | Pooled coldkey derived once at init; no per-user SS58, no owner-settable mapping override. |
| S6 | MED | Validator-delegate change: prefer immutable-after-init; if exposed, ≥7-day timelock + cancel + zero-delegate fuse. |
| S7 | MED | Rate-limiter / pool config changes only via timelock. |
| S8 | MED | 18 decimals on both chains; asserted in pool constructor + deploy script. |
| S9 | MED | Immutable canonical RMN; assert in constructor; redeploy (not mutate) on RMN rotation. |
| S10 | LOW | `nonReentrant` + CEI on mint/redeem. |
| S11 | LOW | `Pausable` on mint; redeem never pausable. |

## Cross-ticket obligations

- **CRE-03** (§8.6/§8.8) consumes `IXAlphaRate.exchangeRate()` — SzAlpha MUST implement that exact interface. The
  APR figure is CRE-computed off-chain (`tickets/bridge/8x-02-xalpha-apr-cre.md`), not an on-chain method here.
- **8-B6 / RecycleModule (8-B10)** hold the `zipUSD/xALPHA` Hydrex LP, consuming `szALPHA` as the `xALPHA` leg — run
  against the stand-in until this ships; confirm the stand-in interface == `szALPHA` (18-dp ERC-20 + `IXAlphaRate`).
- **M2-01 `LienXAlphaEscrow`** (`8-Bx`) holds `szALPHA` — same token, no extra surface here.
- **Treasury (post-M1):** validator emissions, pool seeding, peg-arb, `lock_stake`, any fee — explicitly NOT here.

## References

- Reference (cloned, read-only): `reference/subtensor/precompiles/src/solidity/`,
  `reference/evm-bittensor/solidity/stakeV2.sol`, `reference/chainlink-ccip/chains/evm/contracts/pools/`
  (`BurnMintTokenPool.sol`, `TokenPool.sol`) + `.../interfaces/ITokenAdminRegistry.sol` +
  `.../tokenAdminRegistry/RegistryModuleOwnerCustom.sol`, `reference/ccip-starter-kit-foundry/test/fork/`,
  `reference/chainlink-local/src/ccip/`, `reference/chain-selectors/selectors.yml`,
  `reference/documentation/src/config/data/ccip/v1_2_0/mainnet/chains.json`.
- Memory: [[rubicon-fork-and-closed-loop]], [[zipcode-subnet-role]], [[supply-side-redesign-locked]],
  [[hydrex-gauge-architecture]].

---

> **Revision note (2026-06-09):** TWO adversarial-spec critic rounds (junior-dev / spec-fidelity / ref-verifier /
> qa / security). **Round 1** added the pooled-staker model, Base mirror, S1–S11, expanded tests. **Round 2**
> converged: zero spec gaps both rounds; the one build-critical finding was the `deposit`-vs-`mint` path collision
> (now split + named); plus S4 tightened to both stake directions, dead-shares pinned to `1e3`, Base mirror locked
> to a separate `SzAlphaMirror.sol`, all 5 deploy asserts enumerated, timelock delays pinned, 6 named test
> skeletons added. Ref-verifier re-confirmed every signature/struct/selector/address. Round 2's fixes are
> clarifications of already-intended surface (per §3a, a strict tightening) — **no third re-fan required;
> build-ready.**
>
> **BUILD NOTE (2026-06-09) — BUILT-VERIFIED + KEPT (`reports/8x-01-report.md`).** Three build-exposed
> corrections were folded into the kept code (the code is the source of truth per keep-the-build); this
> ticket's prose above is superseded on these three points:
> 1. **Registration uses `registerAdminViaGetCCIPAdmin`, NOT `registerAdminViaOwner`** (§4 table). The
>    canonical `BurnMintERC20` (the Base mirror) is AccessControl-based with **no `owner()`**, and
>    `SzAlpha.owner()` is the TimelockController from genesis — so the CCIP registrar is the **separate
>    `ccipAdmin` role** (returned by `getCCIPAdmin()`), distinct from the upgrade/owner authority. Both tokens
>    implement `getCCIPAdmin`.
> 2. **`SzAlpha` does NOT inherit `BurnMintERC20`** (deliverable 1). A UUPS proxy cannot use a
>    constructor-based, OZ-4.8.3-bound `BurnMintERC20`; `SzAlpha` is a fresh OZ-Upgradeable (5.1.0) token that
>    *implements* the `IBurnMintERC20` surface (`mint`/`burn`x2/`burnFrom`/`grantMintAndBurnRoles`/
>    `getCCIPAdmin`). Only the immutable **Base mirror** inherits the canonical `BurnMintERC20`.
> 3. **Anti-dilution = OZ ERC-4626 virtual offset, NOT "mint 1e3 dead shares to `address(0)`"** (HIGH-3).
>    Minting to `address(0)` reverts in OZ and would not prevent the first-deposit div-by-zero; the virtual
>    offset (virtualShares=1/virtualAssets=1) is the real OZ pattern — genesis 1:1, no div-by-zero, rounds to
>    the protocol. The pooled-staker model makes a third-party donation **structurally impossible** (stake is
>    coldkey-attributed; `getStake` reads only the wrapper's coldkey), the strongest defense.
>
> Also: precompiles are called **low-level** (`call`/`staticcall` + `encodeWithSelector`) — a typed call never
> reaches the runtime precompile (`stakeV2.sol`); the reference `stakingV2.sol` has a trailing-comma syntax
> error, so minimal local ABIs are authored. The OZ version seam ("8x exception") is resolved via versioned
> `@4.8.3`/`@5.3.0` remap prefixes + a context-scoped OZ-Upgradeable 5.1.0 — no core OZ/solc bump.
