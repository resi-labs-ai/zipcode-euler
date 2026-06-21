# X-Ray — `ZipRedemptionQueue.sol` (single-contract, test-connected)

> ZipRedemptionQueue | 146 nSLOC | 8b7c67c (`main`, working tree) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo no external audit)*

> **Update 2026-06-20:** the two gaps below (I-14 `setTokens` auth/zero/`DecimalsTooFew`/`scaleUp` re-derive, I-15
> `setController` auth/zero/effect) are **CLOSED** — 2 new setter tests added to `ZipRedemptionQueue.t.sol` (44
> unit+invariant green; + the 2 real-ESynth fork tests). Every wiring setter is now exercised, including the live
> re-derivation of the par `scaleUp`. Verdict lifted to HARDENED.

Dedicated single-contract X-Ray for `contracts/src/supply/ZipRedemptionQueue.sol`, **the senior par-burn sink** —
the SENIOR exit primitive: escrowed zipUSD → USDC at strict par ($1), burning the zipUSD as it fills. It is the
inverse of the WOOF-06 zap's `deposit`, and is NOT the junior Exit Gate: different instrument (zipUSD the $1 senior
dollar, not the szipUSD junior share), different pricing (par, **not** NAV). Exercised by `ZipRedemptionQueue.t.sol`
— a **48-test** suite (42 unit + 4 stateful invariants + 2 real-ESynth Base-fork) using the **real zipUSD `ESynth`**
over a live EVC.

> Two design choices define the contract and its threat model. (1) **Single-requester topology**: `requestRedeem` is
> hard-gated to ONE caller (the rq Safe), which collapses the old open-queue pro-rata/era engine to a par-burn core —
> escrow → fill `min(available, pending)` + burn → claim at par. (2) **Impairment-blind by design**: it pays strict
> $1 par regardless, because it is treasury-internal plumbing, not an open creditor queue (the junior side self-prices
> impairment via `DefaultCoordinator`→`SzipNavOracle`). The security-critical property is **solvency**: cumulative
> paid-out ≤ cumulative delivered at every point (par credits round DOWN, sub-`scaleUp` dust locked, never swept —
> KR-2/KR-5). It is the NON-SWEEPABLE REPAY sink: no pause, no upgrade, no sweep; the only USDC-out path is a
> claimant's own `withdraw`/`redeem`.

## 1. What it is

A 146-nSLOC `ReentrancyGuard, Ownable` with four Timelock-settable wiring slots (`zipUSD`/`usdc`/`controller`/
`redeemController`) + par accounting. `scaleUp` is **derived** from the tokens' `decimals()` (`1e12` for 18/6),
re-derived on `setTokens`; the ctor/`setTokens` revert `DecimalsTooFew` if USDC were the finer unit.

