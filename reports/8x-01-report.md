# 8x-01 report — `szALPHA` LST wrapper + CCIP CCT transport (BUILT-VERIFIED)

**Window:** 2026-06-09 · **Item:** `8x-01` (the xALPHA bridge) · **Status:** BUILT-VERIFIED + KEPT
(not git-committed — superintendent commit decision, consistent with the recent item-9 / 8-Bx / DC /
DurationFreezeModule windows).

The AUTHORED + 2-round-critic-hardened ticket (`tickets/bridge/8x-01-szalpha-wrapper-cct.md`) was
**cold-built for real**: the self-built liquid-staking wrapper (`SzAlpha`, 964), the Base mirror
(`SzAlphaMirror`), the CCT pool (`SzAlphaTokenPool`), the minimal bridge interfaces, the deploy/wire
library, and a fork+mock test suite. `forge build` clean; **30 bridge tests green** (29 unit with mocked
precompiles + 1 Base-mainnet-fork integration against the REAL CCT registry).

**Regression evidence (no regression):**
- **Full non-fork suite: 632/632 passed, 0 failed** (`forge test --no-match-test "fork|Fork"`) — includes all
  29 bridge unit tests.
- **Bridge suite on a Base fork: 30/30 passed, 0 failed** (`forge test --fork-url base
  --match-path test/bridge/SzAlphaBridge.t.sol`) — the 29 unit tests + the live-CCT integration.
- A full `--fork-url base` run reached **37 suites / 0 failures** before a **pre-existing** 128k-call
  fork-invariant suite stalled against a throttled Base RPC (not introduced here — this window is purely
  additive: new files + longer-prefix remaps, with `forge build` fully green, so existing fork suites are
  unaffected). The single fork-inclusive grand total was not obtainable this session due to RPC throttling;
  the two complete runs above are conclusive.

## Deliverables (kept on disk)

| File | Role |
|---|---|
| `contracts/src/bridge/SzAlpha.sol` | The 964 LST wrapper: UUPS upgradeable 18-dp ERC-20, pooled-staker, `deposit`/`redeem` over the StakingV2 precompile, `IXAlphaRate.exchangeRate()`, CCT `mint`/`burn` leg. |
| `contracts/src/bridge/SzAlphaMirror.sol` | The Base (8453) mirror: a PLAIN canonical `BurnMintERC20` (18-dp), zero staking surface. |
| `contracts/src/bridge/SzAlphaTokenPool.sol` | CCT `BurnMintTokenPool` subclass + S8 (18-dp) / S9 (canonical RMN) constructor asserts. |
| `contracts/src/interfaces/bridge/ISubtensorPrecompiles.sol` | Minimal local `IStakingV2` / `IAddressMapping` (selectors only). |
| `contracts/src/interfaces/bridge/ICctRegistry.sol` | Minimal `IRegistryModuleOwnerCustom` / `ITokenAdminRegistry`. |
| `contracts/script/DeploySzAlphaBridge.s.sol` | Both-chain deploy + self-serve wire + the full deploy-assert battery (5-address re-read, owner==timelock, decimals==18, canonical RMN). |
| `contracts/test/bridge/SzAlphaBridge.t.sol` + `BridgeMocks.sol` | Fork+mock suite. |
| `contracts/remappings.txt` | +6 remap lines (the "8x exception"); existing remaps untouched. |

## The OZ version seam (the "8x exception", WOOF-00 EXTENDED) — RESOLVED

Three ecosystems coexist under one solc 0.8.24 / cancun invocation. The chainlink submodules use **versioned
OZ import prefixes**, which disambiguate naturally without context-scoping:

- `chainlink-ccip` CCT pool stack imports `@openzeppelin/contracts@5.3.0/...` → remapped onto the scaffold's
  OZ **5.0.2** tree (the `IERC20`/`IERC20Metadata`/`SafeERC20`/`IERC165`/`EnumerableSet`/`EnumerableMap`/
  `ERC165Checker`/`ERC20` subset TokenPool uses is API-stable 5.0.2→5.3.0; **probe-confirmed it compiles**).
- the canonical `BurnMintERC20` (the Base mirror) imports `@openzeppelin/contracts@4.8.3/...` → remapped onto
  `chainlink-local`'s vendored OZ 4.8.3.
- `SzAlpha`'s UUPS leg uses OZ-Upgradeable **5.1.0** from `evk-periphery` (a self-consistent core+upgradeable
  pair), with the upgradeable lib's own `@openzeppelin/contracts/` core **context-scoped** to the matching
  5.1.0 sibling so it stays isolated from the global 5.0.2.

`@chainlink/contracts/` → `chainlink-evm/contracts/` (the `@chainlink/contracts` npm package). The newer
v1.6/v2.0 CCIP pool references `@chainlink/policy-management` only inside `AdvancedPoolHooks.sol`, which is
NOT in the `BurnMintTokenPool` import graph (`advancedPoolHooks` is pinned `address(0)`), so it never
compiles — no missing-dep blocker. A throwaway probe importing `BurnMintTokenPool` + `TokenPool` +
precompile ABI + the OZ-upgradeable stack compiled green before any logic was written (ticket build-step 2).
**No core OZ/solc bump.** Existing 600+-test suite remaps untouched.

