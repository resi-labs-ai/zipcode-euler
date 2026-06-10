# 9 — ZipRedemptionQueue (wiring map)

> Source of truth = the kept code `contracts/src/supply/ZipRedemptionQueue.sol` (read in full). The ticket
> `tickets/sodo/9-zip-redemption-queue.md` + reports `reports/9-report.md` / `reports/credit-union-report.md`
> (C4) are intent only — **the code is final**. Where the report/older NatSpec say the controller is
> "immutable / never renounced," the kept code is in fact `is Ownable` with **Timelock-settable** controller,
> redeemController and tokens (the §17 build-phase rework, 2026-06-09); this doc records the as-built form.

## Role
The **SENIOR exit**: un-staked **zipUSD → USDC at strict par ($1)** through a **30-day epoch queue** with
**pro-rata partial fills** and auto carry-forward. It is the inverse of the WOOF-06 zap's `deposit` (mint zipUSD
against USDC parked in the warehouse). It is **NOT** the junior Exit Gate (§6.4) — different instrument (zipUSD =
the senior dollar, not the szipUSD junior share), different exit, different pricing (**par, NOT NAV**).

The queue **references no EulerEarn and calls nothing to acquire USDC** (KR-1). It treats its **OWN USDC balance**
(`balanceOf(this) − reservedAssets`) as the settlement liquidity. The CRE cron does the warehouse REDEEM (USDC →
Safe) then REPAY (`USDC.transfer(queue, amount)`) and only then calls `settleEpoch()`; the queue never reaches
into the venue pool itself.

## Contracts involved
| Contract / file | What it does |
|---|---|
| `ZipRedemptionQueue` (`is ReentrancyGuard, Ownable`) | The senior par exit queue. ERC-7540-shaped lifecycle (`requestRedeem` → `settleEpoch` → `withdraw`/`redeem`), clean-room (not inherited). Holds escrowed zipUSD + REPAY-delivered USDC; pays out at par. |
| `IZipUSD` (`contracts/src/interfaces/euler/IZipUSD.sol`) | Minimal local seam: `burn(address burnFrom, uint256 amount)`. The queue burns its OWN escrowed zipUSD (`burnFrom == address(this) == msg.sender`) ⇒ the `ESynth._spendAllowance` branch is skipped: **no allowance, no minter-capacity grant** needed. |
| `WarehouseAdminModule` (`contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol`) | The CRE adapter that funds the queue. Its `REPAY` op is `usdc.transfer(to, amount)` with the Roles scope pinned `EqualTo(repaySink)`; **`repaySink == this queue`** is the wiring item-10 owes. |
| zipUSD `ESynth` (Euler, 18-dp) | The escrowed-and-burned senior synth (interfaced, not compiled). |
| USDC (Base, 6-dp) | The redemption asset, delivered by REPAY, paid at par on claim. |

## Wiring — internal

**Constructor (`:165`).** `constructor(address zipUSD_, address usdc_, address controller_) Ownable(msg.sender)`.
- All three zero-checked (`ZeroAddress`).
- `scaleUp = 10 ** (zipDec − usdcDec)` is **derived from the tokens' own `decimals()`** (`1e12` for 18/6) — the
  SAME par scale as the WOOF-06 mint, so mint and redeem stay exact inverses. `zipDec < usdcDec` reverts
  `DecimalsTooFew` (par needs zipUSD the finer unit).
- `controller = controller_`; `cumRemaining = PREC` (`1e27`, never 0 — KR-4a); `lastEpochTime = block.timestamp`
  anchors the first 30-day window. `EPOCH_DURATION = 30 days` is a constant.
- `Ownable(msg.sender)` ⇒ the deployer is the initial owner; item-10 hands ownership to the **Timelock**.

**Authority (three distinct identities — do not conflate):**
- **`owner` (Timelock).** Holds only the three build-phase re-point setters: `setTokens` (re-derives `scaleUp`),
  `setController`, `setRedeemController` — each `onlyOwner` + `ZeroAddress`-guarded, emitting
  `TokensSet`/`ControllerSet`/`RedeemControllerSet`. **No** sweep / pause / upgrade / mint. (§17: wiring is
  Timelock-re-pointable in the build phase; re-freezing to immutable is DEFERRED to pre-prod. The doc header in
  the source still narrates an "immutable controller" / "never renounced" — that is stale relative to the kept
  `Ownable` body; code wins.)
- **`controller` (the CRE redemption-settle operator, CRE-02).** The **sole** caller of `settleEpoch`
  (`if (msg.sender != controller) revert NotController()`). Distinct from the §4.4 `ZipcodeController`, from the
  7540 `requester`/claimant, and from the EIP-7540 `operator`.
