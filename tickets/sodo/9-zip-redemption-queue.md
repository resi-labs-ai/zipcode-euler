# 9 — `ZipRedemptionQueue` — senior zipUSD → USDC epoch redemption queue (§6.1 / §4.5 / baal-spec §12)

> **NEXT / build-only.** The **SENIOR exit**: un-staked **zipUSD → USDC** at **par ($1)** via a **30-day epoch
> queue** with **pro-rata partial fills** when the warehouse can't free enough cash. This is the inverse of the
> WOOF-06 zap's `deposit` (mint zipUSD against USDC parked in the warehouse). It is **NOT the junior Exit Gate
> (§6.4)** — different instrument (zipUSD = the senior $1 dollar, not the szipUSD junior share), different exit,
> different pricing (par, **not** NAV). **Never conflate.** Internal protocol plumbing driven by the CRE
> redemption-settle cron → **build-only** (no INFLOW ticket this window; the redeem/claim UI folds into the
> post-deploy frontend sweep, memory `[[frontend-after-contracts]]` — but this ticket pins the events/views that
> sweep will read; see "Frontend back-pressure surface").

**Deliverable**
One contract + one minimal local interface + tests under the supply tree:
- `contracts/src/supply/ZipRedemptionQueue.sol` — `contract ZipRedemptionQueue is ReentrancyGuard`. A standalone
  (NOT inherited-from-solmate, NOT a Zodiac module, NOT `ReceiverTemplate`) async redemption queue modeled on the
  ERC-7540 `requestRedeem → settle/fulfill → claim` lifecycle (`reference/erc7540-reference`) + a clean-room
  Maple-style pro-rata epoch settle (`reference/maple-withdrawal-manager`). It escrows **external** zipUSD
  (`ESynth`, 18-dp), settles against the USDC the CRE delivers (warehouse REDEEM → REPAY, §8.5), pays USDC at
  **par** (÷`scaleUp`), and burns the filled zipUSD.
- `contracts/src/interfaces/euler/IZipUSD.sol` — minimal local interface for the zipUSD `ESynth` burn seam
  (`burn(address,uint256)`); reuse `@openzeppelin/.../IERC20` for transfers via `SafeERC20`. (Do NOT add an
  `IEulerEarn` import — the queue MUST NOT reference EulerEarn at all; see Key requirement KR-1.)
- `contracts/test/ZipRedemptionQueue.t.sol` — unit + property/fuzz + one integration test wiring the real
  `WarehouseAdminModule` REPAY → queue → `settleEpoch` on a Base fork.

**Spec §**
- `claude-zipcode.md` **§6.1** (epoch queue at par — the lifecycle, the 4-step `settleEpoch`, locked: 30-day epoch,
  **no mid-epoch cancellation**, pro-rata partial fill, carry-forward) + **§4.5** "`ZipRedemptionQueue`" bullet
  (fork target; **ownership = immutable controller, NOT the forked `Owned` owner; `transferOwnership` removed/inert;
  NOT renounced** — the controller keeps calling `settleEpoch` each epoch) + **§6.2** (the AMM secondary is the
  early-exit path — this queue is the at-par path; **the two are independent**, do not couple) + **§6.3** (the
  binding limiter is redemption-vs-draw contention — the queue throttles to freeable warehouse liquidity) + **§8.3**
  (the CRE redemption-settlement cron: **first** warehouse REDEEM → **then** REPAY to the queue sink → **then**
  `settleEpoch()`) + **§8.5** (the warehouse op-set: REDEEM=3 `redeem(shares, SAFE, SAFE)`, REPAY=4
  `USDC.transfer(to==<pinned sink>, amount)` — the sink is THIS queue).
- `baal-spec.md` **§12** (Senior redemption — ZipRedemptionQueue: `requestRedeem → settleEpoch(fulfill) → claim`;
  fork of erc7540-reference + Maple pro-rata; epoch=30 days governed; "Low novelty — a fork + a settle") + **§11**
  (the `CreditWarehouse` it is funded by; the queue is the REPAY sink) + **§19.x** (senior ≠ junior — invariant 9).
- **Locked §17:** zipUSD = **$1 utility**, redeemed for USDC (this queue) or sold (secondary). zipUSD is
  **insulated from loss until the junior is exhausted** (loss waterfall §11) — so this M1 queue redeems at **strict
  par** (no NAV, no markdown, no haircut on the senior). Do **not** introduce any senior markdown/NAV here.

