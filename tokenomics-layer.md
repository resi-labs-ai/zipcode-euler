# zipcode-euler — Tokenomics & Risk Layer (Technical Scope)

> The contract-cited **loss side** of the protocol (plain-language companion: [`risk-vision.md`](./risk-vision.md)):
> continuous mark-to-recovery markdown, the socialized pro-rata term-lock, RESI slash + in-kind bonus, and
> the recovery loop. The **supply side** (zipUSD, mint, yield routing, szipUSD as a token, redemption, NAV)
> lives in [`supply-redemption.md`](./supply-redemption.md); the base/oracle/gating/CRE spine is
> [`claude-zipcode.md`](./claude-zipcode.md). The three are fragments of one build spec, kept separate for
> clean context — §8 maps the merge.
>
> Citations follow the repo standard: `repo/path/File.sol :: function()` with verified line numbers. No emojis.

---

## 1. Purpose & composability

> **Boundary / supersession (2026-05-22).** The **supply side** — the zipUSD token, how it's minted,
> yield routing, the `szipUSD` vault, and redemption — now lives in its own spec, **`supply-redemption.md`**,
> which **supersedes §4.1, §4.2, §5 (mint/redeem), and §7 below.** This doc now owns only the **loss
> side**: markdown, RESI slash, the socialized term-lock, and recovery. The two meet only at `szipUSD`
> (earns yield in `supply-redemption.md`, absorbs loss here). The old synth design here — zipUSD as
> `ESynth`+`PSM`, `szipUSD` as `EulerSavingsRate`+ERC-7540 — is replaced by a 1:1-mint dollar backed by
> EulerEarn with a 30-day epoch redemption queue (see that doc). The default mechanism is the
> **socialized pro-rata term-lock** (§5), not the earlier index-based "pro-rata-haircut-lock."

The base protocol funds isolated home-equity credit lines from a USDC pool and prices lien collateral
via CRE. This layer replaces the *liability representation* (plain pool shares) with a two-token system
and adds the *default/recovery risk machinery*. It is additive: the base contracts (`ZipcodeController`,
`ZipcodeOracleRegistry`, `LienCollateralToken`, `CREGatingHook`, EVK markets) are unchanged in purpose;
this layer wraps the pool's liability side and the default path. The base **gating model is unchanged**:
borrow and liquidate stay controller-only and repay stays permissionless (`claude-zipcode.md` §3.3), and
the controller remains the on-chain borrower of record; this layer only enriches the default branch
(§3.4d) with the markdown / RESI / recovery machinery below.

---

## 2. Token model (loss-side view)

The full token model is in `supply-redemption.md` §1. For the loss side, what matters:
- **zipUSD** — a fixed $1 senior claim; insulated from loss until the junior is exhausted.
- **szipUSD** — the junior **residual** (pool NAV − zipUSD supply); absorbs the markdown first and is
  term-locked during a default (§5).
- **RESI** — the originator's per-lien first-loss bond, slashed **in-kind** to the locked junior as a
  **priced** bonus on default (never sold to defend the peg).

3Jane mapping: zipUSD ≈ USD3 (senior), szipUSD ≈ sUSD3 (junior first-loss).

---

## 3. Reused primitives (loss side)

> Supply-side primitives (zipUSD token + 1:1 mint, yield routing, redemption, the savings/peg stack) have
> moved to `supply-redemption.md`. The synth/PSM/ESR/IRMSynth rows that used to live here are superseded.
> This table is the loss/default side.

| Concern | Surface | Path:line |
|---|---|---|
| Senior/junior loss waterfall (junior = residual; senior protected first) | `USD3 :: _postReportHook / _burnSharesFromSusd3` | `moneymarket-contracts/src/usd3/USD3.sol:502,567` |
| Term-lock pattern (adapted to a **socialized fixed term**, not per-user cooldown) | `sUSD3 :: startCooldown / availableWithdrawLimit`, `UserCooldown` | `moneymarket-contracts/src/usd3/sUSD3.sol:211,277` |
| RESI bond slash (proportional, in-kind) | `MarkdownController :: slashJaneProportional / slashJaneFull` | `moneymarket-contracts/src/MarkdownController.sol:146,187` |
| RESI escrow custody | `InsuranceFund :: bring` | `moneymarket-contracts/src/InsuranceFund.sol:33` |
| Pro-rata in-kind bonus distribution | `RewardsDistributor :: claim / claimMultiple` | `moneymarket-contracts/src/jane/RewardsDistributor.sol:131,141` |
| Settle / write-off (recovery shortfall) | `MorphoCredit :: settleAccount / _applySettlement` | `moneymarket-contracts/src/MorphoCredit.sol:834,874` |
| Delinquency state machine (lock trigger) | `MorphoCredit :: getRepaymentStatus` (Current/Grace/Delinquent/Default) | `moneymarket-contracts/src/MorphoCredit.sol:526` |
| **Recovery-aware markdown** (net-new) | `markdown = debt − (equity mark × recovery haircut)`, continuous on the oracle heartbeat. **NOT** `MarkdownController.calculateMarkdown` (time-linear unsecured decay — dropped). | oracle-driven; no reference contract |
| **RESI price feed** (required new input) | prices the escrowed/slashed RESI for the insurance-bonus NAV + szipUSD bonus APR. | source TBD (DEX/feed) |

