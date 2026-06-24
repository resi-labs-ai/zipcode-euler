# Venue subsystem group — adversarial review prompts

> **Running a cycle?** Read `adversarial-review/CONDUCTOR.md` first — it's the step-by-step operating
> procedure (spawn missions, verify-before-promote, reconcile, ticket). This file is the map.

Mirrors `contracts/src/venue/` — the layer that actually opens and runs credit lines on a lending venue
(Base, chain 8453). Three contracts, one substantive:
- **The Euler venue adapter** — `contracts/src/venue/EulerVenueAdapter.sol` (354 nSLOC) — a per-line
  **isolated-market FACTORY**. One `openLine` atomically mints + aligns a fresh EVC borrower account
  (`LineAccount` + operator grant), an escrow collateral vault (holds the lien), an isolated USDC borrow
  vault, and a dedicated **frozen** per-line `EulerRouter`, then onboards the market to the shared
  `EulerEarn` pool. It also charges the CTR-09 per-draw origination fee, installs the CTR-13 line IRM +
  curator fee, runs the close-time dual queue-slot reclaim (SEC-06/CTR-04), and the farm-utility JIT
  fund/defund under a two-key gate. The most complex contract in the sweep; rated **HARDENED**.
- **The venue-neutral seam** — `IZipcodeVenue.sol` (24 nSLOC) — the interface the `ZipcodeController`
  drives every on-chain venue effect through; only `bytes32`/`address`/`uint*`/opaque `lineRef` cross it
  (no Euler types), keeping the controller venue-agnostic (§4.7). Pure interface; rated **ADEQUATE**.
- **The per-line borrower-of-record** — `LineAccount.sol` (8 nSLOC) — a constructor-only contract
  CREATE2-deployed by `openLine` (salt = `lienId`) that establishes a fresh EVC owner-prefix and grants
  the adapter the operator bit over its code-free `^ 1` borrow account, then goes inert (the §4.4
  "graveyard"). Rated **ADEQUATE**.

One folder per contract; each holds `_boot.md` (shared context fed to every sub-agent for that contract) +
numbered mission files (`1.md`, `2.md`, …) + `context.files` (the inline file list for non-agentic
panelists). Mission count follows each contract's authored attack surface per its X-Ray — not a fixed
number.

## The contracts (mirrors `contracts/src/venue/`)

| Contract | nSLOC | Missions | Surfaces (from the X-Ray) | Verdict |
|---|---:|---:|---|---|
| `eulervenueadapter/` | 354 | 5 | cluster-mint atomicity / orphan-freedom / isolation (I-1/I-2/I-9/I-14) · draw F2 pin + CTR-09 fee leg (I-3/I-10) · reallocate donation-immunity + fund/defund + farm-utility two-key (I-5/I-7/I-15) · the 30-market queue ceiling dual reclaim (I-6/I-8) · submitCap F3 bound + wiring/setters + IRM/curator + wire-check + AmountCap + authority + seniorPool (I-4/I-11/I-12/I-13/I-16/I-17) | HARDENED |
| `izipcodevenue/` | 24 | 1 | venue-neutrality discipline (no Euler type crosses) + dual-sided conformance (P-1…P-4) | ADEQUATE |
| `lineaccount/` | 8 | 1 | the `^ 1` sub-account (prefix-sharing + code-free) + operator grant + per-`lienId` isolation + CREATE2 (I-1…I-7) | ADEQUATE |

**Group total: 7 missions across 3 contracts.**

## The differential is the §4.7 venue-neutral posture + the audited Euler bases — these are ORIGINAL contracts
Unlike the bridge (diffed vs Rubicon) and hydrex-demo-fork (diffed vs their prod parents), the venue
contracts have **no audited code parent to diff line-for-line**. The "supposed to be" baselines are the
posture each X-Ray encodes + the audited bases the contracts build on:
- **The adapter is modeled inline on the verified `EdgeFactory.deploy()`** (`reference/evk-periphery/src/
  EdgeFactory/EdgeFactory.sol` — NOT imported, evk-periphery is un-remapped). The strongest finding is a
  **delta from that precedent** — a cluster-mint step that `EdgeFactory` does and the adapter skips (or
  vice-versa), a wiring it leaves mutable, an onboarding that orphans on a mid-cluster revert.
