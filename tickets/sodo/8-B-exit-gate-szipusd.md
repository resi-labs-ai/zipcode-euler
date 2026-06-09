# Exit Gate + szipUSD (§6.4 / §7 / `reports/design/baal-spec.md §4/§5/§7`) — the junior share + the windowed exit valve

> **Item ID:** `Exit Gate + szipUSD` (absorbs the old `8-B2` mint shaman + `8-B3` lock/freeze shaman). **Team
> folder:** `tickets/sodo/`. **Build-only** (internal plumbing — `requestExit`/`processWindow` are user/keeper
> calls, but the depositor-facing redemption-status UX is INFLOW-06's job; this ticket back-pressures the
> events/views the frontend needs but files no interface ticket — same call as `SzipNavOracle`/WOOF-02).
> **NEXT after this:** re-author + cold-build WOOF-06 (the zap, now seam-correct) → 8-B14 → engine 8-B5…B13.

**Deliverable**
Two contracts under `contracts/src/supply/szipUSD/`, one symbol per file (`README.md` §7):
- `contracts/src/supply/szipUSD/SzipUSD.sol` — `contract SzipUSD is ERC20`. The **transferable** 18-dp user
  share. **No transfer hooks, no soulbind** — a plain ERC-20 that trades on CoW (§6.2). `mint`/`burn` are
  **`onlyGate`** (the Exit Gate is the sole minter/burner); `gate` is set **once** at construction. The only
  privileged surface is the Gate's mint/burn; **no `Ownable`, no admin.** Fixed-supply-per-mint, non-rebasing —
  NAV accrues in *price* (`SzipNavOracle`), never in balance.
- `contracts/src/supply/szipUSD/ExitGate.sol` — `contract ExitGate`. The sole Baal-`Loot` custodian + szipUSD
  minter/burner (holds Baal `manager` = 2) + the sole `ragequit` caller. It implements:
  1. **Issuance** (`depositFor`) — NAV-proportional minting against `SzipNavOracle` (absorbs the old mint shaman).
  2. **Intent queue** (`requestExit`) — escrow szipUSD, queue the claim; no assets move.
  3. **Windowed exit** (`processWindow`) — keeper-driven, rides the harvest cadence: **plain in-kind ragequit** of
     the queued Loot against the main Safe — the exiter gets their **pro-rata slice of the basket** (zipUSD +
     xALPHA), sent straight to them; burn the matching Loot + escrowed szipUSD. **No oracle, no cap, no numeraire on
     exit** — you leave, you get your share (worth `shares × NAV/share` by construction). The committed slice in the
     non-RQ sidecar is the structural freeze (unreachable). The xALPHA→zipUSD dump + zipUSD→USDC queue are **separate
     downstream legs**, not this contract.
  4. **Paired buy-and-burn hook** (`burnFor`) — the §7 / 8-B14 retire path: `burnLoot` + burn szipUSD held by the
     engine Safe (no asset payout). 8-B14 is a *separate* later ticket; this ticket exposes only the hook it calls.

(No yield/strategy/loss-markdown logic — those are the engine `8-B5…B13` and the M2 `DefaultCoordinator`. This
contract is the custody + issuance + exit valve only.)