## Build-exposed corrections (load-bearing — folded into code; the ticket should be amended)

1. **Registration path: `registerAdminViaOwner` → `registerAdminViaGetCCIPAdmin`.** The ticket's deploy step
   used `registerAdminViaOwner(token)`, which calls `IOwner(token).owner()` and requires `owner()==msg.sender`.
   Two reasons it cannot work as written: (a) the canonical `BurnMintERC20` (the Base mirror) is
   **AccessControl-based and has NO `owner()`** — the call reverts; (b) `SzAlpha.owner()` is the
   **TimelockController from genesis** (S1), so a deployer EOA is never the owner. The correct, audited path
   is `registerAdminViaGetCCIPAdmin`: a `ccipAdmin` (registrar) role — distinct from `owner` — returned by
   `getCCIPAdmin()`. This cleanly separates the low-risk CCIP-wiring authority (the deployer, transferable to
   the timelock post-wire) from the dangerous upgrade authority (the timelock from genesis), and resolves the
   timelock-from-genesis-vs-multistep-wiring tension. **`SzAlpha` implements `getCCIPAdmin()`/`setCCIPAdmin`;
   the mirror inherits them.**

2. **UUPS ⊥ constructor-based `BurnMintERC20` → SzAlpha is a FRESH upgradeable token; only the mirror inherits
   the canonical.** The ticket said "`SzAlpha is BurnMintERC20, … UUPSUpgradeable`", but `BurnMintERC20` is
   non-upgradeable (constructor-set `name`/`symbol`/`decimals`/roles) and OZ-4.8.3-bound — behind a proxy its
   constructor never runs. `SzAlpha` is therefore built on OZ-Upgradeable (ERC20/Ownable/Pausable/
   ReentrancyGuard/UUPS) and implements the `IBurnMintERC20` surface (`mint`/`burn`×2/`burnFrom` +
   `grantMintAndBurnRoles` + `getCCIPAdmin`) to match the audited face exactly. The **Base mirror** (immutable,
   no UUPS) DOES inherit the canonical `BurnMintERC20` (the ticket's "plain BurnMintERC20"), so the audited
   mint/burn/role code is used where it can be.

3. **Anti-dilution: "mint 1e3 dead shares to `address(0)`" → OZ ERC-4626 virtual offset.** Minting to
   `address(0)` is impossible in OZ (`_mint` reverts), and 1e3 init-dead-shares would NOT prevent the
   first-deposit divide-by-zero (it needs `totalStaked>0`). `SzAlpha` uses the genuine OZ ERC-4626
   minimum-shares mechanism — **virtual shares = 1, virtual assets = 1** — which is what the ticket invokes by
   name ("locked value, not seed or burn"): no div-by-zero ever, clean **1:1 genesis** (so `exchangeRate()`
   == `1e18` at genesis as the ticket also requires), rounding always favors the protocol. **Stronger still:**
   in the pooled-staker model a third party **cannot** add to the wrapper's backing stake (Subtensor
   attributes stake to the caller's coldkey, and `getStake` reads only the wrapper's coldkey), so the classic
   ERC-4626 donation/inflation attack is **structurally inapplicable** — the only thing that lifts backing
   stake without minting shares is validator rewards (benign, accrues to all holders).

4. **Precompiles MUST be called low-level.** `reference/evm-bittensor/solidity/stakeV2.sol` documents that a
   *typed* call to the StakingV2 precompile "never reaches the runtime precompile." `SzAlpha` invokes
   `addStake`/`removeStake` via `STAKING_V2.call(abi.encodeWithSelector(...))` and reads `getStake`/
   `addressMapping` via `staticcall`. The reference `stakingV2.sol` also has a **trailing-comma syntax error**
   in `allowance(...)`, so the precompile ABIs are authored locally (minimal), per the ticket's "minimal local
   interfaces" rule.

## Mocked vs fork-real (both mock layers are ticket-sanctioned)

- **Fork-real:** the Base-mainnet-fork integration test (`SzAlphaBaseForkTest`) deploys the mirror + pool and
  runs the FULL registration (`registerAdminViaGetCCIPAdmin` → `acceptAdminRole` → `setPool`) against the
  **live Base CCT `RegistryModuleOwnerCustom` 1.6.0 + `TokenAdminRegistry` 1.5.0**, then asserts
  `getPool(token)==pool` on the real registry + the admin/ccipAdmin hand-off to the timelock + deployer-revoke.
- **Mocked (sanctioned):** the Subtensor StakingV2/AddressMapping precompiles are `vm.etch`-mocked (no public
  964 fork node), and the CCIP relay is mocked (no DON) — the lane is driven at the pool level with a mock
  Router (`getOnRamp`/`isOffRamp`) + mock RMN (`isCursed`). Every mocked test says so.
