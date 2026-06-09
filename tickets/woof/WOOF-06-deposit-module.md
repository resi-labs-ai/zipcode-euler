# WOOF-06 — `ZipDepositModule` (the zap) (§4.5) — RE-AUTHORED (two-token / Exit Gate)

> **RE-AUTHORED 2026-06-07 to the two-token / Exit-Gate model (`reports/design/baal-spec.md` §2/§3/§4/§5). Build from THIS ticket.**
> This supersedes the 2026-06-06 re-author (Baal + `CreditWarehouse`, which minted **Loot on-behalf to the user**).
>
> **Surgical change — only the junior seam flips:**
> - the zap's stake leg now calls **`IZipExitGate.depositFor(zipUSD, zipAmount, user)`** (the **Exit Gate**, §4/§5,
>   which absorbs the old 8-B2 mint shaman + holds Baal `manager`=2);
> - the Gate mints **Loot to ITSELF** and mints the **transferable `szipUSD` share to the user**, **NAV-proportional**
>   (priced via `SzipNavOracle`, §3 — round-down, staleness-guarded), and returns the **`shares`** minted;
> - events/previews/fail-closed move from `loot` → **`shares`**; `ZeroLoot` → **`ZeroShares`**; the wired target
>   `stakingVault` → **`gate`**.
>
> **PRESERVED VERBATIM (do NOT re-derive):** the `deposit`/`zap` dual path (`zap` = default UX; plain `deposit` =
> secondary raw-zipUSD); USDC → `EE_POOL.deposit(usdc, WAREHOUSE_SAFE)` (the `CreditWarehouse` Safe is the EE-share
> `receiver`; the module custodies **nothing**); the **decimals / `scaleUp`** ctor derivation (ESynth 18-dp,
> USDC 6-dp, **derived — no literal `1e12`**); the **per-zap exact zipUSD allowance** (D1); the F1
> (`ResidualBalance`) / F2 / F3-F10 (deploy-wiring asserts before `setCapacity`) / F7 (`forceApprove`) hardening; the
> Permit2 fallback resolution; `nonReentrant`; **no `ReceiverTemplate`/EVC/`Ownable`/Forwarder** (user-called).
>
> **STATUS: BUILT-VERIFIED 2026-06-08 — materialized + KEPT on disk against the REAL Exit Gate seam (not a mock).**
> Code at `contracts/src/supply/ZipDepositModule.sol` + `contracts/test/ZipDepositModule.t.sol`; `forge build` green +
> **29/29 tests** (26 mock-gate adversarial unit + 3 real-gate Base-fork), **205/205 total no regression** (run
> `forge test --fork-url $BASE_RPC_URL`). Because 8-B1 / `SzipNavOracle` / the Exit Gate had landed, the headline zap
> path is proven end-to-end against the **LIVE** `ExitGate.depositFor` + real `SzipNavOracle` + real Baal substrate +
> the real zipUSD `ESynth` (suite `ZipDepositModuleRealGateTest`); a `MockGate` is retained ONLY for the adversarial
> gate behaviours the real Gate cannot exhibit (under-pull → `ResidualBalance`, no-share → `ZeroShares`, mid-call
> revert atomicity, reentrancy). **Build-discovered + fixed:** (1) the real `ExitGate` lacked the `previewDeposit`
> obligation this ticket created — **added it to the kept Gate** (`previewDeposit(asset, amount) view`, mirrors
> `depositFor` pricing; obligation DISCHARGED); (2) the real Gate routes the pulled zipUSD into the **main Safe
> basket** (`safeTransferFrom(module, mainSafe, …)`), not into the Gate itself — so the real-gate test asserts
> `zip.balanceOf(mainSafe)`, the mock-gate test asserts `zip.balanceOf(gateMock)` (both prove the module's
> full-pull/residual invariant). NOT git-committed (whole tree untracked — superintendent commit decision pending).

---

**Deliverable**
`contracts/src/supply/ZipDepositModule.sol` — `contract ZipDepositModule`. The supply-side mint+deposit router: the
**only** entry by which a supplier turns USDC into the protocol's two supply positions. `deposit(uint256 usdcIn)`
mints zipUSD **1:1 by value** (zipUSD = `ESynth`, the module is a capacity-granted minter) and parks the USDC in the
venue pool (`EulerEarn`) **with the `CreditWarehouse` Safe as the share `receiver`** — the module holds no shares.
`zap(uint256 usdcIn)` is the default UX: deposit → mint zipUSD (to the module, transient) → **auto-deposit into the
Exit Gate on behalf of the caller** in one atomic call, so the depositor lands directly in the headline junior
position (**transferable `szipUSD`**) without ever holding zipUSD or Loot. **`zap` is THE default action** — the
frontend "deposit/supply" button zaps into szipUSD (INFLOW-06 defaults to it); plain **`deposit` (raw zipUSD, no
stake) is the secondary path**, for protocols / contracts / integrations that specifically want the $1 utility token.
Both are permissionless; the contract exposes both, the UI leads with `zap`.

