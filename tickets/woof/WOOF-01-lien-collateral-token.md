# WOOF-01 — `LienCollateralToken` + `LienTokenFactory` (§4.2)

> **MATERIALIZED + BUILDS GREEN 2026-06-06 (keep-the-build doctrine).** Built from this ticket alone against the
> real WOOF-00 scaffold: `forge build` clean (solc 0.8.24) + **14/14 unit tests pass** (independently re-run). Code
> kept, committed: `contracts/src/LienCollateralToken.sol`, `contracts/src/LienTokenFactory.sol`,
> `contracts/test/LienToken.t.sol`. The ticket proved a true **zero-spec-guess keepsake** — the real build found
> **no** contradiction or wrong citation (all OZ lines `:50/:83/:226/:241`, Create2 `:37/:57`, `Errors.FailedDeployment`
> verified). Three cosmetic build choices the ticket left open, **now pinned**: (a) the constructor param is
> `controller_` (trailing underscore — avoids shadowing the `controller` immutable); (b) the zero-check may be a
> bare `require(controller_ != address(0))` (the message string is the author's choice); (c) the test imports
> `ERC20InsufficientBalance` from `@openzeppelin/contracts/interfaces/draft-IERC6093.sol` (`IERC20Errors`).

**Deliverable**
Two contracts under `contracts/src/`, one symbol per file (`README.md` §7):
- `contracts/src/LienCollateralToken.sol` — `contract LienCollateralToken is ERC20`. A 1/1 collateral token:
  fixed total supply of exactly `1e18` (one whole token at 18 decimals) minted **once** to the controller at
  construction; `decimals()` pinned to the constant `18`; constant name/symbol; `burn` restricted to the
  controller. One instance per lien; the lien's identity is this token's **address**.
- `contracts/src/LienTokenFactory.sol` — `contract LienTokenFactory`. Deploys `LienCollateralToken` instances
  via **CREATE2** with `salt = keccak256(abi.encode(lienId))`, so the controller/CRE can **precompute** a lien's
  address from `lienId` before the origination batch. Exposes the decimals pin and the address-precompute view.

(No protocol valuation/borrow logic — this is the collateral primitive every isolated lien market is built on.)

**Spec §**
`claude-zipcode.md` §4.2 (the token + factory). Cross:
- §4.1 (the token address is the **oracle key** — registry caches `cache[LIEN_i]`; the registry's
  `_processReport` decimals guard reads the factory's pinned decimals).
- §4.4a (origination: the controller calls `LienTokenFactory.create` inside its atomic batch, **after** the
  Proof of Lien + Proof of Insurance gates pass off-chain, §8.5) and §4.4c (close: controller `burn`s the token).
- §13 / `audit/3-results.md` **row 18** (mint/burn authority = `ZIP_CONTROLLER` only, `onlyController` immutable
  at the token's deploy) and **row 19** (`create` caller-bound — `controller := msg.sender`, no gate).
Locked §17: collateral is **mocked** for the MVP (this is the on-chain token shape, not a real-asset bridge);
identity = address (no on-chain `lienId` registry).

**Model from (verified against `reference/`)**
- **`LienCollateralToken is ERC20`** — OpenZeppelin `ERC20`
  (`reference/euler-vault-kit/lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol`, v5.0.2), imported as
  `@openzeppelin/contracts/token/ERC20/ERC20.sol` (WOOF-00 remap, verified resolves). Inherit it; pass the
  constant name/symbol to its constructor (`:50` = `constructor(string memory, string memory)`); mint with the
  internal `_mint` (`:226`) in the constructor; burn with internal `_burn` (`:241`). **Override `decimals()`**
  (`:83`, `public view virtual returns (uint8)`, default body returns `18` at `:84`) to `return 18`. The override
  is **explicit intent**, not a behavior change: it pins the value per §4.2 so a later base bump can't silently
  shift it, and it is the scale `BaseAdapter._getDecimals` would otherwise infer from a fallible `decimals()`
  staticcall (`reference/euler-price-oracle/src/adapter/BaseAdapter.sol:40` — silently returns 18 on failure,
  making an off-by-decimal a 10× mispricing). **Declare it `pure`** (the value is a constant): overriding a
  `view` base function with `pure` is a *legal narrowing* override (verified compiles on solc 0.8.24).
- **`LienTokenFactory` CREATE2** — OpenZeppelin `Create2`
  (`reference/euler-vault-kit/lib/openzeppelin-contracts/contracts/utils/Create2.sol`, v5.0.2), imported as
  `@openzeppelin/contracts/utils/Create2.sol` (same remap copy). Use `Create2.deploy(0, salt, initCode)`
  (`:37`) to deploy and `Create2.computeAddress(salt, keccak256(initCode))` (`:57`, the `address(this)`-deployer
  overload) to precompute. `Create2.deploy` **reverts `Errors.FailedDeployment`** when the address is already
  occupied (`Create2.sol:48-50`; the error is `Errors.FailedDeployment` from
  `@openzeppelin/contracts/utils/Errors.sol`, **not** a `Create2`-local error), which is the on-chain dedup for a
  re-used `lienId`. The `initCode` is `abi.encodePacked(type(LienCollateralToken).creationCode,
  abi.encode(controller))` (verified at runtime: `computeAddress(salt, keccak256(initCode))` matches the deployed
  address for the same `initCode`).
- **NOT** `reference/euler-vault-kit/src/Synths/ESynth.sol` — ESynth is the EVC-aware (`ERC20EVCCompatible`),
  multi-minter, capacity-gated **synth** (zipUSD, §4.5), not a fixed-supply collateral token; its
  `setCapacity`/EVC machinery is the wrong shape. The lien token is a **plain** ERC20.
- **NOT** EVK's `GenericFactory` (`reference/euler-vault-kit/src/GenericFactory/GenericFactory.sol`) — its
  `createProxy` (`:116`) deploys a `BeaconProxy` with plain `new` (`:132`), **no `create2`/`salt`** (verified),
  so it cannot precompute. This is a **net-new** CREATE2 factory (§4.2 says so explicitly).

**Starting state**
- WOOF-00 done; `contracts/src/LienCollateralToken.sol` and `contracts/src/LienTokenFactory.sol` are empty stubs
  with the WOOF-00-pinned header — `// SPDX-License-Identifier: GPL-2.0-or-later` then `pragma solidity 0.8.24;`
  (**keep both exactly; do not change the license or bump the pragma**). The `test/LienToken.t.sol` you add
  carries the same two-line header.
- `@openzeppelin/contracts/` remap resolves (verified, WOOF-00). No new remapping needed.
- The `ZipcodeController` does **not** exist yet (its ticket is item 6, §4.4) — this ticket is built and unit-tested
  against a **mock controller** (any EOA/contract address standing in as the authority).

**Do NOT**
- **Do NOT use `require(cond, CustomError())`** — that overload is **solc ≥ 0.8.26**; WOOF-00 pins **0.8.24**, where
  it fails to compile (`Error 9322: No matching declaration found`). Use the `if (!cond) revert CustomError();`
  form for every custom-error guard (the `controller != address(0)` plain-string/empty `require` is fine).
- **Do NOT pass name/symbol as constructor args.** They are hardcoded constants (`name = "Zipcode Lien
  Collateral"`, `symbol = "zLIEN"`, §4.2) so the **only** constructor arg is `controller`; this keeps the CREATE2
  init-code identical across every lien, so the address precomputes from `lienId` alone (§4.2 "identity = address").
- **Do NOT add a public/re-callable `mint`.** The fixed-supply-of-`1e18`-minted-once invariant is enforced
  **structurally** by minting exactly once in the constructor; a post-deploy mint path would contradict §4.2's
  "fixed total supply of exactly 1e18." The only post-deploy supply-mutating call is `burn` (close, §4.4c). There
  must be **no `mint` function and no admin/`Ownable`** — this is *stronger* than an `onlyController`-gated mint.
- **Do NOT add a `controller` parameter to `create`, and do NOT add an authorization gate to it.** `create`
  takes **only** `lienId` and uses the **caller** (`msg.sender`) as the new token's authority. No gate is needed
  and none should be added: because the CREATE2 init-code embeds the caller, the address **binds to the caller**,
  so an attacker calling `create(lienId)` only ever produces a token authorized to *themselves* at a *different*
  address — they can never occupy or grief `LIEN_i` (derived from `ZIP_CONTROLLER`). The caller-binding *is* the
  authorization. (A two-arg `create(lienId, controller)` + `controller == msg.sender` gate would be functionally
  identical but carries a redundant arg + revert path — not wanted.)
- **Do NOT store the controller as a `LienTokenFactory` constructor immutable.** The `ZipcodeController`
  constructor takes `lienFactory` (§4.4), so the factory deploys **first** (audit/2.md **S4**) and the controller
  does not exist yet — a factory-held controller immutable is a deploy-order circularity. The token's authority
  is supplied by `create`'s caller, never stored on the factory.
- **Do NOT add a `burnFrom`/allowance-based burn or an arbitrary-holder burn.** `burn` burns from the
  controller's **own** balance; an arbitrary-holder burn would need allowance/admin machinery and break the
  plain-transferable-ERC20 shape. (Burn-custody sequencing is a controller-ticket obligation — see the note in
  Key requirements.)
- **Do NOT make the token EVC-aware / `EVCUtil`** (that is ESynth's pattern, not a collateral token's) and **do
  NOT** add transfer hooks / soulbinding — it must be a plain transferable ERC20 so the venue can custody it
  (deposit into the collateral vault, audit/2.md L4 `balanceOf(EVAULT_i) > 0`).
- **Do NOT store an on-chain `lienId → address` mapping** in the factory — identity is the address, recoverable
  via `computeAddress(lienId, controller)` + the `LienCreated` event for off-chain indexing (§4.2 "the registry
  never stores `lienId`"). Installing the hook / registering collateral / seeding the price are **other tickets'** jobs.

**Key requirements**

*`LienCollateralToken`*
- **Constructor `LienCollateralToken(address controller)`** — `require(controller != address(0))` (plain
  `require`); store `address public immutable controller`; call `ERC20("Zipcode Lien Collateral", "zLIEN")`;
  `_mint(controller, 1e18)`. After construction `totalSupply() == 1e18` and `balanceOf(controller) == 1e18`.
  Non-payable constructor (CREATE2 `deploy` passes `amount = 0`).
- **`decimals() public pure override returns (uint8)` → `18`** (constant narrowing override; see Model from).
- **`burn(uint256 amount) external`** — gate with `if (msg.sender != controller) revert NotController();` — burns
  from the **controller's own balance** via `_burn(controller, amount)`. (At close the controller has reclaimed
  the `1e18` from the collateral vault and calls `burn(1e18)`; the resulting `Transfer(controller → address(0),
  1e18)` is the §4.4c / audit/2.md L7 event.) **Burn-custody note (controller-ticket obligation, surfaced here so
  it isn't lost):** `burn` reverts `ERC20InsufficientBalance` if the `1e18` is still sitting in `EVAULT_i`; the
  close path (§4.4c / L7) MUST first withdraw the collateral back to the controller so `balanceOf(controller) ==
  1e18` before calling `burn`. Do not "fix" this in the token by adding an arbitrary-holder burn.
- Declare `error NotController();` in this contract. No `Ownable`, no admin, no other privileged surface; no
  `burnFrom`/allowance path. `controller` is the sole authority and is immutable.

*`LienTokenFactory`*
- **`uint8 public constant LIEN_DECIMALS = 18;`** — the canonical decimals pin (audit/2.md S4 post-condition
  asserts `LIEN_FACTORY.LIEN_DECIMALS() == 18`; the registry's `_processReport` decimals guard, §4.1, reads it —
  the registry must validate a registered key's `decimals()` against `LIEN_DECIMALS` before caching; that
  validation lives in the **registry ticket**, this ticket only exposes the constant).
- **`create(bytes32 lienId) external returns (address lien)`** —
  - **Caller-bound authority (no gate):** the new token's authority is the **caller** — `address controller =
    msg.sender;`. The single legitimate caller is the `ZipcodeController`, which calls `create(lienId)`. No
    authorization check is needed: because `initCode` embeds the caller, the deployed address **binds to the
    caller**, so an attacker calling `create(lienId)` produces a token authorized to *themselves* at a
    *different* address and can never occupy or grief `LIEN_i` (derived from the real controller). The
    caller-binding is the authorization; do **not** add a `controller` parameter or a `require`/`revert` gate
    here. (`msg.sender` is never the zero address, so a zero-controller token is unreachable via `create`; the
    token-constructor zero-check is the real guard, reachable only via direct `new LienCollateralToken(0)`.) The
    factory needs **no custom error** of its own.
  - `salt = keccak256(abi.encode(lienId))` (§4.2, **exactly** this; matches audit/2.md L4 `keccak256(abi.encode(lienId))`).
  - `initCode = abi.encodePacked(type(LienCollateralToken).creationCode, abi.encode(msg.sender))`;
    `lien = Create2.deploy(0, salt, initCode)`.
  - `emit LienCreated(lienId, lien)` (§4.2 — records the `lienId → address` link on-chain for indexing).
  - Return `lien`. A re-used `lienId` **from the same caller** reverts via `Create2.deploy`
    (`Errors.FailedDeployment`) — the dedup (same `(lienId, caller)` → same salt+init-code → same occupied
    address); the deployed token permanently occupies its CREATE2 slot, so a `lienId` is **single-use forever for
    that controller** (even after the supply is burned to 0 at close, the address is retired — intended, identity
    = address). A *different* caller reusing the same `lienId` lands at a *different* address (no revert) — and
    that token is inert (never wired into a market/oracle).
- **`computeAddress(bytes32 lienId, address controller) external view returns (address)`** — note this stays
  **two-arg** (a pure prediction has no `msg.sender` authority semantics; anyone — the controller, the CRE, an
  indexer — must be able to predict any lien's address). Same `salt`/`initCode` (with `abi.encode(controller)`)
  as `create` produces for that caller; return `Create2.computeAddress(salt, keccak256(initCode))` (the
  `address(this)`-deployer overload; the CREATE2 address binds to **the factory** as deployer, so no external
  actor can ever occupy `LIEN_i`'s precomputed slot). This is the precompute the controller asserts against in
  the origination batch (audit/2.md L4 step 3: "Assert `LIEN_i` matches the address that's about to be
  deployed"). **The controller calls `computeAddress(lienId, address(this))`** — it must pass its own address
  here so the prediction matches what `create(lienId)` (caller = the controller) will deploy; the L4
  precompute-equality assert is the guard if they ever diverge. The address is keyed on `(lienId, controller)`,
  deterministic in `lienId` for the single `ZipcodeController`.
- `LienCreated(bytes32 indexed lienId, address indexed lien)` event declared on the factory (both args indexed).

**Done when**
- `forge build` green (solc 0.8.24); new unit test passes (`contracts/test/LienToken.t.sol`). The test calls
  `create(lienId)` **as** the controller (`vm.prank(controller)` for an EOA mock, or a stand-in controller
  contract call) — `create` binds the new token's authority to `msg.sender`.
- **Unit (Foundry) — provable in isolation with a mock controller:**
  - *Token shape:* after `vm.prank(controller); create(lienId)`, `LIEN.totalSupply() == 1e18`,
    `LIEN.balanceOf(controller) == 1e18`, `LIEN.decimals() == 18`, `LIEN.name() == "Zipcode Lien Collateral"`,
    `LIEN.symbol() == "zLIEN"`, `LIEN.controller() == controller`.
  - *Token-constructor zero-guard:* `new LienCollateralToken(address(0))` reverts (the only path that reaches the
    guard; via `create` it is unreachable since `msg.sender` is never the zero address).
  - *Precompute correctness (load-bearing — L4 step 3):* compute `predicted = factory.computeAddress(lienId,
    controller)` **before** deploy; assert `predicted.code.length == 0` (genuinely an empty slot); then
    `vm.prank(controller); deployed = factory.create(lienId)`; assert `predicted == deployed` and
    `deployed.code.length > 0`.
  - *Precompute is keyed on `(lienId, controller)`:* two distinct `lienId`s → two distinct addresses; and
    `computeAddress(lienId, A) != computeAddress(lienId, B)` for distinct controllers `A != B`.
  - *Create is caller-bound + squat-proof (replaces the old gate test):* `vm.prank(attacker); create(lienId)`
    deploys a token with `controller() == attacker` at `computeAddress(lienId, attacker)`, and crucially the
    canonical slot `computeAddress(lienId, controller)` **still has no code** (`.code.length == 0`) — so the real
    controller's later `create(lienId)` still succeeds at `LIEN_i`. (This is the origination-DoS-immunity proof:
    no caller but the controller can occupy `LIEN_i`.)
  - *Dedup / single-use lienId:* a second `vm.prank(controller); create(lienId)` with the same `lienId` reverts
    (`Errors.FailedDeployment` — same caller → same slot); and create → `burn(1e18)` → re-`create(lienId)` (same
    controller) **still** reverts (the address is permanently retired even at 0 supply).
  - *Burn authority + bounds:* `LIEN.burn(1e18)` from `controller` drops `totalSupply()` to 0 and emits
    `Transfer(controller, address(0), 1e18)`; `burn` from any other caller reverts `NotController`; `burn(0)` from
    controller does not revert and leaves supply unchanged (pin OZ behavior); `burn(> balanceOf(controller))`
    reverts (`ERC20InsufficientBalance`).
  - *Transferability:* `controller` `transfer`s the `1e18` to another address; balances move and no
    hook/soulbind reverts (proves the token can be deposited as collateral, L4 `balanceOf(EVAULT_i) > 0`).
  - *Event:* `vm.expectEmit(true, true, false, false)` on `LienCreated(lienId, lien)`; the emitted `lien` equals
    the returned address.
  - *Decimals pin:* `factory.LIEN_DECIMALS() == 18`.
- **Acceptance (integration harness, NOT WOOF-01 unit — these need the controller (§4.4), the market/oracle/hook,
  and the deploy/wiring ticket; listed so the slice is owned, not to be satisfied by `LienToken.t.sol`):**
  - `audit/2.md` **S4** (deploy `LIEN_FACTORY`; post `LIEN_FACTORY.LIEN_DECIMALS() == 18` and salt formula
    `keccak256(abi.encode(lienId))`) — the `LIEN_DECIMALS` + salt parts ARE unit-provable here; the live deploy is S4.
  - `audit/2.md` **L4** origination: step 3 precompute (`computeAddress(lienId, ZIP_CONTROLLER)`) matches the
    CREATE2 deployment (unit-provable slice above); step 4 `LIEN_FACTORY.create(lienId)` — called by
    `ZIP_CONTROLLER` — deploys a token with `totalSupply == 1e18`, `decimals == 18`, mint/burn restricted to the
    controller; `LienCreated(lienId, LIEN_i)` fires. Batch-atomicity (a `create` revert must roll back the whole
    origination batch) is the **controller ticket's** test, not this one.
  - `audit/2.md` **L7** close: the unit slice is `LIEN_i.burn(1e18)` by the controller → supply 0 +
    `Transfer(holder → 0, 1e18)`; the `LienReleased` event and `debtOf == 0` precheck are the controller's job.
  - Authority realized: `audit/3-results.md` **row 18** (`LIEN_i.mint`/`burn` = controller only — realized here as
    the `NotController` custom-error check on `burn` + constructor-only mint, which is the "`onlyController`
    immutable" of the row) and **row 19** (`create` caller-bound — realized as `controller := msg.sender` + the
    caller-embedded CREATE2 address, proven by the squat-proof test above, not a gate) and the attack-table row
    "`LIEN_i` — mint outside controller."

**Depends on**
WOOF-00 (scaffold + `@openzeppelin/contracts/` remap). Nothing else — the token + factory + their unit tests are
completable and provable in isolation with a mock controller. Downstream: `ZipcodeOracleRegistry` (§4.1, keys on
the token address + reads `LIEN_DECIMALS`), `ZipcodeController` (§4.4, the real caller of `create`/`burn`, owner of
the burn-custody sequencing + the same-`controller`-arg obligation), and the venue/market wiring (§4.7) consume
this but are not needed to build or prove it.