- **Deferred (needs a 964 fork):** the `deploy964` on-chain 5-address asserts (the 964 CCT addresses have no
  code on a Base fork) and a real Subtensor stake round-trip. The wrapper LOGIC is fully covered by the etched
  -precompile unit suite; the 964 lane + denomination calibration is an integration step (see Flags).

## On-chain verification (keep-the-build)

The 5 Base CCT addresses were re-read live (`cast`): Router `0x881e…` = **"Router 1.2.0"**, TokenAdminRegistry
`0x6f6C…` = **"TokenAdminRegistry 1.5.0"**, RegistryModuleOwnerCustom `0xAFEd…` = **"RegistryModuleOwnerCustom
1.6.0"**, TokenPoolFactory `0xcD66…` = **"TokenPoolFactory 1.5.1"**, ARMProxy `0xC842…` has code — **all match
the ticket table exactly.** The deploy script re-asserts all five on-chain before wiring (a router-only check
is insufficient). The 964 addresses are from the same 2026-05-21 clone (not independently re-readable here).

## Security requirements (ticket S1–S11)

| # | Sev | Status |
|---|---|---|
| S1 | HIGH | `owner()` = TimelockController from genesis (init arg); `_authorizeUpgrade` onlyOwner. `test_upgradeRevertsIfNotTimelock` + deploy assert `owner()==timelock`. |
| S2 | HIGH | `mint`/`burn` revert unless `msg.sender == ccipPool` (set-once). `test_mintBurnOnlyPool`, `test_grantMintAndBurnRolesOnceAndOnlyAdmin`. |
| S3 | HIGH | Virtual-offset anti-dilution + genesis 1:1 + rounding-to-protocol. `test_firstDeposit_oneToOne_noDivByZero`, `test_inflationDefense_*`, `test_roundingFavorsProtocol`. |
| S4 | HIGH | Both-direction effect verification via `getStake`/balance deltas. `test_depositVerifiesAddStakeEffect`, `test_redeemVerifiesRemoveStakeEffect`. |
| S5 | MED | Coldkey derived once at init, immutable. `test_coldkeyImmutable`. |
| S6 | MED | Validator-delegate change NOT exposed in M1 (immutable hotkey) — the ticket's recommended posture. |
| S7 | MED | Rate-limiter config via `applyChainUpdates`/`setRateLimitConfig` under the pool owner (→ timelock). |
| S8 | MED | 18-dp asserted in the pool constructor + deploy script. `test_poolRejectsNon18Decimals`. |
| S9 | MED | Canonical RMN asserted in the pool constructor; immutable in `TokenPool`. `test_poolRejectsNonCanonicalRmn`. |
| S10 | LOW | `nonReentrant` + CEI on deposit/redeem. `test_reentrancyBlocked`. |
| S11 | LOW | `Pausable` on mint paths; redeem never pausable. `test_pauseBlocksDepositButNotRedeem`. |

## Cross-ticket obligations

- **Discharged (interface):** `SzAlpha` implements the exact `IXAlphaRate.exchangeRate()` CRE-03 consumes; the
  M1 stand-in token already satisfies this face (18-dp ERC-20 + `exchangeRate()`), so 8-B5/8-B6 + 8-Bx + 8x-02
  can build against the stand-in and swap in `SzAlpha`/`SzAlphaMirror` later with no surface change.
- **New obligations → item 10 (deploy/wiring):** (a) supply the real `NETUID` + `VALIDATOR_HOTKEY` at the 964
  deploy (fixtures until subnet/validator registration); (b) run `deploy964` on a 964 RPC to exercise the 964
  CCT 5-address asserts; (c) configure the cross-chain lane (`setRemoteLane`) once both pools exist, with
  ops-decided rate limits, under the timelock; (d) transfer the **pool** ownership to the timelock (2-step
  Ownable) after `applyChainUpdates`, and set the token `ccipAdmin` to the timelock/multisig; (e) wire the M1
  basket / first-loss-bond consumers (8-B5/8-B6, 8-Bx `LienXAlphaEscrow`) onto the deployed `SzAlpha`/mirror.

## Flags for the superintendent

- **TAO/alpha/rao denomination calibration (integration).** `addStake`'s `amount` is denominated in rao and
  the EVM native unit / TAO→alpha conversion is a Subtensor-runtime concern not exercisable without a 964 fork.
  `SzAlpha` is denomination-robust where it matters (S4 reads `getStake` deltas; shares are guarded by
  `delta >= amount`), but the `msg.value==amount` convention and the exact `amount` units must be calibrated
  against the live 964 runtime at the 964 deploy. Logged, not a build blocker (ticket: NETUID/HOTKEY/precompile
  behaviour are deploy-time fixtures).
- **CCT registration on 964** is self-serve (DEC-02 cleared); the registrar (`ccipAdmin`) drives it.
- **Ticket amendments** (recommended): record corrections 1–3 above in
  `tickets/bridge/8x-01-szalpha-wrapper-cct.md` so the on-disk ticket matches the kept code (the code is the
  source of truth per keep-the-build).