**Model from (VERIFIED against `reference/` this window — by inspection, not cited blind)**
- **The 7540 lifecycle shape** — `reference/erc7540-reference/src/ControlledAsyncRedeem.sol` +
  `BaseERC7540.sol` (MIT, `pragma ^0.8.15`). **Verified surface (model, do NOT inherit;** the functions live in the
  `abstract contract BaseControlledAsyncRedeem`, with the concrete `ControlledAsyncRedeem` a 1-line subclass at
  `:153` — line numbers below are exact**):**
  - `requestRedeem(uint256 shares, address controller, address owner) → uint256 requestId`
    (`ControlledAsyncRedeem.sol:39`): checks `owner == msg.sender || isOperator[owner][msg.sender]`, balance,
    `shares != 0`; `safeTransferFrom(share, owner, address(this), shares)` escrows; accumulates into
    `_pendingRedeem[controller]`; emits `RedeemRequest(controller, owner, REQUEST_ID=0, msg.sender, shares)`.
  - `fulfillRedeem(address controller, uint256 shares) onlyOwner` (`:65`): moves pending → claimable using
    `convertToAssets(shares)`.
  - `withdraw(uint256 assets, address receiver, address controller)` (`:81`) / `redeem(...)` (`:104`): claim,
    gated `controller == msg.sender || isOperator[controller][msg.sender]`, `safeTransfer(asset, receiver, …)`,
    emit `Withdraw(msg.sender, receiver, controller, assets, shares)`.
  - `setOperator(address operator, bool approved)` (`BaseERC7540.sol:34`) + `isOperator` mapping + `OperatorSet`
    event — the EIP-7540 operator approval. **Replicate this verbatim** (small, useful, the "+ operator approval"
    the spec asks for).
  - `pendingRedeemRequest(0, controller)` (`:53`) / `claimableRedeemRequest(0, controller)` (`:57`) views.
  - **WHY NOT inherit:** `BaseERC7540 is ERC4626, Owned, IERC7540Operator` (solmate). That base assumes (a) the
    **share token IS the vault itself** (`share = address(this)`, `safeTransferFrom(this, …)`) — but our redeemed
    "shares" are **external** zipUSD (`ESynth`), not vault shares; (b) **NAV conversion** via
    `convertToAssets` (`totalAssets/totalSupply`) — but zipUSD redeems at **par**, not NAV; (c) a **mutable
    `Owned` owner** with `transferOwnership` — §4.5 forbids that (immutable controller). So inheriting fights the
    framework on all three axes. **Build clean-room**, keeping the function **names/signatures, events, and
    operator-approval semantics** (the "fork the lifecycle"), but escrowing external zipUSD, paying USDC at par,
    and gating privileged ops on an immutable `controller`. Cite these reference lines as the model in NatSpec.
- **The Maple pro-rata settle idea** — `reference/maple-withdrawal-manager/contracts/MapleWithdrawalManager.sol`
  `getRedeemableAmounts` (`:367-387`): `partialLiquidity = availableLiquidity < totalRequestedLiquidity`;
  `redeemableShares = partial ? lockedShares * availableLiquidity / totalRequestedLiquidity : lockedShares`;
  carry-forward `:262-273` (unfilled remainder rolls to a later cycle). **Replicate the pro-rata + carry-forward
  IDEA clean-room** (our par twist: `requestedAssets = totalPending / scaleUp`); do NOT import Maple (it is an
  upgradeable proxy bound to a Maple pool/globals — wrong infra). **Verified:** Maple is a pull model (each owner
  calls `processExit` in their window); we use a **push** `settleEpoch()` + a global cumulative-remaining factor so
  fills **auto-carry across epochs with NO per-user action and NO unbounded loop** (fairer than Maple's
  act-in-your-window model; see KR-4).
- **zipUSD = Euler `ESynth`** — `reference/euler-vault-kit/src/Synths/ESynth.sol`. **Verified `burn(address
  burnFrom, uint256 amount)` (`:81`):** the `_spendAllowance` branch (`:91`) is skipped when **`burnFrom ==
  _msgSender()`** — i.e. the **queue burning its OWN escrowed balance** (`burnFrom == address(this) == the queue ==
  the caller`); this is the `burnFrom == sender` path, **NOT** the `(burnFrom == address(this) && sender ==
  owner())` ESynth-self-burn path (that one is for ESynth burning tokens held at the ESynth contract address, by
  its owner — irrelevant here). And `burn` does not gate on `minters[sender].capacity` (only `mint` does,
  `:64-68`) — it only *decrements* `minters[sender].minted` with an underflow-safe floor (`:96-98`), which for a
  non-minter queue stays 0. So the queue burns its escrowed zipUSD with `IZipUSD(zipUSD).burn(address(this),
  amount)` directly — **no allowance, no minter-capacity grant needed.**
  `mint(·,0)`/`burn(·,0)` are silent no-ops (`:60`,`:85`). The deposit module already treats zipUSD as
  18-dp `ESynth` (`contracts/src/supply/ZipDepositModule.sol:11`) — match that.
- **`scaleUp` derivation** — copy the pattern from `ZipDepositModule.sol:88-95`: read `IERC20Metadata.decimals()`
  off zipUSD (18) and USDC (6), require `zipDec >= usdcDec` (`DecimalsTooFew`), `scaleUp = 10 ** (zipDec - usdcDec)`
  (= `1e12`). **Par conversion is the SAME `scaleUp` as the mint** — guarantees mint/redeem are exact inverses.
- **The REPAY funding seam** — `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol:115-118`
  (built, 8-Bw): REPAY = `USDC.transfer(to, amount)` with `to` scope-pinned `EqualTo(repaySink)` and `repaySink ==
  this queue`. So the queue receives USDC as a **plain ERC-20 balance** — it pulls/calls nothing. **Verified.**
