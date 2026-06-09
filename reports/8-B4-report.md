# 8-B4 — authoring-window report to the superintendent

**From:** the builder Claude (ticket-authoring harness). **To:** the superintendent.
**Item:** `SzipNavOracle` (historically "8-B4") — the szipUSD NAV-per-share oracle (§7 / `baal-spec.md §3`).
**Date:** 2026-06-07. **Branch:** `main`.

## TL;DR
- Authored + **BUILT-VERIFIED** the szipUSD junior-vault NAV oracle: `contract SzipNavOracle is ReceiverTemplate`
  — the **issuance + exit pricing primitive** (NOT display-only). It composes basket NAV on-chain across both
  Safes (incl. the staked ICHI LP), CRE-pushes only the off-chain leg marks (reportType 7), maintains an on-chain
  windowed-TWAP (`W=4h`) on `navPerShare`, and serves `navEntry=max(spot,twap)` / `navExit=min(spot,twap)`.
- Code on disk, `forge test` green: **39/39 new tests pass** (incl. a live Base-fork sig-verification of the
  USDC/ICHI/gauge/oHYDX faces); **154/154 total, no regression** (`forge test --fork-url $BASE_RPC_URL`).
  Files: `contracts/src/supply/SzipNavOracle.sol` (~330 LOC), `contracts/src/interfaces/bridge/IXAlphaRate.sol`,
  `contracts/test/SzipNavOracle.t.sol`; `IOptionToken.discount()` added to the stub (on-chain verified == 30).
- **3 spec gaps fixed in `claude-zipcode.md`** (no §17 reopened); **1 unanimous interface BLOCKER fixed**.
- **Build-process caveat — please note (below):** I authored AND built it in one window (the build-subagent
  dropped on a socket error mid-run and couldn't be resumed), so the formal *fresh-subagent zero-guess* gate
  wasn't run independently.
- **NEXT = the Exit Gate + szipUSD** (`baal-spec.md §4/§5`).

## Spec edits this window (please sanity-check — spec-fidelity critic confirmed all 3 faithful, no §17 reopened)
1. **§4.4** — added **`reportType 7` NAV leg price** `(uint8[] legs, uint256[] prices, uint32 ts)` (→ `SzipNavOracle`)
   to the report-ABI table + the routing note. There was previously no enumerated type for the NAV leg-price push
   the CRE sends this oracle (only 1–6 existed).
2. **§7** — named the oracle's **two write authorities** (immutable Forwarder reportType-7 vs the set-once bounded
   `DefaultCoordinator` provision writer), the `navPerShare = basketNAV/(totalSupply − engine pending-burn)`
   denominator, the set-once share-token wiring + renounce-freeze, and the zero-supply genesis `navPerShare₀`.
3. **§12** — rewrote the **stale residual** the PROGRESS banner flagged: §12 still described "NAV display-only /
   WITHHOLD-not-markdown / in-kind exit with **no oracle in the exit path**," which directly contradicted §7/§4.5/
   §11/§17. Now the two-token / `SzipNavOracle`-issuance-exit-primitive / pari-passu provision-that-recovers model.
   (spec-fidelity also confirmed no other active stale residue — the rest is covered by the §4.5 SUPERSEDED markers.)

## The interface BLOCKER (all 5 critics) → fixed
`IOptionToken.discount()` was **absent** from the stub (it had `getDiscountedPrice(uint256)` only). I verified
`discount()` on the live oHYDX (`0xA113…`) returns **30** (selector `0x6b6f4a9d`) and added it to
`contracts/src/interfaces/hydrex/IOptionToken.sol`. The oHYDX intrinsic mark = `HYDX × (100 − discount)/100`.

## Critic fanout (5) → folded
junior-dev / spec-fidelity / ref-verifier / qa / security (full set — foundational/intricate contract).
- **spec-fidelity = clean PASS** (3 edits faithful, §17 honored, no stale residue, no inbound obligations owed).
- **ref-verifier = PASS** except the `discount()` BLOCKER (fixed); confirmed `is ReceiverTemplate`-only (NOT
  BaseAdapter) is correct, and ICHI/gauge/IERC20/ReceiverTemplate faces all resolve.
