# interfaces-euler — local Euler/zipUSD interface shims (wiring map)

> Source of truth = the kept code under `contracts/src/interfaces/euler/`. Reads the three files as
> their final form and records what each shims, the exact declared surface, who consumes it, and the
> seam gotchas. Folder consists of three files: `IEulerEarn.sol`, `IEulerEarnUtil.sol`, `IZipUSD.sol`.

## Role
The WOOF-00 `[EXT]` house posture in concrete form: minimal LOCAL declarations (only the methods we
call) pinned to solc **0.8.24**, so the 0.8.24 engine build never imports the OZ-5.x Euler tree
(`EulerEarn` source pins exact 0.8.26 → mocked in tests, never compiled — WOOF-00 §"compiled vs
interfaced"). Two of the three are **external shims** onto the live/forked Base EulerEarn senior pool;
one is an **internal seam** onto our own zipUSD `ESynth`. SPDX `GPL-2.0-or-later` on all three.

## Catalog

### IEulerEarn.sol — EXTERNAL shim (EulerEarn ERC-4626 senior pool, write+read)
Shims the external EulerEarn ERC-4626 vault over USDC — the §4.5/§8.2 senior-backing pool. Signatures
verified against `reference/euler-earn/src/EulerEarn.sol` (solc 0.8.26, NEVER imported/compiled; mocked
in tests). Fuller surface than the util face: the warehouse deposit/redeem write path + the NAV-mark
read path.
```
function deposit(uint256 assets, address receiver) external returns (uint256 shares);   // EulerEarn.sol:560, reverts ZeroShares on 0-share mint :565
function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets); // :596, owner = 3rd arg, redeem(0) no-op :604
function convertToAssets(uint256 shares) external view returns (uint256 assets);        // ERC-4626 read (NAV mark)
function balanceOf(address account) external view returns (uint256);
function asset() external view returns (address);
```
Consumed by (the two importers of THIS folder file, `import {IEulerEarn} from ".../interfaces/euler/IEulerEarn.sol"`):
- `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol` — builds calldata via
  `IEulerEarn.deposit.selector` (:155) and `IEulerEarn.redeem.selector` (:163, owner=safe=safe) for the
  warehouse Safe to execute.
- `contracts/script/CreditWarehouseDeployer.sol` — the deploy/wire script for the warehouse senior pool.

NOT consumers of this file (each declares its OWN `IEulerEarn`, not the folder shim — name collision):
- `contracts/src/supply/ZipDepositModule.sol` — declares a local `interface IEulerEarn` inline (:18),
  uses only `deposit` (:121,:138).
- `contracts/src/supply/szipUSD/RecycleModule.sol` — declares a local `interface IEulerEarn` inline
  (:28), uses only `deposit` (:301).
- `contracts/src/venue/EulerVenueAdapter.sol` — imports the REAL remapped
  `euler-earn/interfaces/IEulerEarn.sol` (+ `MarketAllocation`), not the shim (venue tier is compiled).

### IEulerEarnUtil.sol — EXTERNAL shim (utilization read face)
The 3-view read-only face onto the same EulerEarn senior pool — ONLY what the DurationFreezeModule needs
to compute the donation-immune utilization `U` (§8.2/§11-B). Source same `EulerEarn.sol` (0.8.26, never
compiled). `maxWithdraw` accounts for live strategy liquidity (`_maxWithdraw` → `_simulateWithdrawStrategy`);
`convertToAssets`/`balanceOf` inherited from OZ `ERC4626`/`ERC20`.
```
function maxWithdraw(address owner) external view returns (uint256);      // assets owner's shares can withdraw RIGHT NOW (strategy-liquidity bounded)
function convertToAssets(uint256 shares) external view returns (uint256); // total backing assets `shares` represent (Σ expectedSupplyAssets)
function balanceOf(address account) external view returns (uint256);      // EulerEarn share balance (warehouse Safe holding the senior position)
```
Consumed by:
- `contracts/src/supply/szipUSD/DurationFreezeModule.sol` — `import {IEulerEarnUtil}` (:10), field
  `eulerEarn` documented as the donation-immune U source (:54), bound `IEulerEarnUtil e =
  IEulerEarnUtil(eulerEarn)` (:234). Computes `U = 1 − maxWithdraw(warehouse)/convertToAssets(balanceOf(warehouse))`.

### IZipUSD.sol — INTERNAL seam (zipUSD ESynth burn)
Shims OUR OWN zipUSD = Euler `ESynth` (18-dp) — the burn seam for the senior par-exit queue. NOTE: the
file declares **only `burn`** — NOT mint/setCapacity (the queue burns its own escrowed balance; it never
mints and needs no minter-capacity grant). Verified against
`reference/euler-vault-kit/src/Synths/ESynth.sol:81`.
```
function burn(address burnFrom, uint256 amount) external;
```
Consumed by:
- `contracts/src/supply/ZipRedemptionQueue.sol` — `import {IZipUSD}` (:9),
  `IZipUSD(zipUSD).burn(address(this), filledShares)` (:308,:315).

## Gotchas
- **EulerEarn is a pure allocator (donation-immune `U`):** `totalAssets() = Σ expectedSupplyAssets(strategy)`
  EXCLUDES idle/stray USDC, and `maxWithdraw` is strategy-liquidity-bounded. A stray-USDC donation to the
  pool address moves NEITHER term of `U = 1 − maxWithdraw/convertToAssets(balanceOf)` → the §11-B
  "not outsider-manipulable" guarantee the DurationFreezeModule U read depends on. **NEVER read
  `balanceOf(eulerEarn)`** — read `balanceOf(warehouse)`.
- **Name collision, not reuse:** three contracts declare/import a DIFFERENT `IEulerEarn` than the folder
  shim (ZipDepositModule + RecycleModule inline-declare their own; EulerVenueAdapter imports the real
  remapped one). The folder `IEulerEarn.sol` has exactly TWO importers: WarehouseAdminModule + the
  CreditWarehouseDeployer script.
- **EulerEarn never compiled:** source pins exact solc 0.8.26 vs the 0.8.24 engine profile → mocked in
  tests, forked on Base mainnet (8453) in integration. These shims exist solely to avoid importing it.
- **IZipUSD needs no allowance / no minter grant:** when `burnFrom == _msgSender()` (queue burning its
  OWN escrow, `burnFrom == address(this) == caller`) `ESynth._spendAllowance` (:91) is SKIPPED; `burn`
  only decrements `minters[sender].minted` with an underflow-safe floor (stays 0 for a non-minter queue);
  `burn(·,0)` is a silent no-op (:85). zipUSD transfers go via OZ `IERC20`/`SafeERC20`, not this seam.
- **NatSpec `@word` trap (WOOF-00):** none of these files use a bare `@word` in `///` comments (would be
  read as a NatSpec tag and fail the build).
