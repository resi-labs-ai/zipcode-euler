# zipcode-euler — Tokenomics & Risk Layer (Technical Scope)

> The contract-cited companion to [`risk-vision.md`](./risk-vision.md), and a **composable layer on top
> of** the base protocol in [`claude-zipcode.md`](./claude-zipcode.md). It specifies the liability side
> (a $1 credit dollar `zipUSD` + staked junior `szipUSD`), RESI as per-lien first-loss + sink, and the
> **pro-rata-haircut-lock** default machinery.
>
> This layer is documented **separately and is NOT merged into the base docs.** Section 8 is the
> merge-impact map describing exactly what it would change when merged later.
>
> Citations follow the same standard as `claude-zipcode.md`: `repo/path/File.sol :: function()` with
> verified line numbers. Each component is labeled **Direct reuse**, **Composed** (net-new, built from
> cited primitives), or **Net-new** (standard pattern, no repo source). No emojis.

---

## 1. Purpose & composability

The base protocol funds isolated home-equity credit lines from a USDC pool and prices lien collateral
via CRE. This layer replaces the *liability representation* (plain pool shares) with a two-token system
and adds the *default/recovery risk machinery*. It is additive: the base contracts (`ZipcodeController`,
`ZipcodeOracleRegistry`, `LienCollateralToken`, `CREGatingHook`, EVK markets) are unchanged in purpose;
this layer wraps the pool's liability side and the default path.

---

## 2. Token model

| Token | Role | Standard |
|---|---|---|
| **zipUSD** | Senior credit dollar, pegged $1. Minted from USDC, redeemed for USDC (queue) or sold (secondary). | ERC-20 synth (NOT a vault — see §7) |
| **szipUSD** | Staked junior. Earns the loan spread; absorbs first loss; holds default duration. | ERC-7540 async-redeem vault (see §7) |
| **RESI** | Per-lien first-loss bond posted by the originator; token sink while a loan is live; liquidity-mining emissions. Slashed in-kind on default. Never sold to defend the peg. | external ERC-20 (Subnet 46 alpha) |

3Jane mapping: zipUSD ≈ USD3 (senior credit dollar); szipUSD ≈ sUSD3 (staked junior first-loss).

---

## 3. Reused primitives (Direct reuse — verified)

| Concern | Surface | Path:line |
|---|---|---|
| zipUSD token (mint capacity, allocate-to-vault, supply exclusion) | `ESynth :: setCapacity / mint / burn / allocate` | `euler-vault-kit/src/Synths/ESynth.sol:47,109` (alt: `evk-periphery/src/ERC20/deployed/ERC20Synth.sol`) |
| zipUSD $1 mint/redeem | `PegStabilityModule :: swapToSynthGivenIn / swapToUnderlyingGivenIn` | `euler-vault-kit/src/Synths/PegStabilityModule.sol:115,83` |
| szipUSD staking + 2-week yield smear | `EulerSavingsRate :: deposit/withdraw/redeem/gulp` (ERC4626) | `euler-vault-kit/src/Synths/EulerSavingsRate.sol:18,132` |
| szipUSD cooldown/lock pattern | `sUSD3 :: startCooldown / availableWithdrawLimit`, `UserCooldown` | `moneymarket-contracts/src/usd3/sUSD3.sol:211,277` |
| Peg-reactive IRM / base+premium | `IRMSynth :: computeInterestRate`; `IRMBasePremium` | `euler-vault-kit/src/Synths/IRMSynth.sol:15,70`; `evk-periphery/src/IRM/IRMBasePremium.sol` |
| Haircut (markdown) | `MarkdownController :: calculateMarkdown / getMarkdownMultiplier` | `moneymarket-contracts/src/MarkdownController.sol:91,116` |
| Token slash on default | `MarkdownController :: slashJaneProportional / slashJaneFull` | `moneymarket-contracts/src/MarkdownController.sol:146,187` |
| Senior/junior loss waterfall | `USD3 :: _postReportHook / _burnSharesFromSusd3` (junior burns first) | `moneymarket-contracts/src/usd3/USD3.sol:502,567` |
| Settle / write-off | `MorphoCredit :: settleAccount / _applySettlement` | `moneymarket-contracts/src/MorphoCredit.sol:834,874` |
| Delinquency state machine | `MorphoCredit :: getRepaymentStatus` (Current/Grace/Delinquent/Default) | `moneymarket-contracts/src/MorphoCredit.sol:526` |
| Insurance fund custody | `InsuranceFund :: bring` | `moneymarket-contracts/src/InsuranceFund.sol:33` |
| Pro-rata claim distribution | `RewardsDistributor :: claim / claimMultiple` (merkle cumulative) | `moneymarket-contracts/src/jane/RewardsDistributor.sol:131,141` |

