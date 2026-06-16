# zipcode-euler — Claude adversarial audit: consolidated summary

Four independent passes, each a parallel fan-out of Claude subagents using the methodology in
`adversarial-spec.md`. The passes are deliberately orthogonal so they catch different bug classes;
where they converge on the same finding, that's cross-confirmation (high confidence).

| Pass | File | Structure | What it's good at |
|---|---|---|---|
| Subsystem | `findings.md` | 1 auditor per subsystem (6) | depth within a subsystem |
| Role-based | `role-based-findings.md` | 1 specialist per attack discipline (8) | cross-contract *consistency* of one discipline |
| Reference-diff | `reference-diff-findings.md` | 1 agent per upstream integration (6) | assumptions about upstream behavior that don't hold |
| Interconnection | `interconnection-findings.md` | 1 agent per money-flow (6) | bugs that live only in the hand-offs between contracts |

26 subagents total. Acknowledged-trust posture (malicious Timelock; compromised CRE within its
documented blast radius) is excluded from findings throughout — that discipline is what keeps this list
signal, not noise.

## Master findings (deduplicated, severity-ranked)

### HIGH
| ID | Finding | Where it surfaced | Fix |
|---|---|---|---|
| H1 | **Registry has no monotonic-timestamp guard** — a stale/replayed/backdated revaluation overwrites a fresher mark, shielding an undercollateralized loan from liquidation or griefing borrows. Manifests on the draw critical path (C4): RT2 re-seed overwrites a fresher RT3 down-revaluation, read directly by the borrow status-check. | subsystem #1, role-A, proxy, interconnection-C4 (4× independent) | `if (ts <= cache.timestamp) revert` (match `SzAlphaRateOracle`) |
| H2 ✅ | **`openLine` grows the EulerEarn supply queue unboundedly and never prunes** — origination permanently bricks at MAX_QUEUE_LENGTH=30. Confirmed against upstream EulerEarn (double-enforced via the withdraw queue too). **RESOLVED 2026-06-15 (SEC-06):** `closeLine` rebuilds the supply queue into a `qlen-1` array excluding the closed `lineRef` (address match, not last-position) + `setSupplyQueue` (`EulerVenueAdapter.sol:357-373`). Queue bounded by concurrent (not cumulative) lines; >30-origination churn test stays live. *(L8/SEC-07 USDC-defund is the distinct sibling — same fn, not subsumed.)* | subsystem #2, role-A, ref-B, interconnection-C (4×) | prune closed-line vaults in `closeLine`; cap concurrent not cumulative |
| H3 | **Loot `ragequit` basket-drain** — szipUSD's entire exit-control thesis assumes Baal Loot is non-transferable, but Baal ships it transferable unless paused and `ExitGate` never pauses it. A holder with raw Loot can `ragequit` the main-Safe basket, bypassing the buy-burn rail + coverage gate. *Invisible to source-only review.* | ref-B (Baal diff) | assert `loot.paused()==true` + `lockAdmin()` at wire; hard deploy invariant |
| H4 ✅ | **CCIP `TokenAdminRegistry` admin left as the ephemeral deploy Script**, never handed to the Timelock — the pool can never be re-pointed (RMN rotation) or delisted; `setCCIPAdmin` only changes a cosmetic view. **RESOLVED 2026-06-15 (SEC-03):** `transferAdminRole`(964→ccipAdmin, Base→timelock) + 2-step `acceptAdminRole` runbook + `pendingAdministrator` assert. | subsystem #11 (low) → ref-B (confirmed HIGH vs upstream) | explicit `transferAdminRole(timelock)` + `acceptAdminRole` |
| H5 ✅ | **xALPHA rate freshness gate is wired into issuance only, not into coverage/exit/release** — a stale-high rate (validator-slash propagation lag) or a 0 rate (never-pushed) opens the freeze hatch and exit pricing **below the true senior floor**, because the floor is rate-independent (USDC) but `coverageValue` is rate-dependent. **RESOLVED 2026-06-15 (SEC-04):** `error RateUnseeded` + `if (rate == 0) revert` in the shared `_xAlphaUSD()` — all four consumers fail-close on the unseeded (genesis) zero. The stale-HIGH (moving-rate) half was **deliberately not gated on `fresh()`** — that would break the §7 last-good-mark exit asymmetry (ratified); TWAP-lag + deviation-band remain the defense for a moving rate. | subsystem #6 (med) → role-A → interconnection-C1 (escalated HIGH) | gate every `_xAlphaUSD` consumer on `fresh()`; treat 0 as fail-closed |

