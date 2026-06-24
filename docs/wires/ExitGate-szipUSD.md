# ExitGate + szipUSD — the deposit/exit seam (wiring map)

> **X-Ray (security verdict):** `ExitGate` rated **ADEQUATE** (a hair from HARDENED) — sole szipUSD
> minter/burner; the two-token conservation (`szipUSD.totalSupply() == loot.balanceOf(gate)`) is under a fuzzed
> stateful invariant vs the real Baal + oracle; no `ragequit` reachable. `SzipUSD` rated **ADEQUATE** (vanilla
> non-rebasing ERC-20, gate-only mint/burn). Reports under `contracts/src/supply/szipUSD/x-ray/`
> (`ExitGate.md`, `SzipUSD.md`; scope: `portfolio-map.md`). ELI20: `docs/supply/szipUSD/ExitGate.md`,
> `…/SzipUSD.md`. This doc is the code-truth wiring map.

> Source of truth = the kept code under `contracts/src/supply/szipUSD/{ExitGate,SzipUSD}.sol`. Ticket
> (`tickets/sodo/8-B-exit-gate-szipusd.md`) + reports (`reports/Exit-Gate-report.md`,
> `reports/credit-union-report.md`) are intent — **code wins.** This doc reads the code as the final form. The
> credit-union rework (C3) already deleted the forfeiting on-chain exit queue; what follows is the *current* code,
> not the historical windowed-ragequit design the older report describes.

## Role
The two-token junior surface. **`SzipUSD`** is the freely transferable 18-dp ERC-20 user share (`"Zipcode Junior
Vault Share"` / `szipUSD`) — non-rebasing; NAV accrues in *price* (`SzipNavOracle`), never in balance; the ONLY
non-standard surface is the `onlyGate` mint/burn. **`ExitGate`** is the seam's authority: it is the **sole Baal
`Loot` custodian** (holds `manager`=2, granted post-deploy by the team-admin), the **sole szipUSD minter/burner**,
and the **sole `burnLoot` caller**. Depositors therefore hold only the transferable szipUSD — never raw Loot — so
a raw `ragequit` footgun is structurally impossible. The Gate mints Loot to *itself* 1:1 against every szipUSD it
mints to a receiver, keeping `szipUSD.totalSupply() == loot.balanceOf(gate)` and `totalShares() == 0` forever
(`claude-zipcode.md` §2/§6.4; `reports/baal-spec.md` §4/§5/§7).

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `ExitGate` (`is Ownable, ReentrancyGuard`) | Custody + issuance + burn valve. `depositFor(asset,amount,receiver)` = NAV-proportional issuance off `SzipNavOracle.navEntry()` (round down); routes the asset into the main Safe basket; mints Loot to itself + szipUSD to the receiver. `burnFor(amount)` = the §7/8-B14 paired buy-and-burn retire (the only exit executor), `windowController`-gated, `burnLoot` from the Gate + burn the engine Safe's szipUSD, NO asset payout. `previewDeposit` = a view quote. All wiring fields are `onlyOwner` (Timelock) setters — build-phase, NOT immutable. **No `mintShares`** path exists. |
| `SzipUSD` (`is ERC20, Ownable`) | The transferable share. `mint(to,amount)`/`burn(from,amount)` both revert `NotGate` unless `msg.sender == gate`. `gate` is a single `onlyOwner`-settable pointer (`setGate`) — build-phase re-pointable **only until first issuance** (`AlreadyIssued` once `totalSupply() != 0`, SUPPLY-ADV-12), immutability re-freeze still deferred to pre-prod. Nothing else non-standard. |

## Wiring — internal

### ExitGate constructor + state
`constructor(address baal_, address navOracle_, address zipUSD_, address xAlpha_, uint256 tvlCap_) Ownable(msg.sender)`
— rejects any zero address and a zero `tvlCap_`, then:
- `baal = IBaal(baal_)`, `navOracle = SzipNavOracle(navOracle_)`, `zipUSD = zipUSD_`, `xAlpha = xAlpha_`, `tvlCap = tvlCap_`.
- **Derives** `loot = IBaal(baal_).lootToken()` and `juniorTrancheSafe = IBaal(baal_).avatar()` from the Baal — these are not
  ctor args, they are read off the substrate. The deployer becomes `owner` (handed to the Timelock at item 10).

All wiring is **Timelock-settable, NOT immutable** (`§17`, 2026-06-09 build-phase): a redeployed Baal/oracle/token/
Safe is a one-call re-point, not a redeploy cascade. The `onlyOwner` setters:
- `setShareToken(address szipUSD_)` → sets `shareToken` (szipUSD is deployed *after* the Gate, so it is wired in
  post-construction; `depositFor` reverts `NotWired` until this is set).