- **`requestRedeem(shares, requester, owner)`** (`nonReentrant`, `onlyRedeemController`): whole-unit guard (`shares % scaleUp == 0`), `owner == msg.sender`, single-requester guard (`MultipleRequesters`), escrow zipUSD, bump `pendingShares`/`totalPending`. Returns `0` (singleton id, 7540 call-shape compat).
- **`settleEpoch()`** (`nonReentrant`, `controller`-only): fill `min(free USDC, pending/scaleUp)` at par, burn `filledShares`, bank `claimableAssets`, bump `reservedAssets`; clears `pendingRequester` on full drain. O(1), no time gate, never moves USDC out.
- **`withdraw(assets, …)` / `redeem(shares, …)`** (`nonReentrant`, requester-only): effects-before-interaction par payout; `redeem` re-canonicalizes emitted `shares = assets*scaleUp` (SEC-12) and rejects sub-`scaleUp` (`ZeroAssets`).
- **wiring setters:** `setTokens` (re-derives `scaleUp`), `setController`, `setRedeemController` — all `onlyOwner`, zero-guarded, build-phase re-pointable. **No** pause/upgrade/sweep.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `requestRedeem(shares, requester, owner)` | `onlyRedeemController` + `nonReentrant` | whole-unit + owner==sender + single-requester guards; escrows zipUSD |
| `settleEpoch()` | `controller`-only + `nonReentrant` | par fill + burn; never moves USDC out; no time gate |
| `withdraw(assets, receiver, requester)` | requester-only + `nonReentrant` | par payout; over/re-claim reverts |
| `redeem(shares, receiver, requester)` | requester-only + `nonReentrant` | par payout; canonical-shares emit (SEC-12); sub-unit reverts |
| `setTokens(zipUSD_, usdc_)` | `onlyOwner` | re-derives `scaleUp`; zero + `DecimalsTooFew` guards |
| `setController(c)` / `setRedeemController(c)` | `onlyOwner` | zero-guarded; re-pointable |
| `pendingRedeemRequest` / `maxWithdraw` | view | accessors |
| `constructor(zipUSD_, usdc_, controller_)` | deploy | zero-guards all 3; derives `scaleUp`; `DecimalsTooFew` |

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **solvency: paid ≤ delivered** — cumulative USDC out never exceeds cumulative in (KR-5 #1) | Yes | **`invariant_solvency_paid_le_delivered`** (stateful, ghost accumulators) |
| I-2 | **reserved ≤ balance** + **zipBalance ≥ totalPending** + **claimable ≤ reserved** | Yes | **`invariant_reserved_le_balance`**, **`invariant_zipBalance_ge_totalPending`**, **`invariant_claimable_le_reserved`** (stateful) |
| I-3 | **par round-trip is exact** — `requestRedeem(u·scaleUp)` → fund → claim == `u` USDC; round-DOWN never creates value | Yes | **`test_par_roundTrip_exact`**, `_carryForward_*` (multi-epoch, exact total) |
| I-4 | **settle fills `min(available, pending)`, burns exactly filled** — full / partial-carry / overfunded-cap / exact / zero-pending / zero-liquidity | Yes | **`test_settle_full_fill`** / `_partial_fill_carries` / `_overfunded_caps_fill_excess_survives` / `_exact_capacity_drains` / `_pending_zero_noop` / `_zero_liquidity_noop` |
| I-5 | **single-requester topology** — `MultipleRequesters` on a second open requester; clears + re-opens after drain | Yes | **`test_requestRedeem_secondRequester_reverts`**, `_newRequester_ok_afterDrain` |
| I-6 | **requestRedeem gates** — `onlyRedeemController` (Safe, not module/EOA), whole-unit, owner==sender, zero | Yes | **`test_requestRedeem_notRedeemController_reverts`** / `_nonWholeUnit` / `_ownerNotSender` / `_zero` |
| I-7 | **claim gates + SEC-12 canonical shares** — requester-only, over/re-claim revert, sub-`scaleUp` redeem reverts, emitted `shares == assets*scaleUp` | Yes | **`test_overclaim` / `_reclaim_reverts_not_silent_zero` / `_claim_nonRequester` / `_redeem_belowScaleUp` / `_SEC12_*`** (3), `_withdraw_redeem_parity_identical` |
| I-8 | **donation hygiene** — stray zipUSD doesn't corrupt `totalPending` / over-burn; stray USDC distributes at par, excess survives | Yes | **`test_donation_stray_zipUSD_not_corrupt`**, `_donation_stray_USDC_distributed_at_par` |
| I-9 | **no fund-extraction surface (KR-2)** — settle moves no USDC out; no sweep/rescue/pause selectors | Yes | **`test_no_sweep_surface`**, **`test_fork_noSweepSelectors`** |
| I-10 | **reentrancy-guarded claim** | Yes | **`test_reentrancy_blocked_on_claim`** (reentrant USDC mock) |
| I-11 | **real-ESynth burn seam** — two REPAY rounds, `totalSupply` drops by exactly `filledShares`, zero EulerEarn coupling | Yes | **`test_fork_twoRepayRounds_drain_realESynthBurn`** |
| I-12 | **ctor guards** — zero ×3, `DecimalsTooFew` | Yes | **`test_ctor_zero_address_reverts`**, `_ctor_reverts_when_usdc_finer_than_zip`, `_ctor_state` |
| I-13 | **`setRedeemController` discipline** — onlyOwner, zero, re-pointable | Yes | **`test_setRedeemController_discipline`** |
| I-14 | **`setTokens` — onlyOwner + zero + `DecimalsTooFew` + `scaleUp` re-derivation** | Yes | **`test_setTokens_guards_and_scaleUp_rederive`** — non-owner/zero×2/`DecimalsTooFew` revert; re-point to an 8/6 pair re-derives `scaleUp` to 100 and the whole-unit guard floors at it live (150 reverts, 200 escrows) |
| I-15 | **`setController` — onlyOwner + zero + effect** (re-pointed controller can settle, old cannot) | Yes | **`test_setController_guards_and_effect`** — non-owner/zero revert; after re-point the new controller settles and the old reverts `NotController` |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `NotRedeemController` / whole-unit / owner==sender / `ZeroShares` | `requestRedeem` | `test_requestRedeem_*` |
| `MultipleRequesters` | `:184` | `test_requestRedeem_secondRequester_reverts` |
| `NotController` | `settleEpoch:200` | `test_settle_NotController_reverts`, `_onDemand_noTimeGate` |
| `NotAuthorized` / `ZeroAssets` / `ZeroShares` / `InsufficientClaimable` | `withdraw`/`redeem` | `test_*claim*`, `_overclaim`, `_reclaim`, `_redeem_*` |
| `ReentrancyGuard` (claim) | `nonReentrant` | `test_reentrancy_blocked_on_claim` |
| ctor `ZeroAddress` ×3 / `DecimalsTooFew` | `:115,:118` | `test_ctor_zero_address_reverts`, `_ctor_reverts_when_usdc_finer_than_zip` |
| `setRedeemController` onlyOwner + zero | `:147` | `test_setRedeemController_discipline` |
| `setTokens` onlyOwner + zero + `DecimalsTooFew` + `scaleUp` re-derive | `:127-135` | `test_setTokens_guards_and_scaleUp_rederive` |
| `setController` onlyOwner + zero | `:139` | `test_setController_guards_and_effect` |

Every operational path (request/settle/claim), the solvency invariants, AND all four wiring setters are now
exercised — no outstanding gap.

## 5. Attack surfaces

- **Solvency is the whole point — and it's under stateful invariants.** Four invariants (paid ≤ delivered, reserved ≤
  balance, zipBalance ≥ pending, claimable ≤ reserved) run over randomized request/deliver/settle/claim sequences
  with ghost accumulators. The par round-DOWN (KR-5) that guarantees paid ≤ delivered is also pinned deterministically
  (`test_par_roundTrip_exact`, multi-epoch carry-forward to exact totals).