---

## 4. Net-new layer contracts

### 4.1 zipUSD — Direct reuse (configuration, not new code)
`ESynth` as the token + `PegStabilityModule` configured USDC↔zipUSD at `CONVERSION_PRICE` for 1:1, with
mint capacity granted to the PSM. No new contract; a deployment + config of cited primitives.

### 4.2 szipUSD — Composed (`EulerSavingsRate` + ERC-7540 layer)
ERC-4626 base from `EulerSavingsRate` (deposit zipUSD, `gulp` smears spread). Add an **ERC-7540
async-redeem layer** (`requestRedeem → pendingRedeemRequest → claimableRedeemRequest → redeem`) in place
of `sUSD3`'s hand-rolled `UserCooldown`. The 7540 `pending` vs `claimable` split is what expresses the
haircut-lock (see §5). Reference: `EulerSavingsRate.sol`, `sUSD3.sol` cooldown semantics, `forge-std`
`IERC7540.sol` (interface only; no protocol uses 7540 today).

### 4.3 `LienRESIEscrow` — Composed
Per-lien escrow holding the originator's RESI bond. `lock` on origination, `release` on repayment,
`slash` on default with **in-kind** distribution to the affected szipUSD slice (never market-sold).
Built from `InsuranceFund.bring:33` (custody/transfer) + `MarkdownController.slashJaneProportional:146`
(proportional slash logic).

### 4.4 `HaircutLockAccountant` — Net-new (the one genuinely novel piece)
Index/checkpoint accounting that applies a **pro-rata-haircut-lock** to szipUSD on default: every current
holder takes a pro-rata haircut, and their at-risk slice is locked until resolution — computed by index
deltas, **not** by iterating or minting per holder. Assembled from three cited patterns:
`USD3._postReportHook:502` (pro-rata loss burn), `sUSD3` cooldown lock, `RewardsDistributor:131`
(cumulative index accounting). No single reference contract; this is the original engineering.

### 4.5 `RecoveryClaimSBT` — Net-new (standard pattern)
Soulbound (non-transferable) ERC-721 representing a holder's locked pro-rata claim on a specific lien's
legal recovery. Lazily minted (a holder mints a discrete handle on demand; not force-minted to all).
Future-transferable variant = the NPL secondary market. Pattern: OZ ERC-721 + transfer override +
`RewardsDistributor`-style cumulative claim.

### 4.6 `DefaultCoordinator` — Composed
Orchestrates the default lifecycle: receives the CRE default/recovery report (§6), drives markdown →
junior waterfall → RESI slash/payout → haircut-lock → settle/recovery → unlock. Mirrors
`MarkdownController` (the `onlyMorphoCredit`-style gating, here gated to the CRE receiver).

---

## 5. Mechanisms

**Mint / redeem (zipUSD).** Mint: USDC → `PSM.swapToSynthGivenIn` → zipUSD at $1. Primary redeem:
`PSM.swapToUnderlyingGivenIn` when reserves are free; otherwise a **~30-day redemption queue** (a
request module borrowing 7540 request/claim semantics). Fast exit: sell in the **zipUSD/RESI** pool;
sub-$1 dips are arbitraged by parties willing to hold the queue.

**Default = pro-rata-haircut-lock.**
1. `MarkdownController.calculateMarkdown` computes the haircut; `USD3._postReportHook`-style burn applies
   it to szipUSD (senior stays $1).
2. `LienRESIEscrow.slash` distributes the lien's RESI bond in-kind to the affected slice.
3. `HaircutLockAccountant` locks the at-risk pro-rata slice (7540 `pending`); the rest stays `claimable`.
4. Resolution: legal recovery inflow repays the locked slice (`RecoveryClaimSBT` settles), or
   `MorphoCredit.settleAccount` writes off; then the slice unlocks.

**Loss/recovery waterfall.** Junior (szipUSD) absorbs in dollars first; RESI is an in-kind bonus to the
junior; the home's legal recovery is the real backstop that repays the junior over time. zipUSD is
insulated from RESI's price entirely.