- `setWindowController(address)` → the CRE operator/keeper that drives `burnFor`.
- `setJuniorTrancheEngine(address)` → the 8-B14 buy-and-burn Safe whose szipUSD `burnFor` burns from.
- `setBaal(address)` → re-points and **re-derives** `loot` + `juniorTrancheSafe`.
- `setNavOracle(address)`, `setTokens(zipUSD_, xAlpha_)`, `setTvlCap(uint256)` (rejects 0).

**Pre-issuance lock on the two conservation-defining pointers (SUPPLY-ADV-06).** `setShareToken` and `setBaal`
(which re-derives `loot`) call `_assertPreIssuance()` — they revert `AlreadyWired` once `shareToken != 0 &&
SzipUSD(shareToken).totalSupply() != 0`. A mid-life re-point would strand the Gate's paired Loot / fork the I-1
identity (`totalSupply == loot.balanceOf(gate)`) onto a token it no longer tracks, so it fails closed; both stay
freely re-pointable BEFORE the first deposit. The other five setters (oracle, tokens, windowController, engine, cap)
do **not** touch the I-1 identity and stay re-pointable until the pre-prod immutable re-freeze.

### `depositFor(address asset, uint256 amount, address receiver) returns (uint256 shares)` — the issuance seam
`nonReentrant`. Guards: `asset` must be `zipUSD` or `xAlpha` (else `UnsupportedAsset`); `amount != 0` (`ZeroAmount`);
`shareToken != 0` (`NotWired`). Then:
1. `navOracle.poke()` — refresh the accumulator before reading.
2. `navE = navOracle.navEntry()` — **propagates `StalePrice`** if a required leg is stale (issuance pauses).
3. `value = navOracle.valueOf(asset, amount)` — the Gate owns valuation; the caller asserts no price.
4. **TVL-cap backstop:** `if (navOracle.grossBasketValue() + value > tvlCap) revert TvlCapExceeded()`.
5. `shares = value * 1e18 / navE` — **round DOWN** (favors the vault); `shares != 0` (`ZeroShares`).
6. `IERC20(asset).safeTransferFrom(msg.sender, juniorTrancheSafe, amount)` — the asset lands straight in the basket (main
   Safe); the Gate keeps **zero custody** of it. **Received-delta guard (SUPPLY-ADV-07):** snapshots the basket
   balance around the transfer and reverts `TransferShortfall` unless it rose by exactly `amount` — a fee-on-transfer
   / rebasing leg that credited less would over-issue szipUSD against backing the basket never received (`shares` is
   priced off the full `amount` at step 3). Same guard the sibling `DurationFreezeModule` carries.
7. `baal.mintLoot(_one(address(this)), _one(shares))` — Loot to the Gate (the `manager(2)` capability).
8. `SzipUSD(shareToken).mint(receiver, shares)` — transferable szipUSD to the receiver.

Steps 7+8 are the paired, equal Loot-mint / share-mint that holds the two-token invariant. The Gate calls
`mintLoot` **only** — never `mintShares` — so `totalShares() == 0` is preserved structurally (the invariant is
asserted by the test harness's `_assertInvariants()` helper after every path, NOT by an on-chain function in the
contract).

### `previewDeposit(address asset, uint256 amount) view returns (uint256 shares)`
A read-only quote (the UI/`ZipDepositModule.previewZap` reads it). Mirrors `depositFor`'s pricing exactly —
`valueOf` ÷ `navEntry()`, round DOWN — **without** the `poke()`/`mint`/cap side-effects. It reverts identically on an
unsupported asset, a zero amount, or a stale oracle (`navEntry()` propagates `StalePrice`), but **does NOT** check
`tvlCap` or whether `shareToken` is wired (a pure pricing projection; the cap + wiring are enforced by `depositFor`
at execution). View-only ⇒ it cannot `poke()` first; it reads the accumulator as-is.

### `burnFor(uint256 amount)` — the only exit executor (paired buy-and-burn, §7 / 8-B14)
`nonReentrant`. `if (msg.sender != windowController) revert NotWindowController()`; `shareToken != 0` (`NotWired`,
SUPPLY-ADV-06 — explicit, symmetric with `depositFor`, not an incidental call-to-codeless-address revert);
`juniorTrancheEngine != 0` (`NotWired`); `amount != 0`. Then `baal.burnLoot(_one(address(this)), _one(amount))` + `SzipUSD(shareToken).burn(juniorTrancheEngine, amount)`
— pure supply reduction on **both** sides, **no asset payout**, basket untouched ⇒ NAV-per-share ticks up for
stayers. This retires szipUSD the engine Safe bought below NAV on the CoW book.