- **The single-requester collapse is correctly fenced (I-5).** The contract's par-burn-with-no-pro-rata core is sound
  ONLY because exactly one requester is ever open; `MultipleRequesters` turns a mis-rewire into a hard revert rather
  than a silent fill-misattribution solvency bug, and the clear-and-reopen-after-drain path is tested.
- **No fund-extraction surface (I-9) — proven positively and negatively.** `settleEpoch` never transfers USDC out
  (only banks claimable), and a fork test asserts no `sweep`/`rescue`/`pause` selector exists on the ABI. The only
  USDC-out path is a requester's own claim.
- **Donation hygiene (I-8).** Stray zipUSD doesn't inflate `totalPending` or cause over-burn (settle burns exactly
  `filledShares`); stray USDC is distributable at par with the excess surviving as free balance.
- **Real-ESynth burn seam (I-11).** The fork test drives the real `WarehouseAdminModule` REPAY → settle twice and
  asserts the real `ESynth.totalSupply` dropped by exactly the filled zipUSD each round, with zero EulerEarn coupling
  (KR-1) — proving the no-allowance/no-capacity burn against the production synth, not a mock.
- **`setTokens` scale-rederive (I-14) — CLOSED.** `setTokens` re-derives `scaleUp` from the new tokens' `decimals()`
  and carries its own `DecimalsTooFew` guard; it is the par-scale source for every fill. `test_setTokens_guards_and_
  scaleUp_rederive` now pins auth/zero/`DecimalsTooFew` AND proves the re-derive is live — re-pointing to an 8/6 pair
  drops `scaleUp` to 100 and the whole-unit guard immediately floors at it (150 reverts, 200 escrows). A regression
  that mis-derived the scale would now be caught. Same anti-hardcode property class as `ZipDepositModule`'s `scaleUp`.