---

## 6. CRE integration

Default detection and recovery amounts are **off-chain truths** that arrive as DON-signed reports.
The allocation/underwriting workflows in `claude-zipcode.md` §4 gain a third path: a default/recovery
workflow that reports `(lienId, status, markdownAmount | recoveryAmount)` via
`runtime.report → evmClient.writeReport({receiver: DefaultCoordinator})`. The coordinator verifies the
report (KeystoneForwarder + workflow identity) before acting. Determinism rules from the base apply.

---

## 7. Vault standard: ERC-4626 vs ERC-7540

- **szipUSD = ERC-7540 async-redeem.** Redemptions are inherently async (cooldown + the haircut-lock).
  7540's request/claim lifecycle models the lock natively: the liquid slice becomes `claimable` while the
  at-risk slice stays `pending` until the default resolves. Cleaner and more auditable than `sUSD3`'s
  bespoke `UserCooldown`. Deposits stay synchronous.
- **zipUSD = ERC-20 synth, not a vault.** It must be a stable $1 unit; any 4626/7540 *share* floats in
  NAV. zipUSD = `ESynth` + `PSM`; its async primary-redemption queue is a property of the redemption
  module (which may borrow 7540 request/claim semantics), not the token.
- **Dependency:** this holds only while zipUSD is stable-$1. If zipUSD were ever made floating-NAV, it
  too would become a 7540 vault. 7540 is net-new here (no reference protocol uses it; only
  `forge-std/IERC7540.sol` is vendored).

---

## 8. Merge-impact map (documented, NOT applied)

When this layer is deliberately merged into the base docs, it changes:

**`claude-zipcode.md`:**
- §1 component map — MODIFY: liability side becomes zipUSD + szipUSD (was "EulerEarn share").
- §2 reused primitives — ADD synth/PSM/ESR/IRMSynth + 3Jane markdown/settle/USD3/InsuranceFund/RewardsDistributor rows.
- §3 net-new contracts — ADD the layer contracts (§4 here); MODIFY `ZipcodeController` (mint zipUSD; trigger markdown/settle via `DefaultCoordinator`).
- §4 CRE workflows — ADD the default/markdown/recovery report path (§6 here).
- §8 lien lifecycle — EXTEND: default → haircut-lock → recovery/settle → unlock.
- §9 trust model — ADD junior risk, RESI illiquidity (never force-sell to defend peg), peg insulation, recovery-timing.
- §13 open decisions — RESOLVE zipUSD flavor (stable-$1) and RESI role (first-loss + sink, not peg backstop); ADD the layer open items (§9 here).
- §7 (oracle), §10 (business), §11 (demo), §12 (repo map), §14 (glossary) — unchanged.

**`vision.md`:**
- ADD a short "how deposits & yield work" paragraph (USDC → zipUSD; stake → szipUSD; RESI sink). The three-stage flywheel is unchanged.

---

## 9. Open decisions

- **Surplus recovery destination:** when legal recovery exceeds the loss, does the surplus go to the
  originator (it was their collateral) or to the junior as profit?
- **szipUSD cooldown length** and the 7540 claim window.
- **RESI bond sizing:** as a first-loss percentage (target ~5–15%, warehouse-equity range), not 100% of lien value.
- **PSM vs pure-synth** for the peg, and reserve/fee parameters.
- **Resolved (recorded for the merge):** whole-stake vs pro-rata lock → **pro-rata at-risk slice**;
  socialized-snapshot vs per-line tranche → **socialized snapshot at default**; zipUSD flavor →
  **stable $1 + staked junior**; exit-during-default → **hard-locked until resolution**.

---

## 10. Glossary (layer-specific)

**zipUSD** senior $1 credit dollar (synth) · **szipUSD** staked junior (ERC-7540) · **RESI** Subnet-46
alpha used as per-lien first-loss bond + sink · **PSM** PegStabilityModule (mint/redeem at $1) ·
**ESR** EulerSavingsRate (yield-smearing ERC-4626) · **markdown** time-based debt-value haircut ·
**settle** write-off of unrecoverable debt · **pro-rata-haircut-lock** the default mechanism: every
junior holder takes a pro-rata haircut and the at-risk slice locks until resolution · **SBT** soulbound
token (non-transferable recovery claim) · **NPL** non-performing loan (the future transferable claim market).
