# 9 — ZipRedemptionQueue (wiring map)

> **X-Ray (security verdict):** rated **HARDENED** — the non-sweepable senior par-burn sink; solvency (paid ≤
> delivered, via par round-down) under 4 stateful invariants, single-requester collapse fenced, no
> fund-extraction surface (proven positively and negatively), and the burn fork-proven against the real zipUSD
> token. Report: `contracts/src/supply/x-ray/ZipRedemptionQueue.md`. ELI20: `docs/supply/ZipRedemptionQueue.md`.
> This doc is the code-truth wiring map.

> Source of truth = the kept code `contracts/src/supply/ZipRedemptionQueue.sol` (read in full). The ticket
> `tickets/sodo/9-zip-redemption-queue.md` + reports `reports/9-report.md` / `reports/credit-union-report.md`
> (C4) are intent only — **the code is final**. Where the report/older NatSpec say the controller is
> "immutable / never renounced," the kept code is in fact `is Ownable` with **Timelock-settable** controller,
> redeemController and tokens (the §17 build-phase rework, 2026-06-09); this doc records the as-built form.
>
> **COLLAPSED 2026-06-13.** The pro-rata / `era` / `cumRemaining` carry-forward engine and the EIP-7540 operator
> surface were **removed**. With `requestRedeem` gated to a single requester (the rq Safe, C4), pro-rata computed a
> fraction over a set of size one — dead code. What remains is the **par-burn core**: escrow → `min(available,
> pending)` fill + burn → claim at par. Par redemption is treasury-internal plumbing (it refills the CoW buy-burn
> bid via the rq Safe), not a holder-facing exit — see `build/wires/8-B14-SzipBuyBurnModule.md` for the buy-burn side.

## Role
The **SENIOR par-burn sink**: **zipUSD → USDC at strict par ($1)** through an **on-demand settle**. The rq Safe
escrows its own idle basket zipUSD, the CRE delivers USDC (warehouse REDEEM → REPAY), `settleEpoch` burns the
zipUSD against that USDC at par, and the rq Safe claims it back to fund the CoW buy-burn bid. A real holder
**never redeems here** — they exit by selling szipUSD on CoW (`build/wires/8-B14-SzipBuyBurnModule.md`). It is the inverse of the
WOOF-06 zap's `deposit` (mint zipUSD against USDC parked in the warehouse). It is **NOT** the junior Exit Gate
(§6.4) — different instrument (zipUSD = the senior dollar, not the szipUSD junior share), different exit,
different pricing (**par, NOT NAV**).

The queue **references no EulerEarn and calls nothing to acquire USDC** (KR-1). It treats its **OWN USDC balance**
(`balanceOf(this) − reservedAssets`) as the settlement liquidity. The CRE cron does the warehouse REDEEM (USDC →
Safe) then REPAY (`USDC.transfer(queue, amount)`) and only then calls `settleEpoch()`; the queue never reaches
into the venue pool itself.

## Contracts involved
| Contract / file | What it does |
|---|---|
| `ZipRedemptionQueue` (`is ReentrancyGuard, Ownable`) | The senior par-burn sink. Lifecycle `requestRedeem` → `settleEpoch` → `withdraw`/`redeem`. Holds escrowed zipUSD + REPAY-delivered USDC; fills `min(available, pending)`, burns, pays out at par. Single-requester (no pro-rata). |
| `IZipUSD` (`contracts/src/interfaces/euler/IZipUSD.sol`) | Minimal local seam: `burn(address burnFrom, uint256 amount)`. The queue burns its OWN escrowed zipUSD (`burnFrom == address(this) == msg.sender`) ⇒ the `ESynth._spendAllowance` branch is skipped: **no allowance, no minter-capacity grant** needed. |
| `WarehouseAdminModule` (`contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol`) | The CRE adapter that funds the queue. Its `REPAY` op is `usdc.transfer(to, amount)` with the Roles scope pinned `EqualTo(redemptionBox)`; **`redemptionBox == this queue`** is the wiring item-10 owes. |
| zipUSD `ESynth` (Euler, 18-dp) | The escrowed-and-burned senior synth (interfaced, not compiled). |
| USDC (Base, 6-dp) | The redemption asset, delivered by REPAY, paid at par on claim. |