**Spec §**
`claude-zipcode.md` **§6.4** (the Exit Gate: custody + issuance + intent queue + liquidity windows + the
sidecar-freeze partial-fill) + **§7** (`SzipNavOracle` is the issuance/exit pricing primitive; `navEntry`/`navExit`
bracket; the supply denominator) + **`reports/design/baal-spec.md §4`** (the one issuance core), **§5** (the patient windowed
path), **§7** (the paired buy-and-burn), **§2.2/§2.3** (the two-token invariant). Cross:
- **§2** — szipUSD = the transferable junior share; the soulbound is on the internal Loot, not the user token.
- **§4.5** — the supply-side wiring: the zap (`ZipDepositModule`, WOOF-06) calls `gate.depositFor(zipUSD, amount,
  user)`; the `CreditWarehouse` is the *senior* custody (never conflate — zipUSD's backing, not the junior basket).
- **§4.5 item-0 / `reports/design/baal-spec.md` 8-B1** — the two-tier authority model: the Gate's `manager(2)` is granted by the
  **team-admin Safe signer** (`mainSafe.execTransaction → Baal.setShamans([gate],[2])`), **not** a Baal proposal
  (governance is inert) and **not** raw `setShamans` by anyone (it is `baalOnly` = avatar-only).
- **§11 / `reports/design/baal-spec.md §8/§9`** — the freeze is the **non-ragequittable sidecar** (committed equity); the Gate
  ragequits only the **main Safe** (free equity). The Gate does **not** rotate, mark down, or size the freeze.
- Locked **§17:** two-token model; Gate = sole real-Loot holder; **Shares stay 0 forever**; NAV-proportional
  bracketed issuance; exit = windowed ragequit at `min(spot, twap)` NAV (partial-fill) + the CoW secondary +
  the 8-B14 buy-and-burn; first-loss = an exit constraint (the freeze), not a markdown here; `navPerShare₀ = $1.00`.

**Model from (verified against `reference/` + the kept on-disk keepsakes)**
- **`SzipUSD is ERC20`** — OpenZeppelin `ERC20`
  (`reference/euler-vault-kit/lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol`, v5.0.2), imported
  `@openzeppelin/contracts/token/ERC20/ERC20.sol` (the remap WOOF-01 used, verified resolves). Inherit it;
  constant name/symbol to the ctor (`ERC20(string,string)`); default `decimals()` = 18 (no override needed — the
  share is 18-dp, the OZ default; **do not** override unless pinning is desired, and if so use the WOOF-01
  `public pure override returns (uint8) → 18` narrowing). Mint via internal `_mint`, burn via internal `_burn`,
  both gated `onlyGate`. This is the **WOOF-01 shape minus the fixed-supply constraint** (szipUSD supply grows/shrinks).
- **`IBaal`** — the **kept** `contracts/src/interfaces/baal/IBaal.sol` (verified 2026-06-06 vs
  `reference/Baal/contracts/Baal.sol`). Use these members:
  - **`mintLoot(address[] to, uint256[] amount)`** (`Baal.sol:814`, `baalOrManagerOnly` → `isManager` `:970`
    accepts permission ∈ {2,3,6,7}) — mint Loot **to the Gate** (`to = [address(this)]`). Mint bypasses the Loot
    pause (`LootERC20.mint` is `onlyOwner`=Baal; the pause hook allows `from==0`, `LootERC20.sol:65/92`).
  - **`burnLoot(address[] from, uint256[] amount)`** (`Baal.sol:834`, `baalOrManagerOnly`) — the **paired-burn**
    retire path (`from = [address(this)]`): `_burnLoot` (`:847`) is a **pure supply reduction, NO asset payout, no
    window** (`reports/design/baal-spec.md §18.2`). Used by `burnFor` (§7), NOT by the windowed exit.
  - **`ragequit(address to, uint256 sharesToBurn, uint256 lootToBurn, address[] tokens)`** (`Baal.sol:619`) —
    permissionless on the **Loot-holder**: `_ragequit` (`:637`) burns `lootToBurn` from **`_msgSender()`** (`:647`),
    so **the Gate must be the caller** (it holds the Loot). It pays `to` a **pro-rata in-kind** slice of
    `balanceOf(target)` for each token in `tokens[]` (`:655-674`); `target == avatar == mainSafe`. **`tokens[]` MUST
    be strictly ascending** (`:625-627`, reverts `"!order"`). `nonReentrant` (`:624`). Burning `lootToBurn` reduces
    `loot.balanceOf(gate)` and `baal.totalSupply()` (= `totalLoot`, since Shares = 0).
  - Read getters: `lootToken()`, `avatar()`, `totalSupply()`, `totalShares()`, `isManager`-equivalent via
    `shamans(address) → permission`. **Do NOT call `mintShares`** (it exists on the interface but minting any Shares
    destroys the zero-Shares invariant — see Do NOT).
- **`SzipNavOracle`** — the **kept** `contracts/src/supply/SzipNavOracle.sol` (built-verified, 39/39). Import it
  directly (same package) and call:
  - **`navEntry() external view returns (uint256)`** — issuance price `max(spot, twap)`, **reverts `StalePrice` if a
    required leg is stale** (issuance pauses on staleness — faithful, do not swallow).
  - **`navExit() external view returns (uint256)`** — exit price `min(spot, twap)`; never reverts on staleness.
  - **`poke() external`** — advance the TWAP accumulator with the current spot. The Gate **MUST `poke()` immediately
    before reading `navEntry`/`navExit`** (the oracle's documented downstream obligation — fold the latest spot into
    the TWAP so a sub-window move can't be front-run).
  - **`fresh() external view returns (bool)`** — both required legs within `maxAge` (== `navEntry` would not revert).
  - **`grossBasketValue() public view returns (uint256)`** — the 18-dp USD gross basket value (for the TVL cap).
  - **`valueOf(address asset, uint256 amount) public view returns (uint256)` — ADDED to the kept oracle this window
    (built + tested, `SzipNavOracle.sol`, 42/42).** The per-asset 18-dp USD mark of a deposit: it is the public
    projection of the oracle's private `_legPriceOfToken`/`_tokenValue` (`SzipNavOracle.sol:356/363`, zipUSD→`1e18`,
    xAlpha→`_xAlphaUSD()`, **reverts `UnknownLpToken` for anything else** — so a Gate whitelist mistake fails closed
    at the oracle too). **The Gate owns valuation via the oracle — the caller never asserts a value** (§3.4/§7).
    Additive: no behavior change to any existing oracle function (the 39 prior tests stayed green; +3 `valueOf` tests).
- **`SummonSubstrate` (8-B1, kept)** — `contracts/script/SummonSubstrate.s.sol` summons the Baal + main Safe
  (avatar = `mainSafe`, ragequit target = free equity) + the non-RQ sidecar + Loot/Shares (Loot paused, **Shares
  = 0 forever**), and injects the **team multisig as a Safe owner** on both Safes. The Gate's `manager(2)` grant is
  the **one seam 8-B1 leaves open**: post-summon, the team-admin signer calls `mainSafe.execTransaction →
  Baal.setShamans([gate],[2])`. The Gate's fork test reuses `SummonSubstrate._summon(team, salt)` then performs that
  grant (model the team-admin signer exactly as `SummonSubstrate._addOwnerToSidecar` does the owner `execTransaction`
  path) — proving the Gate's mint/burn/ragequit work **only after** the grant.
- **CoW swap SDK** (`reference/zodiac-modifier-roles/packages/sdk/src/swaps/`) — **NOT built here.** The CoW
  secondary (§6.2) and the 8-B14 buy-and-burn are *separate* concerns; this ticket only exposes `burnFor` (the
  on-fill retire hook 8-B14 will call). Do not author CoW order plumbing.

**Starting state**
- 8-B1 done (`SummonSubstrate.s.sol` + `IBaal`/`ISafe`); `SzipNavOracle` done (kept, 39/39); WOOF-00..05/10a kept.
- `contracts/src/supply/szipUSD/SzipUSD.sol` and `contracts/src/supply/szipUSD/ExitGate.sol` are created fresh with
  the WOOF-00-pinned header — exactly `// SPDX-License-Identifier: GPL-2.0-or-later` then `pragma solidity 0.8.24;`
  (keep both; do not change the license or bump the pragma). The test
  `contracts/test/ExitGate.t.sol` carries the same two-line header.
- **Remaps:** none new — `@openzeppelin/contracts/`, `forge-std/`, and the local `src/interfaces/baal` path are all
  present (WOOF-00/01/8-B1).
- Built/tested on the **live Base-mainnet fork** (`BASE_RPC_URL` in gitignored `contracts/.env`): real Baal summoner
  + Safes (8-B1's `_summon`) prove the live `mintLoot`/`burnLoot`/`ragequit`/`setShamans` faces and that the freeze
  (main-only ragequit, sidecar excluded) is real on-chain. The NAV oracle is the **real kept contract**, fed mock
  leg pushes via its Forwarder; the basket assets are mock ERC20s deposited into the real Safes (same pattern as
  `SzipNavOracle.t.sol`: real Euler/Baal live, the not-yet-built pieces mocked).

**Do NOT**
- **Do NOT use `require(cond, CustomError())`** — solc ≥ 0.8.26 only; WOOF-00 pins **0.8.24**. Use `if (!cond)
  revert CustomError();` for every custom-error guard.
- **Do NOT let the Gate ever call `baal.mintShares`** and **do NOT mint Loot to anyone but the Gate.** Minting any
  Shares destroys the zero-Shares governance-inertness + ragequit-purity invariant; minting Loot to a user would
  hand them a permissionless `ragequit` (the footgun the Gate exists to remove). Every test asserts
  `baal.totalShares() == 0` after issuance/exit. The Gate's mint path is **`mintLoot([gate],[shares])` only**.
- **Do NOT expose raw `ragequit` to depositors, and do NOT make szipUSD soulbound/transfer-gated.** The whole
  point: depositors hold only the **transferable** szipUSD (trades on CoW); the Gate is the **sole Loot-holder**,
  hence the sole ragequit caller, hence controls *when* exits happen (§6.4 item 1, `reports/design/baal-spec.md §2.3`).
- **Do NOT read or trust a caller-supplied value at issuance.** `depositFor` takes `(asset, amount, receiver)` — the
  Gate values `amount` via `navOracle.valueOf(asset, amount)`; no caller passes a price (§3.4/§7).
- **Do NOT read the szipUSD *market* (CoW) price** anywhere — issuance/exit price **only** off `SzipNavOracle`.
- **Do NOT keep custody of the deposited asset on the Gate.** `depositFor` pulls the asset **straight into the main
  Safe** (`transferFrom(payer, mainSafe, amount)`) so `grossBasketValue` reflects it; the Gate ends `depositFor`
  holding **zero** of the deposited asset (enforce a zero-residual assert in tests). The Gate's only standing
  holding is **Loot** (and szipUSD *escrowed* between `requestExit` and a window).
- **Window exits are PLAIN IN-KIND ragequit — do NOT add a numeraire conversion, a value-cap, or a surplus-sweep.**
  Pass `tokens[]` = the **full sorted basket** (zipUSD + xALPHA), ragequit straight to the exiter (`to = claim.owner`),
  burn the escrowed szipUSD. The exiter gets their literal pro-rata slice of the (free, main-Safe) basket — a mixture
  of zipUSD + xALPHA. Do **NOT** read the oracle on exit, do **NOT** claim only zipUSD, do **NOT** compute an `owe`
  or sweep anything: the in-kind slice self-prices to the live NAV by construction. (xALPHA→zipUSD is a *separate*
  auto-dump module; zipUSD→USDC is the existing `ZipRedemptionQueue` — neither is this contract's job.)
- **Do NOT size, engage, or release the freeze in the Gate.** The freeze is **structural** — committed equity lives
  in the non-RQ sidecar (item 9 / 8-B11 rotation). The Gate ragequits **only `mainSafe`**, so it *automatically*
  reaches only free equity; the partial-fill (a window that can't fund every queued claim from the free zipUSD) **is**
  the freeze. No `coverageFloor` knob, no sidecar reference, no utilization read in this contract (§6.4 item 5,
  `reports/design/baal-spec.md §5.4`).
- **Do NOT write any NAV markdown / provision** — that is the M2 `DefaultCoordinator` writing into `SzipNavOracle`,
  not the Gate.
- **Do NOT make `depositFor` permissionless-mint without the staleness/`fresh` gate.** `navEntry()` reverting
  `StalePrice` IS the issuance-pause; let it bubble (or pre-check `fresh()` for a cleaner error) — never mint at a
  stale or fallback price.
- **Do NOT process windows from an arbitrary caller.** `processWindow` is `onlyWindowController` (the CRE
  operator/keeper that opens windows when the harvest has unstaked the LP and the basket is liquid in the main Safe,
  §6.4 item 3). `requestExit`/`depositFor`/`burnFor` callers differ (see Key requirements).

**Key requirements**

*`SzipUSD` (the share)*
- **`constructor(address gate_)`** — `if (gate_ == address(0)) revert ZeroAddress();` store `address public
  immutable gate;` call `ERC20("Zipcode Junior Vault Share", "szipUSD")`. 18 decimals (OZ default).
- **`mint(address to, uint256 amount) external`** — `if (msg.sender != gate) revert NotGate();` `_mint(to, amount)`.
- **`burn(address from, uint256 amount) external`** — `if (msg.sender != gate) revert NotGate();` `_burn(from,
  amount)`. (The Gate holds escrowed szipUSD in a window and burns it from its own balance; the buy-and-burn burns
  the engine Safe's balance — both via the Gate, both burning the holder the Gate names.)
- `error NotGate(); error ZeroAddress();`. No `Ownable`, no admin, no other privileged surface. **Do NOT override
  `_update` (OZ v5's transfer hook) or add any transfer/approve gate** — szipUSD must be a plain, freely
  transferable ERC-20 so it trades on CoW (§6.2); the only non-standard surface is the `onlyGate` mint/burn.

*`ExitGate` — immutables & set-once wiring*
- **`constructor(address baal_, address navOracle_, address zipUSD_, address xAlpha_, uint256 tvlCap_)`** — reject
  `address(0)` on `baal_`/`navOracle_`/`zipUSD_`/`xAlpha_` (`ZeroAddress`); `tvlCap_ != 0`. Store as `immutable`:
  `IBaal public immutable baal; SzipNavOracle public immutable navOracle; address public immutable zipUSD; address
  public immutable xAlpha; uint256 public immutable tvlCap;`. Derive and store `address public immutable loot =
  baal.lootToken();` and `address public immutable mainSafe = baal.avatar();` (the ragequit target / the basket).
  `Ownable` owner = `msg.sender` (the deployer; frozen by renounce at item-10 wiring — same pattern as the oracle).
- **`shareToken` (szipUSD), set-once** — `setShareToken(address szipUSD_) external onlyOwner`: `if (shareToken !=
  address(0)) revert AlreadyWired(); if (szipUSD_ == address(0)) revert ZeroAddress();` store + emit. (Deploy-order:
  the Gate deploys first — szipUSD's ctor takes the Gate — so szipUSD is wired set-once afterward; the **same**
  szipUSD is also wired into `SzipNavOracle.setShareToken`.)
- **`windowController`, set-once** — `setWindowController(address controller_) external onlyOwner`: same set-once +
  zero-guard. The CRE operator/keeper that calls `processWindow` when the basket is liquid (§6.4 item 3). (Two-tier
  model: this is an *operator* seam, narrow blast radius — it can only *process the queue*, never mint or change
  authority.)
- **`engineSafe`, set-once** — `setEngineSafe(address engineSafe_) external onlyOwner`: the 8-B14 buy-and-burn Safe
  whose szipUSD `burnFor` retires. While unset, `burnFor` reverts (`NotWired`/fail-closed). (This is the **same**
  engine Safe wired into `SzipNavOracle.setEngineSafe` for the denominator exclusion — item-10 wires both.)
- Each setter reverts `AlreadyWired` on a second call and `ZeroAddress` on a zero arg (fail-closed). Genesis: with
  `shareToken == address(0)` the oracle returns `GENESIS_NAV`; the Gate must be wired before the first `depositFor`
  that should mint a real (non-genesis) share — but a genesis-priced first mint is *correct* (`navPerShare₀ = $1`),
  so `depositFor` does not itself require `shareToken != 0` (it requires it only to mint szipUSD — guard with a clear
  revert if `shareToken` unset).

*`ExitGate` — issuance (`depositFor`, absorbs the mint shaman)*
- **`depositFor(address asset, uint256 amount, address receiver) external returns (uint256 shares)`** —
  - `if (asset != zipUSD && asset != xAlpha) revert UnsupportedAsset(asset);` (M1 whitelist — the two §3-markable
    deposit assets; USDC is converted to zipUSD by the zap *before* reaching the Gate).
  - `if (amount == 0) revert ZeroAmount();` `if (shareToken == address(0)) revert NotWired();`
  - `navOracle.poke();` then `uint256 navE = navOracle.navEntry();` (reverts `StalePrice` if stale — issuance pauses).
  - `uint256 value = navOracle.valueOf(asset, amount);` (18-dp USD; the Gate owns valuation).
  - **TVL cap:** `if (navOracle.grossBasketValue() + value > tvlCap) revert TvlCapExceeded();` (read gross BEFORE the
    asset lands — i.e. before `transferFrom` to the Safe — so the cap is on the *pre-deposit* basket + the incoming
    value; equivalently read after with the new balance already counted — pick one and pin it: **read gross before
    the transfer, add `value`**, so the math is unambiguous).
  - `shares = value * 1e18 / navE;` (**round DOWN**, favor the vault). `if (shares == 0) revert ZeroShares();`
  - **Pull the asset into the basket:** `IERC20(asset).transferFrom(msg.sender, mainSafe, amount);` (the Gate keeps
    no custody; `msg.sender` = the zap (WOOF-06) for zipUSD or the team for in-kind xALPHA, each having approved the
    Gate). Use a safe-transfer-from (zipUSD = `ESynth` returns bool; OZ `SafeERC20.safeTransferFrom` is the robust
    choice — import `@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol`).
  - **Mint Loot to the Gate:** build single-element arrays `[address(this)]` / `[shares]`; `baal.mintLoot(g, a);`
  - **Mint szipUSD to the receiver:** `SzipUSD(shareToken).mint(receiver, shares);`
  - **Invariant (assert in tests, not on-chain):** after the call `SzipUSD(shareToken).totalSupply() ==
    IERC20(loot).balanceOf(address(this))` and `baal.totalShares() == 0`.
  - `emit Deposited(receiver, asset, amount, value, shares);`
  - **Reentrancy:** `nonReentrant` (OZ `ReentrancyGuard`) — `depositFor` makes external calls (`transferFrom`,
    `mintLoot`, oracle reads); the mint-Loot-and-mint-szipUSD pair must not interleave.

*`ExitGate` — the intent queue (`requestExit`)*
- **`requestExit(uint256 shares) external returns (uint256 requestId)`** —
  - `if (shares == 0) revert ZeroAmount();`
  - **Escrow the share:** `SzipUSD(shareToken).transferFrom(msg.sender, address(this), shares);` (the user must
    approve the Gate; the Gate holds the szipUSD until the window burns it). The Gate's escrowed szipUSD is **NOT**
    excluded from the NAV denominator (only the *engine* Safe's pre-burn balance is, `SzipNavOracle._effectiveSupply`)
    — a queued-but-unfilled claim is still a live share, still earning, until burned. (Pin this: do NOT wire the Gate
    as the oracle's `engineSafe`.)
  - Append `Claim{ address owner; uint256 shares; uint256 filled; }` to a FIFO array `claims`; `requestId =
    claims.length - 1`; track `uint256 public queueHead` (the next unfilled index for `processWindow` to resume from).
  - `emit ExitRequested(requestId, msg.sender, shares);`
- **`cancelExit(uint256 requestId) external`** (back-pressure / fairness — a user may withdraw an unfilled request):
  `if (requestId >= claims.length) revert NoSuchClaim();` `if (claims[requestId].owner != msg.sender) revert
  NotClaimOwner();` `uint256 remainder = claim.shares - claim.filled;` `if (remainder == 0) revert AlreadyClosed();`
  (so a **double-cancel** and a **cancel of an already-filled claim** both revert — never a silent no-op). Then set
  `claim.filled = claim.shares` (close it — `processWindow` skips closed claims), transfer the `remainder` szipUSD
  back to the owner (`SafeERC20.safeTransfer`), `emit ExitCancelled(requestId, remainder)`. A cancel does **not**
  compact the array or move `queueHead` (the loop skips closed claims as it passes them). `requestExit(shares >
  balance)` needs no Gate guard — the szipUSD `transferFrom` reverts `ERC20InsufficientBalance` naturally (pin in a
  test, do not add a redundant guard).

*`ExitGate` — the liquidity window (`processWindow`) — PLAIN IN-KIND RAGEQUIT*
- **`processWindow(uint256 maxClaims) external`** — `if (msg.sender != windowController) revert NotWindowController();`
  - **NO oracle read.** The exit is honest in-kind pro-rata; the slice self-prices to the live NAV. (`poke`/`navExit`/
    `valueOf` belong to *issuance*, not exit.) Build `tokens` once = `_basketTokens()` = the sorted basket assets.
  - **Loop control (pin exactly — FIFO):** iterate `i = 0..maxClaims`, reading `claims[queueHead]` each step.
    **Empty / exhausted** (`queueHead >= claims.length`) → break (no revert; emit `WindowProcessed(0, queueHead)`).
    `maxClaims == 0` → clean no-op. A claim closed by `cancelExit` (`s == shares - filled == 0`) → advance
    `queueHead` and continue. Otherwise fill it (whole). `queueHead` only advances; claims are never reordered/removed.
  - For each open claim, `s = claims[queueHead].shares - claims[queueHead].filled`:
    - **Ragequit straight to the exiter:** `baal.ragequit(claim.owner, 0, s, tokens);` — arg order
      `ragequit(to, sharesToBurn=0, lootToBurn=s, tokens)` (verified `Baal.sol:619`); `_ragequit` burns `s` Loot from
      `_msgSender()` = the Gate (`:647`) and pays `to = claim.owner` their **pro-rata in-kind slice** of
      `balanceOf(mainSafe)` for **each** token in `tokens` (zipUSD + xALPHA). Pure Baal pro-rata — no `owe`, no oracle,
      no fundability gate, no sweep. (The sidecar is excluded — not the RQ target — so the exiter automatically gets
      their share of the **free** basket only; that IS the freeze, structural, no code.)
    - **Burn the escrowed share:** `SzipUSD(shareToken).burn(address(this), s);` (keeps `szipUSD.totalSupply ==
      loot.balanceOf(gate)` — `s` Loot burned by ragequit, `s` szipUSD burned here).
    - `claim.filled = claim.shares; emit ExitFilled(requestId, claim.owner, s); queueHead++;`
  - After the loop, `emit WindowProcessed(claimsFilled, queueHead);`
  - **`_basketTokens()`** — internal helper returning `address[2]` = `{zipUSD, xAlpha}` **sorted ascending** (compare
    the two immutables; the LP is decomposed to its underlying by the harvest before a window, so M1 ragequits these
    two legs). Distinct addresses → strictly ascending → the Baal `"!order"` check passes.
  - **`nonReentrant`** (the Gate makes external calls — ragequit + burn).
  - **Invariant (assert in tests):** after `processWindow`, `SzipUSD.totalSupply() == IERC20(loot).balanceOf(gate)`
    (every `s` Loot burned by ragequit matched by `s` szipUSD burned); `baal.totalShares() == 0`; the Gate holds
    **zero** basket tokens (ragequit pays the exiter directly — the Gate is never a custody hop).

*`ExitGate` — the paired buy-and-burn hook (`burnFor`, the §7 / 8-B14 retire path)*
- **`burnFor(uint256 amount) external`** — `if (msg.sender != windowController) revert NotWindowController();` (the
  CRE op surface drives 8-B14 too) `if (engineSafe == address(0)) revert NotWired();` `if (amount == 0) revert
  ZeroAmount();` (consistency with `requestExit`). Both `burnLoot` and `SzipUSD.burn(engineSafe, …)` revert on an
  insufficient balance (Gate Loot < amount / engine szipUSD < amount) — checks precede effects so a revert leaves no
  half-burn.
  - **Pure supply retire, NO asset payout:** `baal.burnLoot([address(this)], [amount]);` (`_burnLoot:847`) **and**
    `SzipUSD(shareToken).burn(engineSafe, amount);` (the engine Safe's transient bought-back szipUSD). Supply drops by
    `amount` on both sides; the basket is untouched (the seller already got their USDC on the CoW fill) → navPerShare
    ticks **up** for stayers (the haircut accretes). `emit Burned(amount);`
  - **Invariant:** the szipUSD burned (engine Safe) == the Loot burned (Gate) → the `totalSupply == gate Loot`
    invariant is preserved; `baal.totalShares() == 0`. (The engine Safe must approve / hold the szipUSD; the Gate
    burns it directly via `SzipUSD.burn(engineSafe, amount)` — no allowance needed since `burn` is `onlyGate`.)
  - **DISCHARGES the `SzipNavOracle` 8-B14 denominator obligation's pairing:** the engine Safe is the same one wired
    into `SzipNavOracle.setEngineSafe` so its pre-burn szipUSD is already excluded from the denominator; `burnFor`
    is the retire that follows a fill. (8-B14 itself — the CoW bid plumbing — is a separate ticket.)

*Errors & events*
- `ExitGate`: `error ZeroAddress(); error ZeroAmount(); error ZeroShares(); error AlreadyWired(); error
  NotWired(); error UnsupportedAsset(address asset); error TvlCapExceeded(); error NotWindowController(); error
  NotClaimOwner(); error NoSuchClaim(); error AlreadyClosed(); error NavZero();`
- `event Deposited(address indexed receiver, address indexed asset, uint256 amount, uint256 value, uint256 shares);
  event ExitRequested(uint256 indexed requestId, address indexed owner, uint256 shares); event
  ExitFilled(uint256 indexed requestId, address indexed owner, uint256 shares); event
  ExitCancelled(uint256 indexed requestId, uint256 remainder); event WindowProcessed(uint256 claimsFilled,
  uint256 queueHead); event Burned(uint256 amount); event ShareTokenSet(address indexed szipUSD);
  event WindowControllerSet(address indexed controller); event EngineSafeSet(address indexed engineSafe);`

*Documented invariants (NatSpec — the design's accepted trade-offs)*
- **Two-token invariant:** `szipUSD.totalSupply() == loot.balanceOf(gate)` at all times — every Loot mint/burn is
  paired with an equal szipUSD mint/burn (issuance, window ragequit, buy-and-burn). The engine Safe's pre-burn
  szipUSD (excluded from the *oracle* denominator) is the only transient asymmetry, resolved on the next `burnFor`.
- **Exit is pure in-kind ragequit:** the share is a volatile NAV-bearing claim; you leave, you get your pro-rata slice
  of the treasury (worth `shares × NAV/share` by construction — the slice self-prices, so no oracle read is needed in
  the exit path). No numeraire, no value-cap, no surplus-sweep, no forfeit of the volatile legs.
- **The freeze is structural, not coded here:** `processWindow` ragequits only `mainSafe`; the committed slice is in
  the non-RQ sidecar (not the RQ target) → unreachable, so the exiter gets their share of the **free** basket. No
  floor knob, no fundability gate. (The CRE rotation that frees committed equity back to main is item 9.)
- **Zero-Shares forever:** the Gate never calls `mintShares`; `baal.totalShares() == 0` is asserted after every
  state-changing path (the governance-inertness + ragequit-purity invariant from 8-B1 / §4.5 item-0).

**Inbound cross-ticket obligations DISCHARGED here** (PROGRESS "Open cross-ticket obligations"):
- **"Exit Gate (item 3) · manager grant + Shares invariant" (from 8-B1 F4.2):** the Gate's `manager(2)` is granted
  by `team-admin → mainSafe.execTransaction → Baal.setShamans([gate],[2])` (NOT a proposal, NOT raw `setShamans`);
  the genesis seed mints Loot only AFTER the Gate holds manager; the Gate is **structurally unable to call
  `mintShares`** (only `mintLoot`/`burnLoot`/`ragequit`); every test asserts `baal.totalShares() == 0`. **The fork
  test proves all of it:** before the grant, `depositFor` reverts (the `mintLoot` call fails the `baalOrManagerOnly`
  gate); after the grant, it succeeds.
- **"Exit Gate + szipUSD (NEXT) · NAV pricing seam" (from `SzipNavOracle`):** issue NAV-proportionally off
  `navEntry()` (round down), exit/window-RQ at `navExit()`, **`poke()` before reading**; szipUSD is wired into the
  oracle via `setShareToken`; the Gate is the **first minter** (so a pre-deposit donation can't profit an attacker —
  the oracle adds no first-depositor guard; round-down + the §4.2 seed cover it).

**Done when**
- `forge build` green (solc 0.8.24); new suite `contracts/test/ExitGate.t.sol` passes; **no regression** (`forge
  test` — the existing 154 stay green). The `valueOf` oracle addition keeps `SzipNavOracleTest` green.
- **Unit / fork (Foundry — real Baal+Safes via `SummonSubstrate._summon`, the real `SzipNavOracle`, mock basket
  ERC20s + mock Forwarder pushes).** Pin exact errors with `abi.encodeWithSelector` where named.
  - *Deploy + wiring:* deploy `ExitGate`, `SzipUSD(gate)`, wire `gate.setShareToken(szipUSD)` +
    `oracle.setShareToken(szipUSD)` + `gate.setWindowController(keeper)` + `gate.setEngineSafe(engine)`; each setter
    reverts `OwnableUnauthorizedAccount` from non-owner and `AlreadyWired` on a second call; `SzipUSD.mint`/`burn`
    from a non-Gate caller revert `NotGate`.
  - *Manager gate (the inbound obligation):* BEFORE `setShamans([gate],[2])`, `gate.depositFor(zipUSD, 1e18, alice)`
    **reverts** (the `mintLoot` fails `baalOrManagerOnly`); after the team-admin grant, the same call **succeeds** and
    `baal.shamans(gate) == 2`, `baal.totalShares() == 0`.
  - *Issuance (NAV-proportional, round-down):* push leg prices so `fresh()`; `depositFor(zipUSD, 12e18, alice)` at
    `navEntry == 1.2e18` → `shares == 10e18`; at `navEntry == 0.8e18` → `15e18`; assert the asset landed in `mainSafe`
    (`zipUSD.balanceOf(mainSafe)` rose by `amount`), the Gate holds **zero** zipUSD (zero-residual), `szipUSD.balanceOf
    (alice) == shares`, `loot.balanceOf(gate) == szipUSD.totalSupply()`, `baal.totalShares() == 0`, and `Deposited`
    fired. `depositFor(xAlpha, …)` values via `valueOf` (set `exchangeRate`/`alphaUSD`) → hand-computed shares. A
    `value/navEntry` that floors to 0 reverts `ZeroShares`. `amount == 0` reverts `ZeroAmount`. An asset ∉
    `{zipUSD,xAlpha}` reverts `UnsupportedAsset`. With a leg stale, `depositFor` reverts `StalePrice` (issuance pause).
  - *TVL cap:* a deposit that would push `grossBasketValue + value` over `tvlCap` reverts `TvlCapExceeded`; one just
    under succeeds.
  - *Genesis / first-deposit:* with `szipUSD.totalSupply == 0`, the first `depositFor` mints at `GENESIS_NAV = 1e18`
    (shares == value); a basket donation to `mainSafe` *before* the first mint does not let the first depositor extract
    more than they put in (round-down + first-minter — assert the donor/first-depositor cannot profit).
  - *Intent queue:* `requestExit(s)` pulls `s` szipUSD into the Gate (user approved), appends a claim, emits
    `ExitRequested`; the Gate's escrowed szipUSD is still counted in `oracle` supply (NOT excluded). `cancelExit` by a
    non-owner reverts `NotClaimOwner`; by the owner returns the unfilled remainder + closes the claim.
  - *Window — pro-rata in-kind (the heart):* deposit alice+bob; queue alice's full exit; `processWindow` from a
    non-controller reverts `NotWindowController`; from the controller, alice gets her **pro-rata slice of the
    main-Safe basket in-kind** (e.g. 10/20 of an all-zip basket = her zip), `s` szipUSD + `s` Loot burned, `queueHead`
    advances, the Gate holds **zero** basket tokens (ragequit pays the exiter directly), `szipUSD.totalSupply ==
    loot.balanceOf(gate)`, `baal.totalShares == 0`.
  - *Window — multi-asset in-kind:* with the basket holding **both** zipUSD and xALPHA (mint xALPHA into `mainSafe` to
    model accrued yield), alice's exit pays her pro-rata of **both** legs (e.g. 10/20 → her zip + her xALPHA); the
    stayer's half of each leg stays in `mainSafe`. No conversion, no forfeit.
  - *Freeze = free-equity-only:* move part of the basket `mainSafe → sidecar` (committed); `processWindow` pays the
    exiter their pro-rata of the **free (main-Safe)** basket only; assert the **sidecar balance is untouched** (the
    structural freeze — ragequit target is `mainSafe`). No fundability gate, no partial-Loot.
  - *Buy-and-burn (`burnFor`):* with `engineSafe` wired + holding szipUSD, `burnFor(amount)` from the controller
    `burnLoot`s `amount` from the Gate + burns `amount` szipUSD from the engine Safe; basket (`mainSafe` balances)
    **unchanged**; `szipUSD.totalSupply` and `loot.balanceOf(gate)` both drop by `amount` (invariant held);
    `baal.totalShares == 0`. From a non-controller reverts `NotWindowController`; before `setEngineSafe`, reverts `NotWired`.
  - *Edge cases:* `processWindow` on an empty/exhausted queue (`queueHead >= claims.length`) and `maxClaims == 0`
    each emit `WindowProcessed(0, queueHead)` and revert nothing; `burnFor(0)` reverts `ZeroAmount`; `cancelExit` of a
    non-existent id reverts `NoSuchClaim`, a double-cancel / cancel-of-filled reverts `AlreadyClosed`;
    `requestExit(shares > balance)` reverts `ERC20InsufficientBalance` (no Gate guard); `burnFor` with engine szipUSD
    `< amount` reverts; a claim closed by `cancelExit` is skipped by `processWindow` and its szipUSD was returned, not burned.
  - *Reentrancy:* a malicious basket/share token cannot re-enter `depositFor`/`processWindow`/`burnFor` (each
    `nonReentrant` + checks-effects ordering); assert the re-entrant call reverts and no partial mint/burn persists.
  - *Two-token invariant (cross-cut):* a property-style sequence (deposit×N, requestExit, processWindow, burnFor)
    keeps `szipUSD.totalSupply() == loot.balanceOf(gate)` and `baal.totalShares() == 0` at every step.
- **Fork sig-verification (keep-the-build mandate):** on a Base fork, the real `SummonSubstrate._summon` proves the
  live `mintLoot`/`burnLoot`/`ragequit`/`setShamans`/`avatar`/`lootToken`/`totalShares` faces; the real
  `SzipNavOracle` proves `navEntry`/`valueOf`/`grossBasketValue` (the issuance reads; the exit path reads no oracle). (The zipUSD/xALPHA basket assets +
  the szipUSD share are project contracts, not external — mocked/real as built.)
- **Acceptance (integration — owned here, satisfied downstream):** **WOOF-06** (the zap re-author) calls
  `gate.depositFor(zipUSD, zipAmount, user)`; **8-B14** calls `gate.burnFor` on a CoW fill; **item 10** deploys the
  Gate + szipUSD, grants `manager(2)` via the team-admin `setShamans`, wires `setShareToken`/`setWindowController`/
  `setEngineSafe` (+ the oracle's `setShareToken`/`setEngineSafe`), then renounces; the **CRE/keeper** drives
  `processWindow` on the harvest cadence (`audit/2` Phase S/L rows authored when the junior-acceptance harness is —
  the EXCISED markers in `audit/2`/`audit/3-results` rows 25-27 / Trace E point here).

**Depends on**
8-B1 (the Baal + main Safe + sidecar + Loot, via `SummonSubstrate`), `SzipNavOracle` (the issuance/exit price + the
`valueOf` seam this item adds), WOOF-00 (scaffold + remaps). Buildable + provable on a Base fork with the real
substrate + oracle and mock basket assets. Downstream consumers: **WOOF-06** (the zap, re-authored to `depositFor`),
**8-B14** (buy-and-burn calls `burnFor`), **item 9** (the sidecar rotation feeds the windows), **item 10** (deploy +
manager grant + wiring + renounce), the **CRE/keeper track** (`processWindow` cadence).

**Spec edits this ticket made (DONE this window — both critic-confirmed spec gaps)**
1. **§6.4 item 3** — rewrote the window exit as **plain in-kind ragequit**: the exiter gets their pro-rata slice of
   the (free, main-Safe) basket (zipUSD + xALPHA), no oracle/cap/numeraire on exit (the slice self-prices to NAV); the
   downstream **xALPHA→zipUSD auto-dump module** + the existing **`ZipRedemptionQueue`** (zipUSD→USDC) are named as the
   separate legs; the **set-once `windowController`** (CRE-operator/keeper, the §4.5 item-0 operator tier) opens windows.
2. **§7** — added the **`valueOf(asset, amount)`** public per-asset valuation getter to the `SzipNavOracle` surface
   (the Gate's issuance reads it; the oracle is the §3 valuation authority — additive, no behavior change).
3. **Kept-oracle code** — added `valueOf(address,uint256) public view` to `contracts/src/supply/SzipNavOracle.sol`
   (public projection of `_tokenValue`; reverts `UnknownLpToken` off-whitelist) + 3 unit tests; **42/42 green, 39
   prior tests un-regressed.** This is the dependency the Gate compiles against — done FIRST per the harness.

**Cross-ticket obligations this ticket CREATES (discharge by the named item)**
1. **WOOF-06 (zap re-author):** approve the Gate for the per-zap zipUSD then call `gate.depositFor(zipUSD, zipMinted,
   user)`; consume the returned `shares`; emit `Zapped(user, usdcIn, zipMinted, shares)` (szipUSD, not Loot).
2. **8-B14 (buy-and-burn):** the engine Safe is wired via `gate.setEngineSafe` (== the oracle's `engineSafe`); on a
   CoW fill the CRE op calls `gate.burnFor(amount)`.
3. **Item 9 (sidecar rotation):** rotate SIDECAR→MAIN on line close so a leaver's free-equity share grows; the Gate
   never touches the sidecar (the freeze is structural).
3a. **Exit auto-dump module (NEW ticket — `tickets/sodo/8-B-exit-autodump.md`):** a separate Zodiac module that
   market-sells the **xALPHA leg** the leaver received → zipUSD on Hydrex, so they walk out holding only zipUSD. NOT
   the Gate; reuses the engine's Hydrex sell machinery (8-B9).
4. **Item 10 (deploy/wiring):** deploy Gate → szipUSD(gate) → `gate.setShareToken`/`oracle.setShareToken`/
   `gate.setWindowController`/`gate.setEngineSafe`/`oracle.setEngineSafe`; grant `manager(2)` via the team-admin
   `mainSafe.execTransaction → Baal.setShamans([gate],[2])`; seed genesis Loot/szipUSD AFTER the grant; assert
   `baal.shamans(gate)==2` + `baal.totalShares()==0` + every wiring set before `renounceOwnership()`.
