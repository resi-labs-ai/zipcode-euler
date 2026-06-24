# Boot context — ZipcodeController adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md` … `5.md`) before you begin. This is the **portable core's orchestrator** (§4.4), rated **HARDENED** in
its X-Ray — soundness is the expected result. The value is a precise break of a NAMED invariant (I-1…I-11) or
a confirmation it holds, grounded in the precedent.

## The contract under review
- `contracts/src/ZipcodeController.sol` (174 nSLOC) — the CRE receiver, the per-`reportType` decision logic, and
  the lien-token mint/burn authority. It is the on-chain borrower of record but it touches **NO EVC**: every
  on-chain venue effect (open a line, set LTV/caps, fund, draw, observe debt, close) is driven through the
  venue-neutral `IZipcodeVenue` seam (§4.7); the per-line EVC borrow-on-behalf is the adapter's job (it is the
  line's per-line EVC operator, granted inside `openLine`). The controller holds NO funds beyond a transient
  `1e18` lien `approve` reset by `closeLine`'s reclaim. A `ReceiverTemplate` (CRE receiver, owner = Timelock).
  Five Timelock-settable wiring slots (`venue`/`lienFactory`/`oracleRegistry`/`erebor`/`registry`) + a per-lien
  record map. The single inbound is `onReport` → `_processReport` (`:192`), dispatching by `reportType`:
  - **`_origination`** (RT=1, `:212-261`) — the atomic 9-step batch: `_venueFor(siloId)` → `LienExists` dup-guard →
    `computeAddress`+`create`+`PrecomputeMismatch` assert → approve exactly `FULL_LIEN`=1e18 → `openLine` →
    `seedPrice` (on the openLine-returned `oracleKey`) → `setLineLimits` → `fund`+`draw` (to `erebor`) → store
    record (LAST write) → `incrementLineCount` (FINAL). Any revert rolls back the WHOLE batch incl. the CREATE2
    deploys (no orphan lien/market).
  - **`_draw`** (RT=2, `:264-283`) — re-resolve the SAME venue from the STORED `siloId` → re-anchor `seedPrice` →
    `fund` → `draw`; fail-closed `UnknownLien` on a closed/unknown line.
  - **`_close`** (RT=4, `:286-309`) — `observeDebt != 0 → DebtOutstanding` → `closeLine` (reclaims the lien) →
    `burn(FULL_LIEN)` (RECLAIM-BEFORE-BURN) → flip `open=false` (keeps `r.lien` — single-use lienId forever) →
    `decrementLineCount`.
  - **RT=5/6 (default/liquidation)** — M1 status-marker only (emit `LienStatusUpdated`, no venue/escrow effect).
    **RT=3 (revaluation, delivered DIRECT to the registry, §4.1) and any other** → `UnsupportedReportType`.

**Why it matters:** an origination touches the factory, the venue (5 calls), the oracle, and the registry; a
failure at any step must leave NO orphan lien/market. Draws/closes must always re-resolve the venue from the
line's STORED `siloId`, never a global pointer, so a re-pointed/retired silo cannot strand or misroute a line.
The report-type allow-list must reject everything that isn't origination/draw/close/default/liquidation. The
three drill questions: **is origination atomic, is routing fail-closed, and does the allow-list hold?**

## These are ORIGINAL contracts — the precedent is the ReceiverTemplate base + the §4.4 orchestration posture
Unlike the bridge/hydrex forks there is no audited parent to diff line-for-line. Your "supposed to be"
baselines:
- **The CRE-receiver base** — `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol` —
  supplies the inbound `onReport` (the Forwarder gate `:83` + the optional workflow-identity gate `:88-117`),
  the `onlyOwner` parent setters (`setForwarderAddress`/`setExpectedAuthor`/`setExpectedWorkflowName`/
  `setExpectedWorkflowId`), and the abstract `_processReport` the controller overrides (`:232`). Confirm the
  inbound gate is the base's, not re-implemented; attack what the override adds on top (the decode + dispatch).
- **The §4.4 orchestration posture** (the contract NatSpec `:35-41`, authoritative): a PURE orchestrator —
  decode a CRE report → dispatch by `reportType` → drive the venue seam + seed the oracle + manage the lien
  token. It touches NO EVC; the report paths route EXCLUSIVELY via the registry (`_venueFor`, `:178-182`),
  never the `venue` slot; the unwired registry fails closed (`RegistryUnset`) rather than falling back. **The
  strongest finding is a path where a mid-batch revert leaves an orphan lien/market, where a draw/close
  misroutes via a global pointer, where the allow-list lets reportType 3 (or a truncated payload) through, or
  where the transient lien approve leaks a standing allowance.**
- **The venue seam** — `contracts/src/venue/IZipcodeVenue.sol` — only `bytes32`/`address`/`uint*`/opaque
  `lineRef` cross this boundary; NO Euler types leak. Confirm the controller drives every venue effect through
  it and never reaches behind it to EVC.
- **The lien factory + token** — `contracts/src/LienTokenFactory.sol` (CREATE2 `create`/`computeAddress`, salt
  = `keccak256(abi.encode(lienId))`, caller-bound authority) and `contracts/src/LienCollateralToken.sol` (1/1
  fixed-supply, 1e18 minted-once to the controller, controller-only `burn`, decimals pinned 18).
