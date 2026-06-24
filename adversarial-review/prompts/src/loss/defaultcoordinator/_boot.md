# Boot context — DefaultCoordinator adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md` / `2.md` / `3.md`) before you begin.

## The contract under review
- `contracts/src/loss/DefaultCoordinator.sol` (158 nSLOC) — the single loss-side orchestrator. A CRE-gated
  `ReceiverTemplate` that is the immutable `LienXAlphaEscrow.coordinator` (owns the xALPHA bond lifecycle)
  AND the `SzipNavOracle.defaultCoordinator` (the SOLE `writeProvision` caller). Every action flows through
  `_processReport` (reportType 8, action-discriminated `:181`) behind the Timelock-pinned Forwarder.
  Ownership is TRANSFERRED to the Timelock at deploy (governs `recoveryFloor` + build-phase wiring; **no
  theft, no NAV-inflation, no sweep, no pause**). It custodies the launch xALPHA reserve and grants the
  escrow a MAX allowance via `setEscrow` (`:147`).

**Why it matters:** this is the NAV-impairment writer. It is the only contract that can move
`SzipNavOracle.provision()`, which directly down-marks szipUSD NAV — concurrent exiters exit-poor on a
mis-mark. It also routes the entire xALPHA first-loss bond pool via the escrow. A bug here is either a
NAV-accounting error (provision desync / over-mark / inflation) or a bond-routing error.

## You MUST read the sibling — the escrow it drives
`_resolve` (`:286-287`) and `_writeOff` (`:303-304`) make a TWO-CALL cross-contract sequence into
`contracts/src/loss/LienXAlphaEscrow.sol` (`slashXAlphaToCapital` then a `bondAmount` read then
`slashXAlphaToCohort`). The coordinator does NOT pre-assert `capitalSlashAmount <= bond`; it relies on the
escrow's `ExceedsBond` revert to roll the whole report back (CEI). You cannot judge the resolve/writeoff
paths without reading the escrow. Read it.

## These are ORIGINAL contracts — the precedent is the spec posture + the discipline, not a code parent
Unlike the bridge/hydrex forks there is no audited parent to diff line-for-line. Your "supposed to be"
baselines:
- **The §13 residual-trust posture** (stated in the contract NatSpec `:22-43`, authoritative): the contract
  BOUNDS and ROUTES; it does NOT validate a default is real. The CRE (DON consensus, behind the Forwarder +
  Timelock-pinned workflow identity) is trusted for the MAGNITUDE of `atRisk`/`recoveryProceeds`/
  `capitalSlashAmount`, the TIMING, the capital-vs-premium SPLIT, and the `originator` (the release
  recipient). The on-chain guarantees are narrow and exact: (a) provision falls only by
  `atRisk×(1−recoveryFloor)`, heals up only by realized receipts or fully to 0 on resolve, floored at 0,
  never above the un-impaired basket; (b) `totalProvision == Σ lienLoss.provision == oracle.provision()`;
  (c) a bond reaches only `bondOriginator`/`adminSafe`/`juniorTrancheSafe`; (d) the status machine forbids
  re-recognition / post-resolution heal / release of a defaulted lien. **A compromised CRE can GRIEF but
  not STEAL or INFLATE NAV.** Your strongest finding is a path that breaks one of (a)–(d) — i.e. turns
  grief into theft/inflation, or desyncs the conservation seam.
- **The `ReceiverTemplate` base** — `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol`
  — the Forwarder gate + the workflow-identity pin that fronts `_processReport`. Confirm the entry guard is
  the base's, not re-implemented; attack the decode/dispatch the override adds on top.
- **The X-Ray is your ground truth** — `contracts/src/loss/x-ray/DefaultCoordinator.md` (per-contract,
  authoritative) and `contracts/src/loss/x-ray/invariants.md` (I-1…I-5, X-1/X-2, E-1, G-1…G-17). Every
  finding cites the invariant/guard it attacks.

## Tests
`contracts/test/loss/DefaultCoordinator.t.sol` — 66 unit + 1 fuzz + 3 invariant. The conservation seam
(`invariant_totalProvision_eq_sum`), the sole-writer↔oracle seam (`invariant_oracle_eq_totalProvision`), and
the default bound (`testFuzz_provision_bound`) are fuzz/invariant-asserted; the full illegal-transition
matrix is `test_full_illegal_transition_matrix`. This is the best-tested contract reviewed — see what is
proven (don't re-report it) and where the tests STOP (cross-contract resolve sequencing under a hostile
escrow state, the unsmoothed-provision→exit interaction, the build-phase re-point window).

## Ground rules
- Cite exact lines in `DefaultCoordinator.sol` AND the sibling/base line where the seam crosses a contract.
- The decisive surfaces: (1) a path where `totalProvision`, the per-lien `provision`, and `oracle.provision()`
  DESYNC or where provision is marked DOWN by more than `atRisk` / UP above the un-impaired basket (the
  dangerous direction — NAV inflation or over-impairment); (2) a status-machine or dispatch path that allows
  double-counting / re-recognition / a heal of a written-off loss; (3) a path that escalates the §13 CRE
  trust from GRIEF to THEFT or NAV-INFLATION (an attacker-chosen destination, an arbitrary NAV value).
- **Pressure-test severity (§13).** A finding that merely requires DISTRUSTING the CRE/DON within the
  documented grief ceiling (down-mark NAV, slash a healthy bond, reclaim a fresh bond via a hostile
  originator) is ACCEPTED-RISK / INFO — that is X-1, ratified. A finding is only HIGH/CRITICAL if it breaks
  a guarantee the §13 posture promises HOLDS on-chain (theft to an arbitrary address, NAV inflation, a
  conservation desync, an illegal status transition). Do not re-report X-1 as a vuln.
- The build-phase mutable wiring (X-2) is a documented residual closed by the pre-prod immutable re-freeze
  (process, not code). A finding that merely restates "the Timelock can re-point a sink" is INFO unless you
  show a re-point that drains rather than griefs/redirects.
- "Sound" is a valid result. If a surface holds, say so and show why.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/guard/residual you attack (I-1…I-5, X-1/X-2, E-1, G-n)>
- **Location:** <fn / exact line in DefaultCoordinator.sol + the sibling/base line where the seam crosses>
- **Delta from posture:** <how it breaks a §13 on-chain guarantee, or "grief-only (X-1, accepted)", or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it INFLATES or OVER-IMPAIRS NAV,
  or REDIRECTS a bond, and whether the §13 trust boundary already bounds it to grief.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line
soundness verdict (and explicitly: does the conservation seam `totalProvision==Σ==oracle.provision()` hold?).