(**User-facing item — PROGRESS item 7 = build + interface.** Paired with `tickets/inflow/INFLOW-06-deposit-module.md`.
The module is called by *users* (permissionless `deposit`/`zap`), not by the CRE — no `ReceiverTemplate`, no
Forwarder, no `onReport`.)

**Spec §**
`reports/design/baal-spec.md` §4 (the generalized issuance core — `Gate.depositFor(asset, amount, receiver) → shares`, NAV-
proportional, round-down, the USDC-zap wrapper) + §5 (the Exit Gate) + §3 (`SzipNavOracle` — the share price) + §11
(the `CreditWarehouse`). Cross (target: `claude-zipcode.md` §4.5/§6.4/§7 after integration):
- **`CreditWarehouse` Safe (§11 / 8-Bw)** — the senior-backing Gnosis Safe that holds the `EulerEarn` shares backing
  un-staked zipUSD. This ticket depends only on the Safe **existing as an address** to pass as the deposit
  `receiver` (a ctor immutable). Its Roles-modifier admin is 8-Bw's concern; the module only **deposits TO** it.
- **The Exit Gate (§4/§5)** — the junior is a Baal/Zodiac vault: internal **Loot** is soulbound + held only by the
  Gate; the user share is **transferable `szipUSD`** the Gate mints 1:1 against its Loot. The Gate's
  `depositFor(asset, amount, receiver)` pulls the asset, **values it via `SzipNavOracle` (NAV-proportional, §3)**,
  mints Loot to itself, mints **`szipUSD` to `receiver`**, returns the `shares`. **The Gate + szipUSD + `SzipNavOracle`
  are PROGRESS item 8 (Baal backlog) — out of this ticket's scope; this ticket depends only on the Gate's
  `depositFor`/`previewDeposit` interface**, pinned below + owed back as a cross-ticket obligation.
- **`SzipNavOracle` (§3)** — the Gate reads it for the share price; the module never reads it directly (only via
  `gate.previewDeposit`). A transitive dependency.

Locked (do **NOT** touch): zipUSD = **$1 utility dollar** (a fixed claim, not a share); szipUSD = the main product
reached via the **zap** (now a **transferable** ERC20 share); the depositor's return is the **xALPHA + HYDX-vamp
subsidy**; the lending APR is the **protocol's** (→ treasury). This ticket adds **no** new economic decision — it is
the mint+route plumbing; **all NAV/pricing logic lives in the Gate + oracle, not here.**

---

## Design (the mint+deposit router)

**Shape.** A plain `contract ZipDepositModule` (no `ReceiverTemplate`, no `Ownable`, no EVC, no `BaseAdapter`).
**Four** constructor immutables (`zipUSD`, `usdc`, `eePool`, **`warehouse`**) + one **derived** immutable
`scaleUp` + `deployer` + one **set-once** `gate`. Two permissionless user entrypoints (`deposit`, `zap`), two view
previews (`previewDeposit`, `previewZap`), one deploy-time wiring setter (`setGate`). It holds **no per-user state and
custodies no assets** — value routes straight through: zipUSD is minted to the user (or, in the zap, minted
transiently and immediately handed to the Gate), USDC is deposited to the warehouse Safe, and **szipUSD is minted to
the user by the Gate**.

