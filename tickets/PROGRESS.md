# tickets/PROGRESS.md — authoring ledger (the source of "what's next")

Persisted state for **one item per context window**. A fresh Claude reads this to know exactly what's done
and what's next — no conversation history needed. Update it at the end of every window (see "Conclude" in
`audit/adversarial-spec/README.md`).

**Unit of work = one item per window.** Most WOOF contracts are **build-only** (internal plumbing → one
ticket). Only **user-facing** items (the zap/supply UX, dashboard, onboarding) get **two tickets** (build +
frontend-interface). After each item: file the ticket(s), update this ledger, **commit the built code
(keep-the-build — the discard/reset rule is RETIRED, `kickoff.md`)**, conclude → start a fresh window.

**Status:** DONE (filed) · NEXT · TODO · DEFERRED (M2/post-MVP)

---

> **CURRENT STATE (2026-06-07) — supply-side two-token redesign integrated. READ FIRST.**
> The supply-side model was **rewritten + integrated into `claude-zipcode.md`** this session. Any item-8 row below
> that says *"NAV display-only / first-loss = withhold-not-markdown / soulbound claim / ~30d lock"* is the **OLD
> model — superseded.** Current model:
> - **szipUSD = a transferable ERC-20 share** the **Exit Gate** mints **NAV-proportionally** vs **soulbound
>   gate-held Loot**; **NAV (`SzipNavOracle`) is the pricing primitive**; exit = windowed-RQ at `min(spot,twap)` NAV
>   (partial-fill) + **CoW secondary** + **8-B14 buy-and-burn**; first-loss = a **conservative
>   provision-that-recovers** (NOT withhold-no-markdown); coverage floor = the freeze (not a knob).
> - **Spec artifacts:** `claude-zipcode.md` = canonical (integrated). **`baal-spec.md` = the build-grade companion
>   for the 8-B tickets** (substrate 8-B1, `SzipNavOracle`, the Exit Gate, engine 8-B5…8-B14, + the Base address
>   book incl. `BaalAndVaultSummoner 0x2eF2…`) — **author the 8-B tickets FROM it, then DELETE it once consumed.**
>   `WOOF-06`/`INFLOW-06` are **re-authored** to the two-token shape (the stale `ZipDepositModule.sol` stub is
>   deleted; cold-build once 8-B1/oracle/Gate land). **`audit/1-results.md` I1–I5 are RETIRED** (old model); new
>   invariants derive per-component via the critic fanout at ticket time.
> - **8-B1 DONE (2026-06-07)** — substrate scaffold BUILT-VERIFIED on a live Base fork (8/8 tests, 115/115 total;
>   `forge test --match-contract SummonSubstrateTest`). Authority model **ratified with the user**: admin = the team
>   multisig added as a Safe **signer/owner** on both Safes (governs the module set, grants the Gate `manager`); CRE
>   operator = a Zodiac module the admin enables; **zero Shares forever** (Baal governance inert by design). Code at
>   `contracts/script/SummonSubstrate.s.sol` + `contracts/test/SummonSubstrate.t.sol` (see memory
>   [[szipusd-safe-authority-model]]). **`SzipNavOracle` DONE 2026-06-07. Exit Gate + szipUSD DONE 2026-06-08**
>   (built-verified, kept: `contracts/src/supply/szipUSD/{ExitGate,SzipUSD}.sol`, 17/17 fork). **WOOF-06 (the zap)
>   BUILT-VERIFIED 2026-06-08** against the REAL Gate seam — `contracts/src/supply/ZipDepositModule.sol` +
>   `contracts/test/ZipDepositModule.t.sol`, 29/29 (26 mock-gate adversarial + 3 real-gate Base-fork), 205/205 total.
>   Build-discovered: the real `ExitGate` lacked the `previewDeposit` obligation this ticket created → **added it to
>   the kept Gate** (DISCHARGED). **8-B14 buy-and-burn BUILT-VERIFIED 2026-06-08** — the bid-side CoW module
>   (`contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` + `contracts/src/interfaces/cow/IGPv2Settlement.sol` +
>   `contracts/test/SzipBuyBurnModule.t.sol`), **33/33 Base-fork, 238/238 total**, zero load-bearing guesses; the
>   first engine Zodiac Module (establishes the `is Module`/`setUp`/`onlyOperator`/Call-only pattern). Spec-clarified
>   `baal-spec §7.2/§7.4`: price off **`navExit`=min(spot,twap)** (buyer-conservative, not bare twap), name the
>   **windowController** as the `burnFor` caller, drop "Roles-scoped engine Safe" (§10.1 plain Module governs).
>   **8-B5 reservoir loop BUILT-VERIFIED 2026-06-08** — the strike-financing seam (`contracts/src/supply/szipUSD/
>   ReservoirLoopModule.sol` + `contracts/src/supply/SzipReservoirLpOracle.sol` + `.../szipUSD/ReservoirBorrowGuard.sol`
>   + `contracts/script/ReservoirMarketDeployer.sol` + `contracts/test/ReservoirLoopModule.t.sol`), **33/33 Base-fork,
>   271/271 total**, zero load-bearing guesses; the **second engine Zodiac Module** (adds the EVC-account-driving
>   dimension — the Safe borrows on its OWN account). User-locked the LP collateral oracle = **CRE-fed push-cache**
>   (not fixed-haircut). 4 build-exposed corrections folded into the ticket: (C1) the Safe **swallows inner reverts**
>   → a `_exec` that bubbles via `execAndReturnData`; (C2) `repay` does NOT cap (literal `amount>owed` reverts
>   `E_RepayTooMuch`); (C3) a new borrow gates on **`borrowLTV`** not `liqLTV`; (C4) `setLTV` needs a live LP mark
>   pre-deploy + governor RETAINED = `transferGovernance(timelock)`. Critic hardening: aggregate `borrowCap`, the
>   required `ReservoirBorrowGuard` (pins `OP_BORROW` to the Safe). Spec-clarified `claude-zipcode.md §4.5.1` (LP_MARK
>   reportType + the borrow-pin). **8-B6 LP strategy module BUILT-VERIFIED 2026-06-08** — `LpStrategyModule` (the 3rd
>   engine Zodiac Module, the simplest: no EVC/oracle/hook), `contracts/src/supply/szipUSD/LpStrategyModule.sol` +
>   `contracts/test/LpStrategyModule.t.sol`, **29/29** (24 unit + 5 Base-fork), **300/300 total**. Three `onlyOperator`
>   scalar-only entrypoints — `addLiquidity`(ICHI deposit + `minShares` slippage floor)/`stake`/
>   `unstake`(gauge) — driving the wired ICHI vault + gauge, deposit `to`/views pinned to `engineSafe`. **Resolved on
>   live Base:** direct `IICHIVault.deposit` lands shares against the REAL single-sided ICHI vault `0x07e72…` on our
>   factory → the **DepositGuard is NOT needed**. **SINGLE-SIDED zipUSD (user-directed 2026-06-08):** the vault is a
>   single-sided zipUSD YieldIQ vault, **no balanced add** — single-sidedness is the wired vault's `allowToken*`
>   property, NOT a module gate; the **module stays vault-agnostic** (forwards both legs; the vault rejects the wrong
>   side fail-closed) so the ICHI vault config can be finalized later. The ALM gauge MUST be **`ALM_ICHI_UNIV3`** type.
>   Critic hardening pre-build: non-zero `minShares` floor (security), faithful mock-vault/gauge spec (qa),
>   `_exec`-returns-bytes adaptation, live-RecordingSafe exec-discipline. **8-B7 harvest/vote module BUILT-VERIFIED
>   2026-06-08** — `HarvestVoteModule` (4th engine Zodiac Module, simplest sibling of 8-B6: no EVC/oracle/custody/
>   approvals, **NO tokenId state**), 5 `onlyOperator` mutators (`claimReward`/`lockVe`/`vote`/`resetVote`/`claimRebase`)
>   + 3 views, `exec(Call,value 0)` via `_exec`-bubble, `exerciseVe` recipient + reads pinned to `engineSafe`. **26/26
>   Base-fork** (real `exerciseVe` proves the **fresh-veNFT / account-aggregate** model — the account holds many veNFTs,
>   the Voter aggregates by account), **326/326 total**, **ZERO load-bearing guesses**. **5 spec corrections to the
>   on-chain-verified Hydrex surface** (`§4.5.1` + `baal-spec §10.8`): VoterV5 is **account-keyed** (`vote(address[],
>   uint256[])`/`reset()` — NO tokenId; tokenId variants ABSENT on-chain); floor = `ve.getVotes(account)` not
>   `balanceOfNFT(tokenId)`; state = none/no-tokenId; rebase via the **RewardsDistributor** (`Minter._rewards_
>   distributor()`), not the Minter. Build-exposed test-sequencing folded (epoch snapshot + `Minter.update_period()`;
>   per-account ~1h vote-delay). **8-B8 exercise module DONE 2026-06-08 — BUILT-VERIFIED** (`ExerciseModule`, the 5th
>   engine Zodiac Module: one `onlyOperator` `exercise(amount, maxPayment, deadline)` = `USDC.approve(oHYDX,maxPayment)`
>   → `oHYDX.exercise(amount,maxPayment,engineSafe,deadline)` [4-arg deadline overload; burns the Safe's oHYDX, pulls
>   ≤maxPayment USDC, mints HYDX to the Safe] → `approve(oHYDX,0)`; recipient-pinned, value-0/Call-only/`_exec`-bubble,
>   `paymentToken` live-read, KR5 `paymentAmount≤maxPayment` honesty guard, `quoteStrike` view; **25/25** [21 unit + 4
>   Base-fork real `oHYDX.exercise`], **351/351 total**, zero load-bearing guesses; all oHYDX selectors on-chain-verified;
>   spec tidy to §4.5.1 8-B8 "State" line). **8-B9 sell module BUILT-VERIFIED 2026-06-08** — `SellModule` (6th engine
>   Zodiac Module; sibling of 8-B8, NO EVC/oracle/repay), TWO `onlyOperator` swap entrypoints sharing a private `_swap`
>   approve→`exactInputSingle`→reset dance: `sellHydx`(HYDX→USDC, the 8-B5 strike-loop repay leg) + `buyXAlpha`(zipUSD→
>   xALPHA, the 8-B10/8-B13 Mode-B/C POL buy leg). recipient/`deployer=0`/`limitSqrtPrice=0` hard-pinned, typed
>   `abi.encodeCall`, `minOut` slippage guard, decode+emit `Sold`. **Per-call HYDX size cap added (user-directed
>   2026-06-08):** `maxSellHydx` (default 300k HYDX ≈ ~3% slippage ≈ ~$10k weekly clip), set-once + owner(Timelock)
>   `setMaxSellHydx` setter, `sellHydx` reverts `ExceedsMaxSell` above it; `buyXAlpha` uncapped (bounded upstream by
>   8-B10). **31/31** (27 unit + 4 Base-fork real `exactInputSingle` HYDX→USDC), **382/382 total** — `forge test
>   [--fork-url $BASE_RPC_URL] --match-path test/SellModule.t.sol`. **ZERO load-bearing guesses, zero ticket
>   discrepancies.** Live-chain verified: Algebra
>   Integral router `0x6f4b…` `exactInputSingle((address,address,address,address,uint256,uint256,uint256,uint160))`
>   selector `0x1679c792` (+ `algebraSwapCallback` ⇒ Algebra not UniV3; no `fee` field, has `deployer`+`limitSqrtPrice`);
>   HYDX/USDC pool `0x51f0…` is a BASE-factory pool (`router.factory()==pool.factory()==0x36077D39…`; `poolByPair(HYDX,
>   USDC)==pool`) ⇒ `deployer=address(0)`; token0=HYDX/token1=USDC. **On-chain bounds = `minOut` (price) +
>   `maxSellHydx` (per-call size, the dump backstop); per-EPOCH throughput stays 8-B11/8-B12 CRE** (the on-chain epoch
>   *accumulator* was considered + REJECTED for sibling-consistency + §17 puts that stateful time-policy at CRE — the
>   module stays stateless beyond set-once config; the spec-gap fixed this window: §4.5.1 8-B9 "State: per-epoch volume
>   accumulator" → "no module state"). Security verdict: SECURE/spec-compliant — a single whole-basket dump is now
>   bounded on-chain by `maxSellHydx`; multi-call throughput abuse is bounded by the 8-B12 off-chain tripwire, NOT a
>   module bug. Code `contracts/src/supply/szipUSD/SellModule.sol` +
>   `contracts/test/SellModule.t.sol` + NEW `contracts/src/interfaces/algebra/ISwapRouter.sol` + edits (IAlgebraPool
>   `token0`/`token1`; BaseAddresses `ALGEBRA_SWAP_ROUTER`). NOT git-committed (whole tree untracked).
>   `tickets/sodo/8-B9-sell-module.md`; `reports/8-B9-report.md`. **8-B10 REWORKED → `RecycleModule` (2026-06-08, user-directed
>   single-sink redesign) — BUILT-VERIFIED + KEPT.** The recycle/payout module collapsed to **ONE sink:** `recycle(usdc)` =
>   `ZipDepositModule.deposit` (USDC → `CreditWarehouse` senior backing) → backed zipUSD minted **directly into the basket**
>   (module runs on the MAIN Safe — no `gate.depositFor`, no shares), then 8-B6 single-sides it into the gauge-staked LP →
>   **NAV-per-share accretes for every holder** (the depositor's M1 return; supersedes Mode A/B/C + the xALPHA boost). **DELETED:**
>   `payoutClean`/`payoutBoost`/public `spendFreeValue`/`setCompounder` + `xAlpha`/`distributor`/`compounder` wiring + the entire
>   `SzipRewardsDistributor`. Kept: `freeValueAccrued` + `creditFreeValue` + `recycle` + the internal `_spendFreeValue` gate.
>   `contracts/src/supply/szipUSD/RecycleModule.sol` + `contracts/test/RecycleModule.t.sol`, **19/19 (16 unit + 2 integrated +
>   1 Base-fork) — superintendent-reverified**; `RecyclePayoutModule.sol`/`.t.sol` + `SzipRewardsDistributor.sol`/`.t.sol` DELETED.
>   Spec/docs reconciled (`§4.5.1` recycle-only + §2/§17 NAV-accretion; `baal-spec`/`auto-sodomizer §6,§11`/`treasury §4.7`).
>   **`8-B13` REMOVED — absorbed into 8-B10** (single-sided LP makes the balanced-add/swap-to-fund compounder moot). Full-suite
>   **401/401 GREEN** (re-verified). *(One transient full-suite run showed 2 `LpStrategyModuleForkTest` `DTL` reverts; they do NOT
>   reproduce — that contract passes 5/5 in isolation. Root cause = 8-B6 fork NON-DETERMINISM: `ForkConfig` uses unpinned
>   `createSelectFork("base")` (latest block), and 8-B6's two real-vault tests deposit a FIXED 1 WETH into the live WETH/USDC
>   ICHI stand-in `0x07e72…`, which bounds into `DTL` at some blocks. ZERO coupling to this rework. **FIX: pin the fork block in
>   `ForkConfig`** — latent 8-B6 test-infra fragility, logged below.)* **8-Bw DONE 2026-06-09** (CreditWarehouse senior custody +
>   `WarehouseAdminModule` Roles-v2 CRE adapter; 23/23 fork, 424/424 total — see the 8-Bw row + `reports/8-Bw-report.md`).
>   **NEXT = item 9 `ZipRedemptionQueue`** (the SENIOR exit, now unblocked by the warehouse REDEEM/REPAY seam —
>   `baal-spec §12`/§6.1). Remaining M1 on-chain (contract track): item 9 (queue), item 10 (deploy/wiring), 8x bridge (M1),
>   8-Bx `LienXAlphaEscrow` (M1-adjacent); the **loss side** (DefaultCoordinator) is M2. 8-B11 (CRE robot) + 8-B12 (monitoring)
>   are off-chain (`spec-clear-CRE.md` / `monitoring.md`). Build order: `baal-spec.md §13`. *(Superintendent may re-prioritize
>   among item 9 / 8x bridge / 8-Bx.)* **The FRONTEND is a separate dedicated post-deploy sweep — NOT the contract track:** the
>   `superintendent-allaprima.md` alla-prima role paints the supply/zap/position/exit UI over `reference/euler-lite` (incl.
>   `INFLOW-06`), files in `tickets/frontend/`, keeps its own `tickets/frontend/PROGRESS-frontend.md`, and the renderer half is
>   gated on item-10 deploy (addresses/ABIs). It does not run from this ledger (memory [[frontend-after-contracts]]).
>   **PRE-EXISTING FLAKE TO FIX (logged):** 8-B6's two real-vault fork tests deposit a fixed amount against an unpinned live ICHI
>   vault → intermittent `DTL`; pin the fork block or size the deposit to the vault's live minimum.

---

## Backlog — WOOF contracts (build-priority order; spine = `audit/2.md` Phase S → L)
| # | Item | § | Tickets | Status | Filed at |
|---|---|---|---|---|---|
| 1 | Foundry scaffold | §16 / README §7 | build (WOOF-00) | **BUILT-VERIFIED 2026-06-06** (`contracts/`; `forge build` clean, 3 self-checks incl. live Base fork read; interfaces + address book on-chain-verified — **2 address bugs fixed (ICHI factory, Baal labels) + 10/25 interface sigs corrected**). Kept, not discarded (keep-the-build doctrine). | `tickets/woof/WOOF-00-scaffold.md` |
| 2 | `LienCollateralToken` + `LienTokenFactory` | §4.2 | build (WOOF-01) | **BUILT-VERIFIED 2026-06-06** — materialized + kept on disk; `forge build` green + **14/14 tests pass** (independently re-run). Zero-spec-guess keepsake (no build-exposed errors). | `tickets/woof/WOOF-01-lien-collateral-token.md` |
| 3 | `ZipcodeOracleRegistry` | §4.1 | build (WOOF-02) | **BUILT-VERIFIED 2026-06-06** — materialized + kept; `forge build` green + **34/34 tests pass** (independently re-run, no regression). Scale identity + strict-decimals guard confirmed; zero-spec-guess keepsake. | `tickets/woof/WOOF-02-oracle-registry.md` |
| 4 | `CREGatingHook` | §4.3 | build (WOOF-03) | **BUILT-VERIFIED 2026-06-06** — materialized + kept; `forge build` green + **8/8 tests pass** (56/56 total, no regression). `borrowDriver` immutable + `NotAuthorizedOperator()` `0x3d9adf1c` + isProxy spoof-guard confirmed; zero-spec-guess keepsake. (gate `EVC.isAccountOperatorAuthorized(caller, borrowDriver)` `:286`.) | `tickets/woof/WOOF-03-cre-gating-hook.md` |
| 5 | `IZipcodeVenue` + `EulerVenueAdapter` + `LineAccount` | §4.7 | build (WOOF-04) | **BUILT-VERIFIED 2026-06-06** — materialized + kept on disk; `forge build` green + **20/20 tests pass on a live Base-mainnet fork** (76/76 total, no regression; independently re-run). EVK/EVC/EulerRouter LIVE, EulerEarn mocked (0.8.26); two-line distinct-prefix BOTH-draw isolation (real `evc.batch` borrows, `debtOf` each correct + cross-independent) + operator-grant + AmountCap round-trip + router-freeze + close-reclaim all **live-fork-proven**; every external sig + the AmountCap encode re-verified vs `reference/` (zero discrepancies); **zero spec-guesses** (1 mild cap-seed clarification folded into ticket step 4). | `tickets/woof/WOOF-04-venue-adapter.md` (`openLine` CREATE2-deploys per-line `LineAccount` granting **the adapter** the operator bit over its code-free `borrowAccount`; `draw` via `EVC.batch` operator path; no `subId`, no blanket grant) |
| 6 | `ZipcodeController` | §4.4 | build (WOOF-05) | **BUILT-VERIFIED 2026-06-06** — materialized + kept on disk; `forge build` green + **26/26 tests on a live Base-mainnet fork** (102/102 total, no regression; independently re-run). Zero EVC coupling (only `ReceiverTemplate`+`IZipcodeVenue` imports), 5-arg ctor, `create→openLine→seed→setLineLimits→fund→draw` + reclaim-before-burn + no-controller-operator-wiring borrow all live-fork-proven; zero-spec-guess keepsake (no build-exposed errors, no `claude-zipcode.md` edit). | `tickets/woof/WOOF-05-controller.md` (DROPPED `wireVenueOperator`/blanket `setOperator` + the EVC ctor handle entirely — the controller takes **no EVC** and never touches EVC; borrow authorized per-line by the adapter's `LineAccount` inside `openLine`. Everything else preserved: `onReport` gate, `_processReport` dispatch, `create→openLine→seed→setLineLimits→fund→draw`, close/burn, custody, dormant-gate. **Cold-build YES 17/17 live EVK borrow.**) |
| 7 | `ZipDepositModule` (the zap) — `USDC → mint zipUSD → zap into szipUSD` | §4.5 | build (WOOF-06) + interface (INFLOW-06) | **BUILT-VERIFIED 2026-06-08 against the REAL Gate seam — materialized + KEPT** (`contracts/src/supply/ZipDepositModule.sol` + `contracts/test/ZipDepositModule.t.sol`; `forge build` green + **29/29** [26 mock-gate adversarial unit + 3 real-gate Base-fork], **205/205 total no regression** — run `forge test --fork-url $BASE_RPC_URL`). The headline zap is fork-proven end-to-end against the **LIVE** `ExitGate.depositFor` + real `SzipNavOracle` + real Baal substrate + real zipUSD `ESynth`; `MockGate` retained only for adversarial gate behaviours (under-pull/no-share/mid-call-revert/reentrancy). **Build-discovered + fixed:** the real `ExitGate` lacked the `previewDeposit` this ticket's obligation pinned → **added `previewDeposit(asset,amount) view` to the kept `ExitGate`** (mirrors `depositFor` pricing; obligation DISCHARGED, +2 Gate tests). `depositFor(asset,amount,receiver)→shares` matched exactly; the real Gate routes pulled zipUSD to `mainSafe` (the basket), so the real-gate test asserts `zip.balanceOf(mainSafe)` vs the mock's `gateMock`. `reports/WOOF-06-report.md`. NOT git-committed (whole tree untracked). **INFLOW-06 (the frontend interface) is NOT a contract-track cold-build — it folds into the dedicated post-deploy frontend sweep** (`superintendent-allaprima.md` → `tickets/frontend/`, gated on item-10; memory [[frontend-after-contracts]]). | *(2026-06-07: seam flipped to `gate.depositFor(zipUSD,amount,user)` → transferable szipUSD, NAV-proportional, `shares` not `loot` — see `reports/WOOF-06-report.md`. Historical 2026-06-06 detail below:)* `tickets/woof/WOOF-06-deposit-module.md`: module is a stateless mint+deposit router (NO custody) — `deposit`/`zap` park USDC into `EE_POOL` with the **`CreditWarehouse` Safe** as `receiver` (4th ctor immutable); zap (THE default action) mints zipUSD to the module (transient) → szipUSD Baal **mint shaman** `depositFor(zipAmount, user)` (on-behalf Loot); plain `deposit` (raw zipUSD) = secondary path. Mint-1:1/`scaleUp` preserved; F1/max-allowance/EE-share `stake` seam GONE. Harness: draft + ref-verify + **5 critics** + reviser-fold + **cold-build**. Hardened to **enforce zero-residual in-contract** (`ResidualBalance`/`ZeroLoot`, `forceApprove`); Permit2 RESOLVED (ERC20 fallback); deploy must verify `warehouse`+szipUSD before capacity. **Cold-build YES — 32/32 green** (2 build-proven fixes folded: OZ `IERC20` import, `usdcIn` param); byproduct discarded. New obligations: 8-B2 `depositFor`/`previewDeposit`; 8-Bw warehouse dep; item-10 wiring assertions. **INFLOW-06 (interface) ALSO re-authored** (zap=default Loot via `depositFor`; `Zapped(…loot)`; `sendTransactionAsync` not `writeContract`; euler-lite modeling intact). `reports/WOOF-06-report.md` rewritten. |
| 8 | `szipUSD` — **the auto-sodomizer junior NAV vault** (**Baal Moloch-v3 + Zodiac**: Loot share, Safe-held multi-asset basket [zipUSD + xALPHA + zipUSD/xALPHA ICHI LP gauge-farmed on Hydrex + room for several strategies], ragequit in-kind exit, **NAV = tracked/displayed from multiple oracles** (not a redemption primitive), CRE-driven via manager-shaman + Zodiac modules, **LOCK (~30d) + FREEZE** gates). | §4.5 / §6.4 / §11 + `pending-docs/auto-sodomizer.md` + `hydrex.md` | multi-ticket REBUILD (~13: 8-Bw + 8-B1…12) | **TWO-TOKEN REDESIGN INTEGRATED 2026-06-07 (see the CURRENT-STATE banner at top — the model nouns in the left cell are OLD/superseded). NEXT = `8-B1` (substrate scaffold via `BaalAndVaultSummoner`) → `SzipNavOracle` → Exit Gate → engine 8-B5…8-B14. Author from `baal-spec.md` §13 + `claude-zipcode.md`; cold-build WOOF-06 once 8-B1/oracle/Gate land.** | **PRIOR WOOF-07 + INFLOW-08 DELETED** (wrong vault: ERC-4626 convert-on-stake over EulerEarn loan-book pool shares). Substrate **Baal+Zodiac decided** (user-reversed the interim 7540 lean — don't need single-asset exit/4626 composability; agents 33–29 in plan). First-loss = **WITHHOLD at-risk zipUSD from ragequit** (not markdown/seizure); frozen capital keeps earning. Spec money-model rewrite (§5/§6.4/§11/§12/§17 + audit/1) + ticket decomposition pending — **design still being managed**. See `~/.claude/plans/don-t-be-dropping-deferrals-quirky-ocean.md` + §4.5 guardrail. |
| 9 | `ZipRedemptionQueue` | §4.5 / §6.1 | build | **NEXT** (unblocked 2026-06-09 by the 8-Bw warehouse REDEEM/REPAY seam) | — |
| 10 | Deploy + wiring script (vanilla Euler/OZ/CRE config) | §9 | build (script) | TODO | covers `audit/2.md` S1–S12 |
| 10a | Deploy identity pre-gate (S11 renounce-before-identity, slice of 10) | §9 | build | **BUILT-VERIFIED 2026-06-06** — materialized + kept; `forge build` green + **5/5 tests** (107/107 total, no regression; no fork — pure view over the real WOOF-02/05). Combined fail-closed gate + the three test classes (NEGATIVE x3 / POSITIVE renounce-then-frozen / NEGATIVE-CONTROL dormancy selector-difference) proven against the REAL receivers; zero-spec-guess keepsake. | `tickets/woof/WOOF-10a-deploy-identity-gate.md` |
| 8-Bx | `LienXAlphaEscrow` — per-lien xALPHA bond custody (slashable reservoir) | §4.6 / §11 | build | **PULLED FORWARD (M1-adjacent, 2026-06-08 user-directed)** — buildable now: custody half (`lockXAlpha` at launch / `releaseXAlpha` on repay) is M1, slash half (`slashXAlphaToCapital`/`slashXAlphaToCohort` → routes xALPHA into the sidecar) built + mock-tested now, goes live with the M2 default flow. Authorable after the Exit Gate (the sidecar = its slash-target). | — |
| — | `DefaultCoordinator` — NAV markdown writer + xALPHA recovery waterfall (the freeze is NOT its job; 2026-06-08 shrink) | §4.6 / §11 | build | DEFERRED (M2) — shrunk: writes the bounded provision into `SzipNavOracle` + runs the recovery waterfall; the freeze is **structural/utilization-sized, owned by the Exit Gate** (§6.4), no longer engaged here | — |
| 8x | **xALPHA bridge** (canonical-vs-fork wrapper + CCT pool) — feeds the M1 szipUSD farm-loop basket + the first-loss bond | §2 / `bridge/xalpha-bridge-impl.md` | build | **M1 (2026-06-06, user-directed)** — build it; dev validates against a **stand-in test xALPHA token** (no blocking on CCT registration); real token swaps in. Feeds 8-B5/8-B6. | — |

### Item 8 decomposition — szipUSD = the auto-sodomizer NAV vault (Baal + Zodiac)
The 2026-06-05 `WOOF-07`/`INFLOW-08` (ERC-4626 convert-on-stake over EulerEarn pool shares) were **DELETED — wrong
vault.** szipUSD is the **auto-sodomizer junior NAV vault**: a **Baal/Moloch-v3 + Zodiac** vault (Loot share;
Safe-held basket [zipUSD + xALPHA + zipUSD/xALPHA ICHI LP]; **transferable szipUSD share** (Gate-minted,
NAV-proportional); **NAV (`SzipNavOracle`) is the pricing primitive**; windowed-RQ (partial-fill) + CoW exits; the
**sidecar freeze**; first-loss = a **conservative provision-that-recovers** — 2026-06-07, supersedes the
soulbound/withhold-no-markdown phrasing). See the §4.5
guardrail + the §4.5 strategy-module inventory + the plan. **Build one at a time, in dependency order** (each
builds on the prior); on-chain pieces **fork-tested against live Base** (real ICHI/gauge/oHYDX/NFPM/EulerEarn,
stand-in gauge addrs; swap for production). Build tickets file in **`tickets/sodo/`**.

**Phase 8-S — money-model spec foundation. These are NOT tickets — they are direct spec EDITS** (to
`claude-zipcode.md` / `audit/1-results.md`): no ticket file, no `tickets/sodo/`, no adversarial-harness pass, no
cold-build. They are the foundation the **8-B tickets** are authored from. MUST precede the build; do in order,
each builds on the last:
| # | Spec edit (not a ticket) | Touches | Depends | Status |
|---|---|---|---|---|
| 8-S1 | **§17 flip** — replace the locked "junior is share-backed / convert-on-stake / staked zipUSD = subordinated principal" decisions with the Baal model (Loot / Safe-basket / ragequit; NAV display-not-redemption; first-loss = withhold; yield = HYDX-vamp + xALPHA) | `claude-zipcode.md` §17 (+ §2 token row, §6.4 nouns) | — | **DONE (2026-06-06)** — 4 §17 locked-decision bullets + the §2 "Junior accounting unit" para flipped. **Residual sweep folded into 8-S2:** the big §2 token-table cell (line 94) + §6.4 `unstake`/`cooldown` nouns. |
| 8-S2 | **§12 rewrite** — NAV/solvency for the Baal basket (NAV = multi-oracle basket mark, display-not-redemption; "szipUSD bears first loss" → withhold + passive socialization; solvency restated) + the 8-S1 residual sweep (§2 token cell, §6.4 ragequit/lock/freeze reframe, §3 primitive rows → Baal ragequit + lock/freeze shamans) | `claude-zipcode.md` §12 / §2 / §6.4 / §3 | 8-S1 | **DONE (2026-06-06)**. **Tiny residuals left (guardrail-covered, cosmetic):** the stale convert-on-stake block at §4.5 `:566-607` (delete/replace when 8-B1 is authored) + one "unstake→AMM dump" noun in §11 trigger-B `:1181`. |
| 8-S2b | **Two-Safe custody + `CreditWarehouse`** (superintendent-authored w/ user, 2026-06-06) — add the senior-backing custody Safe (`CreditWarehouse`) + its CRE-gated Zodiac `WarehouseAdminModule` to §4.5: a plain Gnosis Safe holds the `EulerEarn` shares (the senior backing); owner = **GOD-EOA → multisig** (native Safe `swapOwner`/`addOwnerWithThreshold`, no migration contract); admin = the **Zodiac Roles Modifier v2** (audited Gnosis Guild infra), `enableModule`'d + scoped by an owner-applied permissions policy to the warehouse op-set (SUPPLY/APPROVE/REDEEM/REPAY → `EE_POOL`/`USDC`, params pinned, Call-only); the CRE seam is a thin `is ReceiverTemplate` role-member adapter (Forwarder-gated, renounce-immutable) decoding the §4.4 envelope → `Roles.execTransactionWithRole`. **Decided B (Roles v2) over a purpose-built module — user-ratified 2026-06-06, `reports/research/zodiac-warehouse-research.md`** (scope lives in audited code, not bespoke bytecode; no guard can contain a module). EE-share custody moves **deposit module → warehouse Safe**; §5 flow + item-7 zap reshaped (deposit to `WAREHOUSE_SAFE`, junior stake = Baal mint shaman; the F1/max-allowance seam **dissolves**). **Lands AFTER 8-S3 but does NOT invalidate it** — verified `audit/1` is purely economic (`NAV_s=C+D`, `R=NAV_s/Z`), agnostic to EE-share custody location. | `claude-zipcode.md` §4.5 / §5 (+ deposit-module marker, item-7 obligation) | 8-S2 | **DONE (2026-06-06)** |

**Phase 8-S is COMPLETE (8-S1/2/2b/3 all DONE, 2026-06-06).** *(NOTE 2026-06-07: those 8-S edits produced the
**withhold-no-markdown** model, which was then **superseded + re-integrated** as the **two-token / NAV-oracle /
provision-that-recovers** model — see the CURRENT-STATE banner at top; `audit/1-results.md` I1–I5 are RETIRED.)* The
money model is consistent across §2/§4.5/§4.6/§11/§12/§17. The **only** remaining residuals are the two cosmetic
ones noted on 8-S2 above (the stale §4.5 `:566-607` convert-on-stake block + the §11 `:1181` "unstake→AMM dump"
noun) — both **guardrail-covered**, to be deleted/replaced when **8-B1** is authored. **NEXT = 8-B1** (the
Baal + Safe + Loot + shaman/Zodiac scaffold), the first build ticket.

**Pending SPEC phases — pull-forward, run via the `spec-clear-*` plans in FRESH windows (user-directed 2026-06-06).**
Two spec pulls complete the spec the way Phase 8-S did for the money model — each a spec-EDIT window (no
tickets/cold-build); run it in a fresh context off its plan file, then it flows into the regular one-at-a-time
ticketing. **Hold the dependent builds until the matching pull lands.**
| Phase | Plan file (fresh window) | Pulls | Gates | Status |
|---|---|---|---|---|
| **8-SY** (yield-engine spec) | `spec-clear-8SY.md` | `pending-docs/auto-sodomizer.md` + `hydrex.md` → build-grade §4.5 for the auto-sodomizer modules | **8-B5…8-B12** (the engine; NOT 8-Bw / 8-B1–B4 substrate) | **DONE (2026-06-06)** — pulled to build-grade in new **§4.5.1** (shared Zodiac/CRE-operator/EVC-Safe architecture + one block per module: external calls, CRE op seq, state, invariants, failure modes). Verifiable sigs (EVK/EVC/Zodiac-core/Baal) cited `file:line`; ICHI/Hydrex/Algebra marked `[EXT]` interface+fork pinned to Basescan ABI; EulerEarn mocked (0.8.26). **§11/§12/§17 untouched, no `audit/1` follow-up** (strike capital = segregated treasury USDC; recycle mint = existing `ZipDepositModule` path). **Flags for the user:** (1) the 8-B5 LP-collateral oracle source (CRE cache vs fixed haircut — mechanism, not economic); (2) external gates surfaced — Hydrex gauge whitelist + 8x xALPHA stand-in. **Hardened post-draft (fork-reads on Base 8453 + adversarial review):** fork-verified the oHYDX/Voter/gauge/ve/pool signatures (corrected `getMinPaymentAmount()`=no-arg; added the `exercise` deadline overload); fixed 2 BLOCKERs — (1) **`EdgeFactory.deploy` renounces governance** → 8-B5 reworked to `GenericFactory` + retained TimelockController governor + oracle-adapter-as-deploy-prereq; (2) **gauge-staked-LP can't also be EVK collateral** → 8-B5 rewritten (user correction) as THE harvest **process** — the ordered 7-step self-collateralizing loop (unstake→collateralize→borrow strike→exercise→sell→repay→re-stake; LP is its own working capital); standing USDC buffer removed (borrow revolves). **Lucidity + doc pass:** §4.5.1 opens with an end-to-end "harvest cycle" overview (how the 7 sub-routines chain); `auto-sodomizer.md` reconciled + marked (dated STRIKE-FINANCING-CORRECTION callout + §5 rewritten canonical + §4/§9 fork-verified sig fixes) — pending-doc and spec now agree. **8-B9 reframed range-sell → MARKET-sell** (user-directed): the loop repays the borrow immediately + the pool is net-draining (no buy-side, won't fill resting orders), so market-sell via SwapRouter; soft-bleed caps become a SIZE GATE on the loop, regime gate moved upstream to 8-B8 (borrow only in UP/FLAT; DOWN→exerciseVe). Marked in auto-sodomizer §4/§5/§9.1. Plus: `Module.sol:43` exec cite, `freeValueAccrued` ownership/writer/formula pinned, soft-halt($0.018)-vs-hard-floor($0.01) split. `reports/design/8-SY-spec-report.md` (Fidelity-pass section). **8-B5…8-B12 now authorable zero-guess.** **Post-8-SY follow-on (2026-06-06): added 8-B13 Compounder / LP-rebalance (Mode C)** — the recycle loop's growth sink (reinvest free value into more staked LP + credit-line capacity; the "how much xALPHA → swap-if-short → add+stake LP" evaluator). §4.5.1 + `auto-sodomizer.md` §11; 8-SY report addendum. So the engine is now **8-B5…8-B13**. |
| **CRE §8 spec** | `spec-clear-CRE.md` | §8 producer spec for every on-chain report surface (incl. the new warehouse opTypes + szipUSD shaman ops); discharges the CRE-track obligations | the **CRE-00…CRE-03** build track | **DONE (2026-06-09)** — §8 rewritten to producer level: §8.0 per-`(receiver,reportType)` envelope table (discharges WOOF-05); §8.1 gas-bounded revaluation sharding (discharges WOOF-02); **LP_MARK=7 ratified** as per-receiver-scoped (§8.0/§8.6, no collision with NAV_LEG=7); §8.5 warehouse SUPPLY/APPROVE/REDEEM/REPAY via Roles; §8.6 NAV_LEG/LP_MARK push-cache producers; §8.7 the **operator path** (8-B11, NOT a report); §8.8 xALPHA-APR; §8.9 DEC-01 gate (surfaced, not resolved); §8.11 CRE-00…05 map (CRE-04 warehouse-ops + CRE-05 engine-operator added). `reports/design/CRE-spec-report.md`. **CRE-04 still owes an 8-Bw `WarehouseAdminModule` decode reconcile.** |
(The substrate builds — **8-Bw + 8-B1 + `SzipNavOracle` + the Exit Gate** — are spec-ready NOW and wait on neither. (The old "8-B2 mint shaman / 8-B3 lock-freeze shaman / 8-B4 oracle" are folded into the Gate + `SzipNavOracle`, 2026-06-07.) M2 loss / bridge / treasury stay dormant in `tickets/PHASE2.md`.)
| 8-S3 | **`audit/1` re-derivation** — replace I1–I4 (`ν=J×p`, `Burn=loss/p`, escrow) + all P-rows with the Baal/withhold money model (basket NAV, ragequit pro-rata, withhold = duration; **permanent-loss realization = 3 levers, resolved 2026-06-06 + folded into §11/§4.6: sequester+burn the frozen junior zipUSD / sell junior yield→USDC / sell junior xALPHA→USDC, each fills the hole + lifts the freeze**). **Big focused window — the model is now complete + derivable.** | `audit/1-results.md` (whole) | 8-S2 | **DONE (2026-06-06)** — full re-derivation: new invariants **I1 senior solvency `NAV_s/Z≥1` / I2 subordination / I3 ragequit value-preservation / I4 freeze neutrality / I5 three-lever loss-realization**; scenarios **S0 baseline (deposit→draw→interest=protocol σ→xALPHA subsidy+HYDX vamp=junior pay→ragequit) / S1 freeze+recovery (value-neutral, junior whole+premium) / S2 the three levers (one loss row, 3 branches, each restores `R≥1` + shrinks basket by `L`) / S3 insolvency boundary (junior exhausted first)**. Spec-changes-recommended = **None** (§2/§4.5/§4.6/§11/§12/§17 close arithmetically; no gap). `reports/design/8-S3-report.md` written. |

**Phase 8-B — build TICKETS (Baal + Zodiac; harness-authored, fork-tested against live Base, filed in
`tickets/sodo/`; depend on the 8-S spec edits; do in order):**
*(**Authoritative 8-B build order + per-component specs = `baal-spec.md` §13 / §10.8** (2026-06-07 two-token model); 8-B5…8-B13 also in `claude-zipcode.md` §4.5.1. **The rows below were updated to the redesign:** the old 8-B2 mint-shaman + 8-B3 lock/freeze-shaman are **ABSORBED into the Exit Gate**; 8-B4 is now **`SzipNavOracle`** (the **NAV-proportional pricing primitive**, not display-only); **8-B14 buy-and-burn** is added.)*
| # | Ticket | What | Depends | Status |
|---|---|---|---|---|
| 8-Bw | **`CreditWarehouse` — senior custody Safe + `WarehouseAdminModule`** (SENIOR side; independent of the junior 8-B1..12 chain) | summon a Gnosis Safe (owner **GOD-EOA → multisig**, native `swapOwner`/`addOwnerWithThreshold`) holding the `EulerEarn` shares; deploy + `enableModule` the **Zodiac Roles Modifier v2** (`reference/zodiac-modifier-roles`); apply a permissions policy (`reference/permissions-starter-kit`) scoping the role to **SUPPLY/APPROVE/REDEEM/REPAY** (`EE_POOL`/`USDC`, params pinned via `EqualTo`/`EqualToAvatar`, **Call-only**); author the thin **`is ReceiverTemplate` CRE adapter** (immutable-Forwarder-gated, renounce-immutable) that decodes the §4.4 envelope → `Roles.execTransactionWithRole`, `assignRoles`'d as the role member. Fork-test the four permitted ops + that **off-policy / non-member / non-owner** calls revert in the Roles checker. **Gates the item-7 zap re-author + the item-9 redemption draw.** **AUDIT-SWEEP OBLIGATION:** author the new warehouse deploy/wire steps into `audit/2` Phase S (the `CreditWarehouse` Safe + `WarehouseAdminModule` `enableModule`, the opType 1/2/3 pathway L-steps + revert N-steps, the S8 `feeRecipient` wiring) + the matching `audit/3-results` authority rows — the EXCISED markers there point here. **Mechanism DECIDED: Roles Modifier v2** (user-ratified 2026-06-06; `reports/research/zodiac-warehouse-research.md`). **Open:** EulerEarn `redeem(shares,receiver,owner)` arg order (USDC→Safe vs sink); APPROVE infinite-vs-exact-amount. | 8-S2b | **DONE 2026-06-09 — BUILT-VERIFIED + KEPT.** `WarehouseAdminModule` (`is ReceiverTemplate` CRE adapter — NOT a zodiac Module; the SOLE Roles role member) decodes the §8.5 envelope → 1 of 4 scoped ops → `Roles.execTransactionWithRole(to,0,data,Call,roleKey,true)`. **23/23 on a live Base fork** (real Roles-v2 mastercopy `0x9646…D337` + real ModuleProxyFactory + real Safe factory/singleton + real USDC; **EulerEarn MOCKED** per WOOF-04/05 precedent — solc 0.8.26), **424/424 total no regression** (run `forge test --fork-url $BASE_RPC_URL --match-contract WarehouseAdminModule`; full suite `forge test --fork-url $BASE_RPC_URL` — independently re-run). The whole security boundary is the **audited Roles scope** (params pinned EqualToAvatar/EqualTo, Call-only ExecutionOptions.None) — the adapter holds no custody, enforces no scope. Code: `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol` + `contracts/script/CreditWarehouseDeployer.sol` + `contracts/test/WarehouseAdminModule.t.sol` + `contracts/test/mocks/MockEulerEarn.sol` + NEW `contracts/src/interfaces/euler/IEulerEarn.sol` + EXTENDED `src/interfaces/zodiac/IRoles.sol` (`ConditionFlat`+`scopeFunction`) + `src/interfaces/safe/ISafe.sol` (`setup`). **3 §4.5/§8.5 open items RESOLVED + folded to spec** (redeem owner-3rd; redeemed USDC→Safe-then-REPAY; APPROVE amount scope-free + CRE exact; LOANBOOK→pinned `repaySink`; opType bytes 1/2/3/4). **2 build-discovered on-chain corrections** (the DEPLOYED mastercopy is newer than the vendored ref): non-member reverts **`NotAuthorized`** (`moduleOnly` gate fires before `NoMembership`), non-owner reverts **`OwnableUnauthorizedAccount`** (zodiac-core OZ-5 custom error, not an OZ-4 string) — both folded into the ticket; + the deployer is the **transient** Safe/Roles owner during wiring then hands off to GOD-EOA (`swapOwner`/`transferOwnership`). **ZERO load-bearing guesses.** NOT git-committed (whole tree untracked). `tickets/sodo/8-Bw-credit-warehouse.md`; `reports/8-Bw-report.md`. **AUDIT-SWEEP DEFERRED to item-10** (like 8-B5..B10; logged as an OPEN obligation below). |
| 8-B1 | **Baal + main Safe + sidecar + Loot scaffold** | summon via `BaalAndVaultSummoner` (main Safe + non-ragequittable **sidecar**); Loot paused/soulbound; **zero Shares**; **team-multisig admin signer injected on both Safes** (the authority model); the vault substrate. **`baal-spec.md §13`.** | 8-S* | **DONE 2026-06-07 — BUILT-VERIFIED on a live Base fork.** `forge build` green + **8/8 `SummonSubstrateTest` pass** (115/115 total, no regression — run `forge test --match-contract SummonSubstrateTest`). Code at `contracts/script/SummonSubstrate.s.sol` + `contracts/test/SummonSubstrate.t.sol` + interfaces under `contracts/src/interfaces/{baal,safe}/`. Full lifecycle fork-proven: summon → team-owner on BOTH Safes → wireability (team drives `setShamans`/`enableModule` with zero Shares) → governance proven inert. **Spec gap fixed FIRST** (the "post-deploy setShamans" seam was un-reachable; ratified two-tier admin/operator model → `claude-zipcode.md §4.5 item-0` + `baal-spec.md 8-B1`). **Build-discovered:** BaalSummoner's Safe proxy factory = `0xC22834581EbC…` (slot 208), not `0xa6B7…` (new `BaseAddresses.BAAL_SAFE_PROXY_FACTORY`). **NOT git-committed** (whole repo working-tree is untracked; on `main`). `reports/8-B1-report.md`. |
| `SzipNavOracle` | **the szipUSD NAV-per-share oracle** (was "8-B4") | hybrid compose + **on-chain TWAP (W=4h)**, `max`/`min` bracket, staleness + circuit-break, **IL marked-through**, two-layer xALPHA mark. **The issuance/exit pricing primitive — NOT display-only.** `baal-spec.md §3`. | 8-B1 | **BUILT-VERIFIED 2026-06-07** — materialized + kept; `forge build` green + **39/39 tests** (incl. live Base-fork sig-verification); **154/154 total, no regression** (run `forge test --match-contract SzipNavOracleTest [--fork-url $BASE_RPC_URL]`). Code at `contracts/src/supply/SzipNavOracle.sol` + `contracts/src/interfaces/bridge/IXAlphaRate.sol` + `contracts/test/SzipNavOracle.t.sol`; `IOptionToken.discount()` added (on-chain==30). Ticket `tickets/sodo/8-B4-szip-nav-oracle.md`; spec edits §4.4/§7/§12; `reports/8-B4-report.md`. **ZERO-GUESS GATE CLOSED 2026-06-08** — independently re-materialized from the ticket alone (sealed keepsake), 33/33 fresh unit + fork-sig green, 149/149 no-regression; **3 ticket holes folded in** (setter `ZeroAddress` guards; `Poked` arg `uint256` not `uint224`; `grossBasketValue` `public` not `internal`) + `_accumulate`→`bool`/gated-`poke` pinned; keepsake RESTORED (no bug found). `reports/8-B4-zerogate.md`. |
| **Exit Gate + szipUSD** | **absorbs the old 8-B2 mint shaman + 8-B3 lock/freeze shaman** | the sole Loot custodian + **szipUSD minter** (holds `manager`=2): **NAV-proportional issuance** (`gate.depositFor` → transferable szipUSD via `SzipNavOracle`), TVL cap, intent-queue + liquidity-window **plain in-kind ragequit** (pro-rata slice of the free basket; no oracle/cap/numeraire on exit), the paired buy-and-burn, the **structural sidecar freeze**. **`baal-spec.md §4/§5`.** **AUDIT-SWEEP OBLIGATION:** re-author the junior acceptance into `audit/2` (L3 deposit→szipUSD, the S7 junior wiring) + `audit/3-results` matrix rows 25–27 / Trace E — the EXCISED markers there point here. | 8-B1, `SzipNavOracle` | **BUILT-VERIFIED 2026-06-08** — `contracts/src/supply/szipUSD/ExitGate.sol` + `SzipUSD.sol` + `contracts/test/ExitGate.t.sol`; **17/17 on a live Base fork** (real Baal substrate via `SummonSubstrate._summon` + real `SzipNavOracle` + mock basket), **174/174 total no regression** (run `forge test --fork-url $BASE_RPC_URL`). Both inbound obligations DISCHARGED (above). 2 spec gaps fixed (§6.4 windowController + **in-kind exit** [exit reworked from my zipUSD-numeraire to pure in-kind ragequit, user-directed 2026-06-08 — see rework entry] / §7 `valueOf`) + the `valueOf` view added to the kept oracle (42/42). Ticket `tickets/sodo/8-B-exit-gate-szipusd.md`; `reports/Exit-Gate-report.md`. Kept on disk, NOT git-committed (whole tree untracked — superintendent commit decision pending). **AUDIT-SWEEP still OPEN** — pinned to the **"Item 10 / junior-acceptance pass"** obligation row (NOT a missing interface like `SzipNavOracle`'s; the Gate interface exists — it waits on the zap + deploy/wiring being integration-testable; the audit/3 authority rows fold into the same pass). |
| Exit auto-dump | **xALPHA→zipUSD on exit** (a separate Zodiac module) | market-dumps the xALPHA leg a leaver received → zipUSD on Hydrex, so they walk out with only zipUSD (then `ZipRedemptionQueue` → USDC). NOT the Gate; reuses 8-B9's Hydrex sell machinery. User-directed 2026-06-08. | 8-B9, Exit Gate, live zipUSD/xALPHA pool | TODO — `tickets/sodo/8-B-exit-autodump.md` |
| 8-B5 | **Reservoir USDC vault + ICHI-LP collateral + CRE-borrow** | strike-financing plumbing (EVK market; overlaps WOOF-04 baseUsdcMarket + item 10) | 8-B1 | **BUILT-VERIFIED 2026-06-08 — materialized + KEPT** (`contracts/src/supply/szipUSD/ReservoirLoopModule.sol` + `contracts/src/supply/SzipReservoirLpOracle.sol` + `contracts/src/supply/szipUSD/ReservoirBorrowGuard.sol` + `contracts/script/ReservoirMarketDeployer.sol` + `contracts/test/ReservoirLoopModule.t.sol`; `forge test --match-contract ReservoirLoopModuleTest` **33/33 Base-fork**, **271/271 total no regression** — independently re-run). The 2nd engine Zodiac Module: a CRE-`onlyOperator` `is Module` driving the szipUSD Safe's **own EVC account** through the unstake→post→borrow→repay→withdraw loop (`postCollateral`/`borrow`/`repay`/`withdrawCollateral`), all `exec(Call)` with `receiver`/`onBehalf` hard-pinned to `engineSafe`, no generic passthrough. Borrows the reservoir USDC vault (= warehouse resting vault) over-collateralized by the ICHI-LP escrow; **aggregate `borrowCap`**; **`ReservoirBorrowGuard`** pins `OP_BORROW` to the Safe; **`SzipReservoirLpOracle`** = CRE-fed push-cache (`LP_MARK=7`), fail-closed staleness. 5-critic fanout (junior/spec-fidelity/ref-verifier/qa/security). **4 build-exposed corrections folded back** (C1 Safe-swallows-reverts→`_exec` bubbles; C2 `repay` reverts `E_RepayTooMuch`; C3 borrow gates on `borrowLTV`; C4 `setLTV` needs live mark + `transferGovernance(timelock)` RETAIN). Spec-clarified §4.5.1. NOT git-committed (whole tree untracked). `tickets/sodo/8-B5-reservoir-loop.md`; `reports/8-B5-report.md`. |
| 8-B6 | **LP strategy module** | post the **single-sided zipUSD** ICHI LP + gauge-stake; unstake/re-stake for the 8-B5 loop | 8-B1, 8-B5 | **DONE 2026-06-08 — BUILT-VERIFIED.** `LpStrategyModule` (3rd engine Zodiac Module; no EVC/oracle/hook). `addLiquidity`(ICHI deposit + `minShares` floor)/`stake`/`unstake`, all `onlyOperator` scalar-only, deposit-`to`/views pinned to `engineSafe`; **vault-agnostic** (single-sidedness enforced by the wired vault's `allowToken*`, not the module). **29/29** (24 unit + 5 Base-fork — real ICHI vault `0x07e72…` deposit lands shares → DepositGuard NOT needed; full cycle vs real summoned Safe), **300/300 total** — `forge test [--fork-url $BASE_RPC_URL] --match-contract LpStrategyModule`. **Design: single-sided zipUSD YieldIQ, no balanced add** (user-directed 2026-06-08; xALPHA leg accrues from pool flow); gauge MUST be `ALM_ICHI_UNIV3`. NOT git-committed (tree untracked). Code `contracts/src/supply/szipUSD/LpStrategyModule.sol` + `contracts/test/LpStrategyModule.t.sol`; `tickets/sodo/8-B6-lp-strategy.md`; `reports/8-B6-report.md`. |
| 8-B7 | **Harvest/vote module** | claim oHYDX; `exerciseVe` (vote-floor); account-keyed `Voter.vote`/`reset`; rebase | 8-B6 | **DONE 2026-06-08 — BUILT-VERIFIED.** `HarvestVoteModule` (4th engine Zodiac Module; simplest sibling of 8-B6 — no EVC/oracle/custody/approvals, **NO tokenId state**). 5 `onlyOperator` mutators (`claimReward`/`lockVe`/`vote`/`resetVote`/`claimRebase`) + 3 views, all `exec(Call, value 0)` via `_exec`-bubble; `exerciseVe` recipient + every read hard-pinned to `engineSafe`. **26/26** (21 unit + 5 Base-fork: real `exerciseVe` proves the fresh-veNFT/account-aggregate model, real `vote`/`reset` vs live VoterV5, real `claimRebase`), **326/326 total** — `forge test [--fork-url $BASE_RPC_URL] --match-contract HarvestVoteModule`. **ZERO load-bearing guesses.** Code `contracts/src/supply/szipUSD/HarvestVoteModule.sol` + `contracts/test/HarvestVoteModule.t.sol` + interface adds (`IVoter.reset`/`ve`; `IVotingEscrow.getVotes`/`balanceOf`/`ownerOf`/`tokenOfOwnerByIndex`; new `IRewardsDistributor`) + `BaseAddresses` (`HYDREX_VE`/`HYDREX_REWARDS_DISTRIBUTOR`). **5 spec corrections** to the on-chain-verified Hydrex surface (`claude-zipcode.md §4.5.1` + `baal-spec §10.8`): VoterV5 is **account-keyed** (`vote(address[],uint256[])`/`reset()` — NO tokenId; the guessed tokenId variants ABSENT on-chain); floor = `ve.getVotes(account)` (NOT `balanceOfNFT(tokenId)` — the account holds many veNFTs); state = **none / no tokenId**; rebase via the **RewardsDistributor** (`Minter._rewards_distributor()=0x6FCa2…`), not the Minter; `getEpochDuration()`=604800 confirmed. **Build-exposed (test-sequencing, module correctly agnostic):** live `vote` needs an epoch-advanced snapshot + `Minter.update_period()` (`InsufficientVotingPower`/`EpochStale`) and a per-account ~1h vote-delay (`VoteDelayNotMet`) — folded into the ticket. NOT git-committed (whole tree untracked). `tickets/sodo/8-B7-harvest-vote.md`; `reports/8-B7-report.md`. |
| 8-B8 | **Exercise/strike-financing module** | LP → reservoir collateral → CRE-borrow USDC → exercise oHYDX → HYDX | 8-B5, 8-B7 | **DONE 2026-06-08 — BUILT-VERIFIED.** `ExerciseModule` (5th engine Zodiac Module; the *paid* counterpart to 8-B7's free `exerciseVe` — a different oHYDX function with a USDC strike; NO EVC/oracle/LP/veNFT — pure exercise mechanism, sibling of 8-B5's approve→call→reset dance minus the EVC leg). ONE `onlyOperator` mutator `exercise(amount, maxPayment, deadline) → paymentAmount`: 3 `exec`s — `USDC.approve(oHYDX, maxPayment)` / `oHYDX.exercise(amount, maxPayment, engineSafe, deadline)` (4-arg deadline overload; burns the Safe's oHYDX, pulls ≤maxPayment USDC, mints HYDX to the Safe) / `USDC.approve(oHYDX, 0)` (reset, no standing approval) — recipient hard-pinned to `engineSafe`, value-0/Call-only/`_exec`-bubble, `paymentToken` live-read off `oHYDX.paymentToken()` in setUp. KR5 honesty guard `paymentAmount ≤ maxPayment` (`PaymentExceedsMax`). `quoteStrike(amount)` view = `max(getDiscountedPrice, getMinPaymentAmount)`. **25/25** (21 unit RecordingSafe+MockOHYDX+MockUSDC incl. state-moving rollback/happy-path allowance-reset + 4 Base-fork: real `oHYDX.exercise` burns exactly `amount`, pays exactly `paymentAmount` USDC, mints HYDX, resets allowance to 0; maxPayment-too-low + past-deadline revert state-unchanged), **351/351 total no regression** — `forge test [--fork-url $BASE_RPC_URL] --match-contract ExerciseModule`. **ZERO load-bearing guesses.** All oHYDX selectors on-chain-verified Base 8453 (`paymentToken()`=0x3013ce29→USDC, `getMinPaymentAmount()`=0x2abb945c no-args→10000, `exercise`=0xa1d50c3a, `discount()`=30). Spec tidy: §4.5.1 8-B8 "State" line → "no module state; borrow tracked by 8-B5/8-B11". Code `contracts/src/supply/szipUSD/ExerciseModule.sol` + `contracts/test/ExerciseModule.t.sol` + `IOptionToken` adds (`paymentToken`/`getMinPaymentAmount`). NOT git-committed (whole tree untracked). `tickets/sodo/8-B8-exercise-ohydx.md`; `reports/8-B8-report.md`. |
| 8-B9 | **Sell module** | HYDX → USDC via **market-sell** (`SwapRouter.exactInputSingle`) to repay the borrow immediately; soft-bleed caps = size gate on the loop; regime gate upstream at 8-B8 (8-SY-corrected, was range-sell) | 8-B8 | **DONE 2026-06-08 — BUILT-VERIFIED.** `SellModule` (6th engine Zodiac Module; sibling of 8-B8, NO EVC/oracle/repay). TWO `onlyOperator` entrypoints sharing a private `_swap` approve→`exactInputSingle`→reset dance: `sellHydx`(HYDX→USDC repay leg) + `buyXAlpha`(zipUSD→xALPHA Mode-B/C POL buy leg, 8-B10/8-B13). recipient/`deployer=0`/`limitSqrtPrice=0` hard-pinned, typed `abi.encodeCall`, `minOut` slippage guard, `_exec`-bubble, decode+emit `Sold`. **Per-call HYDX size cap (user-directed 2026-06-08):** `maxSellHydx` (default 300k HYDX ≈ ~3%/~$10k weekly clip), set-once + owner(Timelock) `setMaxSellHydx`, `sellHydx` reverts `ExceedsMaxSell` above it — the whole-basket-dump backstop; `buyXAlpha` uncapped (bounded by 8-B10). **31/31** (27 unit + 4 Base-fork real `exactInputSingle`), **382/382 total** — `forge test [--fork-url $BASE_RPC_URL] --match-path test/SellModule.t.sol`. **ZERO load-bearing guesses; zero ticket discrepancies.** Algebra Integral router on-chain-verified (selector `0x1679c792`, `algebraSwapCallback` present, no `fee`; base-factory pool ⇒ `deployer=0`). On-chain bounds = `minOut` (price) + `maxSellHydx` (per-call size); per-EPOCH throughput = 8-B11/8-B12 CRE (the on-chain epoch *accumulator* REJECTED for sibling-consistency + §17 time-policy; spec-gap fixed: §4.5.1 8-B9 "State: per-epoch accumulator" → "no module state"). `buyXAlpha` unit-only (no live zipUSD/xALPHA POL pool yet → deferred fork proof to 8-B10/8-B13). NOT git-committed (tree untracked). Code `contracts/src/supply/szipUSD/SellModule.sol` + `contracts/test/SellModule.t.sol` + NEW `ISwapRouter.sol` + edits (IAlgebraPool `token0`/`token1`, BaseAddresses `ALGEBRA_SWAP_ROUTER`); `tickets/sodo/8-B9-sell-module.md`; `reports/8-B9-report.md`. |
| 8-B9b | **Patient range-sell module** (post-MVP) | single-sided HYDX concentrated-LP sell ladder (+5%→+50% above mark) via Algebra **NFPM** + a new CRE automator (deposit timing + auto-withdraw at +50%); harvests the ~6–8-week HYDX spikes with patient liquidity. **Complements, does NOT replace** 8-B9 market-sell (the strike-repay leg has an open borrow → must stay immediate; this fits the residual/free-value + veHYDX-rebase HYDX + non-borrow-financed strikes). See **README §8 Future Development**. | 8-B9 + new CRE automator + out-of-ICHI HYDX/USDC range capacity | **DEFERRED (M2/post-MVP)** |
| 8-B10 | **Recycle module** (`RecycleModule`) | USDC → backed zipUSD → into the vault basket → NAV accretion; the **single sink** (payout/distributor/Mode A/B/C all removed; 8-B13 absorbed). | 8-B9 | **REWORKED → `RecycleModule` + BUILT-VERIFIED 2026-06-08 (user-directed single-sink redesign; superintendent-reverified 19/19, full-suite 401/401 GREEN; an 8-B6 fork non-determinism can intermittently show 2 `LpStrategyModule` DTL reverts (unpinned fork + fixed live-vault deposit; passes 5/5 in isolation; zero coupling — fix = pin the fork block).** `recycle(usdc)` = `_spendFreeValue`→`approve`→`ZipDepositModule.deposit`→`approve 0` (USDC→warehouse backing, backed zipUSD minted into the MAIN-Safe basket; no `gate.depositFor`/no shares); kept `freeValueAccrued`+`creditFreeValue`+internal `_spendFreeValue`. DELETED `payoutClean`/`payoutBoost`/public `spendFreeValue`/`setCompounder`/`xAlpha`/`distributor`/`compounder` + the whole `SzipRewardsDistributor`. Code `contracts/src/supply/szipUSD/RecycleModule.sol` + `contracts/test/RecycleModule.t.sol`; `RecyclePayoutModule.*`+`SzipRewardsDistributor.*` DELETED. `reports/8-B10-report.md`. *(Historical pre-rework `RecyclePayoutModule` detail follows:)* **DONE 2026-06-08 — BUILT-VERIFIED.** `RecyclePayoutModule` (7th engine Zodiac Module — the ONLY one carrying real state: the single `freeValueAccrued` accumulator) + `SzipRewardsDistributor` (the pull-claim multi-asset Merkle cumulative-claim YIELD distributor, clean-room from `reference/.../jane/RewardsDistributor.sol`). Module: `creditFreeValue` (CRE-only increment, `+= max(0,realized−borrowRepaid)` net) / `spendFreeValue` (`onlyOperatorOrCompounder` decrement gate, the 8-B13 seam) / `recycleModeB` (Mode B leg 1 = debit + drive the **real `ZipDepositModule.deposit`** backed-1:1 mint) / `payoutClean` (Mode A = debit + Safe→distributor USDC) / `payoutBoost` (Mode B leg 3 = Safe→distributor xALPHA, NO debit) / `setCompounder` (owner set-once). Free-value-only enforced TWO-LAYER (policy ceiling + hard real-balance pull); payouts realized, never NAV; effects-before-interaction (decrement BEFORE the execs, ORDERING-PROVEN by a mid-call readback). **45/45** (22 unit + 3 integrated-no-fork against a REAL `ZipDepositModule`/`ESynth` + 2 Base-fork against a REAL summoned Safe + 18 distributor), **427/427 total no regression** — `forge test [--fork-url $BASE_RPC_URL] --match-path test/RecyclePayoutModule.t.sol` / `test/SzipRewardsDistributor.t.sol`. **ZERO load-bearing guesses.** **2 §4.5.1 spec-fixes** (Loot holders→szipUSD holders; "payout-mode flag/distribution checkpoints"→stateless+distributor). spec-fidelity critic returned ZERO gaps. NOT git-committed (whole tree untracked). Code `contracts/src/supply/szipUSD/{RecyclePayoutModule,SzipRewardsDistributor}.sol` + `contracts/test/{RecyclePayoutModule,SzipRewardsDistributor}.t.sol`; `tickets/sodo/8-B10-recycle.md`; `reports/8-B10-report.md`. |
| 8-B11 | **CRE strategy-admin robot** | the Go orchestrator scheduling the loop across the modules (off-chain) | 8-B6..B10, B13 | TODO |
| 8-B12 | **Dashboard / monitoring** | NAV, trailing-realized APR, TVL cap, the action/condition/schedule surface (`monitoring.md`) | 8-B4, 8-B11 | TODO |
| ~~8-B13~~ | **REMOVED — absorbed into 8-B10** (2026-06-08, user-directed) | the Mode-C compounder/LP-rebalance (balanced add, zipUSD→xALPHA swap-to-fund) is **subsumed by 8-B10 recycle + 8-B6 single-sided LP** — single-sided LP needs no xALPHA leg, so the balanced-add machinery is moot. The compounding flywheel is unchanged; the separate module is gone. The engine's on-chain contracts end at 8-B10. | — | **REMOVED** |
| 8-B14 | **szipUSD buy-and-burn** | engine USDC posts discounted `BUY szipUSD` CoW bids **below NAV** → **burn** on fill (the impatient-exit liquidity floor + the haircut-to-stayers mechanism). `baal-spec.md §7` / §4.5.1. | 8-B9, Exit Gate | **DONE 2026-06-08 — BUILT-VERIFIED.** `SzipBuyBurnModule` (bid side only; burn = existing `ExitGate.burnFor` by the windowController). `is Module` on the engine Safe, `onlyOperator`, posts a single resting CoW `BUY szipUSD` PRESIGN bid priced `≤ navExit×(1−d)`, `sellAmount≤buybackCap`, signs via on-chain GPv2 uid + `setPreSignature` (Call-only, no delegatecall), exact-`sellAmount` USDC approve. **33/33 Base-fork** (uid known-answer vector + live `preSignature`/allowance; price boundary incl. non-divisible RHS; navExit-vs-twap; cap/kill-switch/single-bid; partial-fill→cancel→repost; atomicity rollback; freshness; authority/shape; exec-discipline Call/value==0), **238/238 total no-regression** — run `forge test --fork-url $BASE_RPC_URL --match-contract SzipBuyBurnModuleTest`. Code at `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol` + `contracts/src/interfaces/cow/IGPv2Settlement.sol`. CoW addrs added to `BaseAddresses.sol`. NOT git-committed (whole tree untracked). `reports/8-B14-report.md`. |

(The old deferred rows above are subsumed: `sdVAULT` IS this item-8 vault; `LienXAlphaEscrow`/`DefaultCoordinator`
stay the **M2** loss-side, §4.6 — now the xALPHA-bond escrow + the freeze driver, no markdown machinery. Item 9
`ZipRedemptionQueue` + item 10 deploy follow item 8.)

**CRE track + DEC gates (single-pane status; authoritative backlog = `tickets/PHASE2.md`).** The §8 producer
spec is DONE (row above); the workflows are now authorable. Tickets/decisions are tracked in PHASE2 — this block
mirrors their current state, it does not replace it. Spec map = `claude-zipcode.md §8.11`.

| Item | What (§) | Status / gate |
|---|---|---|
| `CRE-00` | project/secrets scaffold | **AUTHORABLE NOW** — no blocker |
| `CRE-01` | origination/draw/close/status → controller + revaluation (sharded) → registry + default → `DefaultCoordinator` (§8.1/§8.4) | spec DONE; **live build gated on DEC-01** (mock Proof until then) |
| `CRE-02` | redemption-settle `cron` + warehouse REDEEM (§8.3/§8.5) | spec DONE; warehouse leg waits on **8-Bw** |
| `CRE-03` | szipUSD share-price feeds `NAV_LEG`(7)/`LP_MARK`(7) + xALPHA-APR (§8.6/§8.8) | spec DONE; xALPHA lane gated on **DEC-02** (stand-in otherwise) |
| `CRE-04` | warehouse SUPPLY/APPROVE/REPAY via Roles (§8.5) | spec DONE; **must reconcile 8-Bw `WarehouseAdminModule` decode before finalize** |
| `CRE-05` | engine strategy-admin **operator** orchestrator (§8.7; the off-chain `8-B11` robot — see row above) | **AUTHORABLE NOW** — engine modules built (401/401); operator-trusted path |
| `DEC-01` | Proof per-lien attestation capability (lien/value/insurance/recovery) | **OPEN** — the live-origination blocker; checklist = `pending-docs/spv-lien-proof.md §6.1` |
| `DEC-02` | xALPHA canonical-vs-fork + CCT registration (chain 964) | **OPEN** — gates CRE-03's real xALPHA lane; `bridge/xalpha-bridge-impl.md §4` |
| `DEC-03` | GTV pairing terms (szipUSD vs USDC) | **OPEN** — gates treasury/bridge; `pending-docs/treasury.md §6` |

**BORROWER-MODEL REWORK COMPLETE (2026-06-05).** The borrower-of-record rework (spec edited Step 1:
§4.3/§4.4/§4.7/§17) invalidated the built keepsakes WOOF-03, WOOF-04, WOOF-05 — which encoded the old
"controller sub-account *i* ↔ market *i*" + blanket `setOperator(prefix, venue, ~uint256(1))` + `haveCommonOwner`
gate. The new model: a **fresh per-line EVC account** (CREATE2 `LineAccount`) + **the adapter** wired as that
account's **EVC operator** → **unbounded** disposable lines (the 255 cap dissolved). Step 2 re-authored each as a
fresh window, **dep-order 03 → 04 → 05** (the gate primitive constrains the venue's `openLine` wiring, which
constrains the controller's draw path). **ALL THREE ARE NOW RE-AUTHORED + cold-build-proven:** WOOF-03 (Step 2a,
operator-auth gate on `borrowDriver`/adapter, 5/6 then 6/6 reconciled), WOOF-04 (Step 2b, `LineAccount` + adapter,
15/15), WOOF-05 (Step 2c, controller minus `wireVenueOperator`/EVC handle, **17/17 live EVK borrow with NO
controller operator-wiring**). **WOOF-10a (deploy identity/renounce gate) was INDEPENDENT of the borrower model →
survived untouched** (it asserts `getExpectedWorkflowId()!=0 && registry.controller()!=0`, nothing about
sub-accounts/operators; item 10's S11 no longer wires a controller-level `wireVenueOperator` — see the obligation
rows). WOOF-00/01/02 unaffected. **The borrower-model migration is closed.**

(CRE / subnet / Inflow / treasury tracks are authored when reached; this ledger leads with the M1 contract
critical path.)

## Open cross-ticket obligations — keyed by the item that must DISCHARGE them
**When you author an item, check this table for rows owed by it.** The ticket MUST discharge each, and the
critics MUST verify it does (this is where composable integrity is won or lost). Mark `DISCHARGED (by WOOF-NN)`
at Conclude; the superintendent confirms. (Each row's *source* digest is in `LEDGER.md`.)

| Owed by item | Obligation | From | Status |
|---|---|---|---|
| **first item-8/bridge window** · scaffold completion (WOOF-00 **[EXT]**) | the scaffold was Euler-only; complete it under **Strategy A (interface+fork)**: add the Base **mainnet** fork RPC (`base = "${BASE_RPC_URL}"`); author `contracts/src/interfaces/{safe,baal,zodiac,ichi,hydrex,algebra}` minimal local interfaces + `contracts/script/BaseAddresses.sol` + `contracts/test/ForkConfig.sol`; add the single new source remap `@gnosis-guild/zodiac-core/`; run the **3-part cross-ecosystem probe** (Euler OZ-5 + local interfaces + OZ-free zodiac-core coexist with **NO OZ-4/5 collision**; a fork-read against a real deployed Base address). **Re-confirm every address on Basescan** (candidates in WOOF-00 `[EXT]`). **Do NOT compile Baal/Roles/Safe/ICHI/Hydrex source** (OZ-4.x collision). The bridge (8x) is the lone external source compiled — its OZ/solc check + CCT remaps are an **8x**-window concern. | WOOF-00 [EXT] | **DISCHARGED 2026-06-06 — scaffold MATERIALIZED + BUILDS GREEN on disk** (`contracts/`). `forge build` clean (52 files, solc 0.8.24); all 3 self-checks pass incl. a **live Base-mainnet fork read** (Alchemy RPC, no longer deferred). interfaces + `BaseAddresses.sol` + `ForkConfig.sol` authored; `@gnosis-guild/zodiac-core/` remap added; euler-earn mocked (0.8.26). **Real build exposed + fixed:** CRE-selector contradiction, **10/25 interface sigs wrong**, **2 wrong addresses** (ICHI "factory" `0x7d11` was a Safe → `0x2b52c416`; Baal labels scrambled → corrected vs `reference/Baal/deployments/base/*.json`). **Kept, not discarded** (keep-the-build doctrine). |
| **3** · `ZipcodeOracleRegistry` (§4.1) | validate a registered key's `decimals()` == `LIEN_DECIMALS` (18) before caching its mark | WOOF-01 | **DISCHARGED (by WOOF-02)** — strict `_strictDecimals` staticcall (reverts, not silent-18) in `_writePrice` on both write paths; unit test proves a 6-dp token AND a code-less EOA are rejected |
| **5** · `EulerVenueAdapter` (§4.7) | register `LIEN_i` as collateral (`setLTV` / market wiring) | WOOF-01 | **DISCHARGED (by WOOF-04) — BUILD-VERIFIED LIVE 2026-06-06:** `openLine` deposits the lien into a per-line escrow collateral vault; `setLineLimits` calls `EVAULT_i.setLTV(COLLAT_i, …)` (1e4 scale) registering it; the **live Base-fork** test asserts `LTVBorrow(COLLAT)`/`LTVLiquidation(COLLAT)` are set on the real EVault |
| **6** · `ZipcodeController` (§4.4a) | **REWORKED (borrower-model 2026-06-05, re-authored by WOOF-04) →** the operator grant is now **per line at origination, issued inside `VENUE.openLine`** (the adapter's per-line `LineAccount` calls `EVC.setAccountOperator(borrowAccount, VENUE, true)` — granting **the adapter**, the `EVC.call` borrow-driver; cold-build VERIFIED), so the controller has **NO** `wireVenueOperator`/blanket `setOperator(prefix,…)` step and takes **no EVC handle at all**. The controller still: seeds `registry.seedPrice(oracleKey, equityMark)` using the `oracleKey` **returned by** `VENUE.openLine` (= `LIEN_i`); owns the lien↔escrow custody (hold the `1e18`, `approve` the adapter for the escrow deposit, reclaim before `burn`); **passes `collateralAmount == 1e18` (the FULL lien) to `openLine`** | WOOF-04 | **DISCHARGED (by WOOF-05, re-authored Step 2c).** The operator-wiring clause is DISCHARGED-AT-ORIGIN by WOOF-04's `LineAccount` (no controller call) — WOOF-05 removed `wireVenueOperator`/blanket `setOperator`/the EVC ctor arg entirely (the controller takes no EVC, touches no EVC). Seed-returned-key / custody / full-`1e18` all realized + cold-build-proven: `isAccountOperatorAuthorized(borrowAccount, adapter)==true` & `(…,controller)==false`; the live origination borrow succeeds with NO controller operator step (17/17). |
| **10** · Deploy/wiring (§9) | grant the adapter **EulerEarn curator + allocator**; deploy `EE_POOL` with curator **timelock 0** (M1); onboard a **`baseUsdcMarket`** (no-borrow USDC EVault at the supply-queue head) as `fund`'s source + pass to the adapter ctor; document single-curator + timelock-0 as production hardening | WOOF-04 | OPEN |
| **10** · Deploy/wiring (§9, S5/S6) | **wire the hook's `borrowDriver` immutable to the ADAPTER (`VENUE`) address — NOT the controller** (the borrow-driver is the `EVC.call` caller = the `EulerVenueAdapter`, §4.3/§4.4). The hook (S5) deploys before the adapter (S6), so the addresses are **circular** → **precompute `VENUE` via CREATE2** and pass it to the hook ctor, or **two-pass deploy** (deploy the adapter, then deploy the hook with the real address, then install) — and **assert the deployed `VENUE` == the address wired into the hook** before installing the hook. In M1, if the adapter is collapsed into the controller, `VENUE == ZIP_CONTROLLER` (one address, still correct). | WOOF-03 | OPEN |
| **10** · Deploy/wiring (§9) | deploy `ZipcodeController` with the **5-arg** ctor (incl. `EREBOR`); ~~call `ZIP_CONTROLLER.wireVenueOperator(EVC)` before the S11 renounce~~ **REMOVED by the borrower-model rework (2026-06-05)** — there is no controller-level operator-wiring step; each line's operator grant is issued per line inside `openLine` (§4.4/§4.7), so `draw` no longer depends on a deploy-time EVC wiring; `ZIP_ORACLE_REG.setController(ZIP_CONTROLLER)` at S6; set identity (S10b) then renounce (S11) with the `getExpectedWorkflowId() != 0` pre-gate. **The S11 pre-gate is the SAME gate as the WOOF-02 F7 row below — discharge them jointly as ONE assert (`getExpectedWorkflowId() != 0` AND `controller() != 0`) and as a REQUIRED tested negative: the deploy test MUST include a run that renounces with identity (or controller) unset and prove it REVERTS at the gate (security F-3 — the controller cannot self-defend; the conditional identity check in `ReceiverTemplate` degrades `onReport` to Forwarder-sender-only if identity is blank). Documentation/an unexercised assert line does NOT discharge.** | WOOF-05 | **GATE PORTION TESTED (by WOOF-10a)** — `ZipcodeDeployAsserts.requireIdentityWired` + a Foundry tested negative (identity-unset → `IdentityNotWired` revert) + the dormancy demo (selector diff `UnsupportedReportType(3)` vs `InvalidWorkflowId`); item 10 imports the assert at S11. **OTHER clauses STILL OPEN:** 5-arg ctor + the actual sequenced `renounceOwnership()` calls. (~~`wireVenueOperator`-before-renounce~~ **dissolved by the borrower-model rework** — per-line operator grant in `openLine`.) |
| **CRE track** · report workflow (§8) | ABI-encode reports as `abi.encode(uint8 reportType, bytes payload)` per the §4.4 per-type table (1/2/4/5/6 → controller, 3 → registry direct); only emit origination/draw once the off-chain Proof gates + delinquency checks pass | WOOF-05 | **DISCHARGED-IN-SPEC (CRE §8, 2026-06-09)** — §8.0 per-`(receiver,reportType)` envelope table is the canonical map; the Proof-gate precondition is §8.9 (DEC-01). Build = CRE-01. |
| **6** · `ZipcodeController` (§4.4a) | origination branch MUST call `registry.seedPrice(LIEN_i, equityMark)` **inside** the atomic batch, ordered `create → openLine → seed → setLTV → borrow` (seed-before-draw; batch-atomicity is the controller test) | WOOF-02 | **DISCHARGED (by WOOF-05)** — origination is one atomic `onReport`; seeds the openLine-returned `oracleKey` before `draw`; cold-build proves over-LTV (`E_AccountLiquidity`), mid-batch (`equityMark=0`), and cap (`E_BorrowCapExceeded`) reverts each roll the **CREATE2 deploy** back (no orphan lien/market/seed) |
| **6** · `ZipcodeController` (§4.4c) | at close, reclaim the `1e18` from `EVAULT_i` **before** `burn` (else `ERC20InsufficientBalance`) | WOOF-01 | **DISCHARGED (by WOOF-05)** — close branch: `observeDebt==0` → `venue.closeLine` (redeems the lien to the controller) → `ILienToken.burn(1e18)`; cold-build proves a mocked no-op `closeLine` makes `burn` revert `ERC20InsufficientBalance` (pins the reclaim-before-burn order) |
| **10** · Deploy/wiring (§9) | `ZIP_ORACLE_REG.setController(ZIP_CONTROLLER)` set-once at S6; at S11 **assert `getExpectedWorkflowId() != 0` AND `controller() != 0` before `renounceOwnership()`** (security F7 — else identity bypass / unseedable). (No `govSetFallbackOracle` — the per-line-router redesign removed the shared router; each `ROUTER_i` is wired + frozen inside `openLine`, §4.7.) **This S11 assert is the SAME gate as the WOOF-05 row above (F-3) — one combined check, and it MUST be a tested negative (a deploy run that renounces with `controller()`/`getExpectedWorkflowId()` unset proves a REVERT), not just an assert line.** | WOOF-02 | **GATE PORTION TESTED (by WOOF-10a)** — the combined `controller() != 0` clause of `ZipcodeDeployAsserts.requireIdentityWired` proven by a tested negative (registry-`controller`-unset → `IdentityNotWired` revert). **OTHER clauses STILL OPEN:** `setController` at S6 wiring. (`govSetFallbackOracle`@S10 clause DISSOLVED by the per-line-router redesign — audit-sweep 2026-06-06.) |
| **CRE track** · revaluation workflow (§8) | shard each revaluation report by a **gas-bounded** batch count (not just ≤5 KB); never include a malformed/duplicate entry (on-chain batch is atomic — one bad entry reverts the cohort) | WOOF-02 | **DISCHARGED-IN-SPEC (CRE §8.1, 2026-06-09)** — sharding rule authored: gas-bounded `MAX_LIENS_PER_REPORT` per shard, one `WriteReport` per shard (each independently atomic per `ZipcodeOracleRegistry.sol:93-111`), dedup across the full sweep (on-chain is last-write-wins) + equal-length enforced pre-encode. Build = CRE-01. |
| **Exit Gate (item 3)** · manager grant + Shares invariant | the Gate's `manager(2)` is granted by **`team-admin → mainSafe.execTransaction → Baal.setShamans([gate],[2])`** (NOT a Baal proposal — governance is inert; NOT raw `setShamans` by anyone — it's avatar-only). Genesis seed (§4.3) mints Loot only AFTER the Gate holds manager. **`manager` also grants `mintShares` — the Gate (and every manager-holder) MUST be structurally unable to call `mintShares`** (only `mintLoot`/`burnLoot`); minting any Shares destroys the zero-Shares governance-inertness invariant. Every downstream fork test asserts `IBaal(baal).totalShares()==0`. | 8-B1 (security F4.2) | **DISCHARGED (by Exit Gate)** — `ExitGate` mints **only `mintLoot([gate],…)`** + `burnLoot`/`ragequit`, never `mintShares`; `_assertInvariants()` asserts `totalShares()==0` after every path; the manager(2) grant via `team→mainSafe.execTransaction→setShamans([gate],[2])` is fork-proven (`test_depositFor_reverts_without_manager_grant`: pre-grant `depositFor` reverts at `mintLoot`, post-grant succeeds). |
| **Item 9** · sidecar rotation/funding | do NOT fund/route value into the **sidecar** until `isOwner(team)==true` on it (8-B1's `_addOwnerToSidecar` lands it; the sidecar ships Baal-only until then) and the team has proven it can drive the sidecar. | 8-B1 (security F6.2) | OPEN |
| **Item 10** · deploy/wiring (szipUSD substrate) | (a) real `TEAM_MULTISIG` MUST be a true **k-of-n (k≥2) Gnosis Safe**, never an EOA/1-of-n — the Safe threshold-1 delegates ALL admin security to the multisig's internal quorum; `run()` should reject an EOA. (b) **Remove Baal as a Safe OWNER** (`removeOwner`) once human signers settle — keep Baal only as the ragequit **module** (a contract left as a threshold-1 owner is a standing signature-path surface). (c) the **CRE operator module** must be enabled **Roles-modifier-v2-scoped** (only strategy entrypoints; NEVER `enableModule`/`addOwner`/`setShamans`/`mintShares`), never bare/unscoped (the `mockModule` enable in 8-B1's test is test-only). (d) use an **unpredictable single-use `saltNonce`** + private submission (the main-Safe CREATE2 addr depends only on factory/singleton/saltNonce → a fixed salt is front-run-griefable; fail-closed but a cheap grief). | 8-B1 (security F3.1/F3.2/F5.1/F1.1) | OPEN |
| **8** · `szipUSD` (§4.5) | implement the `ISzipUSD` seam the zap pins: the **3-arg exact-shares core** `stake(uint256 amount, uint256 shares, address receiver)` — burn `amount` zipUSD **from the caller** (`ESynth.burn(msg.sender, ·)`, allowance), pull **exactly `shares`** EE shares from the **module** (`EE_POOL.transferFrom(module, this, shares)` — the module passes its own `EE_POOL.deposit` share return; do **NOT** recompute from `share_price`, F1), mint szipUSD to `receiver`; PLUS a **2-arg direct-stake convenience** `stake(amount, receiver)` computing a conservative `shares = EE_POOL.convertToShares(amount/1e12)`; PLUS `previewStake(amount) view`. szipUSD's **ctor takes the module** as its EE-share source (`new SZIPUSD(ZIPUSD, EE_POOL, DEPOSIT_MODULE)`); szipUSD holds `ESynth` capacity (S7) + is the perf-fee `feeRecipient` (S8); **szipUSD MUST be owner-renounced/immutable at wiring** (it holds a `max` EE-share allowance over ALL senior backing — F4). | WOOF-06 | **VOID / REOPENED (2026-06-06, Baal redesign): WOOF-07 was DELETED + this EE-pool-share `stake(amount,shares,receiver)` seam NO LONGER EXISTS — the Baal szipUSD holds a zipUSD/xALPHA/LP Safe basket (never EE shares); deposit = the 8-B2 mint shaman. → ITEM 7 (WOOF-06, the zap) IS ORPHANED: its stake leg + EE-share custody must be RE-AUTHORED: USDC deposits to the **`CreditWarehouse` Safe** (EE-share `receiver`, 8-S2b / 8-Bw), junior stake via the **Exit Gate `depositFor`** (the Gate absorbs the old 8-B2 mint shaman; WOOF-06 was re-authored to this seam 2026-06-07); the F1/max-allowance seam dissolves; item-10 S7 allowance / reciprocal-binding wiring is moot.** [Historical discharge detail, no longer valid:] 3-arg exact-shares core (module-only, pulls exactly the passed `shares`, no recompute) + 2-arg conservative `convertToShares(amount/scaleUp)` direct + `previewStake`; ctor takes the module; **F4 discharged by structural IMMUTABILITY (not renounce):** the dangerous surface (module/eePool/zipUSD/scaleUp pointers) is immutable + the only arbitrary-`shares` pull is module-gated, so the `max` allowance can't be siphoned — the owner stays the **TimelockController** (§17 governed setters), NOT renounced. **Item 10's S7 reciprocal-binding check must assert szipUSD's `module()==DEPOSIT_MODULE` + `owner()==TIMELOCK`, NOT `owner()==0`.** Cold-build 36/36. |
| **10** · Deploy/wiring (§9 S7) | **3-arg `ESynth` ctor** `(EVC, "Zipcode USD", "zipUSD")` — zipUSD is **18-dp** (no `, 6 decimals` arg, that was wrong); deploy `ZipDepositModule(ZIPUSD, USDC, EE_POOL)`; `ESynth.setCapacity(module, …)` (bounded in prod) + `setCapacity(szipUSD, …)`; deploy szipUSD **after** the module with the module as its EE-share-source arg; **`module.setStakingVault(szipUSD)`** (set-once, deployer-gated) — assert `module.stakingVault()==szipUSD` AND `EE_POOL.allowance(module,szipUSD)==max` AND the **reciprocal binding** (szipUSD's EE-source ctor arg `== module`, F5) before renounce; renounce `ESynth` ownership only **after** both capacities + the wiring (S7 order). | WOOF-06 | OPEN |
| **Exit Gate + szipUSD (NEXT)** · NAV pricing seam | issue NAV-proportionally off `SzipNavOracle.navEntry()` (round **down**), exit/window-RQ at `navExit()`, and **`poke()` the accumulator before reading**; szipUSD is wired into the oracle via `setShareToken`; the Gate is the first minter (so a pre-deposit donation can't profit an attacker — the oracle adds no first-depositor guard). | `SzipNavOracle` | **DISCHARGED (by Exit Gate)** — `depositFor` `poke()`→`navEntry()` round-down; `processWindow` `poke()`→`navExit()`; `setShareToken` wires szipUSD into both Gate + oracle; genesis-par + min-haircut fork-proven. **Also added the `valueOf(asset,amount)` issuance-valuation seam to the kept oracle** (§7 / 42-test oracle suite). |
| **8-B14 buy-and-burn** · denominator exclusion | the engine Safe holding transient pre-burn szipUSD is wired via `SzipNavOracle.setEngineSafe` so it is excluded from the navPerShare denominator. | `SzipNavOracle` | **ADDRESSED (by 8-B14) for the module side** — `SzipBuyBurnModule.engineSafe` is set in `setUp` and a test asserts `module.engineSafe() == ExitGate.engineSafe()` (the bought szipUSD lands in the Safe the Gate's `burnFor` burns from). The remaining clause — the **oracle's** `setEngineSafe` pinning the SAME Safe so its transient szipUSD is denominator-excluded — is an **item-10 deploy-wiring** step (wire `module.engineSafe == ExitGate.engineSafe == SzipNavOracle.engineSafe == order.receiver`). Still OPEN at deploy. |
| **DefaultCoordinator (M2, §11/§4.6)** · provision bound | it is the sole `SzipNavOracle.writeProvision` caller (wired via `setDefaultCoordinator`) and MUST enforce the bound (down by `atRisk×(1−recoveryFloor)`, up by realized receipts) — the oracle stores the value **unbounded** by design. | `SzipNavOracle` | OPEN |
| **10** · Deploy/wiring (§9) — SzipNavOracle | after deploying szipUSD/Gate, the LP/gauge, the engine Safe, and the DefaultCoordinator, call the four set-once setters (`setShareToken`/`setLpPosition`/`setEngineSafe`/`setDefaultCoordinator`); **assert `shareToken() != 0` before `renounceOwnership()`** (else the oracle is stuck at the genesis price forever); renounce LAST (freezes the Forwarder + identity). | `SzipNavOracle` | OPEN |
| **CRE track** · NAV leg push (§8) | produce the **reportType 7** push (`alphaUSD`, `HYDX/USD`), **gas-bounded** per report (the on-chain batch is atomic — one bad/duplicate entry reverts the cohort), and provision the upstream `alphaUSD` TWAP + the xALPHA `exchangeRate` source (production bridge wrapper selector confirmed at 8x integration). | `SzipNavOracle` | OPEN |
| **Item 10 / junior-acceptance pass** · audit sweep (Exit Gate) | re-author the junior acceptance the Exit Gate window **deferred**: `audit/2` **L3** (deposit→szipUSD), **L12** (windowed exit), **S7** (junior wiring: Gate manager-grant + `windowController` + `setShareToken`) + `audit/3-results` **rows 25–27** + **Trace E** — replacing the EXCISED markers that point at the (now-built) Exit Gate. Author this once the deposit path is integration-testable (after the **WOOF-06 cold-build** lands the zap + item-10 deploy/wiring + windowController wiring) — it's a full-system deploy+lifecycle trace, can't be written against a half-wired system. The authority rows (25–27 / Trace E) fold into the same pass. | Exit Gate (superintendent, 2026-06-08) | OPEN |
| **Engine (8-B9 / 8-B13)** · exit-numeraire conversion handoff | M1 windowed exits pay **zipUSD only** (the Gate forfeits the exiter's volatile-leg pro-rata to stayers), so repeated exits **skew the free main-Safe basket toward the volatile legs** faster than the harvest replenishes zipUSD → window throughput degrades (more partial-fills). Post-M1 the engine must (a) provide the general **volatile→zipUSD** numeraire conversion (8-B9 sell path) and (b) **rebalance the free main-Safe basket toward exit liquidity** (8-B13 compounder). Correctness is fine in M1 (never reverts/mispays); this is a liquidity-management obligation, not a bug. | Exit Gate (JC1, 2026-06-08) | OPEN |
| **WOOF-06 (the zap, NEXT)** · TVL-cap composition | the Gate carries a **hard immutable `tvlCap`** backstop (`grossBasketValue()+value ≤ tvlCap`); 8-B12 describes a **dynamic measured `maxDeposit`** as the WOOF-06 deposit gate. WOOF-06's cold-build must wire the measured cap **on top** of the Gate backstop and assert they compose (measured ≤ hard; a deposit blocked by either reverts). | Exit Gate (JC3, 2026-06-08) | OPEN |
| **8-Bw / item-10** · reservoir borrow vault = warehouse resting vault | the EE supply queue MUST allocate idle depositor USDC into the **reservoir borrow vault** `ReservoirMarketDeployer.deploy` creates (so it IS the warehouse `USDC Resting Vault`); the deploy sets the module's `borrowVault` to that address + keeps its governor at the Timelock (LTV/caps tunable) + retains the router governor via `transferGovernance(timelock)`. The fork test proves the loop against a directly-seeded borrow vault; production points EE at it. | 8-B5 (2026-06-08) | **OPEN — ROUTED to item-10 by 8-Bw (2026-06-09):** it is an EulerEarn curator/allocator (supply-queue) config, NOT a `WarehouseAdminModule` op (the adapter's op-set is SUPPLY/APPROVE/REDEEM/REPAY; it never configures the allocator). 8-Bw established the warehouse + its EE custody; the live point-EE-at-reservoir allocation is an item-10 deploy step. |
| **CRE track (§8)** · `LP_MARK` reportType registration | register the **`LP_MARK` reportType** (pinned `7` in the built `SzipReservoirLpOracle`) in the §8 report ABI alongside the §4.4 lien types, and have the 8-B11 CRE workflow compute the per-LP-share mark from the same reserve×price math `SzipNavOracle` uses for the basket LP leg + push it each epoch within `validityWindow`. **This is the one SPEC-GAP the 8-B5 spec-fidelity critic surfaced — CRE-§8 territory (still TODO), so 8-B5 pinned a placeholder + routed it here** (see Open spec gaps). | 8-B5 (2026-06-08) | **DISCHARGED (CRE §8.0/§8.6, 2026-06-09)** — `LP_MARK=7` ratified as **per-receiver-scoped** (it never collides with `SzipNavOracle.NAV_LEG=7` because each `WriteReport` names one receiver), distinct from `REVALUATION=3` as required; §8.6 specs the producer (same reserve×price math as the NAV LP leg, pushed each epoch within `validityWindow`, fail-closed). Build = CRE-03. |
| **Item 10 / engine-integration pass** · audit sweep (8-B5) | author the harvest-loop borrow into `audit/2.md` Phase L (an L-step post→borrow→repay→withdraw, debt 0→strike→0; N-steps over-LTV / stale-mark / over-cap / non-operator / third-party-direct-borrow each revert) + the matching `audit/3-results.md` authority rows (operator-only entrypoints; owner-only `borrowCap`; `setAvatar`/`setTarget` locked; reservoir governor retained at the Timelock; the `OP_BORROW` guard pins the Safe). Author once the engine is integration-testable (alongside 8-B6…B13 + item-10 deploy), like the Exit-Gate audit sweep. | 8-B5 (2026-06-08) | OPEN |
| **Item 10 / 8-B11** · CRE operator + Forwarder wiring (8-B5) | wire the single CRE operator as the module's `operator` (the only caller of the four entrypoints), the LP-oracle Forwarder push on the engine cadence, and the engine Safe as the EVC account whose borrow/collateral the module drives. | 8-B5 (2026-06-08) | OPEN |
| **Item 10** · 8-B6 gauge + POL vault wiring | resolve + wire the `LpStrategyModule.gauge` via `Voter.gauges(ourPool)` with the **hard gate `Voter.gauges(ourPool) != 0`** (our zipUSD/xALPHA **ALM_ICHI** gauge must be Hydrex-whitelisted — external governance dep, `hydrex.md §9.4`); create the POL ICHI vault as a **single-sided zipUSD YieldIQ vault** (only zipUSD deposited; xALPHA leg acquired via pool flow — vault decision 2026-06-08, exact config pending an ICHI conversation); CREATE2-clone the module via `ModuleProxyFactory`, `enableModule` on the engine Safe, `setUp` it, init-lock the mastercopy, `owner = TimelockController != operator`. | 8-B6 (2026-06-08) | OPEN |
| **Item 10** · LP-token identity (8-B5↔8-B6 seam) | the **production POL ICHI vault** (the LP share token) MUST be the SINGLE shared address wired into ALL of: 8-B6 `LpStrategyModule.ichiVault` (`setUp`), 8-B5 `ReservoirMarketDeployer.lpToken` (the escrow collateral-vault asset), the `SzipReservoirLpOracle` `LP_MARK` key, and the `SzipNavOracle` basket-LP leg. 8-B6 unstakes that LP to the Safe (loop step 1) and 8-B5 `postCollateral` deposits it into the escrow — if the two are wired to different LP addresses the harvest loop silently fractures (the unstaked LP can't be posted). Deploy MUST assert `LpStrategyModule.ichiVault() == reservoir escrow vault asset() == lpOracle key`. | superintendent (8-B6 review, 2026-06-08) | OPEN |
| **8-B11 / CRE track** · 8-B6 op surface | the CRE strategy robot is the sole caller of `LpStrategyModule.addLiquidity`/`stake`/`unstake`; it sizes `minShares` (the non-zero slippage floor) off the same reserve×price math `SzipNavOracle` uses, and sequences the unstake→re-stake around the 8-B5 borrow loop within the epoch (the staked/collateral-exclusivity, §4.5.1). | 8-B6 (2026-06-08) | OPEN |
| **8-B10** · 8-B6 backed-zipUSD invariant | the zipUSD leg of any `LpStrategyModule.addLiquidity` MUST be **backed** zipUSD (minted only via 8-B10's free-value path / the §4.5 zap), never unbacked — the module does not mint; the CRE robot funds the Safe before calling. | 8-B6 (2026-06-08) | **DISCHARGED (mechanism side, by 8-B10)** — `RecycleModule` mints zipUSD ONLY through `ZipDepositModule.deposit` (USDC parked as senior backing BEFORE the mint ⇒ backed 1:1 by construction; fork-proven `test_fork_recycle_against_real_safe`). The module never calls `ESynth.mint` directly. The CRE-funds-the-Safe-before-calling half stays an 8-B11/item-10 wiring obligation. |
| **Item 10 / engine-integration pass** · audit sweep (8-B6) | author the LP lifecycle into `audit/2.md` Phase L (an L-step: `addLiquidity` → `stake` → [harvest off-harness] → `unstake` slice → [8-B5 loop] → `stake` re-stake, with `stakedBalance`/`lpBalance` round-tripping; N-steps: non-operator / zero-amount / slippage-floor each revert) + the matching `audit/3-results.md` authority row (operator-only entrypoints; `setAvatar`/`setTarget` owner-locked; deposit `to`/balance reads pinned to the engine Safe; no custody). Author once the engine is integration-testable (alongside 8-B7…B13 + item-10), like the 8-B5 / Exit-Gate sweeps. | 8-B6 (2026-06-08) | OPEN |
| **Item 10 / 8-B11** · gauge + Voter + RewardsDistributor wiring (8-B7) | wire the single CRE operator as `HarvestVoteModule.operator` (sole caller); wire `gauge` via `Voter.gauges(ourPool)` with the hard gate `Voter.gauges(ourPool) != 0` (our ALM_ICHI zipUSD/xALPHA gauge must be Hydrex-whitelisted — the SAME external-gov dep as 8-B6); pass the live `rewardsDistributor` (= `Minter._rewards_distributor()` read at deploy). 8-B11 sequences claim → vote-floor `lockVe` FIRST → `vote` each epoch, sizes the lock-vs-sell split by regime, and enumerates the Safe's veNFTs (`ve.tokenOfOwnerByIndex`) for `claimRebase`. | 8-B7 (2026-06-08) | OPEN |
| **8-B11 / 8-B12** · over-lock guard + monitoring (8-B7) | `lockVe(amount)` is **uncapped on-chain by design** (stateless module, no basket-size notion), and `exerciseVe` is **irreversible** (permalocked veHYDX is marked ~0 principal, non-redeemable — NOT exit collateral). 8-B11 MUST bound per-epoch `lockVe` to the regime-sized floor slice `s*` (never the full oHYDX balance); 8-B12 MUST tripwire `voteFloor()` growth vs `pendingReward()` drain (detection must precede the irreversible lock). Also: the §4.5.1 failure modes **missed-epoch-vote** + **floor-drift** are CRE/monitoring-layer (not contract-testable) — 8-B11 scheduling + the 8-B12 red tripwire. | 8-B7 (2026-06-08, security #5) | OPEN |
| **Item 10 / engine-integration pass** · audit sweep (8-B7) | author the per-epoch harvest/vote into `audit/2.md` Phase L (an L-step claim → `lockVe` → `vote`, with `ve.getVotes(Safe)`/`oHYDX` balances moving; N-steps: non-operator / zero-amount / empty-array / length-mismatch each revert) + the matching `audit/3-results.md` authority rows (operator-only entrypoints; `setAvatar`/`setTarget` owner-locked; `exerciseVe` recipient + reads pinned to the engine Safe; no custody). Author once the engine is integration-testable (alongside 8-B8…B13 + item-10), like the 8-B5/8-B6/Exit-Gate sweeps. | 8-B7 (2026-06-08) | OPEN |
| **8-B7 (deferred extension)** · veHYDX voting bribes/fees | the per-NFT Bribe-contract claim for voting fees is NOT in 8-B7's scope (gauge swap fees auto-compound in the ICHI vault → captured in NAV; 8-B7 claims only the oHYDX emission). If/when worth harvesting, author as a follow-on (per-NFT, account-curated) + reconcile with the §10.6 #3 / §7 "veHYDX fees" refinery-source marking. | 8-B7 (2026-06-08) | OPEN |
| **Item 10 / 8-B11** · operator + oHYDX wiring + TIGHT cushion (8-B8) | wire the single CRE operator as `ExerciseModule.operator` (sole caller); wire `oHYDX` to the live option token `0xA113…` (its `paymentToken` live-read = USDC). **Deploy the clone via `ModuleProxyFactory` CREATE2 + `setUp` ATOMICALLY in one factory tx (front-run-safe) + init-lock the mastercopy** (the 8-B5/8-B14 pattern, never two-tx deploy-then-init). 8-B11 runs the **profitability gate** (skip exercise when HYDX/USD < the **$0.015 loop cutoff** [user-ratified 2026-06-08 — the canonical cutoff; $0.018 demoted to an amber/begin-taper tier; $0.01 = the mechanical dead floor, never reached]; the gate's price input is the **CRE `reportType 7` HYDX/USD leg** that already feeds `SzipNavOracle` — reuse it, NOT a new feed; all three tiers are GOVERNED CRE policy, NOT contract constants), the regime gate (exercise ONLY in UP/FLAT; DOWN → route to 8-B7 `exerciseVe`), the **commitment gate** (borrow+exercise COMMITS to a repay market-sell → enter only at a size whose 8-B9 repay-sell fits the per-epoch soft-bleed cap), and sizes `maxPayment = quoteStrike(amount) × a modest cushion` (`maxPayment` is the **slippage/spike guard** — oHYDX is immutable/non-proxy and charges exactly `quoteStrike(amount)`, fork-proven; too tight → normal drift reverts, too loose → a genuine TWAP spike overpays the basket). **When unprofitable, simply do NOT call 8-B8** → oHYDX accrues in the Safe (8-B7 keeps claiming it; marked at intrinsic in NAV) until a profitable epoch. **Cadence = the Hydrex weekly epoch** (604800s — votes reset weekly, emissions accrue weekly), so the refinery loop runs ~weekly. **Self-quote-exact was evaluated + REJECTED** (would delete the spike guard). | 8-B8 (2026-06-08) | OPEN |
| **8-B9** · HYDX hand-off (8-B8 → 8-B9) | the HYDX minted to the Safe by `exercise` is the input 8-B9 market-sells (`SwapRouter.exactInputSingle`) to repay the 8-B5 borrow immediately (the pool is net-draining, no buy-side → market-sell, not resting), bounded by the §9.3 soft-bleed caps (which size the loop = 8-B8's `amount`). | 8-B8 (2026-06-08) | **DISCHARGED (by 8-B9)** — `SellModule.sellHydx(amountIn, minOut, deadline)` consumes the Safe's HYDX balance (operator-sized `amountIn`), market-sells via `exactInputSingle` to USDC-in-the-Safe (fork-proven: HYDX out exactly `amountIn`, USDC in exactly `amountOut`); the per-epoch cap that sizes `amountIn` is the 8-B11/8-B12 CRE layer (the §4.5.1 SIZE-GATE model). The CRE calls 8-B5 `repay` from the proceeds after the sell. |
| **Item 10 / engine-integration pass** · audit sweep (8-B8) | author the paid exercise into `audit/2.md` Phase L (an L-step borrow (8-B5) → `exercise` → sell (8-B9) → repay, with oHYDX/USDC/HYDX balances moving; N-steps: non-operator / zero-amount / zero-maxPayment / `maxPayment`-too-low / past-deadline each revert) + the matching `audit/3-results.md` authority rows (operator-only entrypoint; `setAvatar`/`setTarget` owner-locked; recipient pinned to the engine Safe; no standing approval; no custody beyond the transient HYDX). Author once the engine is integration-testable (alongside 8-B9…B13 + item-10), like the 8-B5/8-B6/8-B7/Exit-Gate sweeps. | 8-B8 (2026-06-08) | OPEN |
| **Item 10 / engine-integration pass** · audit sweep (8-B9) | author the per-epoch sell into `audit/2.md` Phase L (an L-step exercise (8-B8) → `sellHydx` → repay (8-B5), with HYDX/USDC/debt moving; N-steps: non-operator / zero-amount / zero-minOut / `minOut`-too-high / past-deadline each revert) + the matching `audit/3-results.md` authority rows (operator-only entrypoints; `setAvatar`/`setTarget` owner-locked; recipient pinned to the engine Safe; `deployer=0`/`limitSqrtPrice=0`; no standing approval; no custody beyond the transient USDC/xALPHA). Author once the engine is integration-testable (alongside 8-B10…B13 + item-10), like the 8-B5..B8/Exit-Gate sweeps. | 8-B9 (2026-06-08) | OPEN |
| **Item 10 / 8-B11** · operator + router + token wiring (8-B9) | wire the single CRE operator as `SellModule.operator` (sole caller); wire `swapRouter` to the live Algebra router `0x6f4b…`, `hydx`/`usdc` to the live tokens, `zipUSD`/`xAlpha` to our `ESynth` + the bridge xALPHA. **Deploy the clone via `ModuleProxyFactory` CREATE2 + `setUp` ATOMICALLY in one factory tx (front-run-safe) + init-lock the mastercopy** (the 8-B5/8-B8/8-B14 pattern; never two-tx). 8-B11 sizes `amountIn`+`minOut` off `pool.globalState()` (the §9.3 per-order slippage cap → a **modest** cushion; too loose = a fat bad-fill ceiling), enforces the per-epoch volume cap (the loop size gate), and sequences sell → 8-B5 `repay` → 8-B6 re-stake → 8-B10 `creditFreeValue`. | 8-B9 (2026-06-08) | OPEN |
| **8-B12** · soft-bleed throughput tripwire (8-B9) | `SellModule` now caps any SINGLE `sellHydx` on-chain (`maxSellHydx`, default 300k), but per-**epoch** *throughput* across many calls is not on-chain (stateless by design, §17) → 8-B12 MUST tripwire/alert if cumulative `sellHydx`/`buyXAlpha` volume exceeds the §9.3 soft-bleed cap — the operational backstop for a multi-call mis-sized or compromised-operator dump (`minOut` bounds price, `maxSellHydx` bounds per-call size, the tripwire bounds throughput). | 8-B9 (2026-06-08, security) | OPEN |
| **Item 10 / 8-B11** · `maxSellHydx` deploy default + re-sizing (8-B9) | wire `SellModule.maxSellHydx = 300_000e18` at deploy (the per-call HYDX size backstop ≈ ~3% slippage / the weekly clip on the live pool); `owner` (the Timelock, NOT the hot operator) re-sizes via `setMaxSellHydx` as pool depth changes. GOVERNED value, not a contract constant. | 8-B9 (2026-06-08) | OPEN |
| **8-B10/8-B13** · `buyXAlpha` live-pool fork proof + POL pool identity (8-B9) | when the zipUSD/xALPHA POL pool is created (8x bridge + the POL LP), wire `zipUSD`/`xAlpha` to the live pair and author the deferred `buyXAlpha` live-swap fork test; assert the POL pool is the SINGLE address the Mode-B/C buy leg trades against and `factory.poolByPair(zipUSD, xAlpha)` resolves it (so `deployer==address(0)` holds for the POL pair too — re-verify). `buyXAlpha` is unit-proven this window; its router calldata shape is fork-grounded by the shared sell-leg sig-verify. **DEPLOYER-SHAPE GATE (2026-06-08, user-directed iteration plan):** iteration 1 wires `buyXAlpha` to a **good-enough stand-in pool** to demonstrate functionality, then repoints to the exact POL pool when available. Because `_swap` hard-pins `deployer: address(0)` (`SellModule.sol:189`) for BOTH legs, the stand-in pool **must itself be a base-factory (deployer-0) Algebra pool** or `buyXAlpha` reverts even in the demo. The planned repoint to the real POL is a pure **re-wire IF the real POL is also base-factory**, but a **code change to 8-B9 (add a `deployer` param/wiring) IF the POL is a custom-deployer pool** — so decide the POL deployment shape BEFORE the repoint, not after. | 8-B9 (2026-06-08) | OPEN |
| **8-B10** · proceeds + free-value hand-off (8-B9 → 8-B10) | the USDC `sellHydx` lands in the Safe (net of the 8-B5 repay the CRE runs next) is the input to 8-B10's `creditFreeValue(realizedUsdc)` (`freeValueAccrued += max(0, realized − borrowRepaid)`); 8-B9 does NOT credit free value (8-B10 owns that accumulator). The `buyXAlpha` POL buy leg is also CRE-sequenced by 8-B10/8-B13 (the free-value gate is 8-B10's, the swap mechanism is 8-B9's). | 8-B9 (2026-06-08) | **DISCHARGED (by 8-B10)** — `RecycleModule.creditFreeValue(uint256 netFreeValueUsdc)` is the owned accumulator's only increment, `onlyOperator`, single-arg + operator-trusted (the CRE passes `max(0,realized−borrowRepaid)` computed off-chain; the module cannot reconstruct historical realized/repaid). 8-B9 does NOT credit. (The net USDC is then consumed by `recycle` — no xALPHA buy leg / boost distribution; those were deleted in the single-sink rework.) |

| ~~**8-B13** · Mode-C `spendFreeValue` seam~~ | **VOIDED — 8-B13 removed (absorbed into 8-B10).** The public `spendFreeValue`/`setCompounder`/`onlyOperatorOrCompounder` seam was deleted from the module (it existed only for 8-B13); the recycle debits via the internal `_spendFreeValue`. No compounder. | 8-B10 (2026-06-08) | **VOIDED** |
| **Item 10 / 8-B11** · operator + token wiring (8-B10, RECYCLE-ONLY) | wire the single CRE operator as `RecycleModule.operator`; `zipDepositModule`→the deployed WOOF-06 module, `usdc`→the live token. **(No `xAlpha`/`distributor`/`compounder` — those were deleted in the single-sink rework.)** `setUp` decodes **5 addresses** `(owner, engineSafe, operator, zipDepositModule, usdc)`. **Deploy the module clone via `ModuleProxyFactory` CREATE2 + `setUp` ATOMICALLY (front-run-safe) + init-lock the mastercopy** (the 8-B5/8-B8/8-B9/8-B14 pattern). 8-B11 sizes the `recycle` amount within `freeValueAccrued` each epoch and sequences sell→repay→`creditFreeValue`→`recycle`→8-B6 single-side LP. No distributor deploy, no Merkle root posting. | 8-B10 (2026-06-08) | OPEN |
| **Item 10 / engine-integration audit sweep (8-B10, RECYCLE-ONLY)** | author the per-epoch recycle into `audit/2.md` Phase L (an L-step 8-B9 sell → 8-B5 repay → `creditFreeValue(net)` → `recycle` → 8-B6 single-side LP, with USDC/zipUSD/`freeValueAccrued`/basket balances moving; N-steps: non-operator / over-spend (`InsufficientFreeValue`) / zero-amount each revert) + the matching `audit/3-results.md` authority rows (operator-only `creditFreeValue`/`recycle`; `setAvatar`/`setTarget` owner-locked; no NAV write; the recycle is NAV-accretive not a payout). **No distributor / payout / Merkle rows** (deleted in the rework). Author once the engine is integration-testable (with 8-B11/8-B12 + item-10), like the 8-B5..B9/Exit-Gate sweeps. | 8-B10 (2026-06-08) | OPEN |
| ~~**8-B11 / 8-B12** · distributor funding-precedes-claim + root correctness~~ | **VOIDED — no distributor.** The `SzipRewardsDistributor` + the entire pull-claim payout path were deleted in the single-sink rework; there is no Merkle root to fund/post and no claim path. Holder return is NAV accretion, realized on exit at NAV. | 8-B10 (2026-06-08) | **VOIDED** |
| **Item 10 / 8-B12** · NAV reads the basket, never the accumulator (8-B10) | `freeValueAccrued` is now a pure off-chain-fed spend-GATE counter (recycle debits it); the recycled value lands as REAL basket assets (backed zipUSD → single-sided LP). `SzipNavOracle` + 8-B12 MUST value the Safe's REAL token/LP balances and NEVER add `freeValueAccrued` (it is a policy counter, not value — adding it would double-count). 8-B10 never writes NAV; the recycle is genuinely NAV-accretive (basket grows, shares flat). | 8-B10 (2026-06-08, security) | OPEN |
| **8-B11 / CRE §8** · `creditFreeValue` net computation (8-B10) | the CRE computes `max(0, realized − borrowRepaid)` off-chain from the 8-B9 sell proceeds + the 8-B5 `debtOf`/repay receipts for that loop and passes the single net to `creditFreeValue`; the module trusts it (cannot reconstruct historical realized/repaid on-chain). The §8 workflow owns this arithmetic. **Trust boundary (§17-accepted, in the contract NatSpec):** `creditFreeValue` is UNBOUNDED — the policy ceiling is operator-trusted, not cryptographic; an over-credit could route depositor principal. Backstops = the 8-B11 fund-discipline + the 8-B12 tripwire above. | 8-B10 (2026-06-08, security) | **DISCHARGED-IN-SPEC (CRE §8.7, 2026-06-09)** — the operator path owns the `max(0, realized − borrowRepaid)` arithmetic and the `creditFreeValue(net)` write; §8.7 states the operator-trusted trust boundary (single immutable operator = the security boundary). Build = CRE-05. |

| **Item 10 / engine-integration pass** · audit sweep (8-Bw) | author the warehouse deploy/wire into `audit/2.md` Phase S (the `CreditWarehouse` Safe + Roles `enableModule` + scope + `assignRoles`; the opType 1/2/3/4 L-steps SUPPLY/APPROVE/REDEEM/REPAY + revert N-steps off-policy/non-member/non-owner/Call-only/escalation; the §4.4/S11 `setExpectedWorkflowId`→`renounceOwnership` seal) + the matching `audit/3-results.md` authority rows the EXCISED markers point at. Deferred to item-10 like 8-B5..B10 (not authorable against a standalone un-wired warehouse). | 8-Bw (2026-06-09) | OPEN |
| **Item 10 / deploy + 8-B11/CRE** · warehouse seal + drain-defense (8-Bw, security HIGH) | (a) `setExpectedWorkflowId(...)`→`renounceOwnership()` seal with `getExpectedWorkflowId()!=0` asserted before renounce — **do NOT fund the warehouse before the identity is sealed** (while `expectedWorkflowId==0` the per-workflow gate is OFF, any Forwarder-relayed workflow can drive ops); a **distinct Forwarder identity/workflowId** from the controller/registry/oracle. (b) wire `repaySink = ZipRedemptionQueue` (item 9) — it MUST be **immutable/non-sweepable** (the residual chokepoint; a compromised CRE can REDEEM→REPAY to it). (c) **ELEVATED from optional → recommended:** a Roles `WithinAllowance` rate-limit and/or a **Delay Modifier** on the drain-capable REDEEM/REPAY ops. (d) the CRE issues **exact-amount APPROVE** per SUPPLY (never standing-infinite); verify whether the live EulerEarn is upgradeable / curator-controlled. (e) GOD-EOA→multisig owner upgrade on BOTH the Safe and the Roles owner. (f) assert `repaySink != juniorBaalSafe` and `safe != juniorBaalSafe` (§11 non-commingling). | 8-Bw (2026-06-09) | OPEN |
| **Item 9 · `ZipRedemptionQueue`** · warehouse REDEEM/REPAY seam | `settleEpoch` funds via the warehouse **REDEEM** (USDC → Safe, `receiver==owner==Safe`) then a **REPAY** to the queue (`repaySink == queue`); the queue never calls EulerEarn directly. The queue is the `repaySink` (must be immutable/non-sweepable, above). | 8-Bw (2026-06-09) | OPEN |
| **CRE track (§8 / CRE-04)** · warehouse op envelope | author the warehouse envelope `abi.encode(uint8 opType, bytes payload)` (SUPPLY=1 `(amount)` / APPROVE=2 `(amount)` / REDEEM=3 `(shares)` / REPAY=4 `(to,amount)` — reconciled to the built `WarehouseAdminModule` decode, §8.5) into the §8 producer spec; reconcile the on-chain `roleKey = keccak256("ZIPCODE_WAREHOUSE_CRE")` with the zodiac-roles-sdk off-chain key encoding. | 8-Bw (2026-06-09) | OPEN |

## Open spec gaps / deferred decisions (persisted — do NOT lose these)
When triage finds a spec gap, log it here: the §, whether it was fixed in `claude-zipcode.md` or is pending a
user decision.
- **8-Bw CreditWarehouse (2026-06-09) — 2 §4.5/§8.5 SPEC-GAPs FIXED in `claude-zipcode.md` (the 3 "open items for the
  8-Bw ticket" resolved + folded), no §17 reopened.** (1) **REPAY `to==LOANBOOK`** (§4.5 op table + §8.5 producer table) was
  a **stale noun** — no `LOANBOOK` contract exists in the current spec (it predates the queue/recovery split). → Generalized
  to `to==<pinned sink>` = the `ZipRedemptionQueue` (§6.1, M1) or a recovery sink (§4.6/§11, M2), scope-pinned `EqualTo`,
  retargeted by an owner re-scope (not a redeploy). (2) **REDEEM producer payload `(shares, receiver)` + `receiver==<pinned>`**
  (§4.5 :517 / §8.5 :1555) was stale/open → resolved to producer `(shares)` only with `receiver==owner==SAFE` (redeemed USDC
  lands in the Safe, then REPAY distributes — the cleaner, fully avatar-pinned choice §4.5's open-item offered). Also folded:
  EulerEarn `redeem` owner-is-3rd-arg (verified `:596`); APPROVE `amount` scope-free + CRE exact-amount (never infinite);
  opType bytes 1/2/3/4 pinned in §8.5 + §4.5; §8.5 RECONCILE-BEFORE-BUILD updated to RECONCILED (the build landed). Both
  edits are mechanism consistency, NOT new decisions — spec-fidelity critic confirmed faithful, no §17 reopened
  (CRE-permissioned single writer / senior-junior never conflated / venue-agnostic / no on-chain liquidation /
  Roles-v2-over-bespoke / GOD-EOA→multisig all preserved). **2 build-discovered ON-CHAIN corrections (the deployed Roles
  mastercopy `0x9646…D337` is NEWER than the vendored `reference/zodiac-modifier-roles`):** non-member reverts
  **`NotAuthorized`** (`moduleOnly` gate, not `NoMembership`); non-owner reverts **`OwnableUnauthorizedAccount`** (zodiac-core
  OZ-5 custom error, not the OZ-4 string the vendored package implied) — both folded into the ticket Done-when; the build
  follows the live chain. **Zero `claude-zipcode.md` gap left un-fixed; zero load-bearing build guesses.**
- **8-B10 recycle/payout (2026-06-08) — 2 §4.5.1 8-B10 consistency spec-gaps FIXED in `claude-zipcode.md`, no §17 reopened.**
  (1) The Mode-A line read "distribute net USDC pro-rata to **Loot holders**" — stale from before the two-token redesign
  (Loot is soulbound + gate-held; the transferable share is szipUSD). `auto-sodomizer.md §6` says "pro-rata to szipUSD
  shares." → Fixed to "**szipUSD holders** (the transferable share — NOT the soulbound gate-held Loot)" + spelled out the
  pull-claim Merkle distributor mechanism + disambiguated it from the M2 insurance-cohort distributor (§11). (2) The
  "**State:** ... the **payout-mode flag**; the **distribution checkpoints**" line contradicted (a) the stateless-CRE-policy
  model (mode = which entrypoint the CRE calls, NOT an on-chain branch) and (b) the distributor (not the module) holding
  the per-holder `claimed` checkpoints — the SAME class of gap as 8-B9's "per-epoch accumulator". → Fixed to "**State: only**
  the `freeValueAccrued` accumulator + set-once wiring; Mode selection is NOT an on-chain flag (it is the entrypoint the CRE
  calls); the distribution checkpoints live in the pull-claim distributor." Both the spec-fidelity critic (zero gaps found,
  both fixes confirmed present + correct + not a §17 reopen) and the build confirm the triage. No §17 decision reopened
  (CRE-permissioned single writer / venue-agnostic / no on-chain liquidation / A-B-C split = Treasury policy not a contract
  constant — all preserved). The build exposed ZERO ticket discrepancies (every cited signature held: `ZipDepositModule.
  deposit(uint256) returns (uint256)` mints to the caller, `scaleUp == 1e12`, OZ5 `Ownable`/`MerkleProof` resolve, the
  reference leaf `keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))))`).
- **8-B9 sell module (2026-06-08) — 1 §4.5.1 consistency spec-gap FIXED in `claude-zipcode.md`, no §17 reopened.** The
  §4.5.1 8-B9 block read "**State:** the per-epoch volume accumulator" — which contradicted (a) the adjacent text
  "Caps are a SIZE GATE on the loop... 8-B8 bounds the exercise size", (b) every sibling engine module being
  stateless-beyond-wiring, and (c) §17 putting caps/regime/cutoff (and time-policy) at the CRE layer. Reconciled the
  "State" line to "**none in the module (stateless beyond set-once wiring)**; the per-epoch volume tracking + soft-bleed
  cap are an **8-B11/8-B12 CRE/monitoring concern**" (the cap is a SIZE GATE enforced upstream, exactly as 8-B8's
  strike/cutoff/regime; on-chain `minOut` is the only on-chain safety bound, a slippage floor). An on-chain epoch
  accumulator was **considered as defense-in-depth and REJECTED** (sibling-consistency + epoch-boundary/reset is the
  stateful time-policy §17 puts at CRE). Both the spec-fidelity and security critics independently confirmed the
  stateless triage is correct + spec-faithful. **No §17 decision reopened** (CRE-permissioned single writer /
  venue-agnostic / no on-chain liquidation all preserved). **POST-BUILD ADDITION (user-directed 2026-06-08):** a
  governed per-CALL `maxSellHydx` SIZE ceiling (default 300k HYDX, set-once + `onlyOwner setMaxSellHydx`, `sellHydx`
  reverts `ExceedsMaxSell` above it) was added as the on-chain whole-basket-dump backstop — this is set-once config,
  NOT the rejected per-epoch *accumulator*, so the module stays stateless beyond wiring; §4.5.1 8-B9 "State" + the
  ticket Do-NOT were refined to "on-chain bounds = `minOut` price floor + `maxSellHydx` size ceiling; per-epoch
  throughput stays CRE/8-B12". Re-tested 31/31 (was 24/24), 382/382 total. Both swap legs (`sellHydx` HYDX→USDC +
  `buyXAlpha`
  zipUSD→xALPHA) confirmed in-scope for 8-B9 per `baal-spec §10.8` (8-B9 = the swap *mechanism*; 8-B10/8-B13 = the
  *policy* that calls `buyXAlpha`). Build exposed ZERO ticket discrepancies (every on-chain fact held: Algebra Integral
  selector `0x1679c792`, base-factory `deployer=0`, struct field order pinned by the real fork swap).
- **8-B8 exercise module (2026-06-08) — NO spec-mechanism gap; 1 cosmetic §4.5.1 tidy, no §17 reopened.** The 5-critic
  fanout (junior/spec-fidelity/ref-verifier/qa/security) confirmed the ticket faithful: the soft-halt (~$0.018), regime
  gate (UP/FLAT-only), and commitment gate are correctly kept OUT of the contract (8-B11 CRE-layer per §4.5.1), the
  strike-funding-via-8-B5-borrow boundary is respected (this module does NOT borrow), and §17 is untouched. The lone
  spec touch: §4.5.1 8-B8 "**State: pending-exercise accounting; the in-flight strike-borrow (tracked by 8-B5)**" read
  as if the module holds storage → tidied to "**no module state (stateless beyond set-once wiring, like the sibling
  engine modules); the in-flight strike-borrow is tracked by 8-B5 (`debtOf`) and the pending-exercise sequencing by the
  8-B11 robot**" (matches the actual stateless module + the sibling 8-B6/8-B7 shape). All oHYDX selectors on-chain-
  verified Base 8453 (`paymentToken()`=`0x3013ce29`→USDC; `getMinPaymentAmount()`=`0x2abb945c` NO-args→10000;
  `getDiscountedPrice(uint256)`=`0x339ccade`; `exercise(uint256,uint256,address,uint256)`=`0xa1d50c3a`; `discount()`=30).
  **Critic-hardened pre-build (folded into the ticket, all strict additions → cold-build-only, no re-fan):** a KR5
  defense-in-depth `paymentAmount ≤ maxPayment` guard (`PaymentExceedsMax` — re-asserts the bound oHYDX already enforces
  internally); the **`maxPayment` = slippage/spike-guard** framing (CORRECTED at user review from an initial "compromised
  oHYDX" overstatement — oHYDX is immutable/non-proxy [verified empty EIP-1967 slot + no `owner()`] and **fork-proven to
  charge exactly `quoteStrike(amount)` in the same block**; `maxPayment` aborts the loop on a TWAP spike, not theft) →
  an 8-B11 modest-cushion obligation; **module-self-quote-exact evaluated + REJECTED** (would delete the spike guard;
  doesn't simplify — the CRE computes the strike anyway to size the 8-B5 borrow); the **profitability gate's HYDX/USD
  input = the existing CRE `reportType 7` leg** (reuse, not a new feed) + the **weekly (Hydrex-epoch) loop cadence**;
  state-moving allowance-reset + rollback tests (live mock, not just calldata shape); decode-all-4-exercise-args
  recipient-pin; quoteStrike(0)/tie boundary; per-call value-0 assertion; atomic front-run-safe deploy+setUp obligation.
  No §17 decision reopened (CRE-permissioned single writer / venue-agnostic / no on-chain liquidation all preserved).
- **8-B7 harvest/vote module (2026-06-08) — 5 §4.5.1 spec corrections to the on-chain-verified Hydrex surface FIXED in `claude-zipcode.md` + `baal-spec §10.8`, no §17 reopened.** The §4.5.1 8-B7 block mis-cited the **un-open-sourced** Hydrex host (the citations predated the on-chain verification the 8-SY/SzipNavOracle passes did for the other legs). All five reverse-verified from deployed bytecode on Base 8453 this window: (1) **VoterV5 is account-keyed, NOT tokenId-keyed** — `vote(address[],uint256[])` (`0x6f816a20`) + `reset()` (`0xd826f88f`) carry NO tokenId; the guessed `vote(uint256,address[],uint256[])`/`reset(uint256)` are ABSENT. (2) **Floor read = `ve.getVotes(account)`** (`0x9ab24eb0`, account-aggregate across all the Safe's veNFTs), NOT `balanceOfNFT(tokenId)` — proven live: the team voter holds 40 veNFTs and `getVotes`>`balanceOfNFT(#1)`. (3) **State = none / no `tokenId`** — each `exerciseVe` mints a FRESH account-owned veNFT and voting/floor are account-keyed, so the spec's "the veHYDX tokenId" state was corrected away (no merge, no enumeration on-chain). (4) **Rebase claimed on the RewardsDistributor** (`Minter._rewards_distributor()` = `0x6FCa200f…`, `claim_many(uint256[])` `0x1f1db043`), NOT the Minter directly. (5) `getEpochDuration()` (`0x5d3ea8f1`) = 604800 confirmed (the lone original citation that WAS right). All five are mechanism-fidelity corrections of an un-open-sourced host (the build follows the chain, not the prose) — **no §17 decision reopened** (CRE-permissioned single writer / venue-agnostic / no on-chain liquidation all preserved). **Build-exposed (NOT spec gaps — test sequencing the module is correctly agnostic to):** the live `vote` needs an epoch-advanced voting-power snapshot + `Minter.update_period()` (`InsufficientVotingPower()`/`EpochStale()`) and the Voter enforces a per-account ~1h vote-delay (`VoteDelayNotMet()`) — both folded into the ticket's fork-test sequencing (an 8-B11 CRE concern). The veHYDX **voting bribes/fees** leg is deferred (the gauge swap fees auto-compound in the ICHI vault → captured in NAV; 8-B7 claims only the oHYDX emission) — logged as a deferred-extension obligation.
- **ICHI vault = single-sided zipUSD YieldIQ — DECIDED 2026-06-08 (user, at 8-B6 review).** The 8-B6 LP vault is a
  single-sided **zipUSD** YieldIQ vault (deposit zipUSD only; ICHI's ALM acquires the ~30% xALPHA leg from the
  underlying Algebra pool's flow, rebalancing to ~70/30 vs IL). Reverses my earlier §4.5.1 "balanced add for 8-B13
  Mode-C" framing — there is **no balanced add**; everything deposits single-sided zipUSD. The **8-B6 contract stays
  vault-agnostic** (no module-level single-sided gate; the wired vault's `allowToken` gates legality) so the vault
  can be finalized with ICHI without re-authoring — **the module did NOT change.** Rationale: the vault share is the
  tokenized receipt needed as collateral to borrow the USDC that finances the oHYDX strike; the xALPHA leg is fed by
  the emissions flywheel (xALPHA incentives market-buy zipUSD → xALPHA lands in pool → absorbed by the single-sided
  vault → bought zipUSD re-deposited = lent USDC parked as protocol-owned collateralizable LP). **OPEN external
  dependency:** exact vault config requires an ICHI conversation (single-sided zipUSD is the decided shape;
  full-range + single-sided-xALPHA rejected). §4.5.1 8-B6 block + item-10 obligation row updated; 8-B13 Mode-C must
  be authored as single-sided (no balanced add).
- **8-B6 LP strategy module (2026-06-08) — module-shape + 2 build facts (the single-sided decision is the entry ABOVE, which supersedes my initial "balanced for 8-B13" framing).** Module shape: `LpStrategyModule` is **vault-agnostic** — it forwards `(deposit0, deposit1)` to the wired vault and does NOT gate single-sided; the wired single-sided zipUSD YieldIQ vault's `allowToken*` rejects the disallowed side fail-closed (so the module did not need to change when the design was pinned single-sided). The only shape guard is `ZeroAmount` (≥1 non-zero side). No §17 reopened. **Build-resolved (not a spec gap, a build flag):** direct `IICHIVault.deposit` is the add path — **VERIFIED on live Base** (the fork test drives the module against the REAL single-sided ICHI vault `0x07e72…` on our factory `0x2b52c416…`; direct deposit lands shares) → the **ICHI DepositGuard is NOT needed** (the operator-supplied non-zero `minShares` post-check replaces its `minimumProceeds` slippage protection). The gauge MUST be a Hydrex **`ALM_ICHI_UNIV3`-type** gauge (item-10 obligation). No CRE-§8 / no `audit/*` follow-on for 8-B6 (the audit-sweep is the deferred engine-integration pass, logged in obligations).
- **8-B5 reservoir loop (2026-06-08) — 2 §4.5.1 clarifications FIXED in `claude-zipcode.md` + 1 SPEC-GAP DEFERRED to CRE §8, no §17 reopened.** FIXED (both critic-confirmed, mechanism clarifications of the build-grade §4.5.1, not new decisions): (1) the **8-B5 reservoir borrow vault installs an `OP_BORROW` guard pinning the borrow to the engine Safe** (security F8a — the borrow vault is the *shared* warehouse resting USDC, so without it any ICHI-LP holder could lever depositor funds via the escrow collateral) **[boundary user-ratified keep-as-built 2026-06-08 at superintendent review — the guard stays a required tested contract gating at the vault level]** + the note that `borrowCap` bounds **aggregate outstanding** debt; (2) the **collateral oracle build-flag RESOLVED to the CRE-fed push-cache** (user-ratified) via a **dedicated `LP_MARK` reportType** distinct from the registry's `REVALUATION=3`, fail-closed on staleness. DEFERRED (the lone SPEC-GAP the spec-fidelity critic surfaced): **`LP_MARK` must be registered in the §8 CRE report ABI** (`spec-clear-CRE.md`, still TODO) — 8-B5 pinned the placeholder `7` in the built oracle + logged a CRE-track obligation; the CRE window ratifies. No §17 reopened (CRE-permissioned engine / venue-agnostic / the Safe-as-EVC-account model all preserved).
- **Exit Gate + szipUSD authoring (2026-06-08) — 2 spec gaps FIXED in `claude-zipcode.md`, no §17 reopened.** Both
  were critic-confirmed (spec-fidelity + reference-verifier + junior-dev). (1) **§7** under-specified the
  `SzipNavOracle` public surface — the Gate needs a per-asset deposit valuation but the oracle exposed only
  `navEntry`/`navExit`/`grossBasketValue`, not a per-asset mark → added **`valueOf(address asset, uint256 amount)
  public view`** to §7 AND to the **kept oracle** (`contracts/src/supply/SzipNavOracle.sol`, public projection of the
  existing private `_tokenValue`/`_legPriceOfToken`; reverts `UnknownLpToken` off-whitelist) + 3 unit tests → **42/42
  oracle suite, 39 prior un-regressed** (additive, no behavior change). (2) **§6.4 item 3** named the **set-once
  `windowController`** (the CRE-operator/keeper that opens windows — the §4.5 item-0 operator tier) and rewrote the
  window exit. *(UPDATE 2026-06-08, user-directed: the exit is **plain in-kind ragequit** — a leaver gets their
  pro-rata slice of the free basket, zipUSD + xALPHA; no oracle/cap/numeraire/sweep on exit. My first draft used a
  zipUSD-numeraire + navExit cap + surplus-sweep, which the user overruled as over-engineering. §6.4 item 3 now reads
  in-kind; the xALPHA→zipUSD dump is a separate module `8-B-exit-autodump.md`, zipUSD→USDC is `ZipRedemptionQueue`.)*
  No §17 decision reopened (two-token / Gate-sole-Loot / zero-Shares / structural freeze / `navPerShare₀=$1` preserved).
- **SzipNavOracle authoring (2026-06-07) — 3 spec gaps FIXED in `claude-zipcode.md`, no §17 reopened.** (1)
  **§4.4** had no reportType for the szipUSD NAV leg-price push (only 1–6) → added **`7` NAV leg price**
  `(uint8[] legs, uint256[] prices, uint32 ts)` (→ `SzipNavOracle`) + the routing note. (2) **§7** under-specified
  the oracle's authority/denominator → named the **two write authorities** (immutable Forwarder reportType-7 vs the
  set-once bounded `DefaultCoordinator` provision writer), the `navPerShare = basketNAV/(totalSupply − engine
  pending-burn)` denominator, the set-once share-token wiring + renounce-freeze, and the zero-supply genesis
  `navPerShare₀`. (3) **§12** still carried the **retired** "NAV display-only / WITHHOLD-not-markdown / in-kind exit
  with no oracle in the path" model (the PROGRESS-flagged stale residual) → rewrote it to the **two-token /
  `SzipNavOracle` issuance-exit-primitive / pari-passu provision-that-recovers** model (consistent with §7/§4.5/§11/
  §17). spec-fidelity critic confirmed all three present + faithful + no other stale residue active. No spec gap
  remained un-fixed; the ticket built zero-contradiction.
- **SzipNavOracle ZERO-GUESS GATE CLOSED (2026-06-08) — independently re-materialized from the ticket alone, 3
  findings folded in.** Per harness `audit/adversarial-spec/README.md` step 4, a fresh builder (no design context)
  rebuilt `SzipNavOracle.sol` + `IXAlphaRate.sol` + the test from `tickets/sodo/8-B4-szip-nav-oracle.md` ALONE
  (sealed the keepsake first): `forge build` clean, **33/33** independent unit tests + the live-fork sig-verify
  green, **149/149 total no regression**. Diff vs the kept keepsake surfaced **3 ticket holes** (all folded into the
  ticket; none a claude-zipcode.md spec gap, none a bug in the kept code — the keepsake was the stricter/correct
  build, so it was RESTORED as canonical): **(c-divergence)** the four set-once setters reject `address(0)` with
  `ZeroAddress` (the kept build does + tests it; the ticket never pinned it, so the rebuild silently omitted the
  guards); **(b)** `event Poked` arg is **`uint256 cumNav`** not `uint224` (the `uint224` in the ticket was
  inconsistent with the `uint256` accumulator + forced a lossy cast); **(b)** `grossBasketValue()` is **`public`**
  not `internal` (the kept suite reads it directly to pin the NAV math). Also pinned the `_accumulate() returns
  (bool)` + gated-`poke()` emit (the ticket's unconditional-emit pseudocode contradicted its own `dt==0`
  idempotence test — both builders had to deviate identically). `reports/8-B4-zerogate.md`. The kept tree is green;
  the gate is now formally met for `SzipNavOracle`.
- **Deploy target = BASE MAINNET — RESOLVED 2026-06-06 (user-directed).** The MVP **ships to Base mainnet (8453)
  and tests there**, NOT Base Sepolia. Rationale: Base gas is cheap, and the item-8 farm/vault deps
  (Baal/Safe/Zodiac/ICHI/Hydrex) are deployed **only on 8453** — Sepolia could never run the full vault. So
  deploy-target = fork-target = Base mainnet; CRE selector `ethereum-mainnet-base-1` (forwarder identical to
  Sepolia). **Folded into WOOF-00** (rpc primary `base`, Euler/CRE mainnet framing). **BROADER SWEEP DONE
  2026-06-06:** `README.md` (§2 MVP scope, §4 WOOF header + the RPC/selector line, §5 critical path),
  `claude-zipcode.md` §15 demo line, and `audit/2.md` (§1 chain/selector, the EVC/USDC/FORWARDER symbol rows →
  real Base-mainnet addresses, S1, S12 faucet→`deal()`/whale, the L6 warp note) all flipped to Base mainnet.
  **Still owed (FORWARD — not yet authored):** the **CRE origination/redemption workflows** must use the mainnet
  selector when the CRE track is built. (Bittensor chain 964 / testnet-945 in the xALPHA bridge is a SEPARATE
  concern — left as-is.)
- **xALPHA source for the M1 farm loop — RESOLVED 2026-06-06 (user-directed).** The full Hydrex farm loop is in
  the M1 szipUSD vault (8-B5…8-B11); the basket holds **xALPHA** + the zipUSD/xALPHA **ICHI LP**. **Decision: BOTH
  (a)+(b)** — the **CCIP xALPHA bridge is pulled INTO M1** (backlog row `8x`, moved off DEFERRED), AND **dev
  validates the 8-B farm-module builds against a stand-in test xALPHA token** on the Base fork (real token swaps
  in when the CCT lane is live). Mandate: *"no stalling out waiting on external gates, but plan on the things we
  need."* So: the bridge is a planned M1 deliverable; CCT-registration on chain 964 is NOT a blocker (stand-in
  meanwhile). **8-B5/8-B6 "Model from" must pin the stand-in test xALPHA** (an 18-dp mock ERC20) + note the real
  bridged token as the production swap-in. **Not blocking 8-Bw or 8-B1** (neither touches xALPHA); first bites at
  8-B5/8-B6.
- **§4.7 venue — FIXED in spec (this window, item 5) + USER-RATIFIED §17 edit.** The §4.7 one-line `openLine →
  createProxy` was realized as the **per-line isolated-market factory** (EdgeFactory pattern): each line mints its
  own escrow collateral vault + USDC borrow vault + a **dedicated `EulerRouter`** wired `escrowVault→LIEN_i→registry`
  and **frozen** (`transferGovernance(0)`). This **supersedes the shared-router "F4"** (no shared router; no
  per-lien timelock; origination stays atomic) and **edits a §17 locked line** ("Router governor = TimelockController"
  → per-line frozen routers; the timelock is retained for §17 *parameter* governance only). **User explicitly
  ratified the §17 edit this session.** Threaded through §3 (ASCII box + Router row), §4.1 Registration, §4.4, §4.7
  (method table + portability), §9 S-setup, §13 (trust + failure-modes), §17 (two locked lines) + audit/2.md
  (S6 ctor, S8 curator+timelock0, S9 subsumed, S10 no-shared-router, N5 frozen-router, L4 1e4 LTV) + audit/3-results
  (rows 12/13, Trace B, failure-mode rows, §2 convention). **Oracle key stays `LIEN_i`** (§4.1/§4.2/WOOF-02 unchanged).
  Open follow-on: the **`baseUsdcMarket`** funding source (EulerEarn has no idle concept) is a supply-side/wiring
  dependency (owed by item 10 + §4.5).
  - **DEFERRED-BUT-MANDATORY cold-build gate (superintendent, 2026-06-05).** WOOF-04 concluded on a cold-build = NO
    with 3 guesses folded in but **no fresh from-ticket-alone re-run**, so the harness §4 zero-guess gate was not
    formally met. The superintendent review caught one fold-back transcription error by reading (AmountCap encode
    inverted — `(exponent<<10|mantissa)` → corrected to `(mantissa<<6)|exponent`, raw-0 = unlimited so `cap==0`
    must revert; fixed in the ticket). **Before the build team implements WOOF-04, run a fresh from-ticket-alone
    cold-build** to confirm no other fold-back errors remain. (Also: tighten the residual "verify at cold-build"
    hedge at ticket `:153` EVC self-call encoding into a pinned assertion during that pass.)
    - **GATE MET (2026-06-05).** Fresh from-ticket-alone cold-build run (the WOOF-04 cold-build — deleted byproduct): **verdict
      YES**, `forge build` clean + `forge test` 14/14 green (live EVK/EVC/EulerRouter + mocked EulerEarn). AmountCap
      encode independently re-derived from `AmountCap.sol` and confirmed CORRECT (`(mantissa<<6)|exponent`, raw-0
      reject); every "verify at cold-build" hedge pinned against the reference (EVC self-call shape, `reallocate`
      absolute-target, `IBorrowing.borrow`/escrow `IERC4626` faces) — all matched. **No second encoding-class error.**
      4 keepsake nits folded in: `EVC.call` is **4-arg** (`value` arg — was written 3-arg in `closeLine`);
      `acceptCap` cite `:307`→`:507` in the Model-from block; `supplyQueueLength()` exists (`:477` — the "no length
      getter" premise was false); `openLine` now **rejects `collateralAmount==0`** (`deposit(0)` doesn't revert, so
      a zero-share line would open unusable). Ticket is now a true zero-guess keepsake. **[Sharpened 2026-06-05 — see
      session log:** the `==0` guard was tightened to **`!= 1e18` (`InvalidCollateralAmount`)** — the lien is a 1/1
      `1e18` primitive and §4.4c close reclaims exactly `1e18`, so a *partial* deposit is as broken as a zero one;
      the controller (item 6) is the primary guarantor it passes the full lien.**]**
    - **DELTA GATE MET (2026-06-05, `cold-build-2.md`).** The sharpened `!= 1e18` guard was spec'd *after* cold-build
      #1, so it was build-exercised in a focused delta pass (the WOOF-04 delta cold-build — deleted byproduct): **verdict YES**, 11/11
      green (live EVK/EVC/EulerRouter + mocked EE). Three-case `openLine` test all pass — `0` → `InvalidCollateralAmount`,
      `0.3e18` (partial) → `InvalidCollateralAmount`, `1e18` → succeeds + escrow holds `1e18`. **Reference-confirmed the
      guard is load-bearing:** EVK `Vault.deposit` (`reference/euler-vault-kit/src/EVault/modules/Vault.sol:124-136`)
      returns 0 on `deposit(0,..)` (no revert) and succeeds on a partial — only the `!= 1e18` guard stops them; a
      partial would later underflow §4.4c's reclaim-`1e18`. Happy-path + two-line isolation un-regressed. **No findings.**
      **WOOF-04 is now a fully gated zero-guess keepsake.**
- **§4.4 controller — FIXED in spec (this window, item 6).** Authoring the orchestrator against the
  venue-neutral constraint surfaced three genuine spec gaps (all spec-fidelity-confirmed, no §17 reopened),
  fixed in `claude-zipcode.md` + audit: (1) **`erebor` 5th ctor arg** — the controller must pass Erebor to
  `venue.draw` (the venue validates `receiver == its erebor`, WOOF-04 F2) and the 4-arg sketch gave it no
  source → §4.4 ctor sketch + audit/2.md S6 now 5-arg. (2) **EVC-operator authorization** — §4.4 described the
  borrower-of-record sub-accounts but not who/how authorizes the adapter as operator; a venue-neutral
  controller cannot observe the adapter's per-line `subId`, so it grants a **one-time owner-gated blanket**
  `setOperator(prefix, venue, ~uint256(1))` (excludes primary sub 0) via `wireVenueOperator(evc)` before the
  S11 renounce → §4.4 borrower-of-record para + §9 wiring step + audit S6 + audit/3-results orphan-sweep row;
  the per-`sub_i` framing of the WOOF-04 obligation 1a is **reframed** (obligations table above). (3) **§4.4a
  ordering** reconciled to `create → openLine → seed(returned oracleKey) → setLineLimits → fund → draw` (seed
  the key openLine returns; seed-before-draw is the load-bearing invariant) — this also fixed a stale
  shared-"router fallback" phrase left from the WOOF-04 per-line-router edit. **Ticket-only (NOT a spec edit,
  spec-fidelity confirmed the spec is already clear):** the controller rejects `reportType 3` (→ registry
  direct) and handles types 5/6 as **M1 status markers** (loss machinery M2; never `venue.liquidate`).
- **§4.5 szipUSD EXIT mechanism — RESOLVED + FIXED in spec (item 8 / WOOF-07).** A genuine three-way conflict
  (spec-fidelity-confirmed): §4.5 said unstake "redeems pool shares **for USDC** via venue `redeem`, mints zipUSD
  back"; `audit/2.md` L12 said `withdraw` pays **USDC** to JR; S7 grants szipUSD mint capacity "**mints** on
  unstake" (zipUSD). **Resolved (faithful to §4.5's "mints zipUSD" + S7 + the §6.3 paced-queue/run-throttle):
  the junior exit pays zipUSD, NOT USDC** — `unstake` returns the pro-rata EE-pool shares to the **module's**
  senior custody and mints `convertToAssets(poolSharesOut)×scaleUp` zipUSD; the user then exits zipUSD→USDC via
  the epoch queue (§6.1). **APPLIED:** §4.5 unstake bullet rewritten (struck the "for USDC" leg; added szipUSD
  18-dp-via-offset-12, the **module-only 3-arg stake** F-CRIT note, M1 floor/freeze scope); **§17 L1334** stale
  "→ USDC →" leg struck; `audit/2.md` L12 (`unstake`→zipUSD, shares→module) + N3 (`ExceedsWithdrawLimit`,
  `withdraw`→`unstake`) + N4 (floor cap) + S7 (capacity-must-be-max corrected rationale + szipUSD owner=timelock
  NOT renounced). **No §17 decision reopened** (share-backed junior, cooldown exit, zipUSD-never-freezes, M1
  yield-routing all preserved; the "M1 keeps junior yield" framing was softened to "structural fee-share NAV
  accrual is the M1 mechanical routing; the §17 protocol-privatization is the end-state" — no decision changed).
- **§4.5 zap — RESOLVED + FIXED in spec (this window, item 7 / WOOF-06).** The three deferred gaps closed, plus
  two reference-verified corrections the authoring surfaced: **(1) on-behalf stake** → `szipUSD.stake(uint256
  amount, uint256 shares, address receiver)`, the zap passes `receiver = the end user`. **(2) stake-vs-deposit
  naming** → `stake` is the **custom convert-on-stake** entry (NOT vanilla 4626 `deposit`): it burns the
  **caller's** zipUSD (ESynth allowance rule, `ESynth.sol:91`) and pulls pool shares from the module. **(3)
  custody account** → **the `ZipDepositModule` IS "the protocol's holding"** of `EulerEarn` shares; a set-once
  `setStakingVault(szipUSD)` grants szipUSD the standing EE-share allowance to pull from it. **(4) DECIMALS
  (reference-verified, audit was WRONG):** `ESynth` is fixed **18-dp** (ctor is `(evc, name, symbol)` — the
  audit's `, 6 decimals` arg was impossible); `EE_POOL` shares are **6-dp** (offset 0, `VIRTUAL_AMOUNT=1e6`);
  "1:1" is **value**-1:1 → the module mints `usdc * 1e12`. **(5) F1 exact-shares (security MED):** the zap
  **captures `EE_POOL.deposit`'s share return** and `stake` pulls **exactly** that — a recompute from a live
  `share_price` could Floor-over-pull 1 wei from the aggregate senior backing per zap. Threaded through §4.5
  (both bullets) + §5 (flow) + §9 (S7 wiring) + `audit/2.md` (S7 3-arg ctor / szipUSD-takes-module /
  `setStakingVault` / decimals callout, L1/L2/L3 e6→e18 + 2-arg-direct vs 3-arg-exact). **No §17 reopened.**
  Cold-build YES 17/17 (the F1 fix proven load-bearing with a non-par EE mock).
- **§4.2 factory authority — FIXED in spec (this window, item 2).** §4.2 read "the factory grants the controller
  mint authority at creation," implying a factory-held controller immutable — but the `ZipcodeController`
  constructor takes `lienFactory` (§4.4), so the factory deploys first (audit/2.md S4) and that immutable is a
  deploy-order circularity. Rewrote §4.2 to **caller-bound one-arg `create(bytes32 lienId)`** — `controller :=
  msg.sender`, no gate, immutable at the token's own construction; `computeAddress(bytes32 lienId, address
  controller)` stays the two-arg precompute view. **Inherently squat-proof** (CREATE2 init-code embeds the
  caller → an attacker's `create` lands at a different, inert address; the canonical `LIEN_i` slot stays free
  for the real controller). Threaded through §4.2 + audit/2.md L4 + audit/3-results row 19 + WOOF-01; aligns
  with the pre-existing §9 trace `create(lienId)`. No §17 reopened.
- **WOOF-00 SPDX license — RESOLVED (user decision, this window).** The cold-build had to guess the SPDX license
  for the `src/` stubs; user pinned **`GPL-2.0-or-later`** for every `contracts/` file the protocol authors (the
  contracts import GPL-2.0-or-later `evk`/EVC code → derivative kept GPL; GPL-compatible with OZ MIT). Pinned the
  exact two-line header (`// SPDX-License-Identifier: GPL-2.0-or-later` + `pragma solidity 0.8.24;`) into WOOF-00's
  Key requirements and WOOF-01's Starting state. No remaining guesses in either ticket.
- **§4.1 registry — FIXED in spec (this window, item 3).** §4.1 described only `_processReport` and the read
  view; the harness surfaced **five real gaps** the spec under-defined, now folded into §4.1 (+ §4.4/§9/§10/§17
  consequence edits): (1) the **controller-gated `seedPrice`** origination path + the **set-once `setController`**
  (deploy-order circularity — registry@S3 deploys before controller@S6, mirrors the §4.2 factory case); (2) the
  **two-stage report decode** — `_processReport` strips the §4.4 envelope `(uint8 reportType, bytes payload)`,
  requires `reportType==3`, then decodes the payload + `liens.length==prices.length`; (3) the **strict-decimals
  guard** (low-level staticcall that reverts, NOT `BaseAdapter._getDecimals` which silently returns 18 — would
  no-op the guard); (4) the **scale/units convention** — `calcScale(18, quoteDecimals, feedDecimals=quoteDecimals)`
  → `getQuote(1e18, LIEN, USDC) == equityMark`, i.e. equityMark is reported in the quote's native units (USDC 6dp);
  (5) a **`ts > block.timestamp` sanity guard** (units guard, not a value band — closes the far-future-ts
  never-stale footgun). No §17 *decision* reopened (event-driven Proof / no heartbeat / no value band all preserved).
- **CRE-receiver immutable Forwarder — "override to revert" was UNIMPLEMENTABLE; CORRECTED to renounce-based.**
  Reference-verified: `ReceiverTemplate.setForwarderAddress` AND `onReport` are **non-virtual** → cannot be
  overridden. The spec said "override `setForwarderAddress` to revert" at **five sites** (§4.1, §4.4, §9, §10
  summary, §17 line 1131) — all corrected to: immutability is sealed by **`renounceOwnership()`** after identity
  wiring; post-renounce every `onlyOwner` setter reverts `OwnableUnauthorizedAccount`. Consequent audit edits:
  audit/2.md S3 (lock lands at S11, not S3), S6 (+`setController`), **S11 (hard pre-gate: assert
  `getExpectedWorkflowId() != 0` AND `controller() != 0` before renounce — security F7)**, N7 (expected revert →
  `OwnableUnauthorizedAccount`), L4 (seed via `controller.seedPrice`; `getQuote(1e18) == equityMark` exact);
  audit/3-results rows 20/21/22 reworded + new `setController`/`seedPrice` sweep rows + forged-value attack row
  (names the **over-borrow** vector, mitigated by the borrowLTV gap + upstream, not by this contract).
- **Judgment call to sanity-check (item 3):** the `ts > block.timestamp` write-time reject is slightly beyond the
  literal §4.1 "no on-chain band" — kept as a *timestamp-sanity* guard (an appraisal can't be dated after now),
  distinct from a forbidden *value* band. Flagged in the report; revert if the superintendent disagrees.

- **Supply-side redesign — RESOLVED 2026-06-05 (user-directed + ratified; folded into `claude-zipcode.md`
  §2/§4.5/§6.4/§7/§11/§17/§18).** A long design session reshaped the supply side. Outcomes:
  1. **xALPHA is the single token name** — the bridged subnet LST. The legacy placeholder token name was renamed
     away **repo-wide** (2026-06-05, user-directed: "no use for it anywhere") — incl. the M2-sketch loss-side
     names (`LienXAlphaEscrow`, `slashXAlphaToCapital/Cohort`, `lockXAlpha`/`releaseXAlpha`). Zero left outside
     `reference/`. Token does first-loss bond / Duration-Bond premium / szipUSD incentive / zipUSD-xALPHA POL leg
     / last-resort backstop (alpha→TAO→USDC) / treasury buyback target.
  2. **szipUSD collapses sdVAULT** → one junior token = the freezable vault share. sdVAULT = a **post-M1
     yield-engine module** that bolts onto it.
  3. **Duration lock = redemption-gate-with-boost, not a seizure.** zipUSD never freezes (senior throttle = the
     epoch queue); the freeze gates a pro-rata szipUSD share subset that **keeps accruing**, objective
     DON-verified release; sdVAULT inherits the freeze transitively. Credit loss = recovery waterfall (secondary
     → insurance → xALPHA bond alpha→TAO→USDC) → frozen-junior **residual, markdown at resolution**. Boost +
     hole-plug funded by the post-M1 HYDX free-value stream ("HYDX/USDC pays for duration and plugs holes").
  4. **Yield routing — DECIDED 2026-06-05: the real lending yield (APR + fees) is the PROTOCOL's**, privatized into
     a treasury strategy that buys xALPHA; depositors are subsidized by xALPHA + the HYDX/USDC pool, NOT by the
     lending yield (target: buy more xALPHA than incentive spend). **Resolves the old "f split"** (no szipUSD real
     base from lending). Implementation flexible (treasury vs shares-resolved-at-cycle-end — user's call); **M1**
     holds the yield protocol-side, szipUSD headline = seeded xALPHA emission; the buyback strategy is post-M1.
     `audit/1` I3–I4 (szipUSD NAV = own fee-shares) to be revisited when the treasury/buyback module is specced.
  5. **M1 cut:** items 7 (zap → `USDC→zipUSD→szipUSD vault`) + 8 (szipUSD = the M1 vault SHELL) ship the simple
     end-state shape; the sodomizer/xALPHA-buyback/POL bolt on post-M1. **The zap (item 7) is UNAFFECTED by the
     tokenomics** — it lands a user in the szipUSD vault either way; **item 7 stays NEXT and is ready to author.**

## Session log (one line per concluded window)
- **2026-06-08** (**8-B7 — harvest/vote module; BUILT-VERIFIED + KEPT**) — Authored `tickets/sodo/8-B7-harvest-vote.md` (the 4th engine Zodiac Module, simplest sibling of 8-B6) through the full harness: pre-verified the **un-open-sourced** Hydrex host on live Base 8453 by reverse-reading the VoterV5/veHYDX/oHYDX/Minter/RewardsDistributor bytecode → **fixed 5 §4.5.1 spec mis-citations FIRST** (account-keyed `vote`/`reset` no-tokenId; floor=`ve.getVotes(account)`; state=none; rebase on the RewardsDistributor; `getEpochDuration`=604800) in `claude-zipcode.md` + `baal-spec §10.8` → drafted the ticket (build-only; the module tracks **NO tokenId** — each `exerciseVe` mints a fresh account-owned veNFT, the Voter aggregates by account) → **5-critic fanout** (junior/spec-fidelity/ref-verifier/qa/security; spec-fidelity verdict FAITHFUL, no §17 reopen, no inbound obligations) → triaged (all ticket gaps) + folded: `IVotingEscrow` needs `balanceOf`/`ownerOf`/`tokenOfOwnerByIndex` adds, full `IRewardsDistributor` sigs, the RecordingSafe return-data extension + target mocks, exec-shape arg-pinning (`encodeCall`) + the `lockVe` recipient decode-assert (the irreversibility firewall), positive `vote`/`reset`/`claimRebase` fork assertions, and the over-lock monitoring obligation (8-B11 bound `lockVe` to `s*`, 8-B12 tripwire) → **cold-build (subagent), ZERO load-bearing guesses, independently re-ran green: 26/26 (21 unit + 5 Base-fork), 326/326 total no-regression** (`forge test [--fork-url $BASE_RPC_URL] --match-contract HarvestVoteModule`). The fork test PROVES the fresh-veNFT/account-aggregate model (real `exerciseVe` + balance/getVotes/ownerOf deltas, real `vote`/`reset` vs live VoterV5, real `claimRebase`). **5 build-exposed corrections folded** (live `vote` needs an epoch-advanced snapshot + `Minter.update_period()` → `InsufficientVotingPower`/`EpochStale`; per-account ~1h vote-delay → `VoteDelayNotMet`; exerciseVe needs NO approval CONFIRMED; `HYDREX_VE` is a `VEHYDX` alias; `lastVoted` kept off the production `IVoter`). Code `contracts/src/supply/szipUSD/HarvestVoteModule.sol` + `contracts/test/HarvestVoteModule.t.sol` + interface adds + `BaseAddresses`. Kept on disk, NOT git-committed (whole tree untracked). `reports/8-B7-report.md`. **NEXT = 8-B8** (exercise/strike-financing module).
- **2026-06-08** (**8-B5 — reservoir strike-loop module; BUILT-VERIFIED + KEPT**) — Authored `tickets/sodo/8-B5-reservoir-loop.md` (the 2nd engine Zodiac Module) through the full harness: drafted → **5-critic fanout** (junior/spec-fidelity/ref-verifier/qa/security) → triaged → cold-build (subagent) → independently re-ran green. Built 4 contracts + a test: a CRE-`onlyOperator` `is Module` (`ReservoirLoopModule`) driving the szipUSD Safe's **own EVC account** through unstake→post→borrow→repay→withdraw (`exec(Call)`, `receiver`/`onBehalf` hard-pinned to `engineSafe`, no passthrough); `SzipReservoirLpOracle` (CRE-fed push-cache, `LP_MARK=7`, fail-closed staleness); `ReservoirBorrowGuard` (pins `OP_BORROW` to the Safe); `ReservoirMarketDeployer` (GenericFactory escrow+router+borrowVault, governor RETAINED at the Timelock). **33/33 Base-fork, 271/271 total, no regression** (`forge test --match-contract ReservoirLoopModuleTest`). **User-locked** the LP collateral oracle = CRE-fed push-cache (not fixed-haircut). **2 §4.5.1 spec clarifications** (the `OP_BORROW` borrow-pin + the LP_MARK reportType) + **1 SPEC-GAP deferred** (LP_MARK registration in CRE §8). **4 build-exposed corrections folded into the ticket** (C1 Safe-swallows-reverts→`_exec` bubbles via `execAndReturnData`; C2 `repay` reverts `E_RepayTooMuch` not silent-cap; C3 a new borrow gates on `borrowLTV` not `liqLTV`; C4 `setLTV` needs a live mark pre-deploy + governor RETAIN = `transferGovernance(timelock)`). **Critic hardening:** aggregate `borrowCap`, the required borrow guard. Kept on disk, NOT git-committed (whole tree untracked). `reports/8-B5-report.md`. **NEXT = 8-B6** (LP/gauge-stake module).
- **2026-06-08** (**WOOF-06 — the zap, cold-build against the REAL Gate seam; BUILT-VERIFIED + KEPT**) — Materialized
  `contracts/src/supply/ZipDepositModule.sol` from the re-authored ticket and, because 8-B1/`SzipNavOracle`/Exit Gate
  had landed, proved the headline zap end-to-end against the **LIVE** `ExitGate.depositFor` + real `SzipNavOracle` +
  real Baal substrate + the real zipUSD `ESynth` (suite `ZipDepositModuleRealGateTest`, Base fork: genesis-par,
  NAV-proportional $1.2→round-down, on-behalf, `previewZap==zap`, two-token invariant, `totalShares()==0`). A `MockGate`
  is kept ONLY for the adversarial gate behaviours the real Gate can't exhibit (under-pull→`ResidualBalance`,
  no-share→`ZeroShares`, mid-call-revert atomicity, gate+EE reentrancy). **29/29** (26 mock + 3 fork), **205/205 total
  no regression**. **Build-discovered:** the real `ExitGate` matched `depositFor` exactly but **lacked `previewDeposit`**
  (the obligation this ticket created) → **added `previewDeposit(asset,amount) view` to the kept `ExitGate`** (mirrors
  `depositFor` pricing; +2 Gate tests; obligation DISCHARGED). **6-critic fanout run** (junior/spec-fidelity/ref-verifier/
  qa/security/frontend): spec-fidelity clean; fixed a misleading ctor error (`ZeroAmount`→dedicated `DecimalsTooFew`),
  a wrong `scaleUp` doc comment, +conservation asserts on 4 tests, +tightened 2 reentrancy `expectRevert` selectors;
  security "preview↔exec divergence"/"stranded-capital-on-revert" findings rejected (view-estimate is documented;
  zap is atomic). frontend gaps (`erc20AllowanceAbi`, `IZipDepositModule.sol`) = INFLOW-06 scope. Also noted: the real Gate
  routes pulled zipUSD to `mainSafe` (the basket), not the Gate itself — real-gate test asserts `mainSafe`. No
  `claude-zipcode.md` spec edit (the contract is pure plumbing; the ticket's pinned seam held). Ticket + LEDGER +
  `reports/WOOF-06-report.md` updated. NOT git-committed (whole tree untracked — superintendent commit decision
  pending). ~~**NEXT = 8-B14 buy-and-burn.**~~ INFLOW-06 (frontend interface) still PENDING cold-build.
- **2026-06-08** (**8-B14 buy-and-burn — BUILT-VERIFIED**) — Authored `tickets/sodo/8-B14-buy-burn-module.md` +
  built `SzipBuyBurnModule` (the **bid side** of §7; the burn stays the existing `ExitGate.burnFor` by the CRE
  windowController — buy and burn split by *authority*). The first engine Zodiac Module: `is Module` (zodiac-core),
  `setUp`-under-`initializer`, `onlyOperator`, mutates the engine Safe via `exec(...,Operation.Call)` only. Posts a
  single resting CoW `BUY szipUSD` PRESIGN order, priced `≤ navExit×(1−d)` off `SzipNavOracle`, `sellAmount ≤
  buybackCap`, `receiver = engineSafe`; signs by computing the GPv2 orderUid on-chain + `setPreSignature` (Call, no
  delegatecall) + an exact-`sellAmount` USDC approve to the live CoW VaultRelayer. **5-critic fanout**
  (junior/spec-fidelity/ref-verifier/qa/security). **3 spec edits to `baal-spec §7.2/§7.4`** (the triage): (1) price
  off **`navExit`=min(spot,twap)** not bare `twapNAV` — security-critic catch, a *buyer* must mark at the lower of
  spot/twap or it overpays off a stale-high twap when NAV trends down; (2) name the **windowController** as the
  `burnFor` caller (§7.2 said "the Gate burnLoot" but `burnFor` is windowController-gated); (3) drop "Roles-scoped
  engine Safe" — §10.1's plain-Module mandate governs the whole 8-B5…B14 family. **Ticket-level fixes from critics:**
  defined the 3-field `GPv2OrderInput` (all other GPv2 fields are module-fixed constants incl. a pinned `appData` so
  no unvalidated field enters the uid); fixed the price inequality to an exact no-truncation integer form (floored
  against the buyer); corrected "store immutable in setUp" → **set-once storage** (clones share mastercopy bytecode,
  immutables can't carry per-clone config); single-resting-bid = `postBid` reverts `BidAlreadyLive` (re-post = cancel
  + new validTo) to kill the partial-fill double-fill; `buybackCap==0` = kill-switch; no generic exec passthrough.
  **Build:** zero load-bearing guesses, **33/33 Base-fork + 238/238 total**, uid proven against an out-of-band `cast`
  known-answer vector + live `GPv2Settlement.preSignature`. **Build-discovered + corrected MID-WINDOW:** the cold-build
  subagent patched `reference/zodiac-core/Module.sol` to add `virtual` (to override `setAvatar`/`setTarget`) — **the
  user flagged this; `reference/` is PRISTINE and must never be edited.** Reverted the reference, dropped the
  hard-lock, and instead leave `setAvatar`/`setTarget` inherited `onlyOwner` (the operator hot-key can't redirect; a
  Timelock redirect is a deliberate governance act — residual accepted), proven by `test_operator_cannot_redirect_safe`.
  Re-greened (reference clean, 33/33, 238/238). Code kept, NOT git-committed (whole tree untracked). `reports/8-B14-report.md`.
  **NEXT = engine 8-B5…8-B13** (`baal-spec §13` order / `§10.8` per-module specs).
- **2026-06-08** (**Exit Gate — exit REWORKED to pure in-kind ragequit, user-directed; supersedes the entries
  below**) — The user overruled the zipUSD-numeraire exit I built (and the superintendent had ACCEPT-for-M1'd). The
  exit is **plain in-kind ragequit**: a leaver gets their **pro-rata slice of the (free, main-Safe) basket — zipUSD +
  xALPHA — sent straight to them**; burn the matching Loot + escrowed szipUSD. **No oracle/cap/numeraire/sweep/
  fundability on exit** — "you leave, you get your share," worth `shares × NAV/share` by construction (the slice
  self-prices; the NAV oracle prices *issuance* only). The leaver's xALPHA→zipUSD conversion is a **separate Zodiac
  auto-dump module** (new TODO ticket `tickets/sodo/8-B-exit-autodump.md`) and zipUSD→USDC is the existing
  `ZipRedemptionQueue` — neither is the Gate. **Consequences:** JC1 (zipUSD-numeraire / M1-fundability) is
  **DISSOLVED** (no numeraire exists); the `NavZero` guard + the `_tokensZipUSDOnly`/`owe`/sweep/fundability code are
  **removed**; `valueOf` **stays** (issuance valuation — unaffected). The freeze stays structural (ragequit reaches
  only main; sidecar excluded). `ExitGate.sol`/`SzipUSD.sol` reworked + tests rewritten to the in-kind model (pro-rata
  in-kind, multi-asset in-kind, free-equity-only freeze); `forge test` **174/174 still green on the live Base fork**.
  §6.4 item 3 rewritten to in-kind; the ticket + LEDGER + report updated. Memory [[prefer-simplest-mechanism]] saved.
  The two superintendent JC1 rulings below are now moot.
- **2026-06-08** (superintendent review of **Exit Gate + szipUSD**) — **VERDICT: on-track; WOOF-06 cold-build
  released.** Independent checks: (1) **Consistency** — `valueOf` landed in §7 + the kept oracle; `windowController`
  in §6.4 item 3; the builder's §6.4 item-3 edit and my §6.4 item-4 structural-freeze edit **coexist cleanly** (item 3
  pays exits from free main-Safe equity, item 4 sizes free-vs-committed by utilization — coherent). (2) **§17 not
  reopened** — both edits additive/clarifying (the zipUSD-numeraire exit satisfies the locked min(spot,twap)/partial-
  fill decision). (3) **Seams — both inbound obligations DISCHARGED + verified:** 8-B1 F4.2 (Gate only
  mintLoot/burnLoot/ragequit, never mintShares; `totalShares()==0` after every path; manager-grant fork-proven) + the
  NAV-pricing seam (poke→navEntry round-down / poke→navExit / setShareToken). (4) **Keep-the-build** — 17/17 fork +
  174/174 total per the report (did not re-run the fork suite). **Rulings on the 4 flagged judgment calls:** JC1 M1
  zipUSD-numeraire exit = **ACCEPT for M1** (zipUSD-dominant basket, harvest replenishes pre-window, never
  reverts/mispays — partial-fills; general volatile→zipUSD conversion is the engine's job, 8-B9; tracked below). JC2
  `NavZero` guard = **ACCEPT** (sound — halts exits at total impairment so a recovering provision can write NAV back
  up). JC3 TVL-cap overlap = **ACCEPT as layered** (Gate hard immutable backstop + 8-B12 dynamic measured cap on top
  at WOOF-06; tracked below). JC4 Gate = manager-shaman + Loot-holder, not a Safe module = **ACCEPT** (minimal surface,
  matches the ratified 8-B1 two-tier authority model). **One real gap caught — the AUDIT-SWEEP was deferred with NO
  named owner** ("deferred to the junior-acceptance harness"): deferring the **audit/2 integration rows** (L3/L12/S7)
  is legitimate (they need the zap + deploy/wiring + windowController wiring, not yet built), and the **audit/3
  authority rows 25–27 + Trace E** fold into that same junior-acceptance pass — but it must be **pinned to a named
  item**, not left vague → added the obligation row below (owner = item 10 / the post-WOOF-06 junior-acceptance pass).
  **Non-blocking caveat (note):** authored+built one window, no fresh zero-guess rebuild — same class as `SzipNavOracle`
  (whose deferred gate, when later run, found 3 real ticket gaps). The Exit Gate is the highest-authority junior
  contract (sole Loot custodian / ragequit caller / szipUSD minter), so I **recommend** its fresh-subagent zero-guess
  rebuild be run before mainnet — non-blocking for WOOF-06 (which consumes the real on-disk interface, not the ticket).
  **NEXT = cold-build WOOF-06** against the real `gate.depositFor` seam.
- **2026-06-08** (**Exit Gate + szipUSD BUILT-VERIFIED — the junior share + the windowed exit valve**) — *[EXIT
  MECHANISM SUPERSEDED — see the rework entry at the TOP of this log: the exit is **pure in-kind ragequit**, not the
  zipUSD-numeraire/navExit/sweep/partial-fill described in this entry. Everything else (issuance, two-token invariant,
  manager-grant, burnFor, valueOf) stands.]* — Authored
  `tickets/sodo/8-B-exit-gate-szipusd.md` through the full harness: drafted vs `claude-zipcode.md §6.4/§7` +
  `baal-spec.md §4/§5/§7`, verified vs `reference/Baal` (ragequit:619 burns from `_msgSender()`; mintLoot:814 /
  burnLoot:834 `baalOrManagerOnly`; `_safeTransfer`→`execAndReturnData(Call)` = the Safe module path, so ragequit
  moves the **main-Safe** treasury) + the kept `SzipNavOracle`/`SummonSubstrate`. Fanned out **5 critics** (junior-dev/
  spec-fidelity/ref-verifier/qa/security) — strong consensus, **2 spec gaps** (§7 `valueOf`, §6.4 windowController +
  zipUSD-numeraire) fixed FIRST (logged above), ~20 ticket-clarity items folded in (helper def, queueHead/loop
  termination, edge cases, invariant-after-every-path, reentrancy). **Built + KEPT:** `contracts/src/supply/szipUSD/
  ExitGate.sol` (~270 LOC, the sole Loot custodian + szipUSD minter + ragequit caller; `depositFor`/`requestExit`/
  `cancelExit`/`processWindow`/`burnFor`) + `SzipUSD.sol` (transferable 18-dp, onlyGate mint/burn) +
  `contracts/test/ExitGate.t.sol`; `forge build` clean (0.8.24) + **17/17 on a LIVE Base fork** (real Baal substrate
  via `SummonSubstrate._summon`, real `SzipNavOracle`, mock basket) + **added `valueOf` to the kept oracle** (42/42);
  **174/174 total, no regression**. Fork-proven: manager-grant gate (pre-grant `depositFor` reverts at `mintLoot`,
  post-grant succeeds), NAV-proportional round-down issuance, two-token invariant after every path, windowed exit
  paid zipUSD at navExit, the **min(spot,twap) haircut accreting to stayers**, the **partial-fill = freeze** (free
  main-Safe equity only; sidecar untouched; fills after rotation), buy-and-burn pure-supply-retire, `totalShares()==0`
  throughout, `NavZero`/empty-queue/double-cancel/unsupported-asset/stale edges. Both inbound obligations DISCHARGED.
  **Judgment call flagged (superintendent please note):** the M1 exit funds each claim from the *zipUSD* freed by
  ragequit (zipUSD-numeraire), so it fully pays only while the free basket holds enough zipUSD per share — true in M1
  (zipUSD-dominant pre-engine; the harvest unstakes LP→zipUSD before a window); a multi-asset shortfall partial-fills
  fewer claims (never reverts/mis-pays); the general numeraire conversion is 8-B9/post-M1. **Author+build collapsed
  in one window** (no independent fresh-subagent zero-guess rebuild — same non-blocking caveat as `SzipNavOracle`; the
  kept fork-green code is the source of truth; a fresh window MAY re-materialize from the ticket to close the gate
  formally). Kept on disk, **NOT git-committed** (whole tree untracked; commit decision pending the superintendent/user).
  `reports/Exit-Gate-report.md`. **NEXT = cold-build WOOF-06** (the zap) against the real `gate.depositFor` seam.
- **2026-06-08** (superintendent spec edit — **structural-freeze lock + `DefaultCoordinator` shrink**, user-directed) —
  Resolved a latent spec inconsistency: §6.4 already modeled the Duration-Bond freeze as **structural +
  utilization-sized + owned by the Exit Gate** (the committed slice lives in the sidecar by virtue of being utilized,
  frozen-until-repaid), but §2/§4.5/§4.6/§9/§11/§15 still carried the older "`DefaultCoordinator` **engages** the
  freeze, sized `atRiskAmount/basketNAV` on a default" framing. **User ratified the structural reading.** Swept all
  sites: the freeze is now uniformly **structural/utilization-sized, owned by the Exit Gate**; a default does **not**
  engage it (utilization stays high → the committed slice stays in the sidecar). **`DefaultCoordinator` shrunk** to two
  jobs: (1) write the bounded recoverable **provision into `SzipNavOracle`** (the at-risk amount sizes the *markdown*,
  not the freeze) + (2) run the **xALPHA recovery waterfall** (`slashXAlphaToCapital`/`slashXAlphaToCohort`); the
  freeze cohort storage / `lockedFraction` / objective-release left it entirely → Exit Gate (§6.4). Edited
  `claude-zipcode.md` §2 (line 153 row), §4.5 (guardrail summary), §4.6 (DefaultCoordinator bullet + LienXAlphaEscrow
  M2-carve-out header), §6.4 (item-4 sizing line), §9 (default-path summary), §11 (the two-parts prose + step-2 freeze
  + trigger-A), §15 (loss summary). **`LienXAlphaEscrow` PULLED FORWARD** off M2 (new backlog item **8-Bx**): custody
  half is M1, slash half built + mock-tested now. `DefaultCoordinator` stays M2 (now the markdown-writer shape).
  Report: `reports/design/structural-freeze-shrink-report.md`. No §17 reopened (the freeze model was already locked
  2026-06-05/06-07; this removes a stale residual framing, not a decision). `forge build` still clean.
- **2026-06-08** (superintendent review — **8-B4 zero-guess gate CLOSED**) — Reviewed `reports/8-B4-zerogate.md`
  (the deferred fresh-subagent gate, now run). **Verdict: accept — gate did its job.** Independent from-ticket-alone
  rebuild returned `ZERO-GUESS: NO` with **3 real ticket gaps** (worst: under-specified zero-address setter validation
  two builders silently diverged on; + `Poked` event `uint224`→`uint256`; + `grossBasketValue` internal→public),
  **no bug in the kept code** (keepsake was the stricter/correct build, restored, 39/39 green), all 3 folded into
  `tickets/sodo/8-B4-szip-nav-oracle.md`, no `claude-zipcode.md` edit needed. This discharges the non-blocking
  deferred-gate item I logged in my 8-B4 review. An item returning findings (not zero) is the healthy harness outcome.
- **2026-06-07** (**`SzipNavOracle` (8-B4) BUILT-VERIFIED — the szipUSD NAV-per-share oracle**) — Authored
  `tickets/sodo/8-B4-szip-nav-oracle.md` (build-only, like WOOF-02) through the harness: drafted against `§7` +
  `baal-spec.md §3`; fanned out 5 critics (junior-dev/spec-fidelity/ref-verifier/qa/security). **spec-fidelity =
  clean** (confirmed the 3 spec edits faithful + no stale residue, no §17 reopened, no inbound obligations).
  **Triage:** the only spec gaps were the 3 fixed above (§4.4 reportType 7 / §7 authorities+denominator / §12
  rewrite); everything else was ticket-clarity — folded in: explicit TWAP ring walk-back pseudocode, `uint256
  cumNav` (drop uint224 packing → no overflow ambiguity), definitive flat constructor, `_legPriceOfToken`/
  `_tokenValue`/`supplyLp==0` LP clarity, pinned required-leg set {alphaUSD,HYDX} both always-pushed (HYDX pool
  thin), and the qa edge-case test list. **Unanimous BLOCKER** = `IOptionToken.discount()` absent from the stub
  → added (on-chain verified == 30, selector `0x6b6f4a9d`). Security findings were natspec/downstream-obligation
  (folded as "Documented invariants" + the obligation rows) + two recorded **misanalyses** (the `max`/`min`
  bracket DOES defend issuance/exit against one-block spikes; the ICHI-donation "attack" is unprofitable under
  round-down + pari-passu). **Built + KEPT:** `contracts/src/supply/SzipNavOracle.sol` (`is ReceiverTemplate`,
  ~330 LOC) + `contracts/src/interfaces/bridge/IXAlphaRate.sol` + `contracts/test/SzipNavOracle.t.sol`; `forge
  build` clean (0.8.24) + **39/39 tests** (NAV composition hand-computed, IL-marked-through, windowed-TWAP+bracket,
  ring-wraparound, dt==0, staleness asymmetry, provision immediate/recover/unbounded-floor, atomicity, one-block-
  spike resistance, forwarder-immutability-via-renounce, **+ a live Base-fork sig-verification** of USDC/ICHI/gauge/
  oHYDX faces); **154/154 total, no regression** (`forge test --fork-url $BASE_RPC_URL`). **Caveat (judgment call —
  superintendent please note):** I authored AND built it (the earlier build-subagent dropped on a socket error
  mid-run; couldn't resume — SendMessage unavailable), so the formal *fresh-subagent zero-guess* gate wasn't run
  independently; the build surfaced no ticket contradiction (I implemented exactly the ticket), and the code is
  green+kept+fork-verified (the keep-the-build proof). A fresh window can re-materialize from the ticket alone to
  formally close the zero-guess gate if desired. `reports/8-B4-report.md` written. **NEXT = the Exit Gate +
  szipUSD** (`baal-spec.md §4/§5`) — reads `navEntry`/`navExit`/`poke`, wired via `setShareToken`.
- **2026-06-08** (superintendent review of `SzipNavOracle` (8-B4)) — **VERDICT: on-track; Exit Gate + szipUSD
  released.** Independent checks: (1) **Consistency sweep PASS** — `reportType 7` + `navEntry`/`navExit` coherent
  across `claude-zipcode.md`/ticket/LEDGER/PROGRESS/the contract. (2) **Editing discipline (check 3) PASS** — §4.4
  gained the reportType-7 row, but `audit/2`/`audit/3-results` only trace reportTypes 1/3/4 and the oracle is **not
  yet in the deploy/trace sequence**, so **no audit row was OWED an edit** (correct EXCISE-then-defer — acceptance
  for the reportType-7 CRE producer is owed when the CRE/oracle-acceptance harness is authored, not now; the
  obligation is the recorded "CRE track · NAV leg push" row). (3) **§17 not reopened** — §12 was restated downstream
  of the already-locked two-token model (line 561 marker), §17 text itself untouched. (4) **Keep-the-build** —
  re-ran `forge build` myself: **0 compilation errors, `SzipNavOracle` artifact present**; did NOT re-run the
  fork-gated 39-test suite (builder reports 154/154 + a live-fork sig-verification of USDC/ICHI/gauge/oHYDX). (5)
  **Seams** — all 5 downstream obligations present in the obligations table (Exit-Gate NAV pricing seam, 8-B14
  denominator exclusion, DefaultCoordinator provision bound, item-10 4-setter wiring, CRE reportType-7 push).
  **Rulings on the builder's flagged "your call" items:** (a) **The two security findings = CONFIRMED documented
  invariants, not bugs.** The `max`/`min` bracket defends the profitable direction (navEntry=max → a spot spike-UP
  makes minting *more* expensive; navExit=min → a spike-UP gives no exit-rich), tested by
  `test_one_block_spike_does_not_enable_cheap_mint`; the ICHI-donation "attack" is unprofitable under round-down +
  pari-passu + Gate-is-first-minter + external-leg-price marking. Both sound. (b) **The fresh-subagent zero-guess
  gate (author+build collapsed into one window) = DEFERRED, NOT BLOCKING** — under keep-the-build the kept,
  compiling, fork-verified code is the source of truth (not the ticket), and the Exit Gate consumes the oracle's
  *interface from the real contract on disk*, so it does not depend on the ticket being independently reproducible.
  Precedent differs from WOOF-04 (there the code was discarded, so the rebuild gate was load-bearing). Logged as a
  **non-blocking** open item: a fresh window MAY re-materialize from `tickets/sodo/8-B4-szip-nav-oracle.md` alone to
  formally close the gate if SzipNavOracle ever needs a from-ticket rebuild. **Surfaced to the user (standing
  decision):** the entire working tree — incl. all kept-build code (8-B1, SzipNavOracle, WOOF-00..10a), tickets/,
  reports/ — is **untracked in git**, which contradicts the keep-the-build doctrine's durability intent (a stray
  checkout/rm is unrecoverable). Recommend committing the kept build + bringing `tickets/` under git before the next
  window. **NEXT = Exit Gate + szipUSD** (`baal-spec.md §4/§5`); inbound obligations it must discharge: the
  Gate-manager-grant/zero-Shares invariant + the NAV pricing seam (`poke()` before read, issue off `navEntry` round-
  down, exit off `navExit`, wire `setShareToken`).
- **2026-06-08** (superintendent review of 8-B1 substrate scaffold) — **VERDICT: on-track; accepted.** Went through
  the full harness (5 critics, spec-fidelity clean) — no author+build collapse caveat (unlike 8-B4). Verified: (1)
  the two-tier authority spec edit landed at `claude-zipcode.md §4.5 item-0` (+ `baal-spec.md 8-B1`), **user-ratified**
  ([[szipusd-safe-authority-model]]); (2) the build-discovered factory correction `BAAL_SAFE_PROXY_FACTORY =
  0xC22834581EbC…` is in `BaseAddresses.sol` (computed-then-fail-closed-asserted == `baal.avatar()` — the WOOF-00
  lesson working as designed); (3) **§17 not reopened** — Shares stay 0 forever is *true to* §17, not a change; (4)
  all 3 downstream security obligations recorded in the obligations table (F4.2 no-`mintShares`/`totalShares()==0`
  invariant → Exit Gate; F3.1/F3.2/F5.1/F1.1 → item 10; F6.2 sidecar-funding → item 9). Build kept + green (8/8 fork,
  115/115). No findings requiring rework.
- **2026-06-06** (**WOOF-10a BUILT-VERIFIED — the deploy identity pre-gate**) — Materialized `ZipcodeDeployAsserts`
  + its 5-test suite from the ticket alone against the live WOOF-00..05 keepsakes (the library + test were both
  absent on disk — the old cold-build was discarded under the retired doctrine); **kept committed** at
  `contracts/src/ZipcodeDeployAsserts.sol` + `contracts/test/ZipcodeDeployIdentityGate.t.sol`. `forge build` clean
  (solc 0.8.24); **5/5 PASS — NO fork needed** (the gate is a pure view; the registry ctor's `quote.decimals()` is
  satisfied by a 6-dp mock); 107/107 total, no regression, independently re-run. Build loop: dispatched a build
  subagent, then the superintendent independently (a) re-ran the new suite + full suite, (b) read the library
  source (combined fail-closed `getExpectedWorkflowId()==0 || controller()==0` → `IdentityNotWired`, two inline
  read interfaces, `internal view`), (c) read the test to confirm the assertions are real — the three NEGATIVE
  cases assert the exact `IdentityNotWired(controller, registry)` selector+args, the POSITIVE chain proves
  renounce-then-frozen (`OwnableUnauthorizedAccount` on the three inherited setters + `setController`), and the
  NEGATIVE-CONTROL is the genuine selector-difference dormancy proof on REAL controllers (dormant →
  `UnsupportedReportType(3)`, gate-active → `InvalidWorkflowId(WRONG_WID, WID)`, `abi.encodePacked` metadata).
  **Zero spec-guesses → NO `claude-zipcode.md` edit** (the §9/audit-S11/§4.4 mandate was realized, not invented).
  Gate-portion obligations re-confirmed (item-10 WOOF-05 F-3 + WOOF-02 F7 rows — now build-verified-KEPT, not just
  cold-built). Docs updated: ticket banner, `reports/WOOF-10a-report.md` (rewritten to the kept-code verdict),
  `reports/README.md`, `LEDGER.md`, `superintendent-auditor.md` CURRENT STATE + worklist. **The pure-Euler M1
  contract spine is now ALL real on disk: WOOF-00/01/02/03/04/05/10a.** NEXT code-UNVERIFIED items both have
  external deps: WOOF-06 (mocks for the unbuilt 8-B2/8-Bw seams) + INFLOW-06 (frontend).
- **2026-06-06** (**WOOF-05 BUILT-VERIFIED — the controller / CRE receiver**) — Materialized `ZipcodeController` +
  its 26-test suite from the ticket alone against the live WOOF-00..04 scaffold (the controller was a 2-line stub
  on disk); **kept committed** at `contracts/src/ZipcodeController.sol` + `contracts/test/ZipcodeController.t.sol`.
  `forge build` clean (solc 0.8.24); **`forge test --fork-url $BASE_RPC_URL` 26/26 PASS on a live Base-mainnet
  fork**, independently re-run (102/102 total, no regression). Build loop: dispatched a build subagent to
  materialize, then the superintendent independently (a) re-ran the full fork suite, (b) read the full controller
  source to confirm real logic (the `create→openLine→seed→setLineLimits→fund→draw` ordering, reclaim-before-burn,
  reportType-3-rejected dispatch), (c) confirmed **zero EVC coupling** (only imports `ReceiverTemplate` +
  `IZipcodeVenue` — the "VIOLATION" grep hits were all comments), (d) re-verified the error selectors via `cast`
  (`E_AccountLiquidity()` `0x34373fbc`, `E_BorrowCapExceeded()` `0x6ef90ef1`, `NotAuthorizedOperator()`
  `0x3d9adf1c`), (e) read the live-fork harness `setUp` to confirm it is genuine (live EVC/EVAULT_FACTORY/USDC,
  real WOOF-01/02/03/04, ctor-cycle via `vm.computeCreateAddress` with the prediction asserted, EE mocked but
  depositing real cash). **Live-fork-proven:** the no-controller-operator-wiring origination borrow
  (`isAccountOperatorAuthorized(borrowAccount, adapter)==true` & `(…, controller)==false`), the L4 full transcript,
  batch-atomicity (exact `E_AccountLiquidity()`/`E_BorrowCapExceeded()` selectors + full no-orphan post-state +
  mid-batch rollback then re-origination), draw-a′, close reclaim-before-burn, dispatch/dup, status markers,
  dormant-gate, reentrancy-impossible. **Zero spec-guesses → NO `claude-zipcode.md` edit** (the zero-spec-guess
  keepsake claim confirmed by the real build). Discharged obligations re-confirmed build-verified (item-6 WOOF-01/
  02/04 rows). Docs updated: ticket banner, `reports/WOOF-05-report.md` (rewritten to the kept-code verdict),
  `reports/README.md`, `LEDGER.md`, `README.md` box, `superintendent-auditor.md` CURRENT STATE. NEXT (per the
  superintendent-auditor worklist): WOOF-06 / INFLOW-06 / WOOF-10a remain code-UNVERIFIED.
- **2026-06-06** (**WOOF-04 BUILT-VERIFIED — the venue adapter, the densest item**) — Materialized `IZipcodeVenue`
  + `LineAccount` + `EulerVenueAdapter` + the test from the ticket alone against the live WOOF-00/01/02/03 scaffold;
  **kept committed**. `forge build` clean (solc 0.8.24); **`forge test --fork-url $BASE_RPC_URL` 20/20 PASS on a
  live Base-mainnet fork**, independently re-run (76/76 total, no regression) + all three contract sources read to
  confirm real logic (not circular green-tests). Build loop: dispatched a build subagent to materialize, then the
  superintendent independently (a) re-ran the full fork suite, (b) read every contract, (c) confirmed every
  external interface signature against the real `reference/` interfaces, (d) grounded the AmountCap encode + the EVC
  operator/self-call mechanics against `reference/` BEFORE reading the agent's output. **Live-fork-proven:** the
  two-line distinct-prefix BOTH-draw isolation (real `evc.batch` borrows on distinct `LineAccount` prefixes,
  `debtOf(borrowAccount_A)==drawA` & B cross-independent, revaluation-independence), the operator-grant
  (`isAccountOperatorAuthorized(borrowAccount, adapter)==true` after `openLine`; `getAccountOwner(borrowAccount)==
  lineAccount`; `borrowAccount==lineAccount^1` code-free), foreign-account hook rejection (re-authored WOOF-03 hook
  wired `controller=address(adapter)`), AmountCap round-trip (read back via real `EVault.caps()`, `cap==0`→`ZeroCap`),
  the `!=1e18` `InvalidCollateralAmount` guard (0 + 0.3e18 both revert), router freeze (`governor()==0`, `govSet*`
  reverts), and close-reclaim (operator-routed 4-arg `evc.call` redeem returns the full `1e18`). `EulerEarn` MOCKED
  (0.8.26 pragma) → `fund`'s two-item ABSOLUTE allocation + F3 onboarding-bound are mock-level (live EE = audit
  S9/L4). **Zero spec-guesses; no `claude-zipcode.md` edit** (the build exposed no spec error — unlike WOOF-00). One
  mild ticket gap folded: `submitCap` `capSeed` was undefined → clarified to `type(uint136).max` (mock-level) in
  ticket step 4. The hook↔adapter deploy cycle is the **existing** item-10/WOOF-03 precompute obligation (now
  empirically confirmed as the forced path, not a new gap). **Discharged** the item-5→WOOF-01 obligation (lien
  registered as collateral via live `setLTV` on `COLLAT`). NEXT = **WOOF-05 (`ZipcodeController`)** materialize +
  fork-test against the now-real WOOF-04 venue.
- **2026-06-06** (**WOOF-03 BUILT-VERIFIED — the CRE gating hook**) — Materialized `CREGatingHook` + test from
  the ticket alone against the real WOOF-00/01/02 scaffold; **kept committed**. `forge build` clean (solc 0.8.24);
  **`forge test` 8/8 PASS**, independently re-run (56/56 across all suites, no regression) + source read to confirm
  real logic: 3 immutables (factory/evc/**borrowDriver** — named borrowDriver, NOT controller), minimal local
  `IEVC`/`IGenericFactory` interfaces, `isHookTarget()` returns `0x87439e04` only when `isProxy(msg.sender)`,
  `fallback()` gate = `isAccountOperatorAuthorized(caller, borrowDriver)` reverting `NotAuthorizedOperator()`, and
  the verbatim isProxy-guarded assembly `_msgSender()` extraction. **Confirmed the load-bearing proofs:** the error
  selector is `0x3d9adf1c` (`cast sig`, matches the audit-fixed name in `audit/3-results.md`), and the **spoof-guard**
  rejects a non-proxy caller appending an authorized account (proves `_msgSender` used `msg.sender`, not the
  appended bytes). **Zero-spec-guess keepsake** — every cited reference line accurate (3 clean tickets in a row
  after WOOF-00). Ran the full doc-update checklist. No spec error → `claude-zipcode.md` untouched. **NEXT =
  WOOF-04 (`EulerVenueAdapter` + `LineAccount`) — the DENSEST item** (EVC operator mechanics, AmountCap encode,
  EdgeFactory per-line markets, EulerEarn mocked at 0.8.26): the one most likely to bite. Will fork-test against
  live Base (the RPC is wired).
- **2026-06-06** (**WOOF-02 BUILT-VERIFIED — the oracle registry**) — Materialized `ZipcodeOracleRegistry`
  (`is ReceiverTemplate, BaseAdapter` — the first multiple-inheritance + new-remap build) + its test from the
  ticket alone against the real WOOF-00/01 scaffold; **kept committed**. Added the 2 remaps (`x402-cre-price-alerts/`,
  `@solady/`). `forge build` clean (solc 0.8.24); **`forge test` 34/34 PASS**, independently re-run (no WOOF-00/01
  regression) + contract source read to confirm real logic: two write paths (controller `seedPrice` / Forwarder
  `_processReport` type-3), `_writePrice` guards (price!=0 / ≤uint208 / ts≤now `FutureTimestamp` / strict
  decimals==18), `_strictDecimals` low-level staticcall (rejects EOA + non-18), `_getQuote` with the staleness
  window + `calcOutAmount`, no illegal override of the non-virtual `onReport`/`setForwarderAddress` (immutability
  via renounce). **Confirmed the two load-bearing proofs with eyes on output:** `getQuote(1e18,LIEN,USDC)==equityMark`
  exact, and strict-decimals rejecting a 6-dp token AND a code-less EOA on both paths. **Zero-spec-guess keepsake**
  — every cited reference line accurate, no inheritance/OZ-version surprise (2 clean tickets in a row after
  WOOF-00's 10 wrong sigs). Ran the full doc-update checklist (ticket, report, `reports/README.md`, LEDGER,
  this row+log, root README checkbox + a stale shared-router line fixed, auditor state). No spec error →
  `claude-zipcode.md` untouched. **NEXT = WOOF-03 (`CREGatingHook`):** verify the EVC `isAccountOperatorAuthorized`
  + `BaseHookTarget` inline replication against `reference/`.
- **2026-06-06** (**WOOF-01 BUILT-VERIFIED — first item under the keep-the-build doctrine**) — Materialized
  `LienCollateralToken` + `LienTokenFactory` + `test/LienToken.t.sol` from the ticket alone against the real
  WOOF-00 scaffold and **kept them committed**. `forge build` clean (solc 0.8.24); **`forge test` 14/14 PASS**,
  independently re-run (not trusting the build subagent) + the contract source read to confirm the logic is real,
  not circularly green: plain OZ ERC20, immutable `controller`, mint-once `1e18`, `decimals()` pure-18, `burn`
  via `if/revert NotController` (honors the 0.8.24 `require(cond,Err())` gotcha), no mint/admin; factory
  caller-bound CREATE2 (salt `keccak256(abi.encode(lienId))`), two-arg `computeAddress`, no mapping. **The ticket
  proved a true zero-spec-guess keepsake** — the real build surfaced NO contradiction or wrong citation (unlike
  WOOF-00's 10 wrong sigs + 2 wrong addresses); only 3 cosmetic build choices (param `controller_`, the require
  message, the `IERC20Errors` test import), now pinned in the ticket. Ran the full doc-update checklist (ticket
  banner, report, `reports/README.md`, LEDGER digest, this row + log, root README checkbox, the auditor's CURRENT
  STATE + worklist). No spec error → `claude-zipcode.md` untouched. **NEXT = WOOF-02 (`ZipcodeOracleRegistry`):
  verify `ReceiverTemplate`/`BaseAdapter`/`calcScale` faces against `reference/`; needs WOOF-01 on disk (done).**
- **2026-06-06** (**WOOF-00 materialized for real + DOCTRINE FLIP: keep-the-build**, user-directed) — Actually
  built the WOOF-00 scaffold from the ticket (not just doc-audited it) and **kept it**: `contracts/` now holds a
  real Foundry project that `forge build`s clean (52 files, solc 0.8.24) with all 3 self-checks passing, incl. a
  **live Base-mainnet fork read** via the user's Alchemy RPC (wired into gitignored `contracts/.env`; added `.env`
  patterns to `.gitignore` so the key can't be committed). **The real build exposed what the prose audits never
  could:** (1) a CRE-selector contradiction (ticket said record the Sepolia selector while declaring mainnet the
  target) → fixed to `ethereum-mainnet-base-1`; (2) **10 of 25 guessed external interface signatures were wrong**
  (ICHI `getICHIVault`/`createICHIVault`, IVoter `vote(address[],uint256[])`, `createLock`, `exerciseVe`, NFPM
  `mint`/`positions` structs, etc.) → corrected by selector-probing the live contracts; (3) **two "CONFIRMED,
  repo-authoritative" addresses were the WRONG contract** — the ICHI "vault deployer" `0x7d11…` is a Gnosis Safe
  (real factory `0x2b52c416…`, read from the deposit guard on-chain), and the **Baal summoner labels were
  scrambled** (`0x97Aaa…` is the AdvTokenSummoner; the real `BaalSummoner` is `0x22e0…`, confirmed vs
  `reference/Baal/deployments/base/*.json` + on-chain `template()`); (4) an undocumented NatSpec `@`-in-comment
  solc trap. All fixed on disk + across the authority docs (`BaseAddresses.sol`, `pending-docs/hydrex.md`,
  `claude-zipcode.md` §4, the WOOF-00 ticket + report). **DOCTRINE FLIP (user-ratified):** the "cold-build then
  discard the byproduct / reset `contracts/` to `.gitkeep`" rule is **RETIRED** — it was the root cause of
  unverifiable rotted "PASSED 32/32" claims. New rule: **build for real and KEEP it; the code is the proof, the
  ticket is the intent; verify every signature + address against the live chain.** Written into `kickoff.md`,
  `audit/adversarial-spec/README.md` (steps 4 & 6), and the `superintendent.md` review checklist. **Implication
  logged:** WOOF-01..06 are in the same unverified state (cold-builds discarded) and each needs the same
  materialize-and-verify treatment. **NEXT: materialize WOOF-01 the same way.**
- **2026-06-06** (**superintendent-auditor — holistic alignment sweep of the built set**, `superintendent-auditor.md`) —
  Ran the per-item audit (report+ticket pair) for **all 7 remaining worklist items** (WOOF-01/02/03/04/05/06,
  INFLOW-06, WOOF-10a) via parallel read-only audit subagents, each running internal-coherence + current-view
  alignment + verify-don't-trust against `reference/`, then folded all corrections serially. **Verdicts:** WOOF-04
  + WOOF-05 + INFLOW-06 **ALIGNED** (dense WOOF-04 fact-by-fact verified — EVC/AmountCap/EdgeFactory/`fund` all
  confirmed, zero hardcoded addresses; WOOF-05 pure-subtraction clean); WOOF-01/02/03/06/10a **DRIFT-FIXED.**
  **Drift folded (all stale-after-redesign residue, NO new mechanism):** (1) **per-line-router redesign residue** —
  the retired shared-router `govSetFallbackOracle`/"router fallback resolves" framing swept from `claude-zipcode.md`
  (§4.1 `:291`, §9 origination diagram), `audit/3-results` F4, WOOF-02 (3 spots), WOOF-10a (3 spots), PROGRESS
  obligation row, LEDGER item-10 line → per-line frozen `ROUTER_i` wired in `openLine`. (2) **borrower-model residue** —
  `wireVenueOperator` baked into WOOF-10a's POSITIVE-test setter list (ticket+report, would not compile vs the current
  no-EVC WOOF-05) removed (5 spots); the §4.4/§9 "controller-as-operator" loose prose (a pre-existing spec
  self-contradiction vs the authoritative adapter reconciliation) tightened to name the adapter/borrow-driver (3
  spots in `claude-zipcode.md`). (3) **error-rename residue** — `audit/3-results:169` `NotControllerOperator` →
  `NotAuthorizedOperator` (the real WOOF-03 hook error, sel `0x3d9adf1c`); LEDGER WOOF-04 digest annotated. (4)
  **redesign-lag in the digest/reports** — the **LEDGER WOOF-06 digest still described the DELETED EE-share /
  convert-on-stake model → fully rewritten** to the Baal+`CreditWarehouse` stateless-router (4-arg ctor, `depositFor`,
  no `max` allowance); the LEDGER "Pending" item-8 "DONE (WOOF-07)" → **REDESIGNING (Phase 8-B TODO)**; the WOOF-06
  report's "INFLOW-06 not yet done" → done. (5) **cosmetic** — WOOF-01 OZ cite `v5.0.0`→`v5.0.2`. **No §17 decision
  reopened; no spec GAP (only an internal contradiction fixed); no `contracts/` touched.** **CERTIFICATION: the built
  set (items 1-6, 6i, 10a) is internally coherent and aligned with the current view — coherent to move into the build
  phase.** Remaining non-blockers are the already-tracked item-8 surface (Phase 8-B unbuilt + the two cosmetic §4.5
  `:566-607` / §11 `:1181` convert-on-stake residuals, to clear at 8-B1) and the OPEN item-10 wiring obligations.
- **2026-06-06** (superintendent — WOOF-00 scaffold audit + address verification + **deploy-target decision**) —
  Brought WOOF-00 (ticket + report) up to date: Euler-only → complete multi-ecosystem scaffold under **Strategy A
  (interface + fork)** for Baal/Zodiac/Safe/ICHI/Hydrex (avoids the OZ-4.x/5.0.2 collision; only Euler + OZ-free
  zodiac-core + the 8x Chainlink bridge are source-compiled). **Verified every Base address on-chain** (Basescan +
  `EulerChains.json` + Chainlink forwarder directory): Euler factories, Safe (ProxyFactory 1.3.0 + L2 singleton
  1.4.1), Baal summoner, Zodiac Roles mastercopy + ModuleProxyFactory `0x0000…cDda236`, CRE KeystoneForwarder
  `0xF8344…4482` (**same addr on Base mainnet AND Sepolia**), Hydrex/ICHI via `pending-docs/hydrex.md`. **USER
  DECISION: ship to BASE MAINNET, test there** (not Sepolia) — Base gas is cheap and the farm/vault deps
  (Baal/Safe/ICHI/Hydrex) are 8453-only, so deploy-target = fork-target = Base mainnet; `base`/`ethereum-mainnet-base-1`
  is primary, `base_sepolia` optional. **Broader sweep still owed** (README §2 "Base Sepolia", `audit/2.md` Phase S
  faucet/Sepolia, `claude-zipcode.md` §9, the CRE workflow selector) — see the resolved open-decision below.
- **2026-06-06** (superintendent — README drift sweep + user scope decision) — Swept `README.md` to the Baal/Zodiac
  item-8 design (szipUSD task, §3 recap, loss-side `LienXAlphaEscrow`/`DefaultCoordinator` → withhold + three-lever
  no-markdown, repo-layout map → `supply/szipUSD/` + `supply/CreditWarehouse/`, §2 supply nouns, the stale `sdVAULT`
  treasury bullet → FOLDED INTO item 8). Also fixed the `reports/README.md` index (added #17 8-S3 + #18 zodiac
  research; 8-S3 was stale-marked NEXT). **USER SCOPE DECISION:** the **full Hydrex farm loop IS in the M1 staking
  vault** — the whole 8-B chain (incl. 8-B5…8-B11 farm modules) is M1, NOT deferred. **xALPHA source RESOLVED
  same session (user-directed):** the **CCIP xALPHA bridge is pulled INTO M1** (backlog row `8x`, off DEFERRED),
  AND dev validates the farm-module builds against a **stand-in test xALPHA token** (no blocking on CCT
  registration; real token swaps in) — *"no stalling, but plan on what we need."* See the resolved open-decision
  bullet. NEXT unchanged: first 8-B build ticket (8-Bw / 8-B1), pending the builder-window release.
- **2026-06-06** (superintendent — szipUSD-redesign review + authored **8-S2b** two-Safe custody w/ user) —
  **Reviewed the szipUSD redesign report.** Ratified the reopening (wrong vault genuinely built; Baal+Zodiac
  substrate + withhold/3-lever model coherent in §11/§12/§17/§4.6). **Caught a bigger blast radius than the report
  stated:** (1) **item 7 (WOOF-06, the zap — DONE/17-of-17, I ratified it last cycle) is ORPHANED** — its EE-pool-share
  `stake(amount,shares,receiver)` seam no longer exists under Baal; the item-8 obligation row was falsely marked
  "DISCHARGED (by WOOF-07)" by a now-**deleted** ticket → **VOIDED** it + flagged item-7 re-author. (2) harness
  staleness is broader than the report's "audit/1 only" — `audit/2`/`audit/3-results` also carry old stake/cooldown
  rows. (3) two **unguarded** stale spec seams presented the dead convert-on-stake model as live (§4.5 setStakingVault
  para, §5 zap pseudo-code) → added SUPERSEDED markers. **Then authored 8-S2b with the user** (the senior-custody
  question "where do the EE shares go"): a **two-Safe** split — junior Baal Safe (basket, ragequit) vs a new senior
  **`CreditWarehouse`** Gnosis Safe holding the `EulerEarn` shares, owner **GOD-EOA → multisig**, routine ops via a
  **CRE-Forwarder-gated, scope-restricted** Zodiac `WarehouseAdminModule` (purpose-built fixed op-set 1/2/3 to
  immutable targets — Roles Modifier not vendored → purpose-built is the stronger lock; **no arbitrary `(to,data)`**).
  Grounded in verified Zodiac APIs (`Module.sol:43` exec → `IAvatar.execTransactionFromModule` `:36`; `enableModule`
  `:19`; Roles Modifier confirmed ABSENT from `reference/zodiac`). Threaded into §4.5 (new `CreditWarehouse` bullet) +
  §5 flow + the deposit-module custody marker; added **8-S2b** (spec, DONE) + **8-Bw** (build, TODO) to the
  decomposition; reshaped the item-7 obligation (zap deposits to `WAREHOUSE_SAFE`). **Verified 8-S2b does NOT
  invalidate the just-finished 8-S3/`audit/1`** — that proof is purely economic (`NAV_s=C+D`, `R=NAV_s/Z`), agnostic
  to EE-share custody location (no module/warehouse coupling). **8-S3 REVIEWED — RATIFIED**
  (audit/1 re-derivation I1-I5 + S0-S3; independently re-checked the three-lever algebra closes — lever-1 burns
  full `L` so `σ` preserved and `R=(NAV_s−L)/(Z−L)≥1` iff pre-loss `σ≥0`; levers 2/3 raise `NAV_s` back; spec-faithful,
  §17 not reopened, custody-agnostic so 8-S2b doesn't disturb it). **STILL OWED — UPDATED 2026-06-06 (post-excise):**
  the **dead-text-removal half is DONE** — the dead szipUSD S7/S8 + stake/cooldown + `ν=J×p` rows were EXCISED
  from `audit/2`/`audit/3-results` (replaced with EXCISED/8-B markers; see the 8-S3 entry below). What remains
  owed is the **positive re-authoring**, correctly deferred to build (you can't write acceptance against unbuilt
  interfaces): **8-B1/8-B2/8-B3** ADD the Baal junior acceptance steps; **8-Bw** ADDS the new warehouse deploy
  steps (CreditWarehouse Safe + `WarehouseAdminModule` + opType 1/2/3 pathways + the deposit→`WAREHOUSE_SAFE`
  reshape + the `feeRecipient` wiring). No Foundry CODE to sweep — `contracts/test/` is empty (.gitkeep); the
  assertions are written fresh against I1–I5 at build. (Obligation attached to the 8-Bw + 8-B2 rows.)
  **8-Bw module mechanism RESOLVED 2026-06-06 → B: Zodiac Roles Modifier v2** (user-ratified after a 7-repo +
  web/audit research pass; the 7 Gnosis Guild repos cloned to `reference/`; synthesis in
  `reports/research/zodiac-warehouse-research.md`). Decisive hard truth: no external guard contains an enabled module
  (Tx Guard = owner-path only pre-Safe-1.5.0; `GuardableModule` = voluntary self-policing) → scope must live in
  the enabled contract, so use the *audited* Roles engine over bespoke bytecode for all-senior-backing value.
  §4.5 + the 8-S2b/8-Bw rows finalized to Roles v2 (admin = Roles Modifier scoped by an owner-applied policy;
  CRE = a thin `is ReceiverTemplate` role-member adapter → `execTransactionWithRole`). Earlier "purpose-built is
  the stronger lock" lean was corrected by the research (true only with a dedicated module audit). NEXT = 8-Bw
  (senior warehouse) and/or 8-B1 (junior scaffold), both unblocked; item-7 re-author waits on 8-Bw + 8-B2.
- **2026-06-06** (item **8-S3** — `audit/1` re-derivation; spec EDIT, not a build ticket) — Re-derived
  `audit/1-results.md` from the dead pool-share/`J×p`/`Burn=loss/p`/escrow proof to the **Baal/withhold money
  model**, matching the already-rewritten §2/§4.5/§4.6/§11/§12/§17. **New invariants:** I1 senior solvency
  `NAV_s/Z≥1` (`NAV_s = idle USDC + marked loans`; the Safe's zipUSD is part of `Z`, which is why lever-1 burn
  works) · I2 subordination (junior basket bears `L` first, then `σ`, then senior) · I3 ragequit
  value-preservation (in-kind pro-rata, `B/Loot` invariant, no oracle in exit) · I4 freeze neutrality
  (`lockedFraction = atRisk/B`, moves no value) · I5 three-lever loss-realization (burn / sell-yield /
  sell-xALPHA, each restores `R≥1` + shrinks `B` by `L`). **Scenarios:** S0 baseline (deposit→draw→interest =
  the **protocol's** σ → xALPHA subsidy + HYDX vamp = the **junior's** pay → ragequit) · S1 freeze + recovery
  (value-neutral, junior whole + xALPHA premium) · S2 the three levers (one confirmed-loss row → 3 mutually
  exclusive branches, all land `B=160,000` + `R≥1` + `σ=16,000` intact) · S3 insolvency boundary (junior
  exhausted first, then I1 fails exactly once). Key derived property: **strict junior-first-loss + surplus
  preserved survives the redesign, mechanism-changed** (withhold during duration; basket realization on
  confirmed shortfall; no markdown machinery). Verified all arithmetic. **Spec-changes-recommended = None** —
  §2/§4.5/§4.6/§11/§12/§17 close arithmetically; no gap or under-specification surfaced. **Phase 8-S is now
  COMPLETE.** Wrote `reports/design/8-S3-report.md`. **Follow-up same day (user-directed): EXCISED the stale
  convert-on-stake junior subset** from `audit/2.md` (scope loop, SZIPUSD symbol row, S7 szipUSD stack, S8
  `feeRecipient=SZIPUSD`, L3 stake, L6 fee-to-szipUSD, L12 cooldown+unstake, N3/N4 exit-gate, the `ν=J×p`
  I1-sanity refs) and `audit/3-results.md` (matrix rows 25–27 + burn row 17, Trace E, the run-fairness/below-floor
  failure-mode rows, the §5 orphan szipUSD row, §6 open items 1+4, the §7 acceptance statement). Each is
  replaced with an **EXCISED / 8-B marker** — no dead convert-on-stake text survives, and nothing was rewritten
  against the not-yet-built Baal interfaces. The Baal junior acceptance is authored at **8-B1/8-B2/8-B3**;
  the senior-custody + ESynth-authority + perf-fee `feeRecipient` re-align at **8-S2b (two-Safe custody, in
  design in another window)**. **NEXT = 8-B1** (Baal + Safe + Loot + shaman/Zodiac scaffold), the first build
  ticket; the two cosmetic §4.5 `:566-607` / §11 `:1181` residuals delete when 8-B1 is authored.
- **2026-06-06** (item 8 REDESIGN — user-directed; WOOF-07 was the WRONG vault) — The 2026-06-05 WOOF-07 +
  INFLOW-08 (ERC-4626 convert-on-stake over EulerEarn loan-book pool shares) were **deleted** — user confirmed
  szipUSD is NOT that. szipUSD is the **auto-sodomizer junior NAV vault** (`pending-docs/auto-sodomizer.md` +
  `hydrex.md`): pools zipUSD, accrues xALPHA, holds + **gauge-farms** a zipUSD/xALPHA **ICHI LP** on Hydrex
  (oHYDX → exercise → HYDX → USDC → recycle), tracks **NAV in zipUSD**, bears **residual first-loss** (markdown
  after the secondary → insurance → xALPHA → HYDX-farmed-USDC waterfall), CRE-operated, ~30d epoch lock + freeze.
  **Root cause:** the supply-side-redesign changed the *framing* (xALPHA subsidy) but left the convert-on-stake
  *substrate* in §4.5/§11/§17 + `audit/1` intact and deferred the reconciliation "to when item 8 is authored" —
  which I dropped, building the stale substrate. **Substrate decided = Baal (Moloch v3) + Zodiac** (two
  comparison agents scored 7540 33/50 vs Baal 29/50, but the user **reversed the interim 7540 lean** — 7540's
  win was only single-asset-exit + 4626-composability, both of which we don't need; Baal wins native multi-asset
  Safe custody + oracle-free ragequit loss-socialization + programmable shaman/Zodiac control). Share = **Loot**;
  treasury = **Gnosis Safe** (basket-native, multi-strategy via multiple Zodiac modules); exit = **ragequit**
  (in-kind); **NAV = tracked/displayed from multiple oracles**, not a redemption primitive; **LOCK** (~30d
  cooldown, lock-shaman) + **FREEZE** (duration bond) gates. **First-loss = WITHHOLD the at-risk zipUSD from
  ragequit (user correction), NOT a markdown/seizure** — frozen capital keeps earning; unrecoverable residual
  socializes passively. Baal + Zodiac cloned into `reference/` (0.8.7 → summon + fork-test). **Validate by
  Foundry FORK of live Base** (real ICHI/gauge/oHYDX/NFPM/EulerEarn, stand-in gauge addrs; swap for production).
  **Decomposes into ~4–5 tickets** (Baal+Safe setup / strategy modules incl. reservoir+borrow / ICHI-LP+gauge /
  CRE robot / dashboard+NAV-oracles). **This window:** deleted
  WOOF-07/INFLOW-08/report, added a SUPERSEDED guardrail block to §4.5, re-pointed item 8. **Pending (still
  managing):** the coordinated §5/§6.4/§11/§12/§17 + audit/1 money-model rewrite, then the ticket decomposition.
  Plan: `~/.claude/plans/don-t-be-dropping-deferrals-quirky-ocean.md`. **NEXT: settle the money-model rewrite
  scope with the user, then author the vault ticket (#1 of the decomposition) fork-tested against live Base.**
- **2026-06-05** (item 8 — `szipUSD` the freezable junior vault — AUTHORED **WOOF-07 + INFLOW-08**, build +
  interface) — Authored item 8 through the full 6-critic harness (junior/spec-fidelity/ref-verifier/qa/security/
  frontend) + cold-build. **Design:** `SZIPUSD is ERC4626, Ownable, ReentrancyGuard`, asset = the `EulerEarn`
  pool share; `_decimalsOffset()=12` → **18-dp** + a `1e12` virtual-share inflation defense; `totalAssets()` =
  its own pool-share balance (the perf-fee fee-shares accrue structurally → NAV, the M1 mechanical routing).
  **stake** (convert zipUSD→szipUSD): 3-arg exact-shares core (the WOOF-06 seam) + 2-arg conservative direct +
  `previewStake`; **unstake** (the inverse): cooldown/floor/freeze-gated, **returns pool shares to the module +
  mints zipUSD** (`convertToAssets×scaleUp`, the realized yield), USDC exit = the queue. Replicated `sUSD3`
  cooldown (struct+startCooldown+window+`availableWithdrawLimit` three-cap); governed share-denominated floor;
  Duration-Bond **freeze seam** (owner-replaceable `lossCoordinator`/`frozenBps`/`freeze`, M2 drives it). **The
  security critic caught a CRITICAL drain (F-CRIT):** the 3-arg `stake` decouples burned `amount` from pulled
  `shares` over the module's `max` allowance → a public caller could `stake(1, ALL_MODULE_SHARES, attacker)` and
  drain the entire senior backing → **fixed: the 3-arg core is module-only** (`NotModule`), direct stakers use
  the 2-arg (binds shares to amount). junior-dev caught a real `_consumeCooldown` underflow (cooldownDuration==0
  path) → made it total; spec-fidelity confirmed the exit resolution + caught the §17 stale-USDC-leg + the
  overstated "M1 keeps junior yield" framing; qa added the round-trip-I1/rounding-direction-solvency/multi-
  staker/capacity-exhaustion/atomicity tests; ref-verifier cleared all sources (sUSD3 AGPL→replicate, EE
  0.8.26→mock, real ESynth over live EVC, OZ ERC4626 `_decimalsOffset`/previews/virtual mutators). **Spec edits:**
  §4.5 exit mechanism (struck "for USDC", added module-only-3-arg + 18-dp + M1 scope), §17 L1334 stale leg,
  `audit/2.md` L12/N3/N4/S7 (see Open spec gaps). **Cold-build = NO→folded, 36/36 green** (real `ESynth` + live
  EVC + par/non-par EE mocks + module mock + 256-run fuzz): the F-CRIT drain test, round-trip I1 solvency,
  rounding-direction fuzz (`zipOut <= value-returned`, global over-backing), cooldown==0 no-underflow, capacity
  exhaustion all pass. **Two narrow findings folded:** (1) the `setCooldownDuration<=90d` bound + ctor
  `zipDec==18&&poolDec==6` invariant referenced no error → added `InvalidDuration()`/`InvalidDecimals()`; (2) the
  capacity-accounting premise was inaccurate vs real `ESynth.burn` (`minted` floors at 0, not "always 0") →
  corrected the rationale (grant `max` still required: stake-burns bank no credit, an exit-wave accumulates the
  full unstake total) in WOOF-07 + `audit/2.md` S7. Both low-risk/additive (error-naming + doc-rationale; the
  built logic was correct + tested). **Discharged the WOOF-06 `ISzipUSD` obligation** (F4 by immutability, not
  renounce — item 10's S7 check must assert `owner()==TIMELOCK`, not `==0`); **created obligations on item 10**
  (S7/S8 wiring: deploy after the module, capacity-max, `setStakingVault`, `setFeeRecipient`, owner=timelock,
  `lossCoordinator` stays 0 in M1) **+ M2** (`DefaultCoordinator` drives the freeze seam). Byproduct discarded;
  `contracts/` back to skeleton. Wrote `reports/WOOF-07-report.md`. **NEXT: item 9 (`ZipRedemptionQueue`, §4.5/
  §6.1 — the senior zipUSD→USDC 30-day epoch queue; build).**
- **2026-06-05** (superintendent review of WOOF-06) — **VERDICT: on-track WITH one seam fix applied; item 8
  released.** **Independently reference-verified the load-bearing decimals correction** (the WOOF-04 AmountCap
  lesson): `ESynth.sol:36-41` ctor is `(evc, name, symbol)` with NO decimals override → inherits OZ-18
  (CONFIRMED); EulerEarn does **not** override `decimals()`, inherits OZ ERC4626 `decimals()==asset.decimals()`
  → 6-dp over USDC (CONFIRMED conclusion). One nuance: `VIRTUAL_AMOUNT=1e6` (`ConstantsLib.sol:22-23`) is an
  exchange-rate/inflation virtual amount, **not** a decimals offset — but the spec text (`:493`) states "offset 0"
  and "VIRTUAL_AMOUNT → shares ≈ assets at par" as *separate* correct facts, so no spec error; and the module
  derives `scaleUp = 10**(zipDec-usdcDec)` at runtime (robust, not a hard-coded 1e12). **Found one real
  consistency bug:** `claude-zipcode.md:500` (the §4.5 szipUSD-seam para) still described the **zap's** stake leg
  calling the **2-arg** `stake(amount, receiver)` — the exact recompute path **F1 was created to eliminate** — while
  §4.5 `:517`/`:528-538`, §5 flow `:677`, and audit/2.md `:226` all have the zap calling the **3-arg exact-shares**
  `stake(amount, sharesRcvd, receiver)` (2-arg is the *direct* non-zap convenience only). A stale pre-F1 line on
  the precise seam item 8 builds NEXT → if read first, would re-introduce the over-pull bug. **Fixed on disk**
  (`:500` → 3-arg exact-shares, points at the F1 block; faithful consistency correction, no new decision, no §17
  reopened). **Judgment-call rulings:** (A) keep zipUSD on `ESynth` (18-dp) + ctor-derived `scaleUp` over a custom
  6-dp synth — ACCEPT (smallest deviation; the money-model zipUSD=ESynth is locked; runtime-derived scale is the
  robust choice). (B) module-as-custodian + set-once `setStakingVault` granting `max` EE-share allowance — ACCEPT
  (avoids the reentrancy a gated push would add) **provided** szipUSD is owner-renounced/immutable at wiring +
  reciprocal binding checked before renounce — both pinned as item-8 F4 + item-10 F5 obligations (verified present,
  well-formed). (C) F1 2→3-arg exact-shares seam change — ACCEPT as faithful, not over-engineering: the
  independent-Floor over-pull (1 wei once share_price>1, nibbling aggregate senior backing, breaks I1) is a real
  correctness defect for a money-routing contract; capture-the-deposit-return is nearly free; the direct path's
  conservative `convertToShares` (monotonic ⇒ never over-pulls) is correct. (D) 6 critics + frontend back-pressure
  satisfied (no missing contract surface) — correct tiering for a user-facing money router. (E) cold-build YES 17/17
  on the final folded ticket (gate met up front, no WOOF-04-style fold-back-without-rebuild). Consistency sweep
  otherwise clean (seam sig / `scaleUp` / `setStakingVault` identical across spec/audit/WOOF-06/INFLOW-06);
  byproduct discarded (`contracts/src` bare); §17 untouched; §4.5 gap RESOLVED. **Standing carry to item 8:** it
  MUST discharge the `ISzipUSD` seam exactly as pinned — 3-arg exact-shares core that pulls **exactly `shares`**
  (no `share_price` recompute, F1), AND be **owner-renounced/immutable** at wiring (F4, it holds a `max` allowance
  over ALL senior backing). NEXT = item 8 (`szipUSD`, §4.5/§6.4/§11; build + interface).
- **2026-06-05** (item 7 — the zap — AUTHORED **WOOF-06 + INFLOW-06**, first user-facing item → build +
  interface) — Authored item 7 (`ZipDepositModule`, §4.5) through the full 6-critic harness (junior /
  spec-fidelity / ref-verifier / qa / security / frontend). **Resolved the three deferred §4.5 zap gaps** +
  surfaced **two reference-verified corrections** the prior windows had carried wrong: **zipUSD = `ESynth` is
  fixed 18-dp** (the audit's `, 6 decimals` ctor was impossible) and **`EE_POOL` shares are 6-dp** (not 18) — so
  "1:1" is **value**-1:1, module mints `usdc * 1e12`. **Design:** the **module is the protocol-side EE-share
  custodian**; `deposit` mints zipUSD to the user + parks USDC in `EE_POOL` (module holds shares); `zap` mints
  to the module (transient), captures the `EE_POOL.deposit` share return, and calls `szipUSD.stake(zipAmount,
  sharesRcvd, user)` (on-behalf, exact-shares); a **set-once `setStakingVault`** grants szipUSD the EE-share
  allowance. **Spec edits:** §4.5 (both bullets — stake seam `stake(amount, shares, receiver)`, custody, decimals,
  the F1 "why `shares` is explicit" block), §5 (flow), §9 (S7 `setStakingVault`) + `audit/2.md` (S7 3-arg ctor /
  szipUSD-takes-module / decimals convention, L1/L2/L3). **No §17 reopened.** Critics: spec-fidelity +
  ref-verifier **clean** (all sources resolve; ESynth real `^0.8.0`, EE mocked `0.8.26`); junior/qa folded ~20
  test/clarity pins; **security F1 (MED) — the one real bug:** the recompute-shares-from-`share_price` pull could
  Floor-over-pull 1 wei from aggregate senior backing → fixed by passing the deposit's exact share return
  (spec + ticket). Frontend: **no missing contract surface** (back-pressure satisfied) + 4 INFLOW modeling
  corrections (`VaultFormInfoBlock` doesn't preview output; `OperationReviewModal` is SDK-plan-gated → fork;
  write via `@wagmi/vue useSendTransaction`+`encodeFunctionData` not `writeContract`; reads via direct
  `readContract`, add an `allowance` fragment). **Cold-build = YES, zero load-bearing guesses** — real `ESynth` +
  live EVC + par/non-par `EE_POOL` mocks + `ISzipUSD` mock + 6-dp USDC mock; `forge build` clean + **17/17**
  green; the **F1 exact-shares pass proven load-bearing** (non-par mock where a recompute would diverge 1 wei —
  the module forwards the captured `sharesRcvd`, asserted no aggregate nibbled). Negative selectors:
  `E_CapacityReached`, `ReentrancyGuardReentrantCall` (`0xc31eb0e0`), `NotWired`, `ZeroAmount`,
  `NotDeployer`/`AlreadyWired`/`ZeroAddress`. Created obligations on **item 8** (the `ISzipUSD` seam:
  3-arg exact-shares core + 2-arg direct convenience + `previewStake`; ctor-takes-module; szipUSD
  owner-renounced before the `max` allowance) and **item 10** (S7 wiring: 3-arg ctor, capacities,
  szipUSD-after-module, set-once `setStakingVault` + reciprocal binding check, renounce-after-wiring). Byproduct
  discarded; `contracts/` back to skeleton. Wrote `reports/WOOF-06-report.md`. **NEXT: item 8 (`szipUSD` — the
  freezable junior vault shell, §4.5/§6.4/§11; build + interface).**
- **2026-06-05** (borrower-model rework — STEP 2c, RE-AUTHOR WOOF-05 — **migration COMPLETE**) — Re-authored
  **WOOF-05** (`ZipcodeController`, §4.4) to the fresh-per-line-borrower model. **A pure SUBTRACTION** — the
  controller got simpler: **REMOVED** `wireVenueOperator(address evc)` + the blanket `setOperator(prefix, venue,
  ~uint256(1))` + the EVC parameter/import + the `~uint256(1)`/sub-account/F-1/F-2 reasoning **entirely**. The
  controller now takes **no EVC handle** and **touches no EVC type at all** — the per-line operator grant is
  issued inside `VENUE.openLine` by the adapter's `LineAccount` (`EVC.setAccountOperator(borrowAccount, adapter,
  true)`, WOOF-04), granting **the adapter** (the `EVC.call` borrow-driver). Ctor confirmed 5-arg
  `(forwarder, venue, lienFactory, oracleRegistry, erebor)` — **no EVC**. **Everything else PRESERVED unchanged**
  (the controller drives the venue purely through the venue-neutral `IZipcodeVenue`, which is unchanged): the
  `onReport` Forwarder+identity gate (immutable via renounce), `_processReport` envelope-decode + dispatch
  (1 origination / 2 draw / 4 close / 5,6 status markers / 3 rejected / else `UnsupportedReportType`), the
  origination atomic batch `create → openLine → seed → setLineLimits → fund → draw`, the close branch
  (`observeDebt==0 → closeLine → burn(1e18)`), the lien custody (`approve(venue, 1e18)`, full-`1e18` guard, the
  `erebor` draw receiver), the seed via `registry.seedPrice` on the openLine-returned `oracleKey`, and the
  **dormant-identity-gate (F-3)** demo. **NO `claude-zipcode.md` edit needed** — §4.4 (`:380-383`) + §9
  (`:915-920`) already state the controller takes no EVC handle and there is no controller-level operator-wiring
  step (Step-1 / WOOF-04 edits); spec-fidelity confirmed. **NO §17 reopened** (supply-side yield/xALPHA/szipUSD
  untouched). Inline critics (junior/spec-fidelity/ref-verifier/qa/security) — no spec gap, no ticket gap beyond
  the subtraction. **Cold-build = YES, zero load-bearing guesses** (rebuilt WOOF-00 scaffold + WOOF-01 lien
  token/factory + WOOF-02 real registry + WOOF-03 re-authored hook + WOOF-04 re-authored adapter incl.
  `LineAccount` + the controller + a 17-test suite; **live EVK `GenericFactory`/EVault/EVC/EulerRouter** borrow,
  EulerEarn + baseUsdcMarket mocked): `forge build` clean + `forge test` **17/17** green. **THE re-author proof**
  (`test_origination_liveBorrow_noControllerOperatorWiring`): the full origination borrow **succeeds with NO
  controller operator-wiring** (the controller has no EVC handle to call) — the live borrow is authorized because
  the adapter's `LineAccount` granted the adapter the EVC operator bit inside `openLine`; asserted directly
  `isAccountOperatorAuthorized(borrowAccount, adapter)==true` AND `(…, controller)==false`
  (`EthereumVaultConnector.sol:286`). The old before/after-`wireVenueOperator` negative-control + the
  `sub_0`-exclusion assertion are **removed** (no controller prefix/sub-account exists). Other live proofs:
  over-LTV → **`E_AccountLiquidity()`** (the LTV check, trace-confirmed NOT `E_InsufficientCash` — the mock
  pre-funds), cap → **`E_BorrowCapExceeded()`**, mid-batch `equityMark=0` rolls the lien+`LineAccount` CREATE2
  deploys back (no orphan), close reclaims `1e18` via operator-routed redeem + `burn` → totalSupply 0, type-2
  draw exact, dispatch reject (`UnsupportedReportType(3)`=`0x2c50a628`, `7`, `0`), dup `LienExists`, dormant-gate
  (wrong-id accepted dormant → after `setExpectedWorkflowId` reverts `InvalidWorkflowId`), post-renounce setters
  revert. **Discharged all four item-6 inbound obligations** (operator-at-origin/seed/custody/full-lien from
  WOOF-04; atomic-batch seed from WOOF-02; reclaim-before-burn from WOOF-01); item-10's `wireVenueOperator`-
  before-renounce obligation stays **REMOVED** (already struck by the WOOF-04 window). Byproduct discarded;
  `contracts/` back to skeleton. Wrote `reports/WOOF-05-report.md`. **THE BORROWER-MODEL REWORK IS
  COMPLETE — WOOF-03/04/05 all re-authored + cold-build-proven.** NEXT: item 7 (`ZipDepositModule` — the zap,
  §4.5; build + interface).
- **2026-06-05** (superintendent review — borrower-model rework, Steps 2a/2b/2c + the WOOF-03 reconcile) —
  **VERDICT: rework RATIFIED, complete.** Verified on disk across all three re-authors: (1) **WOOF-03** gate
  change to `isAccountOperatorAuthorized` confirmed against EVC `:286`/`:1205-1221`; cold-build 5/5. (2) Caught a
  **cross-ticket seam** WOOF-04 surfaced — the EVC operator is the **adapter** (the `EVC.call` caller), not the
  controller, so the hook's gated immutable had to be the adapter; the WOOF-03 ticket + §4.3 still said
  "controller" (a naming trap). **Required + ran a reconcile window:** immutable renamed `controller →
  borrowDriver`, wired to the adapter, §4.3 + WOOF-03 + audit all swept; cold-build 6/6, selector
  `NotAuthorizedOperator`. (3) **WOOF-04** `LineAccount` mechanism verified against the EVC code-free constraint
  (`:787-789`) — mechanically mandatory, not invented; cold-build 15/15 incl. the two-distinct-prefix both-draw
  isolation proof. (4) **WOOF-05** full EVC subtraction RATIFIED (controller takes **zero** EVC handle — cleaner
  venue-neutrality; the intended end state); cold-build 17/17 proving live origination with NO controller
  operator-wiring. §17 supply-side yield/xALPHA decisions confirmed un-clobbered throughout; `contracts/` clean.
  **One real finding folded in:** the WOOF-05 integrated cold-build exposed that **WOOF-04's `fund` under-specified
  `baseBalance`** — the obvious `maxWithdraw` read is cash-capped and breaks the 2nd line's `fund` once cash is
  borrowed out. Pinned WOOF-04's `fund` to `convertToAssets(balanceOf(EE_POOL))` (NOT `maxWithdraw`), the read the
  WOOF-05 cold-build proved (17/17). **The 255-line ceiling is gone; lines are now unbounded + fully disposable.**
  NEXT unchanged: item 7 (the zap, §4.5).
- **2026-06-05** (borrower-model rework — STEP 2b, RE-AUTHOR WOOF-04) — Re-authored **WOOF-04** (`IZipcodeVenue` +
  `EulerVenueAdapter` + the new **`LineAccount`**, §4.7) to the fresh-per-line-borrower model. **The borrower-account
  change:** OLD `sub_i = controller XOR subId` controller sub-account (+ `subId` counter + blanket
  `setOperator(prefix, venue, ~uint256(1))`, 255-line cap) → `openLine` **CREATE2-deploys a minimal `LineAccount`**
  (salt = `lienId`) whose **constructor** registers its own fresh prefix and grants the EVC operator bit over a
  **code-free** `borrowAccount = address(lineAccount) ^ 1` via `EVC.setAccountOperator(borrowAccount, operator, true)`
  (owner-self path, `EthereumVaultConnector.sol:364-401`; code-free guard `:787` passes; prefix registered `:772-774`);
  `draw` borrows via `EVC.batch([enableController self-call, enableCollateral self-call, IBorrowing.borrow])` on-behalf
  of `borrowAccount`; `closeLine` redeems the lien out via the operator-routed `EVC.call`. **Unbounded disposable
  lines** — no `subId`, no controller sub-account, no blanket grant. Everything else PRESERVED (per-line escrow vault +
  USDC borrow vault + dedicated frozen `EulerRouter` wired escrow→lien→registry; EE `baseUsdcMarket` two-item
  `reallocate`; AmountCap `(mantissa<<6)|exponent` reject-0; `draw` receiver pinned to Erebor; `liquidate` =
  `NotImplemented`; `collateralAmount == 1e18` guard; EulerEarn mocked). **SPEC CLARIFICATION (mechanism, EVC-forced,
  no new decision):** the granted operator + the §4.3 hook's `controller` immutable are the address that actually makes
  the `EVC.call` — **the adapter** (the controller drives the borrow through `IZipcodeVenue.draw`). Edited §4.4
  (borrower-of-record para) + §4.3 (caller-semantics) + §4.7 (table row) + §17 (gating-hook resolved line) to say
  "borrow-driver = adapter." **TIDY:** STRUCK the superseded §17 "Hook gating uses an EVC owner check" line (content
  preserved in the §17 borrower-of-record resolved block); swept stale `ZIP_CONTROLLER_SUB(1)`/`sub_i`/`wireVenueOperator`
  refs in `audit/2.md` (S6 step removed, the sub-account-convention note, L4/L6/L7/L8 → `LINE_BORROW_ACCOUNT`) +
  `audit/3-results.md` (access-control row 185 → per-line `LineAccount` grant; row 160 → adapter-as-operator).
  **Cold-build = YES, zero load-bearing guesses** (rebuilt WOOF-00 scaffold + WOOF-01 lien token/factory + WOOF-02 real
  registry + WOOF-03 re-authored hook + the new `LineAccount` + adapter + 15-test suite; **live EVK/EVC/EulerRouter**,
  EulerEarn + baseUsdcMarket mocked): `forge build` clean + `forge test` **15/15** green. The load-bearing proofs:
  **two lines with distinct `LineAccount` prefixes both draw** (`test_twoLines_distinctPrefixes_bothDraw` — distinct
  prefixes asserted via `EVC.getAddressPrefix`, debts isolated); the grant authorizes the **adapter** over each
  `borrowAccount` (`isAccountOperatorAuthorized(borrowAccount, adapter)==true`, `false` for the controller + foreign
  accounts); a **foreign account's borrow is rejected by the re-authored hook** (`CREGatingHook::fallback` →
  `NotControllerOperator(foreign)` `0xbc031a1a`, wrapped `HookReverted` `0xf4844814`); revaluation-independence; over-LTV
  revert; `closeLine` reclaims `1e18` to the controller; router frozen (`governor()==0`); double-`openLine` same `lienId`
  reverts (CREATE2 collision). EVC mechanics verified against `reference/` (operator-on-behalf `enableController`/
  `enableCollateral` `onlyOwnerOrOperator` `:419,:465`; `EVC.call` 4-arg + self-call invariants `:888-895`;
  `authenticateCaller` `:903`). Byproduct discarded; `contracts/` back to skeleton. Wrote `reports/WOOF-04-report.md`.
  **NEXT: Step 2c — re-author WOOF-05 (`ZipcodeController`).**
- **2026-06-05** (borrower-model rework — STEP 2a, RE-AUTHOR WOOF-03) — Re-authored **WOOF-03** (`CREGatingHook`,
  §4.3) to the fresh-per-line-borrower model. **The only semantic change: the gate** `EVC.haveCommonOwner(caller,
  controller)` (owner check) → **`EVC.isAccountOperatorAuthorized(caller, controller)`** (operator-authorization,
  `EthereumVaultConnector.sol:286`, internal `:1205-1221`, fail-closed for unregistered prefix `:1213`) — each line
  now borrows on a fresh per-line account (own prefix, controller-as-operator, §4.4), so the owner check is false for
  every line. Everything else preserved unchanged (inline `BaseHookTarget` replication `:26-41`; three ctor
  immutables = `GenericFactory`/EVC/controller; `isProxy`-guarded `isHookTarget()` returning `0x87439e04`; the
  `isProxy`-guarded `_msgSender()` `shr(96, calldataload(sub(calldatasize(),20)))`; `OP_REPAY` never hooked; named
  custom error → `HookReverted`). **Inline critics** (junior-dev/spec-fidelity/ref-verifier/security) — no ticket
  gap; the new operator-auth gate is at least as strong as (and strictly more isolated than) the old owner check.
  **Consequence sweep (Step-1 leftover, faithful to the ratified model):** swept the stale `haveCommonOwner` gate
  refs in the audit harness — `audit/2.md` S5/L4-post/N1/N1b (`ZIP_CONTROLLER_SUB(1)`→`LINE_BORROW_ACCOUNT`,
  `:250`→`:286`) + `audit/3-results.md` rows 9/10, the access-control preamble, Trace A hop 9/10, and the attack
  table. **No `claude-zipcode.md` edit needed** (§4.3/§4.4 already specify the operator-auth gate, from Step 1).
  **Cold-build = YES, zero load-bearing guesses** (`forge build` clean; `forge test` **5/5** green against a mock
  `GenericFactory` + mock EVC): (a) `isHookTarget()`→`0x87439e04` from proxy / `0x0` from non-proxy; (b) authorized
  line account passes; (c) foreign account → `NotControllerOperator` (`0xbc031a1a`); (d) **non-proxy spoof rejected**
  and the reverted arg is the EOA (not the spoofed appended bytes — proves the `isProxy`-guard used `msg.sender`);
  (e) op-agnostic gate. The lone build hiccup was a test-harness `vm.prank`(single-use)→`vm.startPrank` fix, NOT a
  contract/ticket gap. Byproduct discarded; `contracts/` back to skeleton. Wrote the WOOF-03 report (`reports/WOOF-03-report.md`, later consolidated with the reconcile).
  **NEXT: Step 2 — re-author WOOF-04 (then WOOF-05).**
- **2026-06-05** (borrower-model rework — STEP 1, SPEC EDIT only; superintendent-released, did NOT author a ticket) —
  Replaced the on-chain borrower-of-record model in `claude-zipcode.md`: the old "controller EVC sub-account *i* ↔
  market *i*" scheme (hard 255-line cap; blanket `setOperator(prefix, venue, ~uint256(1))`; `haveCommonOwner` gate)
  → **a fresh per-line EVC account (CREATE2 `LineAccount`) with the controller wired as that account's EVC operator**
  → **unbounded, fully disposable per-loan clusters** (on-chain "graveyard" accepted). **EVC mechanism verified
  against the reference** (`EthereumVaultConnector.sol`): operator can borrow on-behalf of a fresh account
  (`call`→`authenticateCaller(allowOperator:true)` `:782`); op-auth is prefix-owner-keyed (`:1213`) and the
  borrow account must be **code-free** (`:786-789`) → per-line `LineAccount` deploys, registers its own prefix,
  and grants `setAccountOperator(borrowAccount, controller, true)` (`:364`) on a code-free sub-account it owns; the
  hook gates on `isAccountOperatorAuthorized(borrowAccount, controller)` (`:286`). **Edited §4.3 (gate primitive),
  §4.4 (borrower-of-record mechanism + ctor note + branch-a realization), §4.7 (`openLine` deploys `LineAccount`,
  `draw` via operator `call`, table rows), §17 (two new resolved decisions; retired the superseded owner-check line),
  §9 (no controller-level operator wiring; trace), §10/M1 trace.** Ledgers: WOOF-03/04/05 → **RE-AUTHOR PENDING
  (dep-order 03→04→05)**; the 255-line-ceiling carry **STRUCK** (dissolved); the controller operator-wiring +
  item-10 `wireVenueOperator`-before-renounce obligations reworked/removed; WOOF-10a confirmed independent + untouched.
  Wrote `reports/design/borrower-model-spec-report.md`. `contracts/` untouched (no cold-build — spec edit). **NEXT: Step 2 —
  re-author WOOF-03, then WOOF-04, then WOOF-05.**
- **2026-06-05** (item 7 window — concluded on a SPEC FIX, not a ticket) — Opened to author item 7 (the zap) and
  hit a genuine spec hole (the share-custody seam, which `audit/2.md:198` itself punts). Surfacing it opened a
  long user design session that **reshaped the supply side** (see the RESOLVED entry in Open-decisions). Executed
  the spec surgery: `claude-zipcode.md` §2 (xALPHA=xALPHA identity + szipUSD=freezable vault share), §4.5 (szipUSD
  vault shell + sdVAULT-as-post-M1-engine), §6.4 (freeze = redemption-gate-with-boost, zipUSD never freezes),
  §7 (xALPHA feed rename), §11 (resolved duration-lock design block: hold→recovery-waterfall→residual-markdown-
  at-resolution→objective-release), §17 (4 resolved decisions + the M1-direct/end-state-buyback yield split),
  §18 (glossary: xALPHA/szipUSD/sdVAULT). Reshaped the backlog (items 7/8 redefined; sdVAULT + xALPHA-bridge +
  xALPHA-name-sweep added as deferred/follow-up). **Did NOT author the zap ticket** — concluded on the spec fix per
  harness §6 ("if an item needs heavy spec surgery, conclude after the spec fix, author next window"). Wrote
  the supply-side redesign report (deleted; decisions live in §5/§17 + memory). **NEXT unchanged: item 7** (now ready — the zap is tokenomics-robust).
- **2026-06-04** — harness built + validated (zap shakedown); WOOF-00 + WOOF-03 authored (`sample-ticket.md`).
  Next: item 2 (`§4.2`).
- **2026-06-04** — housekeeping: graduated WOOF-00 + WOOF-03 into `tickets/woof/`, retired `sample-ticket.md`.
  Authored **item 2** = WOOF-01 (`LienCollateralToken` + `LienTokenFactory`, §4.2) through the full harness:
  5 critics (junior-dev/spec-fidelity/ref-verifier/qa/security). Spec fix: §4.2 factory-authority rewrite (see
  Open spec gaps). Cold-build = **YES** for WOOF-01 scope (17/17 unit tests pass, `forge build` clean, no ticket
  line wrong); residual guesses were all WOOF-00-scaffold cosmetics, not WOOF-01 logic. Byproduct discarded;
  `contracts/` back to skeleton. Next: item 3 (`ZipcodeOracleRegistry`, §4.1).
- **2026-06-04** (follow-ups, same item) — (1) Pinned the SPDX license **GPL-2.0-or-later** (user decision) into
  WOOF-00 + WOOF-01 → no remaining guesses. (2) Threaded the **one-arg `create(bytes32 lienId)`** simplification
  (caller-bound, `controller := msg.sender`, no gate — strictly simpler + inherently squat-proof; aligns with the
  pre-existing §9 trace `create(lienId)`) through **all** touchpoints: §4.2, audit/2.md L4, audit/3-results row 19
  + negative-test table, and WOOF-01 (sig/Do-NOT/Key-reqs/Done-when/cross-refs). `computeAddress` stays two-arg.
  Re-cold-build = **YES** (14/14 tests incl. the squat-proof test; `forge build` clean; ticket internally
  consistent, no leftover two-arg/gate). Byproduct discarded; skeleton restored. Next unchanged: item 3 (§4.1).
- **2026-06-04** — Authored **item 3** = WOOF-02 (`ZipcodeOracleRegistry`, §4.1) through the full harness: 5
  critics (junior-dev/spec-fidelity/ref-verifier/qa/security). Spec fixes: the **five §4.1 gaps** + the
  **non-virtual-Forwarder → renounce** correction across §4.1/§4.4/§9/§10/§17 + audit/2.md S3/S6/S11/N7/L4 +
  audit/3-results rows 20–22/sweep/attack-table (see Open spec gaps). Discharged the WOOF-01 decimals obligation;
  created new obligations owed by items 6, 10, and the CRE track (see obligations table). Cold-build = **YES**
  (24/24 unit tests pass, `forge build` clean, scale identity `getQuote(1e18)==equityMark` verified exact, no
  ticket line wrong; only forge-lint notes). Byproduct discarded; `contracts/` back to skeleton. Next: item 5
  (`IZipcodeVenue` + `EulerVenueAdapter`, §4.7).
- **2026-06-05** — Authored **item 5** = WOOF-04 (`IZipcodeVenue` + `EulerVenueAdapter`, §4.7) through the full
  harness: 5 critics (junior/spec-fidelity/ref-verifier/qa/security) + a cold-build. Heavy interactive design pass
  with the user, who **directed + ratified** the **per-line isolated-market factory** architecture (each line =
  own escrow vault + USDC borrow vault + dedicated frozen `EulerRouter`; EdgeFactory pattern). **Spec surgery**
  (user-ratified §17 edit): per-line frozen routers **supersede the shared-router/timelock "F4"** across §3/§4.1/
  §4.4/§4.7/§9/§13/§17 + audit/2.md S6/S8/S9/S10/N5/L4 + audit/3-results rows 12-13/Trace B/failure-modes; oracle
  key stays `LIEN_i` (WOOF-02 unchanged). Critics caught a **CRITICAL** isolation bug (shared `subId=1` → all lines
  on one EVC account → fixed to per-line `subId`), the `fund` reallocate zero-sum revert, unvalidated `draw` receiver
  (→ pinned to Erebor), curator over-privilege (→ scoped + production-hardening flag), and AmountCap/EVC-encoding
  errors. **Cold-build = NO (3 residual guesses) → all folded into the ticket** (EulerEarn has no idle market →
  `baseUsdcMarket` ctor immutable; `closeLine` redeem via EVC operator; `setSupplyQueue` rebuild; `abi.encodeCall`
  needs `IBorrowing.borrow`); cold-build compiled clean + **20/20 tests pass incl. the live two-line both-draw**
  (proves the `subId` fix) and revaluation-independence. Discharged the WOOF-01 collateral-registration obligation;
  created obligations on items 6 (operator/seed/custody) + 10 (curator/timelock0/baseUsdcMarket). Byproduct discarded;
  `contracts/` back to skeleton. Next: item 6 (`ZipcodeController`, §4.4).
- **2026-06-04** (superintendent review of WOOF-02) — **VERDICT: on-track; item 5 released.** Consistency sweep
  passed: `seedPrice`/`setController`/renounce-based Forwarder immutability are identical across `claude-zipcode.md`,
  `audit/2.md`, `audit/3-results.md`, and the ticket; **zero** leftover "override to revert" instructions; envelope
  (`reportType==3`) and S11 hard pre-gate coherent across spec+audit+obligation row. §17 unreopened (renounce fix is
  a corrections-list mechanism correction, locked intent preserved). Judgment-call rulings: (1) `ts>now` guard **KEPT**
  — a units/sanity reject of impossible future-dated input, categorically distinct from the forbidden *value* band, no
  §17 conflict. (2) Renounce correction across all 5 sites + §4.4/§17 **resolved now** — the old wording was factually
  unbuildable everywhere; leaving it for item 6 to trip over is worse; faithful mechanism correction, not a decision
  change. (3) Cold-build-only (no re-fan) **accepted** — the added surface was critic-derived, the lone post-synthesis
  addition (`ts>now`) is narrow/defensive/tested, 24/24 cold-build is the zero-guess gate. **Standing carry to item 6:**
  the controller window MUST run spec-fidelity against the *corrected* §4.4 renounce wording (the re-fan of that edit
  lands naturally there, since item 6 owns the Forwarder). (4) 5 critics correct for a foundational authority+price
  contract (no frontend critic — registry is build-only, no interface ticket). Nothing requires a user decision.
- **2026-06-05** (superintendent review of WOOF-04) — **VERDICT: on-track WITH a remediation applied + a deferred
  gate; item 6 released.** Architecture sweep passed: per-line frozen routers / `no shared router` / `subId`-per-line
  are threaded consistently across `claude-zipcode.md`, `audit/2.md`, `audit/3-results.md`, and the ticket; every
  surviving `TimelockController` ref is correctly reframed to **§17 parameter governance only** (not routers). The
  two **§17** locked-line edits are well-formed, flagged "supersedes F4", and **user-ratified this session** — a
  legitimate reopening (§17 is reopenable only by user decision, which happened). **Found one real bug:** the
  cold-build's AmountCap fold-back was transcribed **inverted** — ticket line 161 said `(exponent<<10 | mantissa)`,
  but `AmountCap.sol:12-13,18-28` is **low-6=exponent / high-10=mantissa → encode `(mantissa<<6)|exponent`** (the
  report had it right; the ticket did not), and raw `0` = **unlimited** (`type(uint256).max`), so a `cap==0` request
  must revert, not emit raw 0 (an unbounded cap). **Fixed on disk** (reference-determined correction, not new
  mechanism) + tightened the already-resolved `reallocate`-absolute hedge. This bug is **direct evidence that
  "fold guesses in without a fresh from-ticket cold-build" is unsafe** — the fold-back itself introduced the error.
  Judgment-call rulings: (1) Per-line-factory + §17 edit **accepted** — user-directed & ratified; faithful to the
  immutable-Forwarder/frozen philosophy. (2) **Cold-build NO→fold→no-rerun: the zero-guess gate (harness §4) was NOT
  formally met** — the passing 20/20 build was the guess-laden byproduct, not a clean-room from-ticket-alone run.
  Released item 6 anyway because item 6 consumes WOOF-04's **interface** (openLine/draw/observeDebt/closeLine sigs +
  the operator/seed/custody obligations), which is solid and obligation-logged — NOT the adapter's internal encoding
  (where the bug lived; item 6 would not have caught it). **DEFERRED-BUT-MANDATORY gate:** WOOF-04 must get a fresh
  **from-ticket-alone cold-build** before the build team implements it (the AmountCap miss raises the prior that
  other fold-back transcription errors remain; I found one by reading, not by re-building). Logged as an open item
  below. (3) `baseUsdcMarket` residual **correctly externalized** to item 10 (ctor immutable + obligation row), not a
  WOOF-04 internal gap. **Surfaced to the user:** the per-line-frozen-router *irreversibility* trade (a mis-wired or
  compromised registry cannot be re-pointed for an OPEN line; recovery = open a new line) — ratified in principle via
  the §17 architecture, but the explicit risk-acceptance is worth a user nod. **[User accepted "freeze, no recovery".]**
- **2026-06-05** (superintendent, post-gate sharpening of WOOF-04 R4) — user surfaced the domain fact that **CRE
  only opens a market when a lien exists**, so the zero-`collateralAmount` path is unreachable on the happy path.
  That recast the guard: the design's real invariant isn't "non-zero" but **"the full `1e18` lien"** — the lien is a
  1/1 `1e18` primitive (WOOF-01) and §4.4c close reclaims exactly `1e18` before `burn`, so a *partial* deposit breaks
  the same way a zero does. Edited (user-approved, option 1 = assert on both sides): WOOF-04 guard `== 0`/`ZeroCollateral`
  → **`!= 1e18`/`InvalidCollateralAmount`** (guard + error decl + test-list "both 0 AND partial revert; full `1e18`
  succeeds" + step-5 synthesis); the **item-6 obligation** now names the controller as primary guarantor of the
  full-lien pass; LEDGER digest + the WOOF-04 cold-build (deleted byproduct) addendum updated. Gate stays MET (the new one-line
  guard + its tests are spec'd-not-yet-built, same low-risk class as the prior R4 note). NEXT unchanged: item 6.
- **2026-06-05** (superintendent review of cold-build-2 — R4 caveat CLOSED) — the WOOF-04 delta cold-build (deleted byproduct): focused
  delta re-build of the `!= 1e18`/`InvalidCollateralAmount` guard. **Verdict YES, 11/11 green** (live EVK/EVC/EulerRouter
  + mocked EulerEarn). Three-case guard test all pass (`0` reverts, `0.3e18` partial reverts, full `1e18` succeeds +
  escrows `1e18`); happy-path + two-line isolation regressions undisturbed; internal consistency (error decl / guard /
  test-list / step-5 / WOOF-01 `1e18`) holds. **Superintendent independently verified the two load-bearing claims**:
  EVK `deposit` accepts `0` (returns 0) AND a partial without reverting (`Vault.sol:124-135` — `assets.isZero()→return 0`;
  partial → non-zero shares, `E_ZeroShares` doesn't fire) → the guard is genuinely load-bearing; and WOOF-01 `burn`
  reverts `ERC20InsufficientBalance` unless the full `1e18` is reclaimed (`:108-111`) → a partial breaks close like a
  zero. **The last spec'd-not-built residue on WOOF-04 is gone — the ticket is now build-exercised end-to-end.** NEXT
  unchanged: item 6 (`ZipcodeController`, §4.4).
- **2026-06-05** — Authored **item 6** = WOOF-05 (`ZipcodeController`, §4.4) through the full harness: 5 critics
  (junior/spec-fidelity/ref-verifier/qa/security) + a cold-build. The portable-core orchestrator: `is
  ReceiverTemplate`; `_processReport` envelope-decodes + dispatches reportType 1/2/4 (origination/draw/close,
  full) + 5/6 (M1 status markers, never `venue.liquidate`) + rejects 3 (→ registry) and unknown; lien
  mint/burn authority; drives every venue effect through `IZipcodeVenue`. **Spec fixes (3 genuine gaps, no §17
  reopened):** `erebor` 5th ctor arg; the EVC-operator `wireVenueOperator` blanket `setOperator(prefix, venue,
  ~uint256(1))` (the venue-neutral discharge of WOOF-04 obl. 1a — reframed from per-`sub_i`); §4.4a ordering
  reconciled (+ a stale shared-router-fallback phrase fixed). Threaded through §4.4/§9 + audit/2.md S6 +
  audit/3-results orphan sweep. **Discharged all four item-6 inbound obligations** (operator/seed/custody/full-
  lien from WOOF-04; atomic-batch seed from WOOF-02; reclaim-before-burn from WOOF-01); created obligations on
  item 10 (5-arg ctor + wireVenueOperator-before-renounce) + the CRE track (report ABI encoding). Critics
  caught: the blanket-vs-per-sub operator contradiction, the dormant-identity-gate (security F-3), the
  isolation-backstop caveat (F-2), the `IERC20` import ambiguity, the public-mapping tuple-getter compile trap
  (→ added `getLien`), `PrecomputeMismatch` unreachability, and the EulerEarn-mock-funds-the-live-borrow recipe
  gap — all folded into the ticket. **Cold-build = YES, zero load-bearing guesses** (`forge build` clean,
  **23/23** tests pass with a **live** EVK borrow; over-LTV → `E_AccountLiquidity`, cap → `E_BorrowCapExceeded`,
  operator getter pinned to `isAccountOperatorAuthorized` `:286`, `~uint256(1)` confirmed to exclude sub 0).
  All cosmetic guesses were test-harness/keepsake, not controller gaps. Byproduct discarded; `contracts/` back
  to skeleton. Next: item 7 (`ZipDepositModule` — the zap, §4.5; build + interface).
- **2026-06-05** (superintendent review of WOOF-05) — **VERDICT: on-track; item 7 released.** Consistency sweep
  passed: `erebor` (5-arg ctor), `wireVenueOperator`/`setOperator(prefix, venue, ~uint256(1))`, and the §4.4a
  `create → openLine → seed → setLineLimits → fund → draw` ordering are identical across `claude-zipcode.md` §4.4,
  `audit/2.md` S6/L4, the `audit/3-results.md` orphan-sweep row, and the ticket — no contradiction. §17 unreopened
  (the only §17-region per-line-router content is WOOF-04's prior user-ratified edit; these three are §4.4 mechanism
  detail, not locked decisions). Editing discipline §3a held (audit touched only as a consequence of the operator-
  wiring spec add). Byproduct discarded (verified `contracts/src` back to bare `loss/supply/venue`). **Cold-build
  gate formally MET up front** — a clean from-ticket-alone YES (23/23 live EVK borrow), so the WOOF-04 fold-back
  failure mode does not recur; no deferred re-build owed. **Independently re-verified the crux of reframed obligation
  1a against the EVC reference** (the lesson from the WOOF-04 AmountCap miss): `setOperator(prefix,…)` →
  `authenticateCaller` registers `ownerLookup[prefix].owner = controller` (`EthereumVaultConnector.sol:773`,
  `OwnerRegistered`); `~uint256(1)` authorizes sub-accounts 1…255 and clears bit 0 via `isAccountOperatorAuthorizedInternal`'s
  `& (1<<subId)` (`:1218-1220`) → venue can borrow on `sub_1`, never `sub_0`; `EVC_InvalidOperatorStatus` on unchanged
  re-call (`:352-353`) confirms the not-idempotent claim. All three load-bearing sub-claims hold. **Judgment-call
  rulings:** (1) **blanket `setOperator` excluding sub 0** ACCEPTED — per-`sub_i` is genuinely unreachable from a
  venue-neutral core (the adapter's `subId` is private), the prefix grant is the EVC-native discharge, and excluding
  the primary is the right default; the WOOF-04 *contract* is untouched, only the obligation framing reframed (and
  the isolation-not-a-backstop caveat is correctly surfaced in §4.4 + the ticket). (2) **`erebor` as a 5th immutable**
  ACCEPTED — `venue.erebor()` would push a venue-specific call into the core path; two immutables wired to one address
  + seam validation is faithful to venue-neutrality. (3) **§4.4a ordering** ACCEPTED — a genuine correctness fix (the
  old seed-before-`openLine` was impossible once the seed key must be the `openLine`-returned `oracleKey`), not a
  preference; the WOOF-02-created obligation row was correctly updated to match. (4) **types 2/5/6 ABI-complete**
  ACCEPTED — type 2 (draw) is a real M1 mechanism (not optional); 5/6 emitting status markers vs reverting is strictly
  more forward-compatible and harmless (no state change), and the dispatcher still fails closed on genuine unknowns.
  (5) **5 critics** (cheap-three +qa +security, no frontend — build-only) correct for the authority-bearing orchestrator.
  **Standing carries (logged, not blocking M1):** (a) the **security F-3 dormant identity gate** is correctly
  externalized to the item-10 S11 pre-gate AND the controller test demonstrates the dormancy rather than hiding it —
  but item 10 now carries TWO load-bearing pre-gate assertions (`getExpectedWorkflowId()!=0 && controller()!=0` before
  renounce) that MUST be *tested*, not just documented, when authored. (b) ~~**255-line-per-controller ceiling**~~
  **STRUCK 2026-06-05 by the borrower-model rework** — the ceiling existed only because the old scheme borrowed on
  the controller's own sub-accounts 1…255. The new model gives each line its **own** fresh EVC prefix (`LineAccount`),
  so there is **no per-controller line ceiling**; concurrent open lines are unbounded and no `subId`-reuse/line-256
  design is needed (resolved via the §4.4/§4.7/§17 edit; WOOF-04/05 re-author in Step 2).
  Nothing requires a user decision. NEXT = item 7 (first user-facing item → build + interface tickets, frontend critic
  applies; resolve the deferred §4.5 zap gaps: on-behalf stake recipient, `stake`/`deposit` naming, EE-share custody account).
- **2026-06-05** (superintendent-directed OUT-OF-BAND slice, NOT item 7) — Authored **item 10a** = WOOF-10a
  (`ZipcodeDeployAsserts` deploy identity pre-gate, §9 S11) — the focused slice proving the security **F7/F-3**
  renounce-before-identity defense with a REAL test instead of leaving it a paper obligation. Deliverable: a tiny
  `library ZipcodeDeployAsserts { requireIdentityWired(controller, registry) }` (internal view, ONE combined assert
  — `getExpectedWorkflowId() != 0` AND `registry.controller() != 0`, reverting `IdentityNotWired`), absorbable by
  item 10 at S11 immediately before `renounceOwnership()`. **NO spec edit** — §9 + audit/2.md S11 + §4.4 already
  specify the combined pre-gate + the dormancy caveat (spec-fidelity confirmed; this was a test-authoring + tiny-
  helper item, not a spec gap, exactly as the superintendent predicted). **Cold-build = YES, zero load-bearing
  guesses** (rebuilt WOOF-00/01/02/05 keepsakes + a venue stub; the REAL `ZipcodeOracleRegistry` (WOOF-02) + REAL
  `ZipcodeController` (WOOF-05) are the contracts under test): `forge build` clean + clean-rebuild `forge test`
  **6/6** green. Observed selectors: **NEGATIVE** `IdentityNotWired(controller, registry)` (×3: identity-unset /
  controller-unset / both-unset); **POSITIVE** gate passes → `renounceOwnership()` succeeds → all 5 `onlyOwner`
  setters (`setForwarderAddress`/`setExpectedAuthor`/`setExpectedWorkflowId`/`wireVenueOperator` + registry
  `setController`) revert `OwnableUnauthorizedAccount`; **NEGATIVE-CONTROL (vuln demo)** dormant identity →
  wrong-id `onReport` ACCEPTED past the gate → `UnsupportedReportType(3)` on dispatch, vs gate-active →
  `InvalidWorkflowId(0x9999, 0x1234)` (the selector difference IS the proof the gate is dormant when unwired).
  Marked the two item-10 obligation rows (WOOF-05 F-3 + WOOF-02 F7) **GATE PORTION TESTED (by WOOF-10a)** while
  leaving their other clauses (5-arg ctor / wireVenueOperator-before-renounce / setController@S6 /
  govSetFallbackOracle@S10 / the sequenced renounces) OPEN for the full item 10. Byproduct discarded; `contracts/`
  back to skeleton. **NEXT unchanged: item 7** (the zap, §4.5).
- **2026-06-05** (superintendent review of WOOF-10a) — **VERDICT: on-track; accepted.** Independently verified the
  one load-bearing claim the absent spec-fidelity subagent would have checked: the **combined** gate is genuinely
  spec-mandated, not invented — `audit/2.md` S11 `:166-169` asserts BOTH `getExpectedWorkflowId() != bytes32(0)`
  on each receiver AND the registry's `controller != address(0)`, and §9 `:834-839` mandates the identity clause;
  the post-renounce `OwnableUnauthorizedAccount` post-state the POSITIVE test asserts matches S11 `:171-172`. So
  "no spec edit / confirm-don't-invent" is correct; §17 untouched. Byproduct discarded confirmed (`contracts/` =
  only `.gitkeep`). The dormancy proof (selector diff `UnsupportedReportType(3)` dormant vs `InvalidWorkflowId`
  active) is sound — the revert *location* proves the wrong-id report got past a skipped identity gate without
  needing a full origination. Obligation bookkeeping is HONEST: the two item-10 rows are marked **gate-portion
  TESTED**, not fully discharged — item 10 still must IMPORT + CALL the assert in the real sequence + wire the
  5-arg ctor / `wireVenueOperator` / `setController` / the renounces. **Judgment-call rulings:** (1) library
  `internal view` free function — ACCEPT (deploy-time, two-contract, zero deployed bytecode, item-10-absorbable;
  the external test wrapper for `vm.expectRevert` on an internal lib fn is correct). (2) representative-id scope cut
  (assert controller's id; leave `requireIdentityWired(registry, registry)` optional for item 10) — ACCEPT, since
  §9/S10b sets the SAME `WORKFLOW_ID` on every receiver in one loop, BUT **carry to item 10:** just take the
  redundant registry-self assert — it is zero-cost and closes the theoretical asymmetric-wiring gap where the loop
  sets the controller's id but a bug skips the registry's. (3) no critic subagent fan-out (builder has no Agent
  tool → inline lenses + clean cold-build arbiter) — ACCEPT for this tiny, no-spec-gap, security-already-analyzed
  surface; the independence loss is covered by (a) my own spec-fidelity verification above and (b) item 10's OWN
  authoring re-touching this gate in the full S1–S12 sequence WITH critics. No formal re-fan needed. **The HIGH
  F-3 risk is now defended by a tested negative, not a paper obligation.** NEXT unchanged: item 7.
- **2026-06-05** (superintendent-released RECONCILIATION of WOOF-03 — borrow-driver fix, a WOOF-04 seam; NOT a new
  item) — Closed a **naming footgun** the WOOF-04 re-author surfaced: WOOF-03's third ctor immutable was named
  **`controller`** and `claude-zipcode.md` §4.3 gated on `isAccountOperatorAuthorized(caller, zipcodeController)`,
  but under the fresh-per-line-borrower model the address that makes the `EVC.call(borrowVault, borrowAccount, …)`
  — and is therefore the address EVC authenticates as the **operator** — is the **`EulerVenueAdapter`** (the
  controller drives origination through `IZipcodeVenue.draw`, so the adapter is `EVC.call`'s `msg.sender`). The
  per-line `LineAccount` grants the **adapter** the operator bit (WOOF-04, already built). So the immutable was
  **renamed `controller` → `borrowDriver`** and the gate is now `EVC.isAccountOperatorAuthorized(caller,
  borrowDriver)`, wired to the adapter at deploy (in M1-collapsed, adapter==controller, same address — still
  correct). **EVC verification** (`reference/ethereum-vault-connector/src/EthereumVaultConnector.sol`):
  `isAccountOperatorAuthorized(account, operator)` `:286` → `isAccountOperatorAuthorizedInternal` `:1205-1221`
  keys on the **account's** prefix-owner (`:1209-1210`), fails closed for an unregistered prefix (`:1213`), and
  otherwise returns `operatorLookup[addressPrefix][operator] & bitMask != 0` (`:1220`) — so the gate clears ONLY
  when `operator` equals the exact `EVC.call` caller (the **adapter**), never the controller (unless M1 collapses
  them). **Edits:** WOOF-03 ticket overwritten (immutable + ctor sig `(eVaultFactory, evc, borrowDriver)` + Do-NOT
  + Key-reqs + tests + the revert renamed to imply the operator, not the controller); `claude-zipcode.md` §4.3
  (gate expression → `borrowDriver`, one-line "this is the adapter / the `EVC.call` caller, == controller only if
  M1 collapses them" note, + the §4.4 cross-ref `controller` immutable rename + the venue-boundary line);
  `audit/2.md` S5 (hook ctor `VENUE_precomputed` + the circular-immutable precompute note)/L4-post/N1/N1b
  (`ZIP_CONTROLLER`→`VENUE`); `audit/3-results.md` preamble + row 9 + Trace-A hop 9/10 + the attack table
  (`ZIP_CONTROLLER`→`VENUE`). Consequence edits only — faithful to the ratified borrower model, no new mechanism,
  no §17 reopened. **Cold-build = YES, zero load-bearing guesses** (rebuilt WOOF-00 scaffold + the re-authored hook
  + a 6-test unit suite against a mock `GenericFactory` + mock EVC): `forge build` clean + `forge test` **6/6**
  green. The renamed revert is **`NotAuthorizedOperator()` = `0x3d9adf1c`** (was `NotControllerOperator`). Proofs:
  (a) `isHookTarget()`→`0x87439e04` from proxy / `0x0` from non-proxy; (b) a line account that authorized the
  **borrowDriver** clears the gate; (c) a foreign account → `NotAuthorizedOperator`; (d) **non-proxy spoof**
  rejected (the `isProxy`-guard fell back to `msg.sender`, not the spoofed appended bytes → `NotAuthorizedOperator`);
  + the `borrowDriver()` immutable getter pins the wired address. Cold-build-only gate (harness §3a — a targeted
  rename+rewire correctness fix proven by a test), no full critic re-fan. Byproduct discarded; `contracts/` back to
  skeleton. Folded into the consolidated `reports/WOOF-03-report.md`. **WOOF-03 stays DONE; WOOF-05 stays NEXT** (per the borrower-
  model re-author dep-order; item 7 the zap is the live build NEXT per the main backlog).
- **2026-06-07** (**8-B1 BUILT-VERIFIED — the szipUSD Baal substrate scaffold**) — Authored + materialized the
  summon script `contracts/script/SummonSubstrate.s.sol` + 8 fork tests `contracts/test/SummonSubstrate.t.sol`
  (interfaces under `contracts/src/interfaces/{baal,safe}/`). **8/8 pass on a live Base-mainnet fork; 115/115
  total, no regression.** **A foundational SPEC GAP was found + fixed FIRST (with the user in-loop):** the
  baal-spec "post-deploy `setShamans`" seam was **un-reachable** — at zero Shares the Baal is governance-inert and
  the summoner forces the Safe owned 1/1 by the Baal, so nothing could drive it. **Ratified resolution (user):**
  two-tier authority — **admin = the team multisig added as a Safe owner/signer** (governs the module set, grants
  the Gate `manager`), **CRE operator = a Zodiac module** the admin enables; **Shares stay 0 forever** (authority =
  Safe ownership, not votes). Injected at summon via `executeAsBaal → execTransactionFromModule →
  addOwnerWithThreshold(team,1)`; main-Safe address **computed from the live proxy factory + asserted ==
  `baal.avatar()`** (fail-closed). Spec edits: `claude-zipcode.md §4.5 item-0` + `baal-spec.md 8-B1` (rewrote the
  Authority model + recipe). 5 critics fanned out (junior-dev/spec-fidelity/ref-verifier/qa/security) → folded:
  concrete sidecar owner-add via the OWNER `execTransaction` path, corrected the false governance-inertness
  negative (submitProposal succeeds at zero offering → assert dead-end at `sponsorProposal`/`processProposal`
  `!sponsor` + `!baal` on direct setShamans), before/after sidecar-owner asserts, salt-sensitivity, vaultIdx
  sourcing. **Build-discovered correction (code is truth):** BaalSummoner's Safe proxy factory = `0xC22834581EbC…`
  (verified via on-chain storage slot 208), NOT `0xa6B7…` — the `compute==avatar` assert caught the wrong-factory
  guess (exactly as designed); new `BaseAddresses.BAAL_SAFE_PROXY_FACTORY`. New cross-ticket obligations recorded
  (Exit Gate must-not-mintShares + manager-grant path; item-9 sidecar-funding gate; item-10 team-k-of-n /
  Baal-owner-removal / Roles-scoped-CRE-operator / unpredictable-saltNonce). **NOT git-committed** — the whole repo
  working-tree is untracked (`contracts/` has 0 tracked files; prior "committed" claims were working-tree only) and
  this window is on `main`; left the verified code on disk per keep-the-build (`forge test` green — run it
  yourself), flagged the git state rather than committing unilaterally. `reports/8-B1-report.md`. **NEXT =
  `SzipNavOracle`.**