## Wiring — internal

**Constructor.** `constructor(address zipUSD_, address usdc_, address controller_) Ownable(msg.sender)`.
- All three zero-checked (`ZeroAddress`).
- `scaleUp = 10 ** (zipDec − usdcDec)` is **derived from the tokens' own `decimals()`** (`1e12` for 18/6) — the
  SAME par scale as the WOOF-06 mint, so mint and redeem stay exact inverses. `zipDec < usdcDec` reverts
  `DecimalsTooFew` (par needs zipUSD the finer unit).
- `controller = controller_`. (No `cumRemaining` / `lastEpochTime` / `EPOCH_DURATION` — the pro-rata factor and the
  time gate are both gone.)
- `Ownable(msg.sender)` ⇒ the deployer is the initial owner; item-10 hands ownership to the **Timelock**.

**Authority (three distinct identities — do not conflate):**
- **`owner` (Timelock).** Holds only the three build-phase re-point setters: `setTokens` (re-derives `scaleUp`),
  `setController`, `setRedeemController` — each `onlyOwner` + `ZeroAddress`-guarded, emitting
  `TokensSet`/`ControllerSet`/`RedeemControllerSet`. **No** sweep / pause / upgrade / mint. (§17: wiring is
  Timelock-re-pointable in the build phase; re-freezing to immutable is DEFERRED to pre-prod.)
- **`controller` (the CRE redemption-settle operator, CRE-02).** The **sole** caller of `settleEpoch`
  (`if (msg.sender != controller) revert NotController()`). Distinct from the §4.4 `ZipcodeController` and from the
  `requester`/claimant.
- **`redeemController` (the rq Safe).** The **sole** authorized `requestRedeem` caller — `onlyRedeemController`
  hard-gates new escrow (`msg.sender != redeemController ⇒ NotRedeemController`). The `OffRampModule` `exec`s
  **through** the rq Safe, so the `msg.sender` the queue sees is the **Safe, not the module** — wire
  `redeemController` to the Safe (wiring it to the module would make the C1 off-ramp path revert). The **claim
  path** (`withdraw`/`redeem`) stays **OPEN** for the requester.

**Accounting (par-burn core, single requester).** No pro-rata, no loops:
- `totalPending` — escrowed-and-unfilled zipUSD, always a multiple of `scaleUp`.
- `pendingShares[r]` / `claimableAssets[r]` — per-requester escrow + banked-at-par USDC (one key in practice: the rq Safe).
- `reservedAssets` — USDC committed to filled-but-unclaimed claims.
- `pendingRequester` — the single open requester; set on the first escrow, cleared when pending drains to 0. This is
  the seam that lets `settleEpoch` credit the fill with no loop.

**`settleEpoch()`.** `onlyController`, **no time gate** — settle on demand, repeatedly, even in the same block.
Reads **own balance**: `availableAssets = usdc.balanceOf(this) − reservedAssets`. `maxFillAssets = pending / scaleUp`
(floor); `fillAssets = min(available, maxFill)`; `filledShares = fillAssets * scaleUp`. If `filledShares != 0`:
debit `totalPending` and `pendingShares[pendingRequester]`, credit `claimableAssets` + `reservedAssets`, clear
`pendingRequester` when its pending hits 0, then `burn(filledShares)`. Else: no-op. It **never moves USDC out**
(KR-2). Par credit rounds **DOWN** (`fillAssets = pending / scaleUp`, floor) ⇒ Σ paid ≤ Σ delivered (KR-5).