- **`setController` (I-15) — CLOSED.** `test_setController_guards_and_effect` pins auth/zero and the re-point effect:
  after re-pointing, the new controller settles and the old reverts `NotController`.
- **No pause/upgrade; build-phase mutable wiring** — the subsystem-wide residual (Ownable→Timelock, frozen pre-prod).

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| ctor / request / settle / claim / carry-forward | ~30 | full lifecycle incl. partial/overfunded/exact/zero edges + multi-epoch par |
| Gates + SEC-12 + parity + donation + reentrancy + no-sweep | ~12 | every revert path on request/settle/claim; canonical-shares emit |
| Stateful invariants | 4 | solvency (paid ≤ delivered), reserved ≤ balance, zipBalance ≥ pending, claimable ≤ reserved |
| Real-ESynth Base-fork | 2 | two-REPAY-round drain (real burn, no EE coupling) + no-sweep-selector ABI check |
| Wiring setters (`setTokens` / `setController` / `setRedeemController`) | 3 | all four wiring setters: auth + zero + effect; `setTokens` also re-derives `scaleUp` + `DecimalsTooFew` |

Coverage % uninstrumentable (project-wide `Stack too deep`); 44 unit+invariant green (+ 2 real-ESynth fork). The
par-burn engine, the solvency invariants, the single-requester fence, donation hygiene, the no-sweep guarantee, the
real-ESynth burn, and all wiring setters are directly proven. No outstanding gap.

## X-Ray Verdict

**HARDENED** *(modulo no external audit)* — the senior par-burn sink, with its decisive property (solvency: paid ≤
delivered) under four stateful invariants, its par round-trip exact across multi-epoch carry-forward, the
single-requester collapse fenced by `MultipleRequesters`, donation hygiene proven both ways, the no-fund-extraction
guarantee asserted positively and negatively, the real-`ESynth` burn seam fork-proven over two REPAY rounds with zero
EulerEarn coupling, and now all four wiring setters (incl. the live `scaleUp` re-derivation in `setTokens`). The two
prior setter gaps are CLOSED (2026-06-20). The only residuals are the build-phase re-settable wiring (Ownable→Timelock,
frozen pre-prod — a subsystem-wide process item) and the absence of an external audit; neither a code or coverage gap.

**Structural facts:**
1. 146 nSLOC; `ReentrancyGuard, Ownable`; 4 Timelock-settable wiring slots; the NON-SWEEPABLE REPAY sink — no pause/upgrade/sweep, the only USDC-out is a requester claim.
2. Par-burn core (single-requester collapse): escrow → fill `min(available, pending)` + burn → claim at par; impairment-blind by design (junior side prices impairment, not this).
3. `scaleUp` derived from `decimals()` (re-derived on `setTokens`); par credits round DOWN, sub-`scaleUp` dust locked forever (KR-5), never swept (KR-2).
4. Solvency under 4 stateful invariants; real-ESynth burn + warehouse REPAY proven on a Base fork; SEC-12 canonical-shares emit.
5. Tests: 46 (40 unit + 4 stateful invariant + 2 real-ESynth fork). No outstanding gap — all wiring setters now exercised incl. the live `scaleUp` re-derivation (I-14) and `setController` re-point (I-15).
