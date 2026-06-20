# X-Ray — `OffRampModule.sol` (single-contract, test-connected)

> OffRampModule | 94 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/OffRampModule.sol`, the zipUSD→USDC par off-ramp
driver (credit-union.md C1) — the simplest fleet module: a **pure driver** over the BUILT `ZipRedemptionQueue` with
no new redemption logic. Connected to `test/OffRampModule.t.sol`: **18 unit + 1 base-fork = 19 tests, all passing**
(0 fuzz, 0 invariant). **Unlike the other fleet modules drilled so far, its wiring setters are already tested** —
there is no setter gap to fill here.

> The standout is the fork test: a **full real-queue cycle** (requestRedeem → epoch-fund via warehouse REPAY →
> settle → claim) that proves the C4 authorization (the queue sees the *Safe* as `msg.sender`) and end-to-end **par
> NAV-neutrality**. That's the strongest integration test among the fleet-driver modules.

## 1. What it is

A CRE-operator-gated Zodiac `Module` enabled on the rq Safe (`avatar == target == juniorTrancheSafe`). It turns the
basket's idle zipUSD into USDC by driving the `ZipRedemptionQueue` — par + the 30-day epoch + pro-rata partial fills
are the *queue's* job (it is `onlyController`-settled by the CRE after the warehouse REDEEM/REPAY). Two operator
actions:
- `requestRedeem(zipAmount)` — `approve(queue, amt)` → `queue.requestRedeem(amt, juniorTrancheSafe, juniorTrancheSafe)`
  → `approve(queue, 0)`; `amt` must be a whole multiple of the queue's **live** `scaleUp()`.
- `claim(assets)` — `queue.withdraw(assets, juniorTrancheSafe, juniorTrancheSafe)`.

**The trust/scope (§10.1):** the redeemed USDC sink is the wired `juniorTrancheSafe` only — `requester`/`owner`/
`receiver` are never operator-supplied. It NEVER touches the warehouse Safe (the CRE drives REDEEM/REPAY through
`WarehouseAdminModule`) and never sells xALPHA or any other leg. Because it `exec`s *through* the Safe, the queue
sees the Safe as `msg.sender`, so `requester == owner == juniorTrancheSafe` satisfies the queue's
`owner == msg.sender` check **and** the USDC claim accrues to the rq Safe (C4).

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `requestRedeem(zipAmount)` | operator-only | 3 execs (approve→requestRedeem→reset); `ZeroAmount` + `NotWholeUnit` (vs live `scaleUp()`) guards |
| `claim(assets)` | operator-only | 1 exec `queue.withdraw(assets, Safe, Safe)`; `ZeroAmount` guard |
| `setUp` + 4 × `setX` | `initializer` / `onlyOwner` | clone init; build-phase wiring (`setJuniorTrancheSafe` syncs avatar/target) |

No permissionless mutators. No custody, no recipient parameter — every queue arg is the pinned `juniorTrancheSafe`.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **destination integrity** — `requester == owner == receiver == juniorTrancheSafe`, never operator-supplied; USDC accrues to the rq Safe | Yes | `test_requestRedeem_exec_shape` / `test_claim_exec_shape` (args == Safe), **`test_fork_full_cycle_par_nav_neutral`** (queue's `RedeemRequest.sender`/owner/requester all == Safe — the C4 proof) |
| I-2 | **whole-unit vs LIVE `scaleUp()`** — `zipAmount % queue.scaleUp() == 0` (re-read, never hard-coded `1e12`) | Yes | **`test_requestRedeem_reads_scaleUp_live`** (sets a non-1e12 scaleUp; an amount that's a multiple of 1e12 but not the live scaleUp reverts `NotWholeUnit`) |
| I-3 | **no standing approval** — approve→requestRedeem→reset; atomic | Yes | `test_requestRedeem_exec_shape` (3 calls incl. reset to 0), fork (`allowance == 0` after) |
| I-4 | **bubbling `_exec`** — a swallowed queue revert hard-reverts (no silent no-op / dangling approval) | Yes | `test_requestRedeem_bubbles_on_inner_fail` (bubbles "forced-fail"), `test_exec_failed_empty_revert_data` (`ExecFailed` on empty) |
| I-5 | **par NAV-neutrality** — over a full cycle the basket loses `Q` zipUSD ($1) and gains `par` USDC ($1) — exactly neutral | Yes (economic) | **`test_fork_full_cycle_par_nav_neutral`** (`zipUSD out == USDC in at par`, against the real queue + settled epoch) |
| X-1 | §10.1 residual: operator sizes `(zipAmount, assets)` each period — bounded, not theft | **No** | destination pin + never-touches-warehouse/xALPHA + the queue owning par/epoch/pro-rata cap it on-chain |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `setUp` zero-addr (×5) / owner==operator / abi length / initializer-once / mastercopy lock (SEC-14) | `test_setUp_rejects_zero_in_each_of_five`, `_rejects_owner_equals_operator`, `_abi_length_mismatch_reverts`, `_initializer_once`, `test_SEC14_mastercopy_setUp_reverts`, `test_mastercopy_inert` |
| `setOperator` owner-recheck (SEC-15) | `test_SEC15_setOperator_owner_recheck` |
| `NotOperator` on both actions | `test_action_legs_only_operator` |
| `ZeroAmount` (requestRedeem + claim) | `test_requestRedeem_zero_amount_reverts`, `test_claim_zero_amount_reverts` |
| `NotWholeUnit` (live scaleUp) | `test_requestRedeem_reads_scaleUp_live` |
| operator cannot redirect Safe | `test_operator_cannot_redirect_safe` |
| **wiring setters (onlyOwner + zero-guard + avatar/target sync)** | **`test_wiring_setters_onlyOwner_and_zero_guard`** — already present (no gap, unlike the sibling fleet modules) |

## 5. Attack surfaces

- **Destination integrity is the whole safety story (I-1) — proven on a live cycle** — the operator only sizes
  amounts; every queue arg is the pinned `juniorTrancheSafe`, so a compromised operator cannot route redeemed USDC
  anywhere but the rq Safe. The fork test decodes the real queue's `RedeemRequest` and confirms `sender`/`owner`/
  `requester` are all the Safe (the C4 authorization holds because the module execs *through* the Safe).
- **Par NAV-neutrality (I-5)** — the economic invariant: redeeming at par and claiming the USDC back leaves basket
  value unchanged. Proven end-to-end against the real queue with a settled epoch — the most complete integration
  test of the fleet-driver modules.
- **Live `scaleUp()` read (I-2)** — the whole-unit guard reads the queue's *live* `scaleUp()` (re-derived on the
  queue's `setTokens`), never a hard-coded `1e12` — so a queue re-scale can't silently desync the unit check. Tested
  with a non-1e12 scaleUp.
- **Bubbling `_exec` (I-4)** — a plain `exec` would let the Safe swallow a queue revert and silently no-op (leaving a
  dangling approval); the bubbling `_exec` hard-reverts. Both the bubble and the empty-data `ExecFailed` fallback are
  tested.
- **No setter gap** — uniquely among the fleet modules drilled so far, `test_wiring_setters_onlyOwner_and_zero_guard`
  already covers the setters (onlyOwner, zero-guard, `setJuniorTrancheSafe` avatar/target sync), and SEC-15 covers
  `setOperator`'s owner-recheck. Nothing to add. (Minor: `setZipUSD`'s effect assertion isn't explicit, but its
  shared `onlyOwner`+zero-guard pattern is exercised on the representative setters — not worth a separate test.)
- **No fuzz/invariant — correctly omitted** — a deterministic driver with one modulo guard; the queue owns the
  economic logic (par/epoch/pro-rata) and is tested in its own suite. The fork cycle is the higher-value check.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Unit | 18 | setUp/guards, SEC-14/15 clone-safety, the wiring-setter coverage, both action exec-shapes, the live-`scaleUp` whole-unit guard, zero-amount edges, the bubble + empty-data fallback |
| Base-fork | 1 | **full real-queue cycle**: requestRedeem (C4 `RedeemRequest.sender == Safe`, approval reset) → warehouse REPAY funds the epoch → `settleEpoch` → claim → par NAV-neutrality asserted |
| Stateless fuzz / invariant | 0 | deterministic driver; the queue owns the economic logic (tested separately) |

All **19 pass** (`forge test --match-path test/OffRampModule.t.sol`). The decisive properties (destination integrity,
par neutrality, live-scaleUp guard, bubbled reverts) are tested unit + a complete live-queue cycle. Coverage %
uninstrumentable (project-wide stack-too-deep); green run confirmed.

## X-Ray Verdict

**ADEQUATE** — the cleanest, best-integration-tested fleet driver: a thin pure-driver over the `ZipRedemptionQueue`
with destination integrity (every queue arg pinned to `juniorTrancheSafe`), a live-`scaleUp` whole-unit guard,
bubbled reverts, and a **full real-queue cycle proving C4 + par NAV-neutrality**. It is also the first fleet module
whose wiring setters were already tested (no gap to fill). Capped at ADEQUATE only by: no fuzz/invariant (correctly
low-value — the queue owns the economic logic), the §10.1 operator-sizing residual (bounded by the destination pin +
the queue's par/epoch math), and the build-phase mutable wiring pending the pre-prod re-freeze. No outstanding
coverage gap on the contract surface.

**Structural facts:**
1. 94 nSLOC; clone (`MastercopyInitLock` + `initializer`, no immutable); no custody; sibling of `RecycleModule`/`SzipBuyBurnModule`.
2. Pure driver over `ZipRedemptionQueue`: `requestRedeem` (3 execs, approve/request/reset) + `claim` (1 exec); every queue arg is the pinned `juniorTrancheSafe` (requester==owner==receiver), never operator-supplied.
3. Whole-unit guard reads the queue's LIVE `scaleUp()`; bubbling `_exec` prevents a swallowed queue revert; never touches the warehouse Safe or any non-zipUSD leg.
4. Tests: 18 unit + 1 base-fork (0 fuzz/invariant); the fork is a full cycle proving C4 (`msg.sender == Safe` at the queue) and par NAV-neutrality.
5. No outstanding coverage gap — wiring setters already tested; residuals are the operator-sizing trust + the pre-prod wiring re-freeze.
