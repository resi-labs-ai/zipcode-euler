# Supply subsystem group — adversarial review prompts

> **Running a cycle?** Read `adversarial-review/CONDUCTOR.md` first — it's the step-by-step operating
> procedure (spawn missions, verify-before-promote, reconcile, ticket). This file is the map.

Mirrors `contracts/src/supply/`. Two distinct things live here:
- **The szipUSD junior-vault engine** — `contracts/src/supply/szipUSD/` — 14 contracts, ~1,754 nSLOC: a fleet of
  CRE-operator-gated Zodiac **Modules** running an options-yield flywheel, plus the token, the custody/issuance/
  exit gate, the duration-squeeze solvency freeze, and the shared infra. The per-contract X-Rays + the
  `portfolio-map.md` triage live under `contracts/src/supply/szipUSD/x-ray/`.
- **The collateral oracle** — `algebraichifairlpooracle/` — a standalone EVK price adapter (manipulation-resistant
  fair-LP pricing). A different beast from the engine fleet; reviewed first, prompts already authored.

One folder per contract; each holds `_boot.md` (shared context fed to every sub-agent for that contract) +
numbered mission files (`1.md`, `2.md`, …) + `context.files` (the inline file list for non-agentic panelists).
Mission count follows each contract's authored attack surface per its X-Ray — not a fixed number.

## The szipUSD engine fleet (mirrors `contracts/src/supply/szipUSD/`)

| Contract | nSLOC | Missions | Surfaces (from the X-Ray) |
|---|---:|---:|---|
| `durationfreezemodule/` | 199 | 5 | under-freeze floor (I-1/I-2) · coverage accounting/LP single-count (I-4/I-8) · value-movement/whitelist/FoT (I-3/I-6/I-7) · donation-immune reads + unseeded fail-close (I-5/I-9/X-2) · 12-setter wiring (X-1/X-3) |
| `szipbuyburnmodule/` | 244 | 5 | exact discount price bound + caps (I-2/I-4) · SEC-13 leg-anchored freshness fence (I-3/I-6) · GPv2 uid + order hardening + atomicity (I-7/I-8) · coverage gate + two-doors (I-5/I-9) · privilege/wiring (X-1) |
| `exitgate/` | 133 | 4 | two-token conservation (I-1) · no-ragequit/Baal powers (I-2/I-3) · issuance pricing/custody/fail-close (I-4/I-5/I-7/I-8) · burnFor authority + wiring (I-9) |
| `farmutilityloopmodule/` | 170 | 4 | three borrow bounds (I-2/I-3/I-5) · collateral/repay/fail-close (I-4/I-6) · exec integrity (I-7) · privilege/wiring |
| `lpstrategymodule/` | 165 | 4 | coverage path-lock seam to freeze (X-1) · redirect/pin/live-legs (I-1/I-5/I-6) · slippage/approval/exec (I-2/I-3/I-4) · privilege + setCoverageGate (X-2) |
| `recyclemodule/` | 165 | 4 | SEC-09 cumulative divert (I-3/I-4) · two-layer free-value (I-1/I-2) · CEI/no-guard reentrancy + exec (I-5/I-6/I-7) · privilege/destination/wiring (X-1) |
| `sellmodule/` | 167 | 4 | redirect/pair-pin (I-1) · size-cap (I-2) · swap-safety slippage/deadline/approval/exec (I-3..I-6) · privilege/wiring (X-1) |
| `harvestvotemodule/` | 142 | 4 | recipient pin/account-keying (I-1/I-3) · lockVe permalock (X-1) · external-integration + bubbled + live-read (I-4/I-6) · privilege/wiring |
| `offrampmodule/` | 94 | 4 | destination integrity + C4 (I-1) · live-scaleUp unit + par-neutrality (I-2/I-5) · bubbled exec/approval (I-3/I-4) · privilege/wiring |
| `exercisemodule/` | 95 | 3 | recipient pin + exec shape (I-1/I-2) · maxPayment slippage + quoteStrike (I-3/I-7) · exec/approval/live-paymentToken + wiring (I-4/I-5/I-6) |
| `clonereportreceiver/` | 57 | 3 | fail-closed clone inversion (I-1/I-4) · identity gate + assembly decode (I-2) · dispatch/MRO/setter-auth (I-3/X-1) |
| `farmutilityborrowguard/` | 53 | 3 | account-identity borrow gate (I-1) · isProxy anti-spoof (I-2/I-3) · raw-msg.sender admin + allowlist re-point (I-4) |
| `szipusd/` | 27 | 2 | Gate-only mint/burn + vanilla-ERC20 (I-1/I-2/I-3) · setGate + ctor zero-guard (I-4) |
| `mastercopyinitlock/` | 8 | 1 | clone-safety: lock holds + clones init once (I-1/I-2/I-3) |