### MEDIUM
| ID | Finding | Where |
|---|---|---|
| M1 | `SzipNavOracle` leg-cache has no monotonic guard → a backdated/replayed NAV-leg report freezes **all** issuance + buy-burn (protocol-wide DoS, no value manipulation). | role-A (R1) |
| M2 | `coverageValue()` **double-counts sidecar ICHI-LP** (in `committedValue` + `pathLockedLpEquity`) → `covered()`/`release` pass while undercovered. Reachable by **anyone** (LP is a transferable ERC20 → transfer to sidecar). | subsystem #7, role-A, interconnection-C (3×) |
| M3 | Coverage gate is **post-time only** — a resting CoW buy-burn bid keeps filling after coverage drops below floor (no fill-time re-check). | subsystem #5, interconnection-C |
| M4 ✅ | `SzipReservoirLpOracle` CRE receiver deployed with **zero workflow-identity** → any co-tenant workflow on the shared Forwarder can push LP collateral marks → over-borrow. **RESOLVED 2026-06-15 (SEC-05):** P9 seals `d.lpOracle` (`:535`) + new `requireReceiverIdentityWired(address)` per-receiver pre-gate (`error ReceiverIdentityNotWired`, `:542`), both guarded `!= address(0)` (fair-LP branch unaffected). 7 `test_SEC05_*` incl. dormant-accepts vs sealed-rejects on the REAL oracle. | ref-B (B3) |
| M5 | Coverage gate **defaults OFF when `coverageGate==0`** (M1 pre-wiring) → buy-burn outflow + LP dissolution entirely unfenced. | subsystem #8 |
| M6 | `openLine` silently requires EE `timelock==0` + perspective allow-listing, or **every origination reverts**. | role-A, ref-B (B4), interconnection-C |
| M7 | `RecycleModule.divert` has **no cumulative tally** vs `provision()` → the same default markdown can be over-filled across calls (per-call ceiling, not cumulative). | interconnection-C2 |
| M8 | `_resolve` heals the full junior provision with **no realized-receipt bound** (unlike `_recovery`) → junior NAV marks up on a "clean resolution" carrying no recovery. | interconnection-C3 |
| M9 | Gate manager grant can be **permanently bricked on a re-pointed Baal** if `managerLock==true`. | ref-B (B5) |

### LOW (18) — abbreviated
`requiredCommittedValue` gross-cap can make `covered()` permanently false (bricks release/postBid) · `lpTwapWindow` misconfig cascade-bricks all NAV reads · `SzipReservoirLpOracle` monotonic gap · revaluation batch all-or-nothing stales every lien on one bad key · `fund` base→line-only strands closed-line USDC · `fund` `balanceOf`-vs-`config` donation-grief DoS · redemption-queue missing unclaimed-claimable guard · `redeem` missing whole-unit guard + overstated event · NAV-freshness `validTo` edge stale fill · `postBid` unsatisfiable at `maxAge==0` · RESOLVE/WRITEOFF `ExceedsBond` strands lien in Defaulted · szALPHA sub-rao dust unredeemable · reservoir borrow double-counts coverage (self-brick) · `freeValue` desyncs from `gross−coverageValue` · adapters omit inverse-direction (BaseAdapter convention) · registry global scale assumes 18-dp base · USDC→eePool approval not reset · `setOperator` peer-guard divergence (7 of 8 modules). _Details in the per-pass files._

### INFORMATIONAL / design
Zodiac module mastercopies never init-locked (docstring false; benign — CALL-only) · `SzAlphaRateOracle` "no owner / all knobs immutable" doc inaccurate · par-burn settlement hardcodes 1:1 with no impairment haircut (peg integrity pushed entirely to trust) · junior szipUSD has no on-chain exit path (design trade-off) · szipUSD issuance decoupled from EE share value (zipUSD hard-marked $1).

## The cross-cutting root cause
The dominant systemic weakness is **inconsistent freshness/monotonicity enforcement across oracle read
and write surfaces.** The protocol guards it in some places (`SzAlphaRateOracle` strictly-newer;
`navEntry()` fail-closed) and omits the identical guard in parallel places: the registry revaluation
(H1), the NAV leg-cache (M1), the reservoir LP oracle (low), and every non-issuance consumer of the
xALPHA rate (H5). Four of the five HIGH/most-severe findings trace to this single inconsistency. A
freshness/monotonicity invariant applied uniformly across all push-oracle writes *and* all value reads
would close H1, H5, M1, and three LOWs at once.

## What's genuinely solid (verified, not findings)
The EVK/EVC integration is byte-faithful; the Subtensor precompile usage is correct; reentrancy and
arithmetic are clean; the `max/min(spot,twap)` bracket + buy-burn discount + size caps neutralize the
MEV/sandwich theses; the loss-side accounting identity (`totalProvision == Σ == oracle.provision()`)
holds against CRE-only attackers; the deposit/zap and senior-redemption flows conserve value end-to-end;
CCIP transport doesn't desync NAV/escrow accounting. The protocol is well-built; the findings cluster in
the oracle-freshness seams, the coverage-gate math, and a few deploy-time/liveness foot-guns.