**Decimals (verified against `reference/` — load-bearing).** `ESynth` (zipUSD) reports **18 decimals** (OZ ERC20
default; `ESynth` ctor `(address evc_, string name_, string symbol_)` — **no decimals arg**,
`reference/euler-vault-kit/src/Synths/ESynth.sol:36-41`). USDC = **6 dp**. `EulerEarn` shares over USDC = **6 dp**
(the module is **share-count-agnostic**, so non-par live shares don't matter). **`szipUSD` = the transferable share,
18 dp** (a normal OZ ERC20 the Gate mints). "Mint 1:1" is **value**-1:1: `deposit(usdc)` mints `usdc * 1e12` zipUSD
(`1e12 = 10**(18−6)`). **Derive the scale in the ctor, do NOT hard-code `1e12`:** read
`IERC20Metadata(zipUSD).decimals()` and `IERC20Metadata(usdc).decimals()`, require `zipDec >= usdcDec`, store
`uint256 public immutable scaleUp = 10 ** (zipDec - usdcDec);`. The module is **decimals-agnostic on the EE-share
side** and **does not compute szipUSD share amounts** — the Gate does (NAV-proportional).

**Constructor.** `constructor(address zipUSD_, address usdc_, address eePool_, address warehouse_)` — store the four
`address public immutable` pointers, derive `scaleUp`, store `address public immutable deployer = msg.sender;`. Revert
on any zero address (`if (x == address(0)) revert ZeroAddress();`) for **all four**. `gate` starts `address(0)`
(un-wired). **No EVC, no Ownable, no Forwarder.**

> **`warehouse`** is the `CreditWarehouse` Safe address (8-Bw) — only ever passed as the `receiver` arg of
> `EE_POOL.deposit`; never read for identity. (Cold-build: a plain EOA test address suffices.)

### `setGate(address gate_)` — deploy-time, set-once (the Exit Gate seam)
The Gate is deployed/summoned **after** the module (it is the junior vault), so the module cannot take it as a ctor
immutable — wired once, after both exist:
- `if (msg.sender != deployer) revert NotDeployer();`
- `if (gate != address(0)) revert AlreadyWired();`  (set-once — no re-point)
- `if (gate_ == address(0)) revert ZeroAddress();`
- `gate = gate_;`
- `emit GateWired(gate_);`

**Design decision D1 (allowance — flag for security): approve-per-zap, NOT a standing zipUSD allowance.** `setGate`
grants **no** standing allowance. The zap grants the Gate an **exact-amount, fully-consumed zipUSD allowance** inside
each `zap` (step 7), so no standing approval exists between calls: (1) the dangerous asset is zipUSD the module mints
transiently — never an idle balance for a standing allowance to drain, and an exact per-zap approve consumed by the
same `transferFrom` leaves the allowance at 0 (assertable); (2) it shrinks what deploy/wiring must verify; (3) it
keeps the zap atomic (the Gate pulls via `transferFrom`, never calling back into the module). One extra `approve`
per zap (negligible). The Gate must still be the immutable / owner-renounced-or-timelock-governed contract item 10
verifies.

After `setGate` the module exposes **no** owner/admin surface — `deposit`/`zap` are permissionless; no
pause/upgrade/repoint. The `deployer` immutable's only power was this one set-once call.

### `deposit(uint256 usdcIn) returns (uint256 zipMinted)` — plain mint (user holds zipUSD)
1. `if (usdcIn == 0) revert ZeroAmount();`
2. `IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);` (OZ `SafeERC20`)
3. `zipMinted = usdcIn * scaleUp;`
4. `IESynth(zipUSD).mint(msg.sender, zipMinted);` — mint zipUSD **to the depositor**. Capacity-gated
   (`ESynth.setCapacity(module, …)`, item 10; reverts `E_CapacityReached`, `ESynth.sol:55/64-69`). `mint(·,0)` is a
   silent no-op (`:60-62`) → the `ZeroAmount` guard is load-bearing.
5. `IERC20(usdc).forceApprove(eePool, usdcIn); uint256 shares = IEulerEarn(eePool).deposit(usdcIn, warehouse);` —
   park the USDC with the **`CreditWarehouse` Safe** as the share `receiver`. `deposit(assets, receiver)` is standard
   ERC4626 (`EulerEarn.sol:560`): pulls `assets` from the module, mints shares **to `receiver`**, so the module never
   holds shares. Capture `shares` for return-discipline only (never re-used). **PERMIT2 — RESOLVED:** the real pull
   is `safeTransferFromWithPermit2` (`EulerEarn.sol:698`) which **falls back to standard `safeTransferFrom`** with no
   Permit2 pre-approval (`SafeERC20Permit2Lib.sol:46-50`), so plain `forceApprove(eePool, usdcIn)` is correct +
   sufficient — no separate Permit2 approval. (Confirm on live pool at integration; non-blocking; cold-builds MOCK
   EE.)
6. `emit Deposited(msg.sender, usdcIn, zipMinted);`

### `zap(uint256 usdcIn) returns (uint256 shares)` — the default UX (deposit → on-behalf szipUSD mint, atomic)
1. `if (usdcIn == 0) revert ZeroAmount();`
2. `if (gate == address(0)) revert NotWired();`
3. `IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);`
4. `uint256 zipAmount = usdcIn * scaleUp;`
5. `IESynth(zipUSD).mint(address(this), zipAmount);` — mint zipUSD **to the module** (transient — handed to the Gate
   in step 8; the module is the depositor-of-record into the Gate).
6. `IERC20(usdc).forceApprove(eePool, usdcIn); IEulerEarn(eePool).deposit(usdcIn, warehouse);` — USDC → venue pool,
   **warehouse Safe custodies the shares** (third-party `receiver`, same RESOLVED Permit2 path).
7. `IERC20(zipUSD).forceApprove(gate, zipAmount);` — grant the Gate an **exact-amount zipUSD allowance** (D1) via
   `SafeERC20.forceApprove`. The Gate pulls the module's freshly-minted zipUSD via `transferFrom` in step 8.
8. `shares = IZipExitGate(gate).depositFor(zipUSD, zipAmount, msg.sender);` — the **Exit Gate**: pulls `zipAmount`
   zipUSD **from the module** (adding it to the junior basket), **values it via `SzipNavOracle` (NAV-proportional,
   round-down, staleness-guarded, §3)**, mints **Loot to itself** + mints **`szipUSD` to `msg.sender`** (the end user
   — on-behalf; the module never holds Loot or szipUSD). Returns the **`shares`** (szipUSD) minted. **On-behalf:**
   pass `msg.sender` as `receiver`, NEVER `address(this)`.
9. **Enforce the "holds nothing" invariant in-contract (F1/F7):**
   - `if (shares == 0) revert ZeroShares();` — fail closed on a no-op/paused Gate (a `depositFor` minting no shares —
     e.g. a stale-oracle revert should propagate, but a silent 0 must not pass).
   - `if (IESynth(zipUSD).balanceOf(address(this)) != 0) revert ResidualBalance();` — the Gate must have pulled the
     **entire** `zipAmount`; a residual means it under-pulled → revert.
   - `IERC20(zipUSD).forceApprove(gate, 0);` — defensively reset the zipUSD allowance to 0.
10. `emit Zapped(msg.sender, usdcIn, zipAmount, shares);`

**Atomicity / reentrancy.** Guard both `deposit` and `zap` with OZ `ReentrancyGuard` (`nonReentrant`). The Gate's
`depositFor` pulls zipUSD via `transferFrom(module, …)`, which never calls back into a guarded module function. Do
**not** guard `setGate` (deploy-time, single-shot).

### Previews (read-only — the interface ticket's back-pressure)
- `previewDeposit(uint256 usdcIn) external view returns (uint256 zipMinted)` → `usdcIn * scaleUp`. **Must succeed
  un-wired** (does not depend on `gate`).
- `previewZap(uint256 usdcIn) external view returns (uint256 zipMinted, uint256 shares)` →
  `zipMinted = usdcIn * scaleUp; shares = IZipExitGate(gate).previewDeposit(zipUSD, zipMinted);`. Reverts `NotWired`
  if `gate == address(0)`. **Forces the Gate (item 8) to expose `previewDeposit(address asset, uint256 amount) view
  returns (uint256 shares)`** — an obligation on the Gate (the frontend quotes the user's expected szipUSD before
  signing). `previewZap`'s `shares` is an **estimate** (NAV moves between preview and tx; the §3 `max(spot,twap)`
  entry bracket) — label "≈".