szipUSD fleet total: **50 missions** across 14 contracts.

## The collateral oracle (standalone)

| Contract | nSLOC | Missions | Surfaces |
|---|---:|---:|---|
| `algebraichifairlpooracle/` | 58 (+43 lib) | 3 | spot-leak into the fair price · over-value rounding/overflow/domain · degenerate-TWAP non-revert (X-2) |

**Group total: 53 missions across 15 contracts.**

## The differential is the §10.1/§13 posture + the audited bases — these are ORIGINAL contracts
Unlike the bridge (diffed vs Rubicon) and hydrex-demo-fork (diffed vs their prod parents), the supply contracts
have **no audited code parent to diff line-for-line**. The "supposed to be" baselines are the posture each X-Ray
encodes + the audited bases the contracts build on:
- **The engine fleet** shares one shape — *operator supplies scalars → the module builds fixed-shape calldata →
  the Safe execs → build-phase wiring is Timelock-re-pointable* (§10.1). Each `_boot.md` names that boundary, the
  zodiac-core `Module` base, the `MastercopyInitLock` clone mixin, and the specific external (CoW/Baal/EVK/EVC/
  ICHI/Hydrex/the senior queue) it drives. The strongest finding is a delta from the boundary — a pinned field
  becoming operator-influenced, a redirect, an unbounded borrow, an under-freeze.
- **The two load-bearing brains** — `DurationFreezeModule` (the solvency floor) and `SzipBuyBurnModule` (the only
  exit valve) — carry the richest test pyramids (a 128k-call floor invariant; the SEC-13 fence + uid KAT). Their
  missions attack named invariants the suite already exercises, aiming PAST what's proven.
- **The custody core** — `ExitGate` + `SzipUSD` — the two-token conservation `totalSupply == loot.balanceOf(gate)`
  (fuzzed in the Gate) + the deliberate no-ragequit/CoW-only exit topology (ratified, see
  `exit-topology-intentional`).
- **The infra** — `CloneReportReceiver` (the fail-closed clone inversion of `ReceiverTemplate`),
  `FarmUtilityBorrowGuard` (the account-identity borrow gate), `MastercopyInitLock` (the SEC-14 clone lock) —
  small, consumer-covered bases; soundness is the expected result.

## Pressure-test severity hard (carry into every synthesis)
- **§10.1 operator-sizing (X-1)** — an operator sizing scalars within the on-chain bounds (recipient/pair pins,
  caps, slippage, coverage/freshness gates, the F1 borrow cap + EVK health + the guard) is the ratified residual:
  ACCEPTED-RISK / INFO, bounded to grief, not theft.
- **Build-phase mutable wiring (X-3)** — the Timelock can re-point wiring; that's a documented residual closed by
  the pre-prod immutable re-freeze. A bare re-point restatement is INFO unless it DRAINS or breaks an on-chain
  invariant. The sharpest ones worth working: the freeze module's leg-token whitelist drift, the buy-burn
  stranded-bid-on-rewire, the recycle `setWarehouseSafe`-to-attacker, the borrow-guard hostile-factory re-point.
- **Oracle / EVK trust (X-2)** — `SzipNavOracle`'s marks and the EVK's own health enforcement are the trusted base
  (out of scope); a finding must show THIS contract mis-USING an honest read, not "the oracle could lie".
- **Ratified design** — CoW-only exit, no on-chain forfeiting queue, no wired `baal.ragequit`, the `lockVe`
  permalock, `coverageGate == 0` = gate-off: all intentional (`exit-topology-intentional`). Don't re-report as gaps.
- A finding is HIGH/CRITICAL only if it breaks an on-chain guarantee: an under-freeze, an above-NAV fill, a
  conservation desync, a reachable ragequit/mintShares, a borrow escaping its bounds, a redirect, or a drain.

These are among the **best-tested contracts reviewed** (the freeze floor + the conservation invariant are fuzzed;
the borrow/exit controls are proven on real EVK/CoW/Baal forks). "Sound" is the expected result for most surfaces,
especially the thin wrappers and the infra bases — a manufactured finding is noise.

## Run
Per `CONDUCTOR.md`: prompts authored ✅ (this tree); X-Rays exist ✅ (`contracts/src/supply/szipUSD/x-ray/` —
per-contract files are authoritative; `portfolio-map.md` is the subsystem triage). Each mission's `context.files`
inlines the contract + its base(s)/precedent + the external it drives + the test suite for non-agentic (Fugu)
panelists. Reports/synthesis land under `adversarial-review/reports/src/supply/<contract>/` (gitignored scratch).