### SzipUSD constructor + mint/burn authority
`constructor(address gate_) ERC20("Zipcode Junior Vault Share", "szipUSD") Ownable(msg.sender)` — rejects a zero
gate, sets `gate = gate_`, emits `GateSet`. `mint(to,amount)` and `burn(from,amount)` each `revert NotGate()`
unless `msg.sender == gate`. `setGate(address)` is `onlyOwner` (Timelock, build-phase re-point) and `revert
AlreadyIssued()` once `totalSupply() != 0` (SUPPLY-ADV-12 — the sole-minter pointer is the third leg of the
two-token conservation, so it fails closed over a live supply, symmetric with `ExitGate._assertPreIssuance`).
There is **no public mint/burn, no cap, no pause** — the Gate is the entire authority surface.

## Wiring — cross-component (who points at whom)
- **Gate `manager(2)` grant (the inbound 8-B1 F4.2 obligation).** The Gate's Loot-mint capability is granted by the
  team-admin, NOT a Baal proposal (governance is inert at zero Shares), NOT a raw `setShamans` (it is avatar-only):
  `team-admin → juniorTrancheSafe.execTransaction → Baal.setShamans([gate], [2])`. Fork-proven in `ExitGate.t.sol`
  (`test_depositFor_reverts_without_manager_grant`: pre-grant `depositFor` reverts at `mintLoot`
  (`baalOrManagerOnly`), post-grant it succeeds). PROGRESS row 319 = DISCHARGED.