- **`redeemController` (the rq Safe).** The **sole** authorized `requestRedeem` caller — `onlyRedeemController`
  hard-gates new escrow (`msg.sender != redeemController ⇒ NotRedeemController`). This is the C4 credit-union
  change: the `OffRampModule` `exec`s **through** the rq Safe, so the `msg.sender` the queue sees is the **Safe,
  not the module** — wire `redeemController` to the Safe (wiring it to the module would make the C1 off-ramp path
  revert). It closes the **epoch-dilution / senior-USDC-griefing** vector of an OPEN `requestRedeem` (a whale
  escrowing just before `settleEpoch` to shrink honest pro-rata fills). It is **not** theft prevention (par is
  fixed, settle is `onlyController`, the queue is non-sweepable) — only griefing closure. The **claim path**
  (`withdraw`/`redeem`) stays **OPEN** for existing requesters.

**The pro-rata engine (global cumulative-remaining factor, scoped by `era`).** O(1), no loops, censorship-resistant
(no settle caller can omit a requester):
- `cumRemaining` (RAY, init `PREC`) = the running product of per-epoch UNFILLED fractions within the current
  `era`. Invariant `0 < cumRemaining <= PREC`.
- `era` increments **only on a 100%-fill (full-drain) settle**, which resets `cumRemaining = PREC`. A requester
  whose `eraAt[r] < era` is treated as **fully filled** (`pendingNow = 0`) with NO stale-factor division — the
  zero-safe escape that fixed the div-by-zero bug.
- Per-requester `_realize(r)` (`:221`) is called at the start of every touch: it banks prior fills
  (`pendingNow` rounds **UP** ⇒ `filled` rounds **DOWN** ⇒ Σ credited ≤ reserved — KR-5 solvency) and re-bases
  `(eraAt, cumAt)` to the current global factor. State is `sharesAt` / `cumAt` / `eraAt` / `claimableAssets`.

**`settleEpoch()` (`:290`, the 4-step fill).** `onlyController`; reverts `EpochNotElapsed` before
`lastEpochTime + EPOCH_DURATION`; advances `lastEpochTime` by a **fixed** `EPOCH_DURATION` (cadence can't drift
earlier, KR-8) and `epoch += 1`. Reads **own balance**: `availableAssets = usdc.balanceOf(this) − reservedAssets`.
`maxFillAssets = pending / scaleUp` (floor); `fillAssets = min(available, maxFill)`; `filledShares = fillAssets *
scaleUp`. Three branches: **100% drain** ⇒ `era += 1`, `cumRemaining = PREC`, `totalPending = 0`, reserve, burn;
**partial** ⇒ fold an **UP-rounded** unfilled fraction `R ∈ [1, PREC)` into `cumRemaining` (ceil ⇒ never 0),
reserve, burn; **zero** ⇒ no-op (epoch/time still advanced). It **never moves USDC out** (KR-2).

**`requestRedeem(shares, requester, owner)` (`:266`).** `nonReentrant onlyRedeemController`. `shares` must be
non-zero and a **whole multiple of `scaleUp`** (`NotWholeUnit`) — the F1/F2 fix that keeps `totalPending` an exact
`scaleUp` multiple so a fully-funded settle reaches the full-drain era bump (a sub-`scaleUp` request is
structurally unfillable). `owner` must be `msg.sender` or have approved it as a 7540 operator. Escrows EXTERNAL
zipUSD via `safeTransferFrom`, realizes, joins `sharesAt[requester]` at the CURRENT `(era, cumRemaining)` (no
retroactive fill), bumps `totalPending`, emits `RedeemRequest`. There is **no mid-epoch cancel**.

**`withdraw` / `redeem` (`:326` / `:347`).** Claim USDC at par to an arbitrary `receiver`; gated by the per-
requester check (`requester == msg.sender || isOperator[requester][msg.sender]`). Effects-before-interaction:
decrement `claimableAssets` and `reservedAssets`, then `safeTransfer`. `redeem(shares < scaleUp)` reverts
`ZeroAssets` rather than a phantom zero-transfer.

**Events / GRAPH-01 B-1.** `RedeemRequest`, `EpochSettled`, `Withdraw`, `OperatorSet`, plus the three wiring
events. **The `Withdraw` event lacks a `requestId`** (`Withdraw(sender, receiver, controller, assets, shares)`) —
the subgraph cannot deterministically close a specific request when an owner has multiple pending (it FIFO-matches
as the M1 workaround). Tracked as **GRAPH-01 B-1** (LOW; add `uint256 indexed requestId` on any future touch).

## Wiring — cross-component (who points at whom)