---

## 4. Net-new layer contracts

### 4.1 zipUSD — SUPERSEDED
Moved to `supply-redemption.md` — zipUSD is a 1:1-mint dollar backed by EulerEarn (no `ESynth`+`PSM` synth/peg machinery).

### 4.2 szipUSD — SUPERSEDED (token + redemption)
The szipUSD token, its yield routing (EulerEarn `feeRecipient`), and its redemption (7540-ref fork + the
30-day epoch queue) are in `supply-redemption.md`. Its **loss behavior** — residual NAV + the socialized
term-lock — is defined here (§4.4/§5).

### 4.3 `LienRESIEscrow` — Composed
Per-lien escrow holding the originator's RESI bond. `lock` on origination, `release` on repayment,
`slash` on default with **in-kind** distribution to the locked szipUSD cohort (never market-sold). The
slashed RESI is **priced** (RESI price feed, §3) to value the insurance-bonus NAV and substantiate the
szipUSD bonus APR. Built from `InsuranceFund.bring:33` (custody) + `MarkdownController.slashJaneProportional:146`
(proportional slash) + a `RewardsDistributor`-style pro-rata distributor for the in-kind payout.

### 4.4 `DefaultCoordinator` — Composed
The single loss-side orchestrator. Receives the CRE default/recovery report (§6) and drives the
**socialized** flow: enact the pro-rata term-lock on szipUSD → `LienRESIEscrow.slash` (in-kind, priced) →
on recovery, release the lock with the bonus → `MorphoCredit.settleAccount` write-off only if recovery
falls short. It does **not** apply markdown — markdown is continuous via the oracle (§5). Gated to the CRE
receiver (immutable Forwarder).

> **Dropped from the earlier draft:** `HaircutLockAccountant` (index/per-position pro-rata-haircut-lock)
> and `RecoveryClaimSBT` (per-holder soulbound recovery claim). The socialized term-lock (§5) needs no
> per-position index or claim token — it locks the same pro-rata fraction of every staker and auto-releases
> on resolution. A transferable NPL-claim secondary market remains a *possible future* feature, not a
> built component.

---

## 5. Mechanisms

**Mint / redeem (zipUSD)** — see `supply-redemption.md` (1:1 mint; 30-day epoch redemption queue +
secondary AMM; no PSM). Not repeated here.

**Markdown (continuous, oracle-driven).** The lien's equity mark (home value − senior debt) is reported
by the oracle on its heartbeat. The markdown is the residual: `markdown = debt − (equity mark × recovery
haircut)`. It is **continuous** — re-evaluated every heartbeat, not a time-linear decay curve. The junior
absorbs it automatically by NAV arithmetic (below); there is no separate "apply markdown" step in the
default path.

**Default = socialized pro-rata term-lock.**
1. **Trigger.** `MorphoCredit.getRepaymentStatus` → delinquent → grace elapsed → default. The CRE reports
   `(lienId, status)`; `DefaultCoordinator` acts.