- **The oracle it seeds** — `contracts/src/ZipcodeOracleRegistry.sol` — the controller is the set-once
  `seedPrice` caller (`:113`, `NotController`-gated); the registry's `_writePrice` (`:141`) enforces
  price!=0 / price<=uint208.max / ts<=now / strictly-newer-ts / decimals()==18 (fail-closed).
- **The silo registry it routes through** — `contracts/src/SiloRegistry.sol` — `venueOf` (`:257`, ignores
  `active`), `incrementLineCount`/`decrementLineCount` (`:240`/`:248`, `onlyController`, `SiloFull`/
  `NoLinesToDecrement` guards, cap `MAX_LINES_PER_SILO=28`).
- **The X-Ray is your ground truth** — `contracts/src/x-ray/ZipcodeController.md` (I-1…I-11, the guard table,
  the attack surfaces). Every finding cites the invariant/guard it attacks.

## Tests
`contracts/test/ZipcodeController.t.sol` — a **~43-test Base-fork suite** against the real EVK/EVC/EulerEarn
stack via the real `EulerVenueAdapter`, plus `RecordingVenue` / `ReentrantVenue` / `MockSiloRegistry`
harnesses (a `MockEulerEarn` supplies real cash on `reallocate` so the live borrow has cash — the LTV check is
the gate, not a cash shortfall). This is a fork-INTEGRATION suite: the orchestrator's correctness IS its
end-to-end interaction with the venue. The atomicity cluster drives a late revert (over-LTV), a mid-batch
revert (zero-mark, proving the CREATE2 deploys roll back), and the `SiloFull` rollback — the highest-value
tests for an orchestrator. Coverage % is uninstrumentable (project-wide `Stack too deep`). See what is proven
(don't re-report) and where the tests STOP (the build-phase re-point window; any incident the fork suite's
action set doesn't model).

## Ground rules
- Cite exact lines in `ZipcodeController.sol` AND the `IZipcodeVenue` / `ReceiverTemplate` / factory / registry
  line where the seam crosses.
- **Orchestrator touches NO EVC.** Every venue effect goes through `IZipcodeVenue`; the per-line EVC
  borrow-on-behalf is the adapter's (it is the line's operator, NOT the controller — `test_LiveBorrow_
  NoControllerOperatorWiring` proves the adapter, not the controller, is the granted operator). A finding that
  asserts the controller should touch EVC, or distrusts the adapter's internal EVC use, is out of scope: the
  venue adapter is a trusted, separately-X-rayed dependency.
- **Atomicity is the core safety property.** The decisive break is a mid-batch revert (over-LTV draw, zero-mark
  seed, `SiloFull`, a `PrecomputeMismatch`) that leaves an orphan lien token, an orphan LineAccount/market, an
  orphan seed, or a phantom line count — OR a double-mint on a dup lienId. The `liens` write is the LAST state
  mutation and `incrementLineCount` is the FINAL statement (last-write reentrancy safety, the trusted
  no-callback registry); confirm the ordering can't be exploited.
- **Fail-closed routing is the multi-silo safety net.** Draws/closes re-resolve from the line's STORED `siloId`
  via the registry (`_venueFor`), never a mutable global pointer — so a re-pointed/retired silo can't strand or
  misroute an open line, and a line always closes even after its silo is retired (`venueOf` ignores `active`).
  The unwired registry fails closed (`RegistryUnset`); a zero-resolving siloId reverts `SiloUnrouted`. A
  finding is HIGH/CRITICAL only if it shows a line stranded/misrouted, a silent fallback to the `venue` slot,
  or a phantom/leaked line count.
- **Trusted dependencies (out of scope to distrust):** the CRE Forwarder (identity-gated), the venue adapter,
  the lien factory, and the oracle registry are all trusted, separately-X-rayed dependencies. Distrusting their
  internal correctness is not a controller finding — attack only how THIS contract drives/orders them.
- **Build-phase mutable wiring is INFO.** The 5 Timelock-settable slots (frozen pre-prod, §17) are the
  documented subsystem residual. A finding that merely restates "the Timelock can re-point a wired slot" is
  INFO unless you show a re-point that DRAINS rather than redirects/griefs.
- "Sound" is a valid (expected) result. For a HARDENED orchestrator, "the atomicity holds, routing fails
  closed, the allow-list is exhaustive, here's what I diffed" is the right outcome; a manufactured finding is
  noise.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/guard you attack (I-1…I-11, G-n)>
- **Location:** <fn / exact line in ZipcodeController.sol + the IZipcodeVenue / ReceiverTemplate / factory / registry line where the seam crosses>
- **Delta from posture:** <how it breaks a §4.4 on-chain guarantee, or "trusted-dependency (out of scope)", or "build-phase wiring (INFO)", or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it leaves an ORPHAN (lien/market/seed/count),
  DOUBLE-MINTS, MISROUTES/STRANDS a line, lets a forbidden report TYPE through, or LEAKS a standing approval —
  and whether the §4.4 posture already bounds it.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness
verdict (and explicitly: is origination atomic, does routing fail closed, and is the report-type allow-list
exhaustive?).