- **Funded by `WarehouseAdminModule` REDEEM → REPAY.** The CRE drives the warehouse: **REDEEM** (EulerEarn
  `redeem` → USDC to the senior Safe, `receiver == owner == Safe`) then **REPAY** (`usdc.transfer(to, amount)`
  with the Roles scope pinned `EqualTo(repaySink)`). **The queue IS the `repaySink`.** The queue references/calls
  **no** EulerEarn (grep-confirmed: only a doc comment mentions it; no `IEulerEarn` import) — it settles against
  the USDC the REPAY delivered into its own balance.
- **Burns escrowed zipUSD via `IZipUSD`.** On every filled settle the queue calls
  `IZipUSD(zipUSD).burn(address(this), filledShares)`. Because `burnFrom == address(this) == msg.sender`, the
  `ESynth` allowance/minter-capacity branch is skipped — the queue needs no grant. Fork-proven: a real REPAY raises
  the queue balance by exactly `amount`, and the real `ESynth.totalSupply` drops by the burned amount.
- **Non-commingling.** Item-10 must assert `repaySink != juniorBaalSafe` and the queue is not the junior Safe
  (§11) — the senior par exit and the junior NAV exit never share custody.

## Item-10 deploy facts (the obligations this queue owes / is owed)

From `PROGRESS.md` (rows 364–369, 371):
1. **Wire `WarehouseAdminModule.repaySink == ZipRedemptionQueue`** — pinned in the Roles scope `EqualTo`. The
   queue is the warehouse's single REPAY sink (M1).
2. **Deploy the queue with `controller =` a DISTINCT CRE redemption-settle identity** (CRE-02) — separate from
   the §4.4 origination controller and from the warehouse's CRE adapter identity. Assert **`controller != 0`** and
   confirm **non-sweepable** (no owner-sweep selector — KR-2 ABI-negative) before going live.
3. **The REPAY Roles-scope re-target authority (who can change `repaySink`) MUST be the timelock/multisig, NOT the
   CRE settle operator** (security F6) — a re-scope can redirect senior redemption funding. The queue's own
   `setRepaySink`-equivalent (`WarehouseAdminModule.setRepaySink`) is `onlyOwner` (Timelock); keep it there.
4. **Ownership hand-off:** `transferOwnership(Timelock)` on the queue after deploy (it is `Ownable(deployer)` at
   construction); the three setters (`setTokens` / `setController` / `setRedeemController`) then sit behind the
   Timelock.
5. **Wire `redeemController` to the rq Safe** (the `OffRampModule` `exec`s through it) — NOT the module.
6. **Deferred audit obligations:** the senior-queue `audit/2` L-rows + `audit/3` authority rows are deferred to
   item-10 (like 8-Bw / the Exit Gate — not authorable against an un-wired system). Obligation row 365 (warehouse
   REDEEM/REPAY seam) is already **DISCHARGED** by item 9.

## Gotchas
- **"Immutable / never renounced controller" is stale.** Older NatSpec/report language says the controller is
  immutable and the queue has no `Owned`. The kept body is `is ReentrancyGuard, Ownable` with **Timelock-settable**
  `controller` / `redeemController` / tokens (§17 build-phase). Re-freezing to immutable is a **pre-prod** step,
  not done in M1. Trust the code, not the header.
- **7540 operator = full claim control (intended, security F7).** A requester-approved `operator` (`setOperator`)
  can call `withdraw(assets, receiver, requester)` with an **arbitrary `receiver`** — i.e. redirect the
  requester's claimed USDC. Only the requester can grant it (`msg.sender == operator ⇒ CannotSetSelfAsOperator`,
  and the `requester != msg.sender && !isOperator` guard stands). A grant is therefore total — by design.
- **Clean-room fork, NOT inherited.** Modeled on `reference/erc7540-reference` (lifecycle + `setOperator`) and
  `reference/maple-withdrawal-manager` (pro-rata carry-forward) but **not** inherited: solmate's `BaseERC7540 is
  ERC4626, Owned` assumes `share == address(this)`, NAV `convertToAssets`, and a mutable transferable owner — all
  three wrong here (redeemed "shares" are EXTERNAL zipUSD; conversion is PAR; settle is `onlyController`). The
  function names, signatures, events and operator semantics are kept; the internals are bespoke.
- **`requestRedeem` requires whole-`scaleUp` units.** An odd zipUSD balance redeems the whole-USDC-unit floor and
  keeps/sells the sub-`scaleUp` (< $0.000001) remainder on the AMM. This both fixes the CRITICAL value-destruction
  (era could never bump) and avoids a sub-`scaleUp` dust-trap.
- **Round-down dust stays locked permanently.** `reservedAssets − Σ credited` (bounded sub-cent across the
  protocol lifetime) is **never swept** — sweeping would break the non-sweepable KR-2 guarantee. `availableAssets`
  is understated by the accumulated dust; acceptable for M1.