- **szipUSD ↔ Gate ↔ NavOracle.** szipUSD's ctor takes the Gate (deployed first), so the Gate is its sole minter.
  `setShareToken(szipUSD)` then wires szipUSD into **both** the Gate (so `depositFor`/`burnFor` can mint/burn it) and
  `SzipNavOracle` (so the oracle's denominator = szipUSD supply). PROGRESS row 324 = DISCHARGED.
- **`ZipDepositModule` → `gate.depositFor`.** The zap (WOOF-06, §4.5/§5) grants the Gate a per-zap zipUSD allowance
  and calls `gate.depositFor(zipUSD, zipAmount, user)` with the end user as `receiver` — the Gate pulls the zipUSD
  into the basket and mints transferable szipUSD to the user on-behalf (`claude-zipcode.md` §4.5 / §6.4).
- **`SzipBuyBurnModule.burnFor` rail.** 8-B14 (`is Module` on the engine Safe, `onlyOperator`) posts a discounted
  resting `BUY szipUSD` CoW bid `≤ navExit×(1−d)`; on fill the bought szipUSD lands in the engine Safe; the CRE/
  `windowController` then calls `ExitGate.burnFor(amount)`, which burns it from `juniorTrancheEngine`. The Gate's
  `juniorTrancheEngine` must equal the module's `juniorTrancheEngine` and the oracle's `setJuniorTrancheEngine` (denominator exclusion of the
  transient pre-burn szipUSD) — wired at deploy (PROGRESS rows 325 module-side ADDRESSED, oracle-side OPEN at item 10).
- **Hard `tvlCap` backstop ↔ WOOF-06 measured cap.** The Gate carries a hard `tvlCap` (`grossBasketValue()+value ≤
  tvlCap`); 8-B12 describes a dynamic measured `maxDeposit` as the WOOF-06 deposit gate. WOOF-06 composes the
  measured cap **on top** of the Gate backstop (measured ≤ hard; a deposit blocked by either reverts) — PROGRESS
  row 332, OPEN.

## Item-10 deploy facts
- **Manager grant + zero-Shares invariant (PROGRESS 319).** Grant `manager(2)` via `team → juniorTrancheSafe.execTransaction
  → setShamans([gate],[2])` only AFTER the Gate is deployed; the genesis seed (§4.3) mints Loot only after the Gate
  holds manager. The Gate (and every manager-holder) MUST be structurally unable to call `mintShares` — the kept
  code only `mintLoot`/`burnLoot`, and every downstream fork test asserts `IBaal(baal).totalShares() == 0`.
- **szipUSD owner == TIMELOCK, not 0 (PROGRESS 322 lineage).** szipUSD is NOT renounced — its `gate` pointer stays
  re-pointable in the build phase, so `owner()` is transferred to the `TimelockController`, asserted `== TIMELOCK`
  (NOT `== 0`). Same Timelock-LAST-not-renounce discipline as `SzipNavOracle` (PROGRESS 327).
- **juniorTrancheEngine wiring (PROGRESS 325).** Wire `module.juniorTrancheEngine == ExitGate.juniorTrancheEngine == SzipNavOracle.juniorTrancheEngine ==
  order.receiver` so the bought szipUSD lands in the one Safe `burnFor` burns from AND that Safe's transient szipUSD
  is excluded from the navPerShare denominator. Module-side proven (`module.juniorTrancheEngine() == ExitGate.juniorTrancheEngine()`);
  the oracle's `setJuniorTrancheEngine` clause is still OPEN at deploy.
- **windowController wiring.** `setWindowController(CRE-keeper)` — the single actor allowed to call `burnFor`
  (`NotWindowController` otherwise). The CRE holds both the buy-burn `operator` and this `windowController` role and
  drives `postBid`/`burnFor` directly.
- **tvlCap (PROGRESS 332).** Set the governed gross-basket cap (ctor arg, re-settable via `setTvlCap`, rejects 0);
  WOOF-06 layers the measured cap on top.
- **junior-acceptance audit sweep (PROGRESS 330, OPEN).** The deferred `audit/2` L3 (deposit→szipUSD), L12 (exit),
  S7 (junior wiring: manager-grant + `windowController` + `setShareToken`) + `audit/3-results` rows 25–27 / Trace E
  must be re-authored once the deposit path is integration-testable (post WOOF-06 zap + deploy/wiring). **It must
  trace the CoW exit, not `processWindow`** — the forfeit removal changed the path being audited.
- All Gate + szipUSD wiring is **Timelock-settable** (build phase, §17) — immutability deferred to pre-prod.

## Gotchas
- **The forfeiting on-chain exit queue is GONE (credit-union.md C3).** The older `Exit-Gate-report.md` describes
  `requestExit`/`cancelExit`/`processWindow` (a keeper-driven windowed in-kind ragequit). The credit-union rework
  **deleted** `processWindow` + its orphans — the forfeit math, the `Claim` struct/queue, and `_basketTokens`/the
  in-kind-ragequit payout. The reason it was removed: it ragequit the FULL claim against the *free* main-Safe
  basket, so an exiter at utilization `U` **forfeited `U` of their equity to stayers** — a confiscation. That rail is
  replaced by the CoW book + the treasury buy-and-burn (`burnFor`). The kept `ExitGate.sol` has **no** `ragequit`
  call at all — only `mintLoot`/`burnLoot`.
- **`test_invariant_sequence` was repurposed, not deleted.** The credit-union report says the "hidden
  `test_invariant_sequence` landmine" was removed; in the kept `ExitGate.t.sol` (line 372) it still exists but is
  **reworked** to assert the two-token invariant across deposit → a *simulated CoW fill* (transfer to the engine
  Safe) → `burnFor`. The landmine that was actually removed = the forfeit/`processWindow`/`requestExit` test cases.
- **`_assertInvariants()` is a TEST helper, not a contract function.** The invariant (`szipUSD.totalSupply() ==
  loot.balanceOf(gate)` + `totalShares() == 0`) is enforced *structurally* by the contract (only paired
  `mintLoot`+`mint` / `burnLoot`+`burn`, never `mintShares`) and *checked* by the test's `_assertInvariants()` (line
  174) after every path. Do not look for an on-chain `_assertInvariants`.
- **Two distinct exits, both Gate-mediated, depositors hold no raw Loot.** (1) The CoW book — a holder rests a
  szipUSD sell order, the treasury (`SzipBuyBurnModule`, buy `≤ navExit×(1−d)`) or an external buyer fills it,
  retired via `burnFor`. (2) The windowed-RQ via the juniorTrancheSidecar is **wind-down-only** / the structural freeze, not the
  routine impatient exit. The routine exit is the CoW book.
- **`previewDeposit` is an ESTIMATE.** NAV (and staleness) can move between the read and the tx (the §3
  `max(spot,twap)` entry bracket); the realized `shares` may differ. It is exact only in the same block with a fresh
  oracle. It also skips the cap + wiring checks `depositFor` enforces.
- **The Gate is a Baal manager-shaman + Loot holder, NOT a Safe Zodiac module.** It mints/burns Loot via
  `baal.mintLoot/burnLoot` (the manager capability) — neither needs the Gate enabled as a Safe module. The deposited
  asset routes to the main Safe via plain `safeTransferFrom`, not a module call.
- **0.8.24 pin.** Guards use `if (!cond) revert CustomError()` (the `require(cond, CustomError())` form is 0.8.26+).