2. **Lock.** Lock a **pro-rata fraction of every szipUSD holder's position** for a fixed term — the same
   fraction for everyone, sized to the at-risk amount as a fraction of junior NAV. Reuses the
   redemption-queue pro-rata gate; no per-position index, no SBT. (UX: "xx% locked for YY days, resolves
   with the insurance bonus.")
3. **RESI bonus.** `LienRESIEscrow.slash` distributes the lien's RESI bond in-kind to the locked cohort;
   priced (§3) to value the bonus.
4. **Recovery / resolution.** Home-sale recovery repays the loan (permissionless `repay`; debt → 0; the
   controller closes the lien) → pool NAV heals → junior NAV restored → the term-lock auto-releases with
   the RESI bonus. If recovery genuinely falls short, `MorphoCredit.settleAccount` writes off the residual
   and the junior bears it (still first-loss).

**Loss/recovery waterfall (by NAV arithmetic).** zipUSD is a fixed $1 claim; **szipUSD is the residual**
(pool NAV − zipUSD supply). A markdown drops pool NAV, which eats the junior residual first — the senior
stays $1 until the junior is exhausted (the `USD3._postReportHook` mechanism, by arithmetic). The senior
is backed by **junior NAV + the home's legal recovery**; RESI is a priced in-kind bonus to the junior,
not senior backing. zipUSD is insulated from RESI's price entirely.

---

## 6. CRE integration

Delinquency status and recovery amounts are **off-chain truths** that arrive as DON-signed reports (Go,
`cre-sdk-go`). The workflows in `claude-zipcode.md` §4 gain a default/recovery path that reports
`(lienId, delinquency status, recovery amount on resolution)` via
`runtime.GenerateReport → evmClient.WriteReport(runtime, {receiver: DefaultCoordinator})`. **Markdown is
not in the report** — it is continuous via the oracle (§5); the report only triggers the lock and carries
recovery proceeds. The coordinator verifies the report (immutable CRE Forwarder + workflow identity)
before acting.
(In the un-merged base protocol this report targets `ZipcodeController._processReport` §3.4(d); the merge
introduces `DefaultCoordinator` as the dedicated receiver.)

---

## 7. Vault standard — SUPERSEDED
zipUSD is a hard $1 unit (1:1 mint, not a vault share); szipUSD redemption is the MIT 7540-reference fork +
the 30-day epoch queue. Details in `supply-redemption.md` (§7). The socialized term-lock (§5 here) is what
holds szipUSD during a default.

---

## 8. Merge-impact map (documented, NOT applied)

When this layer is deliberately merged into the base docs, it changes:

**`claude-zipcode.md`:**
- §1 component map — MODIFY: supply side becomes zipUSD + szipUSD (was "EulerEarn share"); see `supply-redemption.md`.
- §2 reused primitives — ADD the loss-side rows (recovery-aware markdown, USD3 waterfall, settle, InsuranceFund, RewardsDistributor, RESI price feed). Supply-side rows live in `supply-redemption.md`.
- §3 net-new contracts — ADD `LienRESIEscrow` + `DefaultCoordinator` (§4 here); MODIFY `ZipcodeController` (the default branch triggers the socialized lock / RESI slash / recovery via `DefaultCoordinator`).
- §4 CRE workflows — ADD the default/recovery report path (§6 here; markdown is continuous, not in the report).
- §8 lien lifecycle — EXTEND: default → continuous markdown + socialized term-lock → recovery → unlock/settle.
- §9 trust model — ADD junior risk, RESI illiquidity (never force-sell), peg insulation, recovery-timing.
- §13 open decisions — RESOLVE zipUSD flavor (1:1-mint $1) and RESI role (junior bonus + sink, not peg backstop).
- §7 (oracle), §10 (business), §11 (demo), §12 (repo map), §14 (glossary) — unchanged.

**`vision.md`:**
- ADD a short "how deposits & yield work" paragraph (USDC → zipUSD; stake → szipUSD; RESI sink). The three-stage flywheel is unchanged.

---

## 9. Open decisions

- **Surplus recovery destination:** when legal recovery exceeds the loss, does the surplus go to the
  originator (it was their collateral) or to the junior as profit?
- **Term-lock length** (the YY days a defaulted cohort is locked) and the **recovery haircut** value.
- **RESI bond sizing:** a first-loss percentage (target ~5–15%, warehouse-equity range), not 100% of lien value.
- **RESI price source** for the insurance-bonus NAV (DEX vs feed).
- **Surplus split** (above): when recovery exceeds the loss, originator vs junior.
- **Resolved:** lock granularity → **socialized pro-rata fraction of every position** (not a per-loan
  at-risk slice; `HaircutLockAccountant` + `RecoveryClaimSBT` dropped); markdown → **continuous
  mark-to-recovery** (not time-linear); zipUSD flavor → **1:1-mint stable $1** (no PSM; `supply-redemption.md`);
  exit-during-default → **hard-locked for a fixed term, resolves with the RESI bonus**.

---

## 10. Glossary (layer-specific)

**zipUSD** senior $1 credit dollar (1:1 mint) · **szipUSD** staked junior — the residual NAV · **RESI**
Subnet-46 alpha — per-lien first-loss bond + supply sink + priced junior bonus · **markdown** continuous
recovery-aware debt-value haircut (`debt − home value × lien position × haircut`; not time-linear) ·
**settle** write-off of unrecoverable debt on a recovery shortfall · **socialized term-lock** the default
mechanism: a fixed pro-rata fraction of every junior position locks for a fixed term and resolves with the
RESI bonus — no per-position index or claim token · **NPL** non-performing loan (a transferable
recovery-claim market is a possible future feature, not built).