---

**Model from (verified against `reference/`)**
- **`ESynth` (zipUSD) — `reference/euler-vault-kit/src/Synths/ESynth.sol` (local `IESynth`; do NOT inherit).**
  pragma `^0.8.0` → compiles under 0.8.24 → cold-build uses the **REAL `ESynth`** over a **live EVC**. Ctor 3-arg,
  **no decimals** → `decimals()` = OZ **18**. `mint(account, amount)` capacity-gated (`E_CapacityReached`), `mint(·,0)`
  silent no-op. **Local interface:** `interface IESynth { function mint(address,uint256) external; function
  balanceOf(address) external view returns (uint256); }`. zipUSD `approve` goes through `SafeERC20.forceApprove(IERC20(zipUSD), …)`.
- **`EulerEarn` (`EE_POOL`) — `reference/euler-earn/src/EulerEarn.sol` (local `IEulerEarn`; MOCKED).** pragma `0.8.26`
  (fixed) → **cannot compile in 0.8.24 → MOCK.** `deposit(assets, receiver)` (`:560`, ERC4626, `revert ZeroShares()`
  on dust). Permit2 pull (`:698`) → standard fallback (above). **Local interface:** `interface IEulerEarn { function
  deposit(uint256 assets, address receiver) external returns (uint256 shares); }`. **EE mock:** 6-dp ERC20; on
  `deposit` `transferFrom(msg.sender, this, assets)` (real custody) then `_mint(receiver, assets)` (par) and return
  `assets`; revert if `assets==0`. **Provide non-par mocks BOTH directions** (`*9/10`, `*11/10`) — each pulls the
  FULL `assets`, then mints scaled — to prove the module is share-count-agnostic.
- **Exit Gate (the stake seam) — PROGRESS item 8, NOT YET BUILT (interface-only; MOCKED). THIS ticket pins it:**
  `interface IZipExitGate { function depositFor(address asset, uint256 amount, address receiver) external returns
  (uint256 shares); function previewDeposit(address asset, uint256 amount) external view returns (uint256 shares); }`.
  Semantics (§4/§5): **pull `amount` of `asset` from the caller** (the module) via `transferFrom`, add it to the
  junior basket, **value it via `SzipNavOracle`** (`shares = amount * 1e18 / max(spot,twap)`, round down, revert if
  the oracle is stale), mint **Loot to itself** + mint **`szipUSD` to `receiver`**. **Cold-build-verify item:** the
  exact signature is THIS ticket's proposal pinned as the Gate's obligation; the cold-build MOCKS it and the Gate
  must conform (or the obligation is renegotiated).