- **Test scaffold** — model `contracts/test/ZipDepositModule.t.sol`: a **real `ESynth`** over a live
  `EthereumVaultConnector` (`import {ESynth} from "evk/Synths/ESynth.sol"`, `import {EthereumVaultConnector} from
  "ethereum-vault-connector/EthereumVaultConnector.sol"`) as zipUSD, a 6-dp `MockERC20` USDC, no fork needed for
  the unit/fuzz core. For the integration test, model `contracts/test/WarehouseAdminModule.t.sol` +
  `contracts/test/ForkConfig.sol` (`BASE_FORK_BLOCK` pinned) and `contracts/test/mocks/MockEulerEarn.sol`.

**Starting state**
- `contracts/` builds green (424/424). zipUSD `ESynth`, USDC, the `ZipDepositModule` (the inverse mint), the
  `WarehouseAdminModule` (the REPAY funder), `BaseAddresses`, `ForkConfig`, `MockEulerEarn` all exist.
- No `ZipRedemptionQueue` yet. `remappings.txt` already resolves `@openzeppelin/contracts/`, `evk/`,
  `ethereum-vault-connector/`, `forge-std/`.

**Do NOT**
- Do NOT inherit solmate `ERC4626`/`Owned`/`BaseERC7540` (see "Model from"). Do NOT make the queue itself an
  ERC-20/ERC-4626 share token (the redeemed share is external zipUSD; the queue mints nothing).