**`requestRedeem(shares, requester, owner)`.** `nonReentrant onlyRedeemController`. `shares` must be non-zero and a
**whole multiple of `scaleUp`** (`NotWholeUnit`) — keeps `totalPending` an exact `scaleUp` multiple so a
fully-funded settle reaches a clean zero (a sub-`scaleUp` request is structurally unfillable). `owner` must be
`msg.sender` (`NotAuthorized`). **Single-requester invariant:** the first open request sets `pendingRequester`; a
second *distinct* requester while pending is open reverts **`MultipleRequesters`**. Escrows EXTERNAL zipUSD via
`safeTransferFrom`, bumps `pendingShares[requester]` + `totalPending`, emits `RedeemRequest`. No mid-epoch cancel.

**`withdraw` / `redeem`.** Claim USDC at par to an arbitrary `receiver`; gated `requester == msg.sender`
(`NotAuthorized` otherwise — the EIP-7540 operator delegation was removed). Effects-before-interaction: decrement
`claimableAssets` and `reservedAssets`, then `safeTransfer`. `redeem(shares < scaleUp)` reverts `ZeroAssets`
rather than a phantom zero-transfer. **Both emit the CANONICAL `shares = assets * scaleUp`** in `Withdraw` — `redeem`
recomputes it from the floored `assets` before the emit (SEC-12 / B9), so a sub-unit-excess input
(`redeem(scaleUp + scaleUp/2)` → `assets == 1`) reports `shares == scaleUp`, NOT the raw `1.5·scaleUp`; the event
field matches the USDC actually paid. (No `% scaleUp` revert guard — the recompute is preferred over rejecting
currently-accepted inputs.)

**Events.** `RedeemRequest(requester, owner, sender, shares)`, `RedemptionSettled(pending, filledShares,
fillAssets, availableAssets)`, `Withdraw(sender, receiver, requester, assets, shares)` (`shares` always canonical
`assets * scaleUp`, both claim paths — SEC-12), plus the three wiring
events. (`OperatorSet` and the `era`/`settleCount` event fields were removed with the collapse.)

**Views.** `pendingRedeemRequest(uint256, r) → pendingShares[r]` and `maxWithdraw(r) → claimableAssets[r]` (the
7540 `claimableRedeemRequest` / `maxRedeem` / `previewRealize` mirrors were dropped — the public mappings are
direct reads now).

## Wiring — cross-component (who points at whom)

- **Funded by `WarehouseAdminModule` REDEEM → REPAY.** The CRE drives the warehouse: **REDEEM** (EulerEarn
  `redeem` → USDC to the senior Safe, `receiver == owner == Safe`) then **REPAY** (`usdc.transfer(to, amount)`
  with the Roles scope pinned `EqualTo(redemptionBox)`). **The queue IS the `redemptionBox`.** The queue references/calls
  **no** EulerEarn (grep-confirmed: only a doc comment mentions it; no `IEulerEarn` import) — it settles against
  the USDC the REPAY delivered into its own balance.
- **Burns escrowed zipUSD via `IZipUSD`.** On every filled settle the queue calls
  `IZipUSD(zipUSD).burn(address(this), filledShares)`. Because `burnFrom == address(this) == msg.sender`, the
  `ESynth` allowance/minter-capacity branch is skipped — the queue needs no grant. Fork-proven: a real REPAY raises
  the queue balance by exactly `amount`, and the real `ESynth.totalSupply` drops by the burned amount.
- **Non-commingling.** Item-10 must assert `redemptionBox != juniorBaalSafe` and the queue is not the junior Safe
  (§11) — the senior par exit and the junior NAV exit never share custody.

## Item-10 deploy facts (the obligations this queue owes / is owed)

From `PROGRESS.md` (rows 364–369, 371):
1. **Wire `WarehouseAdminModule.redemptionBox == ZipRedemptionQueue`** — pinned in the Roles scope `EqualTo`. The
   queue is the warehouse's single REPAY sink (M1).