- **`SzipNavOracle` (§3) — transitive (the Gate reads it; MOCKED via the Gate mock's `navPerShare`).** The module
  never calls it directly.
- **`CreditWarehouse` Safe (`WAREHOUSE_SAFE`) — 8-Bw (a Gnosis Safe).** Opaque `receiver` for `EE_POOL.deposit`; no
  interface. **Cold-build:** a plain test address; assert `EE_POOL.balanceOf(warehouse)`.
- **`IERC20`/`IERC20Metadata` — import from OZ (do NOT declare inline).** `SafeERC20`/`forceApprove` are typed on
  OZ's `IERC20`; a local `IERC20` does not compile with `using SafeERC20 for IERC20`. Wrap `zipUSD`/`usdc` as
  `IERC20(...)` at call sites. (`IESynth`/`IEulerEarn`/`IZipExitGate` stay local.) USDC mock: 6-dp, **no
  fee-on-transfer** (NatSpec invariant).
- **`SafeERC20`** (`using SafeERC20 for IERC20;`) for ALL token moves; **`ReentrancyGuard`** (OZ v5). Resolve under
  the WOOF-00 `@openzeppelin/contracts/` remap.
- **NOT** `ReceiverTemplate`/`Ownable`/`BaseAdapter`/EVC. **NOT** `require(cond, CustomError())` (use `if (!cond)
  revert`). **NOT** a vanilla ERC4626 vault.

**Starting state**
- WOOF-00 done; `contracts/src/supply/ZipDepositModule.sol` is the WOOF-00-pinned stub header; `contracts/test/
  ZipDepositModule.t.sol` carries the same header. (The prior keepsake was discarded.)
- **Cold-build convention (as WOOF-05):** rebuild the WOOF-00 scaffold from its ticket, then `ZipDepositModule.sol`,
  then the test with real `ESynth`/EVC + mocks. No prior-WOOF contract dependency.
- **`ESynth.setCapacity`:** call directly from the owner EOA (`onlyEVCAccountOwner onlyOwner`, `ESynth.sol:47`). The
  Gate mock pulls zipUSD via `transferFrom`, so it needs no capacity.

**Do NOT**
- **Do NOT hard-code `1e12`.** Derive `scaleUp` in the ctor with `require(zipDec >= usdcDec)`.
- **Do NOT deposit USDC with `receiver = address(this)`.** Deposit with `receiver = warehouse`.
- **Do NOT custody EE shares, szipUSD, Loot, zipUSD, or USDC across calls.** Everything transient; assert the module
  holds none at the end of every test.
- **Do NOT mint zipUSD to the user in `zap`.** Mint to **the module**; the Gate mints **szipUSD** to the user. In
  plain `deposit`, mint zipUSD to the **user**.
- **Do NOT compute szipUSD share amounts in the module.** The Gate prices NAV-proportionally; the module passes
  `zipAmount` and takes back `shares`.
- **Do NOT call `depositFor` with `receiver = address(this)`** (strands the user's szipUSD). Pass `msg.sender`.
- **Do NOT add an owner/admin/pause/upgrade/repoint surface.** Only the set-once `setGate` (deployer-gated).
- **Do NOT assume zipUSD is 6-dp / raw-equal to USDC.** `ESynth` is fixed 18-dp; `scaleUp` is the point.
- **Do NOT grant the module `ESynth` capacity before `warehouse` is verified == the real `CreditWarehouse` Safe**
  (F3 — unbacked zipUSD). `warehouse` is a ctor immutable → a wrong wire is unrecoverable; the deploy assertion
  `module.warehouse() == WAREHOUSE_SAFE` precedes `setCapacity`.
- **Do NOT trust the Gate/eePool callee to leave the module clean.** In `zap`, enforce: revert `ZeroShares` on a
  no-share Gate, revert `ResidualBalance` if any zipUSD remains, `forceApprove`-reset the gate allowance to 0.

**Key requirements**
- `contract ZipDepositModule is ReentrancyGuard`, `using SafeERC20 for IERC20;`. Ctor
  `constructor(address zipUSD_, address usdc_, address eePool_, address warehouse_)` storing the four immutables +
  `deployer` + derived `scaleUp`; zero checks on all four; `require(zipDec >= usdcDec)`.
- `address public gate;` (mutable until set-once) + **`setGate(address gate_)`** (deployer-gated;
  `AlreadyWired`/`ZeroAddress`/`NotDeployer`; stores + `GateWired`; **grants NO standing allowance** — D1).
- **`deposit(uint256 usdcIn) external nonReentrant returns (uint256 zipMinted)`** — steps 1–6.
- **`zap(uint256 usdcIn) external nonReentrant returns (uint256 shares)`** — steps 1–10 (incl. the step-9
  `ZeroShares`/`ResidualBalance`/allowance-reset enforcement).
- **`previewDeposit`/`previewZap`** views (`previewZap` reverts `NotWired` if un-wired; `previewDeposit` works
  un-wired).
- **Errors:** `error ZeroAmount(); error ZeroAddress(); error DecimalsTooFew(); error NotDeployer(); error
  AlreadyWired(); error NotWired(); error ZeroShares(); error ResidualBalance();`. **(AS BUILT)** the ctor
  `zipDec >= usdcDec` guard reverts the dedicated **`DecimalsTooFew`** (not `ZeroAmount` — a misleading reuse the
  critic fanout caught).
- **Events:** `event Deposited(address indexed user, uint256 usdcIn, uint256 zipMinted); event Zapped(address
  indexed user, uint256 usdcIn, uint256 zipMinted, uint256 shares); event GateWired(address indexed gate);`.
- **`scaleUp`** is `public immutable`, derived; no literal `1e12` anywhere in the contract.

**Done when**
- `forge build` green (solc 0.8.24); `contracts/test/ZipDepositModule.t.sol` passes.
- **(AS BUILT 2026-06-08) Two suites:** `ZipDepositModuleTest` realises the mock-gate harness below (REAL `ESynth`
  zipUSD over a live EVC; par/non-par EE mocks; `MockGate`) for the full Done-when matrix incl. the adversarial guards;
  `ZipDepositModuleRealGateTest` (Base fork) re-proves the zap headline path (genesis par, NAV-proportional,
  on-behalf, `previewZap == zap`) against the **LIVE** `ExitGate`/`SzipNavOracle`/Baal substrate — there the pulled
  zipUSD lands in `mainSafe` (the basket), not the Gate, so substitute `zip.balanceOf(mainSafe)` for the mock's
  `zip.balanceOf(gateMock)` assertion. The real two-token invariant (`szipUSD.totalSupply == Loot.balanceOf(gate)`,
  `totalShares()==0`) is asserted in the real-gate suite.
- **Harness:** REAL `ESynth` (live zipUSD over a live EVC) is the UUT's zipUSD; **`EE_POOL` = par EE mock** (pulls
  the FULL `assets` via `transferFrom` then `_mint(receiver, assets)` 1:1 6-dp); **`gate` = a mock `IZipExitGate`**
  implementing the seam against the real ESynth + a **mock `navPerShare`**: `depositFor(zipUSD, zipAmount, receiver)`
  does `ESynth.transferFrom(module, this, zipAmount)` (consumes the per-zap approval) then `shares = zipAmount * 1e18
  / navPerShare` (round down) and `_mint(receiver, shares)` into a **mock 18-dp szipUSD ERC20**, records
  `(zipAmount, receiver)` via PUBLIC getters `lastReceiver()`/`lastAmount()`; `previewDeposit(zipUSD, zipAmount)`
  returns the same formula. **`WAREHOUSE_SAFE` = a plain test address.** **USDC = a 6-dp mock with `mint(actor,amt)`.**
  Setup: `new ESynth(evc,"Zipcode USD","zipUSD")`, then `ESynth.setCapacity(module, type(uint128).max)` from the
  owner EOA, `module.setGate(gateMock)`. **Zap test input `zap(200_000e6)`** (explicit).
- **Decimals + scale:** `module.scaleUp() == 1e12` (the harness's expected value given USDC=6/zipUSD=18 — NOT a
  contract constant); `ESynth.decimals() == 18`; `deposit(1_000_000e6)` → `ZIPUSD.balanceOf(user) == 1_000_000e18`,
  `ZIPUSD.totalSupply() == 1_000_000e18`, `EE_POOL.balanceOf(WAREHOUSE_SAFE) == 1_000_000e6`.
- **`deposit` (warehouse custody):** `USDC.balanceOf(LP)==0`, `USDC.balanceOf(EE_POOL)==1_000_000e6`,
  `ZIPUSD.balanceOf(LP)==1_000_000e18`, `EE_POOL.balanceOf(WAREHOUSE_SAFE)==1_000_000e6`,
  `EE_POOL.balanceOf(module)==0`, `USDC.allowance(module,eePool)==0`, module holds no zipUSD/USDC; `vm.expectEmit`
  `Deposited(LP, 1_000_000e6, 1_000_000e18)`. Return == `1_000_000e18`.
- **`zap` at navPerShare = $1 (1e18) — the headline on-behalf test:** `ZIPUSD.balanceOf(USER)==0`,
  `SZIPUSD.balanceOf(USER)==shares` and **`shares == 200_000e18`** (par NAV), `SZIPUSD.balanceOf(module)==0`,
  `ZIPUSD.balanceOf(module)==0`, `ZIPUSD.balanceOf(gateMock)==200_000e18` (the Gate pulled the basket zipUSD),
  `ZIPUSD.allowance(module,gateMock)==0`, `EE_POOL.balanceOf(WAREHOUSE_SAFE)==200_000e6`,
  `EE_POOL.balanceOf(module)==0`, `EE_POOL.balanceOf(gateMock)==0`, `USDC.balanceOf(EE_POOL) += 200_000e6`;
  `vm.expectEmit Zapped(USER, 200_000e6, 200_000e18, shares)`. Return `shares == SZIPUSD.balanceOf(USER)`.
- **`zap` NAV-proportional (non-par):** set `navPerShare = 1.2e18` → `shares == 200_000e18 * 1e18 / 1.2e18`
  (round down) and `SZIPUSD.balanceOf(USER) == shares`; `ZIPUSD.balanceOf(gateMock) == 200_000e18` unchanged (the
  zipUSD basket leg is par; only the share count is NAV-scaled). Proves the module passes value through and the
  Gate prices it — the module never assumes par.
- **On-behalf correctness:** the gate mock recorded `receiver == USER` (not the module) and `amount == 200_000e18`.
- **`previewZap` matches `zap` (fixed-NAV mock — assert EQUALITY):** before the zap the `previewZap` tuple EXACTLY
  equals the realized `(zipMinted, shares)` (same `navPerShare`). `previewDeposit(200_000e6) == 200_000e18`.
- **`previewDeposit` standalone:** `previewDeposit(N) ==` the realized `deposit(N)` return; **AND succeeds when
  `gate == address(0)`** (only `previewZap` reverts `NotWired`).
- **Conservation / stateless (every test):** `ZIPUSD/USDC/SZIPUSD/EE_POOL .balanceOf(module) == 0`; post-deposit
  (par mock) `USDC.balanceOf(EE_POOL) * 1e12 == ZIPUSD.totalSupply()` AND `EE_POOL.balanceOf(WAREHOUSE_SAFE) ==
  USDC.balanceOf(EE_POOL)`.
- **Zap atomicity on mid-zap revert:** a gate mock whose `depositFor` reverts → `zap` reverts, post-state pristine —
  enumerate the EXACT balances re-read == the pre-call snapshot (module/USER/WAREHOUSE_SAFE/gateMock/EE_POOL across
  USDC/ZIPUSD/EE_POOL + `ZIPUSD.totalSupply()`).
- **Under-pull gate mock → `ResidualBalance`:** a mock whose `depositFor` pulls LESS than `zipAmount` (e.g. half)
  makes `zap` revert `ResidualBalance`.
- **No-share gate mock → `ZeroShares`:** a mock whose `depositFor` **pulls the full `zipAmount`** then returns
  `shares == 0` makes `zap` revert `ZeroShares` (the full pull isolates `ZeroShares` from `ResidualBalance`).
- **Stale-oracle propagation:** a gate mock whose `depositFor` reverts (simulating the §3 staleness guard) → `zap`
  reverts and post-state is pristine (covered by the atomicity test; note the contract does NOT swallow it).
- **Share-price-agnostic — BOTH EE directions:** under-par (`*9/10`) AND over-par (`*11/10`) EE mocks (each pulls
  FULL `assets`): `deposit(1_000_000e6)` still mints `1_000_000e18` zipUSD; `EE_POOL.balanceOf(WAREHOUSE_SAFE) ==
  900_000e6` (resp. `1_100_000e6`); `EE_POOL.balanceOf(module)==0`; the zap's `shares`/`SZIPUSD.balanceOf(gateMock)`
  unchanged.
- **Wiring guards:** `setGate` from non-deployer → `NotDeployer`; second call → `AlreadyWired`; `address(0)` →
  `ZeroAddress`; after wiring `module.gate() == gateMock` AND `EE_POOL.allowance(module, gateMock) == 0`.
- **`zap` before wiring reverts `NotWired`** (and `previewZap` reverts `NotWired`); a plain **`deposit` works
  un-wired** — assert the FULL balance set.
- **Sequential / no-residue:** two `deposit`s then two `zap`s all succeed (assert module holds nothing + both
  allowances == 0 after).
- **Zero-amount guards:** `deposit(0)`/`zap(0)` revert `ZeroAmount` (FIRST statement).
- **Capacity (negative):** ungranted → `deposit(1e6)` reverts `E_CapacityReached`; bounded `setCapacity(module,
  500_000e18)` → `deposit(1_000_000e6)` reverts `E_CapacityReached`, full rollback (module USDC 0, user USDC + total
  supply unchanged).
- **Overflow boundary:** `usdcIn` just above `type(uint128).max / scaleUp` → `ESynth.mint` reverts the EXACT
  `E_CapacityReached` (`ESynth.sol:64-69`, NOT a `Panic`); split the NatSpec doc-note from the assertion.
- **Reentrancy guard ACTUALLY guards:** a gate mock whose `depositFor` re-enters `module.deposit`/`zap` → reverts
  `ReentrancyGuardReentrantCall`; AND a re-entrant EE mock variant reverts the same (covers the EE callout).
- **`testFuzz_deposit`/`testFuzz_zap`** over `usdcIn ∈ [1, type(uint128).max / scaleUp]`: `zipMinted == usdcIn *
  scaleUp` AND conservation (par mock, fixed `navPerShare`).
- **`ZeroShares` dust:** unreachable here (the `ZeroAmount` guard + par mock never round to 0) — no test owed;
  stated so the claim isn't unbacked.
- **Acceptance:** plain `deposit` → zipUSD value-1:1 + USDC parked to the warehouse; the zap → USDC parked to the
  warehouse + **transferable szipUSD** minted on-behalf to the user via the Gate (NAV-proportional); module stateless
  in every asset.

**Audit (status — owed re-align; no new rows invented here)**
- The supply-side deploy/wiring + acceptance re-aligns in the **owed `audit/2` Baal sweep (carried by 8-Bw + the
  Gate)**: the 4-arg ctor (`+ WAREHOUSE_SAFE`), `EE_POOL.deposit(·, WAREHOUSE_SAFE)`, `setGate` granting a **zipUSD**
  (not EE-share) allowance per-zap, the `Gate.depositFor` on-behalf **szipUSD** mint, and the NAV-proportional
  pricing in the Gate (+ `SzipNavOracle` staleness). **A dependency, not a new audit row.**

**Depends on**
WOOF-00 (scaffold + remaps); real `ESynth` + live EVC (reference deps).
- **`CreditWarehouse` Safe (8-Bw, §11)** — HARD: must exist as a deployed address before the module is deployed
  (ctor immutable `warehouse_`). Cold-build stands it in with a plain test address.
- **The Exit Gate (§4/§5, item 8)** — the `setGate` target; must implement `IZipExitGate.depositFor`/`previewDeposit`
  (NAV-proportional via `SzipNavOracle`, minting **transferable szipUSD**). Cold-build mocks it.
- **`SzipNavOracle` (§3)** — transitive (the Gate reads it). Cold-build folds it into the gate mock's `navPerShare`.

**Cross-ticket obligations this ticket CREATES (verify discharged by the named ticket):**
1. **The Exit Gate (§4/§5, item 8 — absorbs the old 8-B2 mint shaman):** implement **`depositFor(address asset,
   uint256 amount, address receiver) returns (uint256 shares)`** — (a) pull `amount` of `asset` from the caller via
   `transferFrom` into the junior basket; (b) **value it via `SzipNavOracle`** (`shares = amount * 1e18 /
   max(spot,twap)`, round down, revert if stale); (c) mint **Loot to itself** + mint **`szipUSD` to `receiver`**.
   PLUS **`previewDeposit(address asset, uint256 amount) view returns (uint256 shares)`** (UI estimate). The Gate must
   be **immutable / owner-renounced or TimelockController-governed** at wiring; it is the **sole real-Loot holder**
   and the **sole szipUSD minter**.
   **DISCHARGED 2026-06-08:** the real `ExitGate` already matched `depositFor(asset, amount, receiver) → shares`
   exactly; `previewDeposit` was MISSING and was **added to the kept Gate** (`contracts/src/supply/szipUSD/ExitGate.sol`
   — mirrors `depositFor` pricing: `valueOf(asset,amount) * 1e18 / navEntry()`, round down, same whitelist/zero/stale
   guards, view-only so no `poke`). Verified by `ZipDepositModuleRealGateTest.test_real_zap_genesis_par`
   (`previewZap == zap`) + `ExitGateTest.test_previewDeposit_matches_depositFor`/`_guards`. The Gate stays
   `TimelockController`-governable (item-10 wiring asserts owner-renounce/timelock before capacity).
2. **Deploy/wiring (item 10, §9 — re-authored in the 8-Bw/Gate `audit/2` sweep):** (a) deploy `CreditWarehouse` Safe
   FIRST; (b) deploy **`ZipDepositModule(ZIPUSD, USDC, EE_POOL, WAREHOUSE_SAFE)`**; (c) **BEFORE
   `ESynth.setCapacity(module, …)` assert:** `module.warehouse() ==` the canonical Safe; the Gate is owner-renounced
   or Timelock-governed AND non-upgradeable; `module.eePool() ==` the canonical pool. (Load-bearing — `warehouse` is
   immutable; granting capacity before a verified receiver mints unbacked zipUSD, F3.) Then `setCapacity` (bounded);
   (d) deploy/summon the Baal substrate + the Gate (8-B1/Gate); (e) **`module.setGate(gate)`** (set-once) — grants no
   EE-share allowance; assert `module.gate() == gate`, `module.warehouse() == WAREHOUSE_SAFE`,
   `EE_POOL.allowance(module, gate) == 0`; (f) renounce `ESynth` ownership only **after** capacity + wiring.