- **The security model IS wiring discipline** — `openLine` mints a fleet of fresh markets in one call; the
  security work is all in *how they are wired*: the draw receiver pinned to the immutable off-ramp (F2),
  the curator `submitCap` bounded to ONLY the freshly-minted vault (F3), reallocate sizing read off the EE
  **tracked** balance so a share donation can't grief it (SEC-11), the per-line router frozen
  (governance → `address(0)`), and the SEC-06/CTR-04 dual queue-slot reclaim that keeps origination from
  bricking at the 30-market `EulerEarn` cap. Each is fork-proven; a finding must be a delta the fork suite
  did NOT reach.
- **External-infra trust is the ratified base** — the EVK `GenericFactory`/`EVault`, EVC, `EulerEarn`,
  `EulerRouter`, the `CREGatingHook`, and the `ZipcodeOracleRegistry` price source are trusted dependencies
  (audited once, used per-line). A finding that distrusts one of those is accepted-risk/INFO, not a vuln —
  it must show THIS contract mis-USING an honest dependency.

## Pressure-test severity hard (carry into every synthesis)
- **External-infra trust (the residual base)** — the EVK/EVC/`EulerEarn`/`EulerRouter`/`CREGatingHook`/
  `ZipcodeOracleRegistry` stack is the trusted, audited base. "The router could lie", "the EVK could
  mis-account", "the hook could be bypassed at the EVC level" are out of scope unless the finding shows the
  adapter mis-using an honest read. ACCEPTED-RISK / INFO.
- **The two-key deploy invariant (a genuine residual with no on-chain handle)** — `farmUtilityAllocator`
  MUST differ from the `FarmUtilityLoopModule.operator` (so draining idle USDC needs both keys), but the
  adapter holds no reference to the loop module, so this can't be asserted on-chain — only proven indirectly
  (the loop-operator key reverts `NotFarmUtilityAllocator`). Restating "the deploy could wire the same key
  to both" is the KNOWN residual; the panel's job is to confirm the gate fires, not to re-flag the residual.
- **Build-phase mutable wiring (§17)** — the ~13 infra setters are Timelock-re-pointable until the deferred
  pre-prod immutable re-freeze (a process step, not on-chain). A bare re-point restatement is INFO unless it
  DRAINS or breaks an on-chain invariant (e.g. a `setErebor` that redirects a future draw, a `setGatingHook`
  that disarms isolation). The `setAdminSafe`/`setCuratorSafe` zero-as-"off" sentinels are intentional — not
  a missing zero-guard.
- **The `liquidate` stub reverts `NotImplemented` by design** (§4.4e, no on-chain economic liquidation) —
  not a gap; ratified.
- **The CREATE2 graveyard model** (the `LineAccount` cluster abandoned at close, never reclaimed) is
  intentional (§4.4/§17) — don't re-report as a leak.
- A finding is HIGH/CRITICAL only if it breaks an on-chain guarantee: a mid-cluster orphan, a draw to a
  non-`erebor` receiver, a `submitCap` on a foreign market, a donation that griefs reallocate, a leaked
  queue slot that permanently bricks origination, a foreign borrow account that draws, or a fee that exceeds
  the cap / is levied without financing.

These are among the **best fork-tested contracts reviewed** (53 Base-fork tests against the real EVK/EVC/
`EulerEarn`/`EulerRouter` stack — the right kind of test for a factory whose correctness IS its interaction
with that stack). "Sound" is the expected result for most surfaces, especially the interface and the
constructor-only `LineAccount` — a manufactured finding is noise.

## Run
Per `CONDUCTOR.md`: prompts authored ✅ (this tree); X-Rays exist ✅ (`contracts/src/venue/x-ray/` —
`EulerVenueAdapter.md` is the anchor and summarizes its two siblings; per-contract files are authoritative).
Each mission's `context.files` inlines the contract + its `EdgeFactory` precedent + the externals it drives
(EVC, `EulerEarn`, the gating hook) + the test suite for non-agentic (Fugu) panelists. Reports/synthesis
land under `adversarial-review/reports/src/venue/<contract>/` (gitignored scratch).