2. **Deploy the queue with `controller =` a DISTINCT CRE redemption-settle identity** (CRE-02) — separate from
   the §4.4 origination controller and from the warehouse's CRE adapter identity. Assert **`controller != 0`** and
   confirm **non-sweepable** (no owner-sweep selector — KR-2 ABI-negative) before going live.
3. **The REPAY Roles-scope re-target authority (who can change `redemptionBox`) MUST be the timelock/multisig, NOT the
   CRE settle operator** (security F6) — a re-scope can redirect senior redemption funding. The queue's own
   `setRedemptionBox`-equivalent (`WarehouseAdminModule.setRedemptionBox`) is `onlyOwner` (Timelock); keep it there.
4. **Ownership hand-off:** `transferOwnership(Timelock)` on the queue after deploy (it is `Ownable(deployer)` at
   construction); the three setters (`setTokens` / `setController` / `setRedeemController`) then sit behind the
   Timelock.
5. **Wire `redeemController` to the rq Safe** (the `OffRampModule` `exec`s through it) — NOT the module.
6. **Deferred audit obligations:** the senior-queue `audit/2` L-rows + `audit/3` authority rows are deferred to
   item-10 (like 8-Bw / the Exit Gate — not authorable against an un-wired system). Obligation row 365 (warehouse
   REDEEM/REPAY seam) is already **DISCHARGED** by item 9.

## Gotchas
- **The pro-rata / `era` / `cumRemaining` engine and the 7540 operator surface were REMOVED (2026-06-13).** With
  `requestRedeem` gated to a single requester (the rq Safe, C4), the carry-forward ratio computed a fraction over a
  set of size one. The collapse replaced it with a direct `min(available, pending)` fill credited to a single
  `pendingRequester`. Any future decision to *re-open* `requestRedeem` to external holders would make pro-rata
  load-bearing again — restore it from git history then, not before. Older NatSpec/report/ticket language
  referencing `era`, `cumRemaining`, `_realize`, `previewRealize`, `setOperator`, a "30-day epoch cadence," `§6.1`,
  or `KR-8` is **stale**.
- **Single-requester invariant is enforced on-chain.** A second distinct requester escrowing while pending is open
  reverts `MultipleRequesters`. After a full drain (`pendingRequester` cleared) a new requester may open.
- **Trust invariant — `redeemController` must never be untrusted.** Par-burn at strict 1:1 is sound
  ONLY because this is single-requester treasury-internal plumbing; the `MultipleRequesters` guard is the SOLE
  defense keeping it so. An untrusted `redeemController` could redeem at par ahead of an impairment.
- **Impairment-blind by design.** The "no loan-marked-bad signal" premise is WRONG —
  `DefaultCoordinator.writeProvision` marks impairment into the JUNIOR `SzipNavOracle` NAV (the junior CoW exit
  self-prices). This SENIOR par queue is INTENTIONALLY impairment-blind (pays $1 par regardless); no pro-rata /
  impaired-rate machinery belongs here.
- **The time gate was already gone (2026-06-12).** `settleEpoch` is `onlyController` with no time check (on-demand,
  same-block-repeatable). Do not re-introduce a time gate.
- **"Immutable / never renounced controller" is stale.** The kept body is `is ReentrancyGuard, Ownable` with
  **Timelock-settable** `controller` / `redeemController` / tokens (§17 build-phase). Re-freezing to immutable is a
  **pre-prod** step, not done in M1. Trust the code, not the header.
- **`requestRedeem` requires whole-`scaleUp` units.** An odd zipUSD balance redeems the whole-USDC-unit floor and
  keeps/sells the sub-`scaleUp` (< $0.000001) remainder on the AMM. Avoids a sub-`scaleUp` dust-trap.
- **Round-down dust stays locked permanently.** Par credit floors (`fillAssets = pending / scaleUp`), so
  `reservedAssets − Σ credited` (bounded sub-cent) is **never swept** — sweeping would break the non-sweepable KR-2
  guarantee. Acceptable for M1.