- **junior-dev / qa = ticket-clarity** (no spec gaps): folded → explicit **TWAP ring walk-back pseudocode**,
  **`uint256 cumNav`** (dropped the `uint224` packing → removes the overflow/precision ambiguity), a **definitive
  flat constructor** (not a struct), `_legPriceOfToken`/`_tokenValue`/**`supplyLp==0`** LP-valuation clarity, the
  **pinned required-leg set** `{alphaUSD, HYDX}` (both always-pushed in M1 — HYDX pool is thin, so no Algebra-oracle
  TWAP read), and the full qa edge-case test list.
- **security = natspec + downstream-obligations** (folded as "Documented invariants" + the obligation rows), plus
  two findings I judged to be **misanalyses** and recorded as documented invariants (your call to confirm):
  - The `max`/`min` bracket **defends the profitable direction of a one-block spot spike**: `navEntry=max` makes a
    spike-UP mint *more* expensive (not cheap), `navExit=min` ignores a spike-UP (no exit-rich). I added a test
    (`test_one_block_spike_does_not_enable_cheap_mint`) proving it.
    - The **ICHI-donation "attack" is unprofitable** under round-down + pari-passu (a donor recovers `share× donation
    < donation`); marking reserves at *external* leg prices (not the pool's internal spot) also neutralizes a
    flash-swap skew. Recorded as a documented invariant; the genuine residual (stale-mark exit) is the §3.3
    by-design asymmetry, defended by the Gate's `poke()` obligation.

## What the build proves (the keepsake)
`forge build` clean (solc 0.8.24). 39 unit tests cover: deploy/immutables + set-once/auth; genesis price (zero
supply → `1e18`); reportType-7 push + every guard (forwarder/type/length/empty/invalid-leg/zero-price/future-ts);
deviation circuit-break (first-push-exempt, ±20% boundary); **batch atomicity** (one bad entry reverts all, no
partial write); **NAV composition hand-computed** (the two-Safe sum, USDC ×1e12, xALPHA `exchangeRate×alphaUSD`,
oHYDX `(100−discount)/100`, engine pending-burn subtraction + underflow-to-genesis); **ICHI LP marked-through**
(staked+unstaked over both Safes, IL moves with `alphaUSD`, `UnknownLpToken`, `supplyLp==0`, unset→0); **windowed
TWAP + bracket** (exact `2.2e18` hand-computed, ring wrap-around past CARDINALITY=65, `dt==0` no-op, fallback-to-
spot before `W`); staleness asymmetry (issuance pauses, exit doesn't; single-leg-stale); provision (immediate,
recovers, unbounded → floors at 0); forwarder-immutability-via-renounce + identity. **Plus a live Base-fork
sig-verification** (`test_fork_external_signatures`, self-skips off-fork) confirming USDC `decimals==6`, the ICHI
`getTotalAmounts/token0/token1/totalSupply/balanceOf`, the gauge `balanceOf`, and oHYDX `discount()==30`.

## Build-discovered / design decisions to sanity-check
- **`cumNav` and `Observation.cum` are `uint256`** (not the `uint224`-packed form a first draft considered) — the
  qa critic flagged the cast/overflow ambiguity; uint256 removes it at a small gas cost, correct for a pricing
  primitive.
- **The guard params `W`/`maxAge`/`maxDeviationBps` are constructor immutables** (governance's deploy-time
  default), matching WOOF-02's immutable `validityWindow` + the renounce-to-freeze pattern. If governance wants to
  re-tune a guard post-deploy without losing the accumulator, that's a future setter / redeploy — flagged.
- **xALPHA leg = on-chain `exchangeRate()` × pushed `alphaUSD`.** M1 reads `exchangeRate()` from a STAND-IN mock;
  the production Rubicon `LiquidStakedV3` getter selector + supply-immutability are verified at 8x/bridge
  integration (PROGRESS xALPHA-stand-in resolution; flagged, not blocked).
- **`writeProvision` is unbounded at the oracle by design** (bound lives in the M2 `DefaultCoordinator`). Until the
  coordinator is wired it reverts for everyone (fail-closed). Documented + tested.

## Process caveat (your call)
I **authored and built this in one window.** The harness step-4 *fresh-subagent zero-guess* build was attempted
but the build-subagent's connection dropped ~18 min in (after writing only `IXAlphaRate.sol`), and SendMessage to
resume it was unavailable in this context, so I materialized the contract + tests directly. Mitigations: the
critic fanout had already hardened the ticket; the build surfaced **no ticket contradiction** (I implemented the
ticket as written — the ticket is on disk and self-contained); and the code is **green + kept + fork-verified**
(the keep-the-build proof the doctrine privileges). **If you want the formal zero-guess gate closed, a fresh
window can re-materialize from `tickets/sodo/8-B4-szip-nav-oracle.md` alone** — it should reproduce the same
contract. I did not git-commit (the whole repo working-tree is untracked on `main`, same state as 8-B1 — your
standing decision on version control applies).

## Status
`SzipNavOracle` **DONE** (built-verified on disk, not committed). PROGRESS + LEDGER updated; 3 spec gaps fixed in
`claude-zipcode.md` (§4.4/§7/§12); `IOptionToken.discount()` added; 5 downstream obligations recorded. **NEXT =
the Exit Gate + szipUSD** (`baal-spec.md §4/§5`) — it reads `navEntry`/`navExit`, `poke()`s the accumulator, and
is wired into the oracle via `setShareToken`.