- Do NOT use NAV / `convertToAssets` / any oracle — the senior redeems at **strict par** (`assets = shares /
  scaleUp`). No markdown, no haircut, no `SzipNavOracle`. (That is the junior's world, §6.4/§7.)
- Do NOT call EulerEarn (no `deposit`/`redeem`/`withdraw`/`convertToAssets`), and do NOT import `IEulerEarn`. The
  queue is funded **only** by USDC arriving via the warehouse REPAY; settlement reads the queue's **own** USDC
  balance. (KR-1 — discharges the obligation row.)
- Do NOT add a mutable owner, `transferOwnership`, pause, upgrade, or **any** path that moves USDC out except the
  claim path. The queue is the **non-sweepable** REPAY sink (KR-2).
- Do NOT implement mid-epoch cancellation (`cancelRedeemRequest`) — **locked out** (§6.1: a committed request keeps
  the pro-rata denominator stable until settle; the AMM secondary is the early-exit, §6.2).
- Do NOT iterate over a requester list anywhere (no unbounded loop). `settleEpoch` and every claim MUST be O(1)
  (KR-4) — `settleEpoch` is permissionless-shaped only to the trusted controller, but unbounded gas is still a
  bug.
- Do NOT pull zipUSD on settle or pay USDC on request — request escrows zipUSD, settle reserves USDC + burns
  filled zipUSD, claim pays USDC. Keep the three phases separate.
- Do NOT widen `settleEpoch` beyond `onlyController`. Do NOT renounce/zero the controller (it must keep settling).

**Key requirements**

**KR-1 (DISCHARGE: warehouse REDEEM/REPAY seam — obligation owed by item 9).** The queue is funded **externally**:
the CRE cron does warehouse **REDEEM** (`EE_POOL.redeem(shares, SAFE, SAFE)` → USDC into the warehouse Safe) **then
REPAY** (`USDC.transfer(queue, amount)`) **then** `settleEpoch()` (§8.3/§8.5). The queue therefore:
- references **no** EulerEarn (verify: `grep -i eulerearn contracts/src/supply/ZipRedemptionQueue.sol` is empty;
  no `IEulerEarn` import) and calls **nothing** to acquire USDC;
- treats its **own USDC balance** as the settlement liquidity (`IERC20(usdc).balanceOf(address(this))`);
- is the **`repaySink`** wired into `WarehouseAdminModule` at deploy (item-10 wiring; the scope pins it `EqualTo`).
- **Test (integration, fork) — assemble the two existing harnesses:** (1) **zipUSD side** (from
  `ZipDepositModule.t.sol`): `new EthereumVaultConnector()` + `new ESynth(evc,"Zipcode USD","zipUSD")`; mint zipUSD
  to a `requester` (grant the test minter capacity, then `zip.mint(requester, Q)`); `requester` approves the queue
  and calls `requestRedeem(Q, requester, requester)` → assert `totalPending == Q`, `zip.balanceOf(queue) == Q`.
  (2) **warehouse side** (from `WarehouseAdminModule.t.sol` + `CreditWarehouseDeployer`): deploy the queue FIRST,
  then `deployer.deploy(godOwner, address(eeMock), realUSDC, forwarder, repaySink = address(queue), 1)` so the
  REPAY scope pins `to == queue`; `deal(realUSDC, safe, Q/scaleUp)`. (3) Drive a **REPAY** report `abi.encode(uint8
  4, abi.encode(address(queue), Q/scaleUp))` through the Forwarder → assert `IERC20(usdc).balanceOf(queue)` rose by
  exactly `Q/scaleUp`. (4) `vm.warp` past the epoch boundary; `vm.prank(controller); queue.settleEpoch()` → assert a
  **full fill** (`Q/scaleUp` delivered == requested) → `requester` claims `Q/scaleUp` USDC. Also run a **half-fund**
  variant (`deal` only `Q/2/scaleUp`) → assert 50% pro-rata fill + carry-forward. **Note:** the queue's USDC is real
  Base `USDC` (6-dp) and its zipUSD is the real `ESynth` (18-dp) — `scaleUp == 1e12`. This proves the queue settles
  against REPAY-delivered USDC with **zero EulerEarn coupling** (the queue calls nothing; USDC arrives by transfer).

**KR-2 (DISCHARGE: non-sweepable repaySink — obligation, security HIGH).** No function may move USDC out of the
queue except `withdraw`/`redeem` against a caller's own `claimableAssets`. There is **no owner, no sweep, no
admin-transfer**. The only privileged op (`settleEpoch`, `onlyController`) **never transfers USDC out** — it only
burns zipUSD and books `reservedAssets`. **Test:** the immutable `controller` cannot extract USDC (no such
function exists / a call to any non-existent sweep does not compile); a non-controller `settleEpoch` reverts
`NotController`.

**KR-3 (par, exact inverse of the mint).** `scaleUp` derived in the ctor from `zipUSD.decimals()` /
`usdc.decimals()` (require `>=`, else `DecimalsTooFew`). Redemption value is **strict par**: `assetsOut = filledZip
/ scaleUp` (round **down**, protocol-favorable). A `requestRedeem(x)` fully filled returns exactly `x / scaleUp`
USDC. **Test:** mint via `ZipDepositModule.deposit(u)` → `requestRedeem(u*scaleUp)` → fully fund → claim → receive
exactly `u` USDC (round-trip parity, no value created/destroyed beyond sub-`scaleUp` dust).

**KR-4 (O(1) pro-rata settle with auto carry-forward — the core mechanism).** Use a single **global
cumulative-remaining factor**, scoped by an **era counter** so a 100%-fill epoch resets cleanly (the era construct
is what makes a full drain *zero-safe* — see KR-4a). Fills auto-carry across epochs with **no per-user action and
no loops** (fair + censorship-resistant: no `settleEpoch` caller can omit a requester; everyone auto-pro-ratas).

State (`PREC = 1e27` RAY — high precision so many small partial fills don't lose resolution in `pendingNow`):
- `uint256 public constant PREC = 1e27;`
- `uint256 public era;` — increments **only** on a 100%-fill (full-drain) settle. The factor's epoch of validity.
- `uint256 public cumRemaining;` — init `PREC`. The running product of per-epoch *unfilled* fractions **within the
  current era**. Reset to `PREC` at each era bump. **Invariant: `0 < cumRemaining <= PREC` at all times** (never 0 —
  a would-be-0 is exactly the full-drain case, handled by the era bump, see KR-4a).
- **WHOLE-UNIT REQUESTS (the F1/F2 fix — load-bearing).** `requestRedeem` enforces `shares % scaleUp == 0` (so
  `shares >= scaleUp`, since `shares != 0`). This guarantees **`totalPending` is always an exact multiple of
  `scaleUp`**, which is what makes the full-drain era bump reachable: when fully funded, `filledShares =
  (pending/scaleUp)*scaleUp == pending` exactly, so the `filledShares == pending` branch fires, `era` bumps, and
  `cumRemaining` resets — **without it, a sub-`scaleUp` zipUSD remainder makes `filledShares < pending` forever, the
  era never bumps, `cumRemaining` decays to 1, and the queue burns zipUSD while no one can claim (CRITICAL).** It
  also removes the sub-`scaleUp` dust-trap (a `shares < scaleUp` request is structurally unfillable AND
  uncancellable). Par redemption is inherently whole-USDC-unit (sub-`1e-6` zipUSD can't redeem to nonzero USDC), so
  this is a natural constraint; a holder with an odd zipUSD balance redeems the whole-unit floor and keeps/sells the
  sub-unit dust on the AMM (§6.2). Revert `NotWholeUnit`.
- `uint256 public totalPending;` — the **authoritative** aggregate escrowed-and-unfilled zipUSD (**always a multiple
  of `scaleUp`**, per the whole-unit guard). Decremented by the
  **exact** `filledShares` at settle; it (NOT the lazy per-requester `sharesAt`) backs the `zipBalance == totalPending`
  invariant and the fill-ratio denominator. The sum of lazily-realized per-requester `pendingNow` need **NOT** equal
  `totalPending` (per-requester rounding makes `Σ pendingNow ≥ totalPending` — a conservative *under*-crediting that
  is trued up at the next era close; see KR-5). `totalPending` is the single source of truth; `sharesAt` is
  per-requester claim bookkeeping only.
- `uint256 public reservedAssets;` — USDC committed to fulfilled-but-unclaimed claims.
- `uint256 public epoch;` — increments each `settleEpoch` (display/UX; distinct from `era`).
- `uint256 public lastEpochTime;` — init `block.timestamp` (deploy); the 30-day gate anchor.
- `uint256 public constant EPOCH_DURATION = 30 days;`
- per requester: `mapping(address => uint256) sharesAt;` (escrowed zipUSD, normalized to `cumAt`) +
  `mapping(address => uint256) cumAt;` (the `cumRemaining` snapshot at last touch) +
  `mapping(address => uint256) eraAt;` (the `era` at last touch) +
  `mapping(address => uint256) claimableAssets;` (USDC ready to withdraw).

`_realize(address r)` (called at the START of every per-requester touch — request, withdraw, redeem; mirrored by a
pure `_previewRealize` for the views):
```
uint256 s = sharesAt[r];
if (s == 0) { eraAt[r] = era; cumAt[r] = cumRemaining; return; }
uint256 pendingNow;
if (eraAt[r] < era) {
    pendingNow = 0;                  // the requester's era ended in a 100% drain ⇒ fully filled
} else {
    // same era: cumAt[r] >= cumRemaining (cumRemaining is non-increasing within an era), so pendingNow <= s.
    // ceil ⇒ pendingNow rounds UP ⇒ filled rounds DOWN ⇒ Σ credited <= reserved (solvency, KR-5).
    pendingNow = (s * cumRemaining + cumAt[r] - 1) / cumAt[r];     // ceil
}
uint256 filled = s - pendingNow;                                  // >= 0 always (proven above)
if (filled != 0) claimableAssets[r] += filled / scaleUp;          // par, round DOWN
sharesAt[r] = pendingNow;
eraAt[r] = era;
cumAt[r] = cumRemaining;
```

`requestRedeem(uint256 shares, address requester, address owner)` — the 7540 claimant param is named **`requester`**
(not `controller`) to disambiguate from the privileged `controller` state var; param names don't affect the selector
`requestRedeem(uint256,address,address)`:
```
require(shares != 0, ZeroShares); require(shares % scaleUp == 0, NotWholeUnit);   // F1/F2 fix: whole USDC-units
require(owner == msg.sender || isOperator[owner][msg.sender], NotAuthorized);
SafeERC20.safeTransferFrom(zipUSD, owner, address(this), shares);  // escrow external zipUSD
_realize(requester);                       // bank prior fills; sets eraAt/cumAt[requester] to current
sharesAt[requester] += shares;             // joins at the CURRENT (era, cumRemaining) ⇒ no retroactive fill
totalPending += shares;                    // joins the CURRENT open epoch; eligible for the NEXT settle (§6.1)
emit RedeemRequest(requester, owner, 0, msg.sender, shares);
return 0;                                  // REQUEST_ID singleton
```
(A request joins the current epoch and is filled at the next `settleEpoch` boundary — faithful to §6.1 "the request
joins the current epoch's queue.")

`settleEpoch() onlyController nonReentrant`:
```
require(block.timestamp >= lastEpochTime + EPOCH_DURATION, EpochNotElapsed);
lastEpochTime = block.timestamp;           // anchor the next 30-day window to THIS settle (≥30d between settles;
                                           //   no back-to-back catch-up settle after a missed/late epoch)
epoch += 1;
uint256 pending = totalPending;
uint256 availableAssets = IERC20(usdc).balanceOf(address(this)) - reservedAssets;  // free USDC delivered by REPAY
uint256 maxFillAssets = pending / scaleUp;                  // par capacity (floor)
uint256 fillAssets = availableAssets < maxFillAssets ? availableAssets : maxFillAssets;
uint256 filledShares = fillAssets * scaleUp;                // ≤ pending, EXACT multiple of scaleUp
if (filledShares == pending && pending != 0) {              // 100% DRAIN ⇒ close the era (zero-safe, KR-4a)
    era += 1;
    cumRemaining = PREC;                                    // fresh factor for the next era
    totalPending = 0;
    reservedAssets += fillAssets;
    IZipUSD(zipUSD).burn(address(this), filledShares);
} else if (filledShares != 0) {                             // PARTIAL fill
    // round R UP so a partial fill can NEVER produce R==0 (only a true full drain does, handled above):
    uint256 R = ((pending - filledShares) * PREC + pending - 1) / pending;   // ceil, in [1, PREC)
    cumRemaining = (cumRemaining * R + PREC - 1) / PREC;     // ceil ⇒ stays >= 1 (never 0)
    totalPending = pending - filledShares;
    reservedAssets += fillAssets;
    IZipUSD(zipUSD).burn(address(this), filledShares);
}
emit EpochSettled(epoch, era, pending, filledShares, fillAssets, availableAssets);
```

`withdraw(uint256 assets, address receiver, address requester) nonReentrant → shares` /
`redeem(uint256 shares, address receiver, address requester) nonReentrant → assets`:
```
require(requester == msg.sender || isOperator[requester][msg.sender], NotAuthorized);
_realize(requester);
// withdraw: require assets != 0; shares = assets * scaleUp; require assets <= claimableAssets[requester]
// redeem:   require shares != 0; assets = shares / scaleUp; require assets != 0 && assets <= claimableAssets[requester]
//           (the assets != 0 guard rejects redeem(shares < scaleUp), which would else be a phantom zero-transfer)
// A re-claim of an already-claimed amount REVERTS (over-claim: assets > remaining claimableAssets), not silent-zero.
claimableAssets[requester] -= assets;      // effects BEFORE interaction
reservedAssets           -= assets;
SafeERC20.safeTransfer(usdc, receiver, assets);
emit Withdraw(msg.sender, receiver, requester, assets, shares);
```

`_previewRealize(address r) view → (uint256 pendingNow, uint256 totalClaimableAssets)` — a pure mirror of
`_realize` (same era/ceil/floor math) that returns `pendingNow` and `totalClaimableAssets = claimableAssets[r] +
(s - pendingNow) / scaleUp` (the banked claim **plus** the not-yet-realized increment). Views derive from it:
`pendingRedeemRequest(uint256, address r)` = `pendingNow`; `maxWithdraw(r)` = `totalClaimableAssets`;
`claimableRedeemRequest(uint256, address r)` = `maxRedeem(r)` = `totalClaimableAssets * scaleUp` (7540 share-terms).
The leading `uint256` requestId arg is the 7540 singleton (always `0`); ignore its value.

**KR-4a (zero-safe full drain — fixes the div-by-zero the critics flagged).** A naive `cumRemaining *= R` hits **0**
when an epoch fills 100% (`filledShares == pending` ⇒ `R == 0`), and a later `requestRedeem` then sets
`cumAt[requester] = 0` ⇒ **division-by-zero** in the next `_realize`. The **era construct** removes this: a 100% fill
**bumps `era` and resets `cumRemaining = PREC`** instead of multiplying by 0; requesters whose `eraAt < era` are
**fully filled** (`_realize` returns `pendingNow = 0`, crediting their entire `sharesAt`), so no stale factor is ever
divided. Rounding `R` **up** (ceil) additionally guarantees a *partial* fill can never floor `R` to 0 (only a true
full drain reaches 0, and that path is the era bump). **Invariant `0 < cumRemaining <= PREC` and `cumAt[r] != 0`
hold at all times** — assert + fuzz a full-drain-then-new-request sequence explicitly.

**KR-5 (SOLVENCY — the must-prove invariant).** **Total USDC ever paid out via claims ≤ total USDC ever delivered
to the queue.** By construction: each settle reserves `fillAssets ≤ availableAssets = balance − reservedAssets`, so
`reservedAssets ≤ balance` always. Per requester, `filled` rounds **down** in `_realize` and a requester's lifetime
filled is bounded by what they deposited; total deposited-and-filled = total `filledShares` burned = `reservedAssets
× scaleUp` (since each `filledShares = fillAssets × scaleUp` is exact). So `Σ credited = Σ floor(lifetimeFilled_i /
scaleUp) ≤ Σ lifetimeFilled_i / scaleUp = reservedAssets` (`Σ floor(x_i) ≤ floor(Σ x_i)`). The per-requester `ceil`
on `pendingNow` only **defers** crediting (under-credit early, trued-up at era close), never over-credits — so
cumulative `Σ credited ≤ cumulative reserved` holds at **every** point. Round-down dust (`reservedAssets − Σ
credited`) stays locked in the queue; it is bounded by `< 1` USDC-unit (`1e-6` USDC) per requester-realize and is
**negligible for M1** (do NOT add a sweep — that would break non-sweepable KR-2). Note: `reservedAssets` retains
this dust permanently (never decremented away), so `availableAssets` is understated by the accumulated dust over
time — bounded and sub-cent across the protocol lifetime; acceptable, **document it**.
**Invariants to assert + fuzz (≥256 runs).** The fuzz handler MUST track two **ghost accumulators** —
`ghost_totalDelivered` (Σ all USDC sent into the queue: REPAY-ins + any donation) and `ghost_totalPaid` (Σ all
`assets` paid out by `withdraw`/`redeem`) — because the internal-bookkeeping invariants below cannot, on their own,
catch a *systematic* over-credit. The binding solvency statement is the ghost one (#1):
1. **`ghost_totalPaid <= ghost_totalDelivered`** at every step (the real solvency property — never pay out more
   USDC than was ever delivered). This is the must-not-break invariant.
2. `reservedAssets <= IERC20(usdc).balanceOf(queue)` after every op (never owe more than the queue holds).
3. After **force-realizing every actor** (so deferred fills are banked): `Σ claimableAssets_i <= reservedAssets`
   (no over-credit). Summing un-realized requesters is meaningless — realize first.
4. **`IERC20(zipUSD).balanceOf(queue) >= totalPending`** after every op — **`>=`, not `==`** (donation-tolerant: a
   stray zipUSD `transfer` into the queue must not wedge settle; the settle burn is a fixed `filledShares`, so
   donated zipUSD is harmless surplus, never burned/credited). Assert exact `==` only in the no-donation tests.
5. `0 < cumRemaining <= PREC` and `cumAt[r] != 0` after every op (zero-safety, KR-4a); **and a fully-funded epoch
   always bumps `era` + resets `cumRemaining == PREC`** (the F1 guard works — fuzz with whole-unit requests of
   varied sizes).
6. round-trip parity (KR-3): since every request is a whole multiple of `scaleUp`, a full-fund → claim returns the
   **exact** deposited USDC (assert `==`, not `approxEqAbs`); a partially-filled-then-eventually-drained requester
   nets their exact deposit at the drain (era-close credits the full residual `sharesAt`).

**KR-6 (ownership = immutable controller).** Ctor takes `controller` (the CRE redemption-settle operator,
CRE-02), stored `immutable`, non-zero (`ZeroAddress`). `settleEpoch` is `onlyController` (`NotController`). **No**
`Owned`, **no** `owner()`, **no** `transferOwnership`, **no** renounce. The queue is **never renounced** (the
controller must keep calling `settleEpoch`). Document: the immutable-`controller` differs from the 7540 per-request
`requester`/claimant and from the EIP-7540 `operator` (a per-requester delegate set via `setOperator`).

**KR-7 (operator approval — EIP-7540).** Replicate `setOperator(address operator, bool approved)` +
`isOperator[controller_acct][operator]` + `OperatorSet` verbatim from `BaseERC7540.sol:34`, with the
`msg.sender != operator` guard. `requestRedeem`/`withdraw`/`redeem` honor it (`requester == msg.sender ||
isOperator[requester][msg.sender]`). (Skip the EIP-7441 `authorizeOperator` signature path — out of M1 scope; note
it as a deferred extension.)

**KR-8 (30-day epoch, governed-constant).** `EPOCH_DURATION = 30 days` (locked §6.1). `settleEpoch` reverts
`EpochNotElapsed` before the boundary; advances `lastEpochTime` by a fixed `EPOCH_DURATION` increment (not
`= block.timestamp`) so cadence cannot drift earlier under a late call. (If a settle is missed, the next eligible
time is the original schedule + `EPOCH_DURATION`; a single call advances exactly one epoch.)

**KR-9 (reentrancy / token hygiene).** `nonReentrant` (OZ `ReentrancyGuard`) on `requestRedeem`, `settleEpoch`,
`withdraw`, `redeem`. Use `SafeERC20` for all zipUSD/USDC transfers. Effects-before-interactions: book state
(`claimableAssets`/`reservedAssets` decrements) **before** the `safeTransfer` out. zipUSD and USDC are trusted
non-callback tokens, but guard anyway (cheap, defensive — matches the deposit module).

**Frontend back-pressure surface (for the later frontend sweep — pin these now).** Expose: `RedeemRequest`,
`EpochSettled`, `Withdraw`, `OperatorSet` events; `pendingRedeemRequest`, `claimableRedeemRequest`, `maxWithdraw`,
`maxRedeem`, `previewRealize` views; `epoch`, `lastEpochTime`, `EPOCH_DURATION`, `totalPending` public getters
(so the UI can render "your place in the queue", "epoch N closes in T", "claimable now"). No INFLOW ticket filed
this window (memory `[[frontend-after-contracts]]`); the post-deploy alla-prima sweep models the redeem panel on
`reference/euler-lite` and reads these.

**Done when**
- `forge build` green; `forge test --match-path test/ZipRedemptionQueue.t.sol` green; full suite no regression
  (`forge test --fork-url $BASE_RPC_URL`).
- **Lifecycle unit tests:** `requestRedeem` escrows zipUSD + emits; `requestRedeem` reverts on zero / on
  non-owner-non-operator; operator can request/claim on behalf (`setOperator`), self-as-operator reverts.
- **Settle tests:** full-fill (available ≥ requested) fills 100%, burns the filled zipUSD, books `reservedAssets`,
  **bumps `era` and resets `cumRemaining == PREC`**; partial-fill (available < requested) fills exactly
  `availableAssets`-worth pro-rata, carries the remainder, keeps `0 < cumRemaining < PREC`; multi-requester pro-rata
  is proportional to each requester's pending; carry-forward across ≥2 partial epochs with a late-claiming requester
  still credits them their full multi-epoch fill (auto-roll, KR-4); zero-liquidity settle is a no-op fill that still
  advances `epoch`/`lastEpochTime`; `settleEpoch` reverts `EpochNotElapsed` before the boundary and `NotController`
  for a non-controller.
- **Zero-safety test (KR-4a, the critic-flagged bug):** drive a settle that fills the queue 100% (full drain →
  `era++`, `cumRemaining == PREC`), then a **fresh `requestRedeem` in the new era**, then another partial settle and
  claim — assert NO revert (no div-by-zero), the new requester is filled correctly, and a pre-drain requester who
  never realized still claims their full fill (`eraAt < era ⇒ pendingNow == 0`). Fuzz a randomized
  drain/request/settle sequence asserting `0 < cumRemaining <= PREC` throughout.
- **Claim tests:** `withdraw`/`redeem` pay exactly `claimableAssets`; `withdraw`/`redeem` of zero reverts;
  `redeem(shares < scaleUp)` reverts (`assets == 0` guard, not a phantom zero-transfer); over-claim reverts; a
  re-claim of an already-claimed amount **reverts** (not silent-zero); claim **before any settle** reverts
  (`claimableAssets == 0`); `withdraw(a)` and `redeem(a*scaleUp)` from identical state move identical USDC and leave
  identical state; operator claim works and `setOperator(self)` reverts; par round-trip (KR-3) returns the **exact**
  deposited USDC.
- **Cross-era / carry-forward (qa M-2/M-3/M-4):** (a) one requester partially filled over ≥2 epochs then fully
  drained — assert exact-par total whether they realize each epoch or only after the drain (identical totals);
  (b) two cohorts straddling an era boundary — A,B request in era 0, partial fill, A claims, **full drain bumps to
  era 1**, C requests in era 1, partial fill, then B (never realized since era 0, `eraAt[B] < era`) claims its full
  era-0 fill with **no div-by-zero** and is NOT re-subjected to era-1 partials; assert `ghost_totalPaid <=
  ghost_totalDelivered` throughout.
- **Settle edge cases (qa M-6):** over-funded (`available > maxFillAssets`) caps the fill and the **excess USDC
  survives** to the next settle; `available == maxFillAssets` exactly takes the **drain** branch (`era++`);
  `pending == 0` settle is a no-op that still advances `epoch`/`lastEpochTime`; `available == 0` no-op fill does
  **not** bump `era` and leaves `cumRemaining` unchanged; `EpochNotElapsed` at exactly `lastEpochTime +
  EPOCH_DURATION - 1` reverts and at `+0` succeeds (the `>=` boundary).
- **Donation hygiene (qa M-10):** a stray zipUSD `transfer` into the queue does not corrupt `totalPending` or let
  settle burn more than `filledShares` (invariant #4 is `>=`); a stray USDC donation is distributed at par to real
  requesters (never stuck, `reservedAssets <= balance` holds), and cannot be withdrawn by the donor.
- **Reentrancy (qa M-9, KR-9):** a re-entrant `withdraw`/`settleEpoch` attempt during a transfer is blocked by
  `nonReentrant` (use a callback-token mock standing in for USDC in the unit harness).
- **Preview parity (qa M-11):** `previewRealize(r)`/`pendingRedeemRequest`/`maxWithdraw` match the post-`_realize`
  state for randomized states (fuzz `previewRealize` == actual touch). **Build note:** when a partial fill leaves
  only **sub-`scaleUp` dust**, `previewRealize` correctly returns `claimableAssetsOut == 0` (par floor) while
  `pendingNow` already reflects the realized value — so the parity test must force a realize via a benign touch
  (e.g. a `requestRedeem(scaleUp)` or a no-op claim attempt) and assert `sharesAt == pendingNow` + `claimableAssets`
  advanced by the previewed increment; do NOT use a "claim `claimableAssetsOut`" trigger (it skips the realize when
  the increment floors to 0 → false mismatch). `previewRealize` is a bit-exact mirror of `_realize`.
- **Invariant/fuzz (KR-5, ≥256 runs):** randomized request/settle/claim sequences (varied amounts, varied
  available USDC, varied requester counts) — assert `zipBalance == totalPending`, `reservedAssets <= usdcBalance`,
  `Σ claimableAssets <= reservedAssets`, and **never** more USDC paid out than delivered.
- **Integration (fork, KR-1/KR-2):** real `WarehouseAdminModule` REPAY → queue balance rises by `amount` → queue
  settles against it with zero EulerEarn coupling. Run **two REPAY rounds** (REPAY half → partial settle → REPAY the
  rest → drain settle/era bump) and assert the **real `ESynth` `totalSupply` dropped by the burned `filledShares`**
  both times (proves the no-allowance/no-capacity burn seam on the real ESynth, KR-1). **KR-2 negative:** assert no
  `transferOwnership`/`sweep`/`pause`/`owner()` selector exists (ABI/compile check) and the `controller` cannot
  extract USDC by any external call.
- **Acceptance map:** maps to `audit/2.md` Phase-L redemption steps (L-step: `requestRedeem` → `settleEpoch` →
  claim) — **author the L-rows + `audit/3-results` authority rows for the senior-queue path** if absent (audit
  sweep; if deferred to item-10 like the warehouse, log it as an OPEN obligation, do not silently skip).

**Depends on**
- 8-Bw `CreditWarehouse` / `WarehouseAdminModule` (the REDEEM/REPAY funding seam — **DONE**); zipUSD `ESynth` +
  `ZipDepositModule` (the inverse mint — **DONE**). Item-10 wires `repaySink = queue` + the `controller` = the CRE
  settle operator; the CRE-02 cron drives REDEEM→REPAY→`settleEpoch`.
- **Creates (item-10 deploy/wiring obligations):** (a) wire `WarehouseAdminModule.repaySink == ZipRedemptionQueue`
  (the Roles scope pins it `EqualTo`); (b) deploy the queue with `controller =` the CRE redemption-settle
  operator's address (distinct identity); (c) assert the queue is non-sweepable + `controller != 0` before going
  live; (d) **assert the REPAY Roles scope (the power to re-target `repaySink`) is owned only by the
  timelock/multisig — NOT the CRE operator** (security F6: a re-scope can redirect senior redemption funding, so
  that authority must not sit with the same operator that drives settle); (e) the audit sweep for the senior-queue
  L-rows / `audit/3` authority rows (if not done in-window).

**Operator semantics note (security F7 — not a bug, document in NatSpec).** A requester-approved 7540 `operator`
(`setOperator`) can call `withdraw(assets, receiver, requester)` with an **arbitrary `receiver`** — i.e. redirect
the requester's claimed USDC. This is intended ERC-7540 operator power (only the requester can grant it; the
`msg.sender != operator` guard stands), but state it plainly so integrators understand an operator grant is
full claim control.
