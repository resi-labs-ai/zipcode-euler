# zipcode-euler — Supply Side & Redemption (Technical Scope)

> The contract-cited spec for the **supply side**: the credit dollar `zipUSD` (minted 1:1 against USDC,
> backed by the EulerEarn pool), the staked junior `szipUSD` (yield + RESI insurance + first loss), and
> the **30-day epoch redemption queue** (pro-rata partial fills when the pool's cash is lent out).
>
> **Status: exploration spec for synthesis.** This is one of several separate spec docs (oracle,
> gating, supply/redemption, loss/tokenomics) kept apart for clean context; they will be synthesized
> into a single coherent pathway. Nothing here is a deferred or lower-priority phase — there is no
> V1/V2 staging. `claude-zipcode.md` currently shows the supply side as plain EulerEarn shares as a
> stand-in; this doc is the actual supply-side design and **supersedes** the old synth design in
> `tokenomics-layer.md` §4.1/§4.2/§5(mint-redeem)/§7.
>
> **Boundary:** this doc owns supply, mint, yield routing, redemption, and NAV. `tokenomics-layer.md`
> owns the loss side (markdown, RESI slash, socialized term-lock, recovery). The two meet only at `szipUSD` —
> which earns yield *here* and absorbs loss *there*. Citations follow the repo standard
> (`repo/path/File.sol :: fn()`, verified lines). No emojis.

---

## 1. Token model

| Token | Role | Form |
|---|---|---|
| **zipUSD** | Senior credit dollar, **hard $1** — minted 1:1 on USDC deposit, redeemed for USDC (epoch queue) or sold (secondary). Spendable/composable money (the reason it's a dollar, not a vault share). | mintable/burnable ERC-20 |
| **szipUSD** | Staked junior. Stake zipUSD to earn the pool's yield + RESI insurance; absorbs first loss; bounded by a subordination cap/floor. | vault share (see §6) |
| **RESI** | Per-lien first-loss bond posted by the originator; slashed in-kind to the affected `szipUSD` on default. Defined in `tokenomics-layer.md`; referenced here only as a junior yield/insurance source. | external ERC-20 |

The peg is **"minted 1:1,"** not a NAV. zipUSD stays $1; the pool's growth accrues to `szipUSD`, and any
retained growth is surplus NAV over the zipUSD supply (an over-collateralization cushion). zipUSD is
solvent while backing NAV ≥ zipUSD supply (§8).

---

## 2. Reused / forked primitives

| Concern | Surface | Path | License |
|---|---|---|---|
| zipUSD token | `ESynth` — controlled-mint ERC-20 (`setCapacity` per minter, `mint`/`burn`); **PSM peg machinery NOT used** (§10) | `euler-vault-kit/src/Synths/ESynth.sol` | reuse |
| Backing pool | `EulerEarn` (the USDC pool, base protocol) — deposit/withdraw, `reallocate` to lien markets | `euler-earn/src/EulerEarn.sol` | reuse |
| Yield routing | `EulerEarn :: setFeeRecipient` (`:258`), `setFee` (`:243`), accrual `_mint(feeRecipient, feeShares)` (`:889`) | `euler-earn/src/EulerEarn.sol` | reuse (config) |
| Async redeem base | `BaseERC7540 is ERC4626, Owned, IERC7540Operator` (`:12`, `setOperator :34`), `ControlledAsyncRedeem` (`requestRedeem :39`, `fulfillRedeem onlyOwner :65`, pending/claimable `:22-23`) | `erc7540-reference/src/{BaseERC7540,ControlledAsyncRedeem}.sol` | **MIT — fork** |
| Epoch + pro-rata (idea) | `MapleWithdrawalManager :: getRedeemableAmounts` (`:367-387`, `redeemable = locked × available/totalRequested`), carry-forward (`:263-270`) | `maple-withdrawal-manager/contracts/MapleWithdrawalManager.sol` | **BSL/GPL — concept only, clean-room** |
| Junior first-loss burn (model) | `USD3 :: _postReportHook` (`:502`), `_burnSharesFromSusd3` (`:567`) | `moneymarket-contracts/src/usd3/USD3.sol` | AGPL — concept only |
| Subordination cap/floor (model) | `sUSD3 :: availableDepositLimit` (`:249`, cap), `availableWithdrawLimit` (`:277`, floor), `maxSubordinationRatio` (`:408`, ~15%) | `moneymarket-contracts/src/usd3/sUSD3.sol` | AGPL — concept only |
| Epoch trigger | Go CRE `cron.Trigger` (`cre-sdk-go/capabilities/scheduler/cron/trigger_sdk_gen.go:16`) + controller as caller | `reference/cre-sdk-go` | reuse |

---

## 3. Net-new contracts

### 3.1 `ZipDepositModule` — mint at $1
- `deposit(uint256 usdc)`: pull USDC, **mint `usdc` zipUSD 1:1** (zipUSD = `ESynth`, module is the
  capacity-granted minter), deposit the USDC into `EulerEarn`. Peg held by the 1:1 mint, not a swap.
- No instant redeem here — redemption is the epoch queue (§7.1) or the secondary market (§7.2).

### 3.2 `szipUSD` — junior tranche vault (see §6)

### 3.3 `ZipRedemptionQueue` — epoch redemption (see §7.1)

---

## 4. Mint / deposit flow
```
deposit(USDC)
  → ZipDepositModule pulls USDC
  → ESynth.mint(user, USDC)            // 1:1, module is the minter (capacity-gated)
  → EulerEarn.deposit(USDC, protocol)  // USDC goes to work in the lending pool
```
The protocol holds the EulerEarn shares; zipUSD is the user's $1 claim against the pool's NAV.

---

## 5. Yield routing (native EulerEarn — no new contract)

Set `EulerEarn.setFeeRecipient(szipUSD)` (`:258`) and `EulerEarn.setFee(f)` (`:243`). On interest
accrual, `_accruedFeeAndAssets` mints `feeShares` to the recipient (`_mint(feeRecipient, feeShares)`,
`:889`) — so the pool's interest flows to `szipUSD` as minted EulerEarn shares. This is the same
performance-fee mechanism 3Jane uses to route yield from `USD3` to `sUSD3`.

The fee parameter `f` governs the split:
- the fee'd portion → `szipUSD` (junior yield);
- the retained portion → surplus NAV above the zipUSD supply (an over-collateralization cushion that
  keeps zipUSD ≥ $1-backed).

zipUSD itself stays flat $1 (it's a fixed claim, not a share); the float lives in `szipUSD`.

---

## 6. `szipUSD` — junior tranche

- **Stake:** deposit zipUSD → `szipUSD`. The vault is EulerEarn's `feeRecipient`, so the pool's yield
  accrues to it (§5); it also receives RESI insurance (per-lien bond slashed in-kind on default —
  `tokenomics-layer.md`).
- **First loss:** on a reported loss, the junior's holdings are burned before the senior is touched —
  modeled on `USD3._postReportHook` / `_burnSharesFromSusd3` (`USD3.sol:502,567`). zipUSD stays whole
  until `szipUSD` is exhausted.
- **Subordination cap + floor** (the gap the comparison surfaced; model `sUSD3`):
  - **Cap** — `szipUSD` ≤ a max ratio of outstanding debt (`maxSubordinationRatio`, e.g. 15%;
    `sUSD3.availableDepositLimit:249`) so the junior stays a thin first-loss layer.
  - **Floor** — `szipUSD` can't withdraw below a minimum backing of current debt
    (`sUSD3.availableWithdrawLimit:277`) so the senior is never left unprotected.
- **Exit:** governed by the same epoch/cooldown discipline as zipUSD redemption (§7.1) plus the loss-side
  **socialized term-lock** in `tokenomics-layer.md` (a junior can't flee an in-flight default).

---

## 7. Redemption — two paths

### 7.1 Epoch queue at par (primary) — `ZipRedemptionQueue`
The USDC backing zipUSD is lent out to illiquid lien markets, so par redemption is a **30-day epoch
queue** with **pro-rata partial fills** when the pool can't free enough cash.

- **Base:** fork `erc7540-reference` `BaseERC7540` + `ControlledAsyncRedeem` (MIT) for the
  `requestRedeem → fulfill → claim` lifecycle + operator approval. A redeemer calls `requestRedeem(zipUSD)`;
  the zipUSD is escrowed and the request joins the current epoch's queue.
- **Epoch + pro-rata (clean-room, modeled on Maple):** at the 30-day boundary, `settleEpoch()`:
  1. read freeable USDC from `EulerEarn` (what the pool can withdraw now);
  2. `redeemable = queued × freeable / totalQueuedValue` per requester (pro-rata; full fill if liquidity
     suffices) — the `MapleWithdrawalManager:383` idea, reimplemented;
  3. burn the filled zipUSD, withdraw the USDC from `EulerEarn`, mark each requester `claimable`;
  4. carry the unfilled remainder to the next epoch (`Maple:263-270` carry-forward idea).
- **Trigger:** `settleEpoch()` is called by the controller on the 30-day boundary via a Go CRE
  `cron.Trigger` — reuses the controller-as-privileged-caller and the cron workflow from `claude-zipcode.md` §4.
- Claiming is a separate `withdraw`/`redeem` against the `claimable` balance (7540 semantics).

### 7.2 Instant secondary (market)
Sell zipUSD into a **zipUSD/USDC** AMM at the market price for an immediate exit (below par when the
queue is backed up; arbitrageurs who will wait the queue buy the dip). The queue is the at-par path; the
AMM is the fast path. zipUSD/RESI is kept **off-center** (the reflexivity finding) — zipUSD's liquidity
should not depend on RESI.

---

## 8. NAV / solvency reporting
**Backing NAV = idle USDC (cash/reserve) + outstanding loan value** — where each loan is marked at par
(performing) or **marked to recovery** when impaired (equity mark × recovery haircut, the loss-side
markdown — `tokenomics-layer.md`). Do **not** double-count: the lent-out USDC and the lien collateral
securing it are two sides of one loan, so the loan's *marked value* is the asset, not the cash plus the
full home equity.

Solvency = **NAV ÷ zipUSD minted ≥ 1**. The `szipUSD` junior (the residual) + the home's recovery are the
buffers that keep it ≥ 1 through defaults; only if the junior is exhausted does zipUSD's backing fall below par.

**Dashboard — five metrics:**
1. **Total protocol NAV** (cash + marked loan value).
2. **Total zipUSD minted** (senior supply).
3. **zipUSD peg vs USDC** (secondary-market price; deviation = stress signal).
4. **Insurance pool size** — the **RESI fund** in escrow (`tokenomics-layer.md` LienRESIEscrow), valued via the RESI price feed.
5. **APR paid via the insurance pool** to locked/defaulted positions (the szipUSD bonus).

**Two pricing inputs feed this:** collateral/equity pricing → the zipUSD dollar NAV (the lien oracle,
`claude-zipcode.md` §3.1); a separate **RESI price feed** → the insurance-bonus NAV and the szipUSD bonus
APR (metrics 4–5; specified loss-side in `tokenomics-layer.md`). Both feeds are required for solvency reporting.

---

## 9. The real constraint: redemption vs. draw contention
`settleEpoch()` can only fill up to the USDC `EulerEarn` can free at that moment, which depends on the
lien markets having repaid. **Redemptions compete with new draws for the pool's free cash.** That
contention — not the queue mechanics — is the binding limiter, and it is why par redemption is an epoch
queue rather than instant. Policy levers: the cash-reserve ratio (`claude-zipcode.md` §4.2), epoch
length, and pacing draws against pending redemptions.

---

## 10. Explicitly NOT using (the previous synth structure)
- **`PegStabilityModule`** (instant 1:1 swap peg) — replaced by `ZipDepositModule` (1:1 mint) + the epoch
  queue. The PSM has no queue (it reverts when its reserve is short), which doesn't fit lent-out cash.
- **`EulerSavingsRate`** (gulp / 2-week smear) — replaced by EulerEarn's native perf-fee routing (§5).
- **3Jane `UserCooldown`** (hand-rolled per-user cooldown) — replaced by the 7540 + epoch model.
- **Centrifuge code** (`centrifuge-liquidity-pools`, AGPL) — its epoch/pro-rata is off-chain (a sovereign
  chain + cross-chain gateway) anyway; concepts only, no copy.
- **Maple code** (`maple-withdrawal-manager`, BSL → GPL, copyleft) — clean-room reimplementation of the
  pro-rata idea only; no copied code.
- `tokenomics-layer.md` §4.1 (zipUSD = ESynth+PSM) and §4.2 (szipUSD = EulerSavingsRate + ERC-7540) —
  superseded by this doc.

Only the **MIT** `erc7540-reference` is forked directly; all other external repos are concept-only.

---

## 11. Open decisions
- **Cash-reserve ratio: fixed-% vs dynamic** (scaling with the pending redemption queue / expected draw volume).
- zipUSD redemption: epoch length (30 days assumed), and whether requests can be cancelled mid-epoch.
- The exact junior accounting unit (zipUSD held vs EulerEarn shares held in `szipUSD`) and how realized
  EulerEarn fee-shares are credited to stakers — pin against the `USD3`/`sUSD3` perf-fee pattern at build.
- Fee parameter `f` (yield split junior vs retained surplus) and the subordination cap/floor values.
- Whether a small always-liquid reserve sits outside EulerEarn to smooth small redemptions between epochs.
- zipUSD's external money uses (collateral, MBS-loop funding) — drives how aggressively to grow supply.
