# 8-Bx — `LienXAlphaEscrow` — per-lien xALPHA first-loss bond custody (§4.6 / §11 / §2)

> **M1-adjacent / build-only.** The **per-lien xALPHA bond vault**: it holds the originator's xALPHA first-loss
> bond (protocol-posted at launch, §2/§4.6), returns it on repayment, and — on a default — routes it at resolution
> in two ordered jobs: **sell-to-cover a realized capital hole** (`slashXAlphaToCapital`) then **the in-kind
> premium to the frozen cohort** (`slashXAlphaToCohort`). The **custody half** (`lockXAlpha`/`releaseXAlpha`) is
> **live in M1** (originator bonds are posted at launch); the **slash half** is **built + mock-tested now** and
> goes **live with the M2 default flow** (its driver, `DefaultCoordinator`, is M2). This is **internal protocol
> plumbing** driven by the loss-side orchestrator → **build-only** (no INFLOW ticket; any bond-status UI folds into
> the post-deploy frontend sweep, memory `[[frontend-after-contracts]]`).
>
> **This is NOT a Zodiac module, NOT a Baal shaman, NOT `ReceiverTemplate`.** It is a standalone, non-sweepable,
> fully-immutable custody contract — the loss-side sibling of the senior `ZipRedemptionQueue` (item 9): no owner,
> no sweep, no pause, no upgrade.
>
> **Security thesis (the centerpiece — verify it as a tested invariant): destination integrity, NOT authorization
> correctness.** No state-changer takes a recipient parameter; the funds the contract holds can only ever flow to
> **three destinations** — the **recorded originator** (captured at lock from the coordinator's arg), the immutable
> `capitalSink`, the immutable `sidecar`. Therefore **even a fully-compromised `coordinator` cannot redirect a bond
> to an attacker address** (the theft surface is structurally closed). What a compromised/buggy coordinator *can*
> still do is **grief** — release a bond prematurely (unbonding a live lien) or slash a healthy bond to the fixed
> sinks. That **timing/authorization correctness is wholly the coordinator's trust boundary** (the §13 trusted-
> operator model — this escrow trusts its coordinator exactly as the engine modules trust their CRE operator); the
> escrow does **not** add on-chain solvency/default gating (§4.6: the split + timing are the coordinator's job).
> For M1 this is acceptable and **no split role is required**: the M1-live surface is only `lock`/`release` driven by
> the launch poster, and the slash surface goes live only with the M2 CRE-Forwarder-gated `DefaultCoordinator`.

**Deliverable**
One contract + tests under the loss tree:
- `contracts/src/loss/LienXAlphaEscrow.sol` — `contract LienXAlphaEscrow is ReentrancyGuard` (`@openzeppelin/
  contracts/utils/ReentrancyGuard.sol`; `using SafeERC20 for IERC20`). Per-lien xALPHA bond custody. Four
  `onlyCoordinator nonReentrant` state-changers (`lockXAlpha`, `releaseXAlpha`, `slashXAlphaToCapital`,
  `slashXAlphaToCohort`) + public-getter views. All authority + all destinations are **immutable** (ctor-pinned).
  NO `Ownable`/`Owned`/owner, NO `sweep`/`rescue`, NO pause, NO `setCoordinator`/`setSink`/`setSidecar`, NO
  `transferOwnership`, NO `renounce`. (`ReentrancyGuard` is the **only** base — mirrors the sibling
  `ZipRedemptionQueue is ReentrancyGuard`; it adds no owner/admin surface.)
- `contracts/test/LienXAlphaEscrow.t.sol` — unit + a stateful Foundry `invariant_` handler + a malicious-token
  reentrancy probe + a no-sweep ABI-negative, against a local `MockERC20` / `ReentrantToken` mirrored from
  `contracts/test/ZipRedemptionQueue.t.sol` (the `MockERC20` at `:18` and the `ReentrantUSDC` template at `:58`).
  **No fork test** — the bond asset is a generic ERC-20 and the production bridged xALPHA (8x-01 `SzAlphaMirror`) is
  **not yet live on Base** (the 8x-01 stand-in swaps in later); a fork test has nothing real to hit. The custody
  logic is venue/token-agnostic and is fully exercised by mocks.

**Spec §**
- `claude-zipcode.md` **§4.6** (the `LienXAlphaEscrow` bullet — `lockXAlpha` at origination [protocol-posted on the
  originator's behalf at launch], `releaseXAlpha` on repayment; on default the bond is **held through the freeze**
  and applied at resolution in **two ordered jobs**: (1) `slashXAlphaToCapital` sells xALPHA → external USDC to cover
  a **capital hole**, last resort for a *realized* loss, **up to the shortfall**; (2) the **remainder is the
  premium**, `slashXAlphaToCohort`, **in-kind, never market-sold**, to the frozen cohort. Custody models
  `InsuranceFund.bring:33`. **As edited this window:** the capital-vs-premium amount is computed off-chain by the
  coordinator and passed as a parameter — the escrow only **routes** it; the premium is delivered by **routing the
  remaining bond into the sidecar Safe**, the socialized pro-rata automatic via NAV — **NO snapshot / per-holder
  index / `RewardsDistributor` / SBT**. **There is NO `escrowLoss`/`releaseLoss`/`finalizeLoss` share-move — the
  loss is a recoverable NAV provision on `SzipNavOracle`; this contract holds ONLY the xALPHA bond.**) +
- **§11** (the loss/default/recovery machinery: the recovery waterfall order — (a) secondary purchase, (b) outside
  insurance, (c) **xALPHA bond liquidation — alpha → TAO → USDC on Bittensor** = `slashXAlphaToCapital`, (d) residual
  → frozen junior; step 3 "xALPHA bond (held, applied at resolution)"; the premium is **in-kind, priced via the CRE
  xALPHA feed, never market-sold**; "**no per-position index, no SBT**" — the cohort distribution is **socialized via
  the sidecar/NAV**, and the dropped `HaircutLockAccountant`/`RecoveryClaimSBT` are **not built**) +
- **§2** (the xALPHA token row — **ONE token**, the bridged subnet LST; job #1 = the per-lien **first-loss bond**,
  protocol-posted at launch, originators self-fund via OTC as they scale; job #2 = the **Duration-Bond premium**,
  in-kind, priced, **never market-sold**; yield-bearing as the LST — **exchangeRate-accruing, NOT rebasing, NOT
  fee-on-transfer** — the 8x-01 `SzAlphaMirror` is a plain OZ `BurnMintERC20`) +
- **§6.4 / §4.5** (the **sidecar** = the non-ragequittable Safe holding the frozen cohort's basket; the freeze is
  **structural via the Exit Gate + sidecar**, "no per-position index, no SBT" — so the in-kind premium is delivered
  by **routing xALPHA into the sidecar Safe**, where the socialized pro-rata is **automatic via NAV** — every frozen
  holder's slice of the sidecar basket grows; `SzipNavOracle` already reads sidecar balances, §7/§12).
- **Locked §17 (do not reopen):** stack = junior → insurance → xALPHA; xALPHA is **sold only for a realized loss,
  never peg defense**; the Duration-Bond premium is a **separate in-kind** payment; **no on-chain economic
  liquidation**; the freeze is **structural, owned by the Exit Gate** — this escrow neither engages nor reads the
  freeze (it holds only the bond).

**Model from (VERIFIED against `reference/` this window — by inspection; all five sources confirmed by the
reference-verifier critic)**
- **Custody pattern — `reference/moneymarket-contracts/src/InsuranceFund.sol` (`bring`, `:33`; GPL-2.0).** VERIFIED:
  a **fully-immutable** custody contract — `address public immutable CREDIT_LINE` (decl `:18`, ctor zero-check
  `:23-26`, rejects `address(0)`); `bring(address loanToken, uint256 amount)` (`:33-37`) gated `if (msg.sender !=
  CREDIT_LINE) revert Unauthorized()`, then `IERC20(loanToken).safeTransfer(CREDIT_LINE, amount)`. **No owner, no
  sweep, no upgrade.** **Replicate the shape clean-room** — the *single-immutable-authorized-caller + gated
  `safeTransfer`* pattern is exactly our model; generalize it to (a) a **pull-in** at lock
  (`safeTransferFrom(coordinator, this, amount)`), (b) per-lien bookkeeping, and (c) three fixed destinations. Cite
  `InsuranceFund.sol:33` as the model in NatSpec. Do **NOT** import it (`pragma >=0.5.0` over Morpho's own
  `IERC20`/`SafeTransferLib`/`ErrorsLib` — wrong infra; we use OZ `IERC20` + `SafeERC20`, the project standard,
  `ZipDepositModule.sol:4,6` / `ZipRedemptionQueue.sol:4,6`).
- **`slashJaneProportional` is a CONCEPT TEMPLATE ONLY, NOT a drop-in** —
  `reference/moneymarket-contracts/src/MarkdownController.sol:146-181`. VERIFIED: it computes a target slash from an
  *initial-balance × time-driven markdown multiplier* (`getMarkdownMultiplier :127` = `WAD*timeInDefault/
  markdownDuration`), slashes the delta-since-last-touch, caps at current balance. **We do NOT replicate this.** Our
  split is **not time-proportional and not balance-progressive** — the capital-vs-premium amount is computed
  **off-chain by the coordinator** and passed as a parameter; the escrow merely **routes** the passed amount.
- **The cohort distributor is delivered by route-to-sidecar, NOT a Merkle/snapshot distributor** —
  `reference/moneymarket-contracts/src/jane/RewardsDistributor.sol` (`claim`/`claimMultiple`, `:131`/`:141`) is a
  **Merkle/cumulative-allocation pull-claim** distributor (`MerkleProof.verify`, `:159-162`; it even has its own
  `sweep` at `:225` — the wrong shape for a non-sweepable escrow). The §4.6 "snapshot → per-holder share" sketch was
  **stale M2-sketch language that contradicted §11/§6.4** ("no per-position index, no SBT") — **fixed in
  `claude-zipcode.md §4.6` this window** (the spec-fidelity critic confirmed the contradiction was real). **Do NOT
  build any Merkle/snapshot/claim distributor.** The premium is delivered **in-kind by a single `safeTransfer` of the
  remaining bond to the immutable `sidecar` Safe** — NAV does the pro-rata for free (memory `[[prefer-simplest-
  mechanism]]`).
- **Token transfer safety** — OZ `SafeERC20` (`@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol`) +
  `IERC20` (`@openzeppelin/contracts/token/ERC20/IERC20.sol`) + `ReentrancyGuard`
  (`@openzeppelin/contracts/utils/ReentrancyGuard.sol`); all resolve via `contracts/remappings.txt:7` (used by
  `ZipDepositModule`/`ZipRedemptionQueue`). xALPHA is a standard ERC-20 (the bridged LST is exchangeRate-yield-
  bearing, **not rebasing, not fee-on-transfer**), so balance/amount bookkeeping is safe.

**Starting state**
- `contracts/src/loss/LienXAlphaEscrow.sol` exists as a 2-line `.gitkeep` stub (license + `pragma 0.8.24`). The
  sibling `contracts/src/loss/DefaultCoordinator.sol` is also a stub — **DO NOT touch it** (M2, separate window).
- The scaffold (`forge build` green) + OZ remap + the `contracts/test` tree (local `MockERC20` + `ReentrantUSDC`
  templates in `ZipRedemptionQueue.t.sol`) are in place. No new interface file is needed.

**Do NOT**
- Do **NOT** add an `Ownable`/`Owned` base, an `owner`, a `sweep`/`rescue`/`skim`, a pause, a `setCoordinator`/
  `setSink`/`setSidecar`, `transferOwnership`, or `renounceOwnership`. **Everything is immutable; non-sweepable is a
  hard requirement** (the loss-side sibling of `ZipRedemptionQueue`). A mutable destination or a sweep is a rug
  surface over the first-loss bond. (`ReentrancyGuard` is the only allowed base — it adds no admin surface.)
- Do **NOT** build any Merkle/snapshot/claim/per-holder cohort distributor. The cohort premium is one `safeTransfer`
  to the `sidecar`.
- Do **NOT** implement any NAV markdown, loss-escrow, `escrowLoss`/`releaseLoss`/`finalizeLoss`, share-burn, or
  ragequit gate (§4.6/§11: the loss is a NAV provision on `SzipNavOracle`; the freeze is the Exit Gate's). This
  contract holds **only** the xALPHA bond.
- Do **NOT** read or engage the freeze, the Exit Gate, the cohort membership, `SzipNavOracle`, or any utilization
  metric. The off-chain coordinator computes the split + timing and drives the calls; the contract is a dumb, safe
  router. **Do NOT add on-chain solvency/default gating** (it violates §4.6 and the dumb-router mandate — the
  grief residual above is the accepted trade).
- Do **NOT** market-sell xALPHA on-chain (no swap router, no AMM). `slashXAlphaToCapital` **routes** xALPHA to the
  `capitalSink`; the alpha → TAO → USDC liquidation happens **off-chain on Bittensor** (§11). The premium is
  **in-kind, never market-sold** (§2/§11).
- Do **NOT** recompute the capital-vs-premium split on-chain or read any oracle for it — the coordinator passes the
  capital amount.
- Do **NOT** allow a second `lockXAlpha` on a lienId that already carries a bond (no silent clobber/top-up).
- Do **NOT** add `balanceBefore/After` delta accounting (it conflicts with the non-rebasing/feeless assumption and
  the dumb-router simplicity) — instead keep that assumption explicit and pin the production-token assertion to
  item-10 (below). DO follow CEI (zero state before every external transfer) **and** keep `nonReentrant` — the two
  together close the reentrancy class even if the asset is ever swapped for a hooked token.

**Key requirements**
1. **Immutables (all ctor-pinned). Exact ctor signature:**
   `constructor(address xAlpha_, address coordinator_, address capitalSink_, address sidecar_)` — a single combined
   check `if (xAlpha_==0 || coordinator_==0 || capitalSink_==0 || sidecar_==0) revert ZeroAddress();` then assign.
   Stored as:
   - `IERC20 public immutable xAlpha` (assigned `IERC20(xAlpha_)`) — the bond asset (the bridged xALPHA / 8x-01
     `SzAlphaMirror`; a generic ERC-20 in M1 tests).
   - `address public immutable coordinator` — the **sole** authorized caller of all four state-changers (production:
     the loss-side orchestrator that posts launch bonds and, in M2, the `DefaultCoordinator` that drives slash; M1
     tests use a fixture address). `modifier onlyCoordinator { if (msg.sender != coordinator) revert
     NotCoordinator(); _; }`.
   - `address public immutable capitalSink` — the **only** destination of `slashXAlphaToCapital` (the off-chain
     recovery/bridge account that liquidates alpha → TAO → USDC, §11).
   - `address public immutable sidecar` — the **only** destination of `slashXAlphaToCohort` (the non-ragequittable
     sidecar Safe; NAV does the cohort pro-rata, §6.4).
2. **State (per-lien bond book — keyed by `bytes32 lienId` to match the canonical type** used by `ZipcodeController`/
   `IZipcodeVenue`/`LienTokenFactory` and the CRE default report ABI `(bytes32 lienId, uint8 status)`, §8.0):**
   - `mapping(bytes32 lienId => uint256) public bondAmount;` — current escrowed xALPHA for the lien.
   - `mapping(bytes32 lienId => address) public bondOriginator;` — who the bond returns to on release.
   - (A `struct Bond { address originator; uint256 amount; }` single mapping is an acceptable equivalent — author's
     choice; the two-mapping form keeps the public getters trivial.)
3. **`lockXAlpha(bytes32 lienId, address originator, uint256 amount) onlyCoordinator nonReentrant`:**
   - `require originator != address(0)` (`ZeroOriginator`); **`require originator != address(this)`** (`SelfOriginator`
     — closes the self-lock footgun); `require amount != 0` (`ZeroAmount`); `require bondAmount[lienId] == 0`
     (`BondExists` — no clobber/top-up).
   - Effects **before** interaction (CEI): `bondAmount[lienId] = amount; bondOriginator[lienId] = originator;`
   - Interaction: `xAlpha.safeTransferFrom(msg.sender, address(this), amount);` (the coordinator funds the bond; it
     must have approved this escrow — an item-10 wiring obligation). A failed pull reverts the whole tx (so the
     mapping writes roll back — no orphaned bond entry).
   - `emit Locked(lienId, originator, amount);`
4. **`releaseXAlpha(bytes32 lienId) onlyCoordinator nonReentrant`** (repayment path, M1-live):
   - `require bondAmount[lienId] != 0` (`NoBond`).
   - Cache `amount`, `originator`; **zero both mappings first** (CEI); then `xAlpha.safeTransfer(originator,
     amount);` `emit Released(lienId, originator, amount);`
5. **`slashXAlphaToCapital(bytes32 lienId, uint256 amount) onlyCoordinator nonReentrant`** (resolution job 1, mock-
   tested, M2-live):
   - `require amount != 0` (`ZeroAmount`) and `amount <= bondAmount[lienId]` (`ExceedsBond` — partial allowed, up to
     the shortfall the coordinator computed; the lien **stays open** with the remainder for the cohort; `amount ==
     bondAmount` is the exact-equality boundary that **passes** and drives the bond to 0).
   - Effects first: `bondAmount[lienId] -= amount;` (do NOT touch `bondOriginator` — the lien is still mid-
     resolution). Interaction: `xAlpha.safeTransfer(capitalSink, amount);` `emit SlashedToCapital(lienId, amount);`
6. **`slashXAlphaToCohort(bytes32 lienId) onlyCoordinator nonReentrant`** (resolution job 2 = the in-kind premium,
   mock-tested, M2-live):
   - `require bondAmount[lienId] != 0` (`NoBond`).
   - Cache `remaining = bondAmount[lienId]`; **zero both mappings first** (the lien's bond is now fully resolved);
     then `xAlpha.safeTransfer(sidecar, remaining);` `emit SlashedToCohort(lienId, remaining);`
   - This delivers the **entire remaining bond** (whatever `slashXAlphaToCapital` left, or the **whole bond** if no
     capital slash ran — the pure-premium path) to the sidecar in-kind. The ordered pair (capital-first, then cohort)
     realizes §4.6's "sell-to-cover the hole, remainder is the premium." If a full-bond capital slash already drove
     the bond to 0, the coordinator **skips** the cohort call (it would revert `NoBond`).
7. **Structural fund-flow safety (the security thesis — tested invariant):** the only addresses xALPHA can ever leave
   to are `{bondOriginator[lienId]` (recorded at lock from the coordinator's arg), `capitalSink`, `sidecar}` — all
   either ctor-immutable or recorded-at-lock. **No function takes a recipient parameter.** Prove it: a stateful
   `invariant_` (below) asserts xALPHA never lands on any address outside that set (and never on `address(this)` via
   an outbound transfer), and the no-recipient-param ABI makes redirection structurally impossible.
8. **CEI + `nonReentrant` (both):** every external `safeTransfer`/`safeTransferFrom` happens **after** all state
   writes for that path (CEI), AND every state-changer carries `nonReentrant`. CEI alone defends the *current* asset
   (xALPHA is hookless), but the contract is **token-agnostic** (item-10 swaps a stand-in for production xALPHA), so
   `nonReentrant` is mandatory belt-and-suspenders (mirrors `ZipRedemptionQueue is ReentrancyGuard`). Together: a
   reentrant call reverts on the guard (`ReentrancyGuardReentrantCall`), and even without it CEI re-reads a zeroed
   bond and reverts (`NoBond`/`BondExists`).
9. **Events:** `Locked(bytes32 indexed lienId, address indexed originator, uint256 amount)`,
   `Released(bytes32 indexed lienId, address indexed originator, uint256 amount)`,
   `SlashedToCapital(bytes32 indexed lienId, uint256 amount)`,
   `SlashedToCohort(bytes32 indexed lienId, uint256 amount)` (the cohort event emits the **remaining** amount, not
   the original bond). These are the surface the M2 `DefaultCoordinator` and the frontend bond-status view read.
10. **Custom errors** (no string reverts): `ZeroAddress`, `NotCoordinator`, `ZeroOriginator`, `SelfOriginator`,
    `ZeroAmount`, `BondExists`, `NoBond`, `ExceedsBond`. Pragma **`0.8.24`**.
11. **Non-sweepable / immutable** (KR — assert with an ABI-negative test): no `owner`/`sweep`/`rescue`/`pause`/
    `setCoordinator`/`transferOwnership`/`renounceOwnership` selector exists. The contract cannot be rugged and holds
    the bond passively between coordinator calls.

**Done when**
`forge build` green + `forge test --match-contract LienXAlphaEscrow` green + the **full suite has no regression**
(`forge test`). Tests (all use a local `MockERC20` mirrored from `ZipRedemptionQueue.t.sol:18`, ctor
`constructor(uint8 d)` with `d = 18` for xALPHA, open `mint(to, amt)`; the reentrancy probe mirrors the
`ReentrantUSDC` template at `:58`):

- **ctor:** rejects `address(0)` for each of `xAlpha`/`coordinator`/`capitalSink`/`sidecar` (4 negatives, all revert
  `ZeroAddress`); stores all four immutables (getters return them).
- **lock (happy):** fixture mints xALPHA to the coordinator and `vm.prank(coordinator)`-approves the escrow; lock
  pulls exactly `amount` (escrow +`amount`, coordinator −`amount`); records `bondAmount`/`bondOriginator`;
  `vm.expectEmit` `Locked(lienId, originator, amount)` (indexed topics + data).
- **lock (negatives):** non-coordinator → `NotCoordinator`; `amount==0` → `ZeroAmount`; `originator==0` →
  `ZeroOriginator`; `originator==address(escrow)` → `SelfOriginator`; re-lock a bonded lienId → `BondExists`;
  **zero allowance** → reverts (`SafeERC20FailedOperation`/allowance revert); **insufficient coordinator balance** →
  reverts; **failed pull leaves NO orphaned bond entry** (after a reverting lock, `bondAmount[lienId]==0`).
- **release (happy):** returns the **full** bond to the recorded originator; zeros `bondAmount`+`bondOriginator`;
  `vm.expectEmit` `Released`; re-release reverts `NoBond`.
- **release (negatives):** non-coordinator → `NotCoordinator`; unbonded lienId → `NoBond`.
- **slashToCapital (happy + partial):** routes exactly `amount` to `capitalSink`; decrements `bondAmount`; leaves
  `bondOriginator` intact; `vm.expectEmit` `SlashedToCapital`. A partial (`amount < bond`) leaves the remainder.
- **slashToCapital (boundary + negatives):** `amount == bondAmount` **passes** → 0 remaining; `amount == bondAmount+1`
  → `ExceedsBond`; non-coordinator → `NotCoordinator`; `amount==0` → `ZeroAmount`; unbonded (amount>0 over 0 bond) →
  `ExceedsBond`.
- **slashToCohort (happy — pure premium AND remainder):** (a) **pure premium** `lock(B)` → `slashToCohort()` routes
  the **whole** `B` to `sidecar`; (b) **remainder** `lock(B)` → `slashToCapital(part)` → `slashToCohort()` routes
  `B-part` to `sidecar`. Both zero both mappings; `vm.expectEmit` `SlashedToCohort` with the **remaining** amount;
  re-call reverts `NoBond`; assert **no `Transfer`/event fires** on the reverting cohort call.
- **the ordered resolution (the §4.6 two-job split):** `lock(B)` → `slashToCapital(part)` → `slashToCohort()`
  delivers `part` to `capitalSink` and `B-part` to `sidecar`, escrow net 0, bond cleared. A **full-bond capital
  slash** (`part == B`) followed by `slashToCohort()` reverts `NoBond` (coordinator skips cohort when capital took
  everything).
- **multi-lien independence (no cross-contamination):** lock lienId A and B concurrently; `release(A)` pays A's
  originator and does NOT touch B; `slashToCapital(B, x)` does NOT touch A; aggregate invariant holds throughout.
- **re-lock reusability:** `lock(A) → release(A) → lock(A)` succeeds with a fresh originator/amount; same after a full
  `slashToCohort(A)` clears the lien.
- **`bondOriginator` survives a partial slash:** `lock(A, orig) → slashToCapital(A, part) → release(A)` returns the
  remainder to the original `orig`.
- **reentrancy probe (concrete):** a `ReentrantToken` (the xALPHA) whose `transfer`/`transferFrom` re-enters the
  escrow; **the test sets `coordinator == address(reentrantToken)`** so the re-entrant call passes `onlyCoordinator`
  and actually exercises the guard/CEI (a plain-token callback otherwise reverts on `NotCoordinator` and proves
  nothing). Arm it to re-enter (a) the **same** function on the same lienId during `releaseXAlpha`/
  `slashXAlphaToCohort`, and (b) **cross-function** (`release` → reenter `slashToCohort`); assert the re-entrant call
  reverts (`ReentrancyGuardReentrantCall`), the outer call still completes, and the balance moved **exactly once**.
  Also arm a `lockXAlpha` reentry → reverts (guard; CEI would give `BondExists`).
- **fund-flow stateful invariant (the security thesis):** a Foundry `invariant_` with a handler exposing all four
  state-changers over a small fixed lienId set + a ghost array of touched lienIds. Assert: (i) `xAlpha.balanceOf(
  escrow) == Σ bondAmount[lienId]` over touched liens; (ii) the **sum** of xALPHA across `{escrow, capitalSink,
  sidecar, all recorded originators}` is conserved and **no other address's xALPHA balance ever increases** (i.e.
  every outbound transfer landed on one of the three destination classes, never `address(this)`/an attacker). Use
  balance-conservation accounting (not event-matching), since the mock emits no `Transfer`.
- **non-sweepable ABI-negative:** low-level `staticcall`/`call` each forbidden selector (`owner()`,
  `sweep(address,uint256)`, `sweep(address)`, `rescue(address,uint256)`, `transferOwnership(address)`,
  `renounceOwnership()`, `setCoordinator(address)`) and assert `!success` (mirrors `ZipRedemptionQueue.t.sol`'s
  no-sweep negative).
- **fuzz:** lock/slash amounts across the range (bounded to the mock mint) preserve the balance invariant.

Integration-layer mapping (for item-10 / M2, **not** built here): the lock/release path joins `audit/2.md`
Phase S (launch bonding); the slash path joins the M2 default trace — record the obligations below.

**Depends on**
- The scaffold (WOOF-00 — `forge build` green, OZ remap, the `contracts/test` MockERC20/`ReentrantUSDC` templates).
  **No other contract dependency** — this is a leaf. It imports nothing from the substrate, the Exit Gate,
  `SzipNavOracle`, `DefaultCoordinator`, or the venue; all couplings are deploy-time address wiring (below).

**Cross-ticket obligations this item CREATES (record in PROGRESS at Conclude — discharged by others later):**
- **Item 10 (deploy/wiring):** wire `xAlpha` = the bridged xALPHA (8x-01 `SzAlphaMirror`; the stand-in until the lane
  is live); `coordinator` = the loss-side orchestrator that posts launch bonds (and, once built, the M2
  `DefaultCoordinator`); `capitalSink` = the off-chain recovery/bridge account (alpha→TAO→USDC); `sidecar` = the
  8-B1 substrate **sidecar Safe** address. **Assert all four immutables wired correctly**; assert the coordinator has
  **approved the escrow** over the protocol's launch xALPHA before any `lockXAlpha`; and **assert the wired `xAlpha`
  is non-fee-on-transfer / non-rebasing** before any bond is locked (the contract has no balance-delta defense — the
  feeless assumption is load-bearing; a generic mock is fine in tests but the production token swap MUST be
  asserted hookless+feeless).
- **`DefaultCoordinator` (M2, §4.6/§11):** it is the `coordinator` for the slash path — computes the
  capital-vs-premium split off-chain (shortfall after foreclosure + insurance) and calls `slashXAlphaToCapital(part)`
  then `slashXAlphaToCohort()`; on a clean recovery it calls `releaseXAlpha`. The contract enforces only the routing
  + `amount ≤ bond`; the *split + timing policy* lives in the coordinator (the §13 trust boundary).
- **Operational invariant (terminal-call):** the coordinator MUST **terminalize every locked lien** (release, or
  slash-then-cohort) — a never-resolved bond is permanently stuck (non-sweepable by design). **Do NOT lock a bond
  against a coordinator that may be decommissioned without a live successor.** Record as an item-10 / M2 operational
  invariant.
- **`SzipNavOracle` / §12:** the sidecar Safe's xALPHA balance (grown by `slashXAlphaToCohort`) must be in the NAV
  basket read (it already reads sidecar balances, §7) so the in-kind premium accretes the frozen cohort's
  `navPerShare` — this is what makes route-to-sidecar the socialized pro-rata. (No new oracle work; confirm the
  xALPHA leg of the sidecar is valued.)
