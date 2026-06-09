# WOOF-02 — authoring-window report to the superintendent

> **UPDATE 2026-06-06 — MATERIALIZED + BUILT-VERIFIED (keep-the-build doctrine).** Built for real from the ticket
> alone against the WOOF-00/01 scaffold and **kept on disk** (the original "`contracts/` back to skeleton" is
> retired). **Evidence:** `forge build` clean (solc 0.8.24) + **`forge test` 34/34 PASS** (independently re-run,
> exit 0; no WOOF-00/01 regression). The two load-bearing proofs confirmed with eyes on the output: the exact
> scale identity `getQuote(1e18, LIEN, USDC) == equityMark`, and the strict-decimals guard rejecting **both** a
> 6-dp token and a code-less EOA on both write paths. The real build found **no wrong citation / no
> inheritance-override collision / no OZ-version issue** — a genuine zero-spec-guess keepsake (like WOOF-01,
> unlike WOOF-00). Code at `contracts/src/ZipcodeOracleRegistry.sol` + `contracts/test/ZipcodeOracleRegistry.t.sol`
> (+ 2 remap lines). The 2026-06-04 authoring narrative below is preserved for the design rationale.

**From:** the builder Claude (ticket-authoring harness). **To:** the superintendent.
**Item:** 3 — `ZipcodeOracleRegistry` (§4.1 → WOOF-02).
**Date:** 2026-06-04 (authoring); **2026-06-06** (materialized + built). **Branch:** `main`.

## TL;DR
- Authored item 3 end-to-end (5 critics → triage → cold-build). **Cold-build = YES: 24/24 unit tests pass, `forge build` clean, scale identity `getQuote(1e18)==equityMark` verified exact, no ticket line wrong.**
- This was a **heavy** item: the harness surfaced **five real §4.1 under-specs** (all confirmed faithful gap-closures by the critics, not invention) **plus** one cross-cutting reference conflict — the spec's "override `setForwarderAddress` to revert" is **unimplementable** (the base function is non-virtual). Both fixed in the spec first, then the audit harness updated as a consequence.
- New cross-ticket obligations created (owed by items 6, 10, and the CRE track); the inbound WOOF-01 decimals obligation is **discharged** (strict guard, proven by tests rejecting a 6-dp token and a code-less EOA).
- Repo clean + resumable: `contracts/` back to skeleton; ledgers + spec + audit updated; **NEXT = item 5 (`IZipcodeVenue` + `EulerVenueAdapter`, §4.7)**.

## Design decisions (superintendent sanity-check)
**A. Five §4.1 gaps (fixed in spec).** §4.1 described only `_processReport` + the read view. Folded in: (1) the **controller-gated `seedPrice`** origination path + **set-once `setController`** (registry deploys at S3 *before* the controller at S6 → constructor-immutable controller is a deploy-order circularity, exactly the §4.2 factory shape — resolved with a set-once owner-gated setter frozen by renounce); (2) **two-stage report decode** — `_processReport` strips the §4.4 envelope `(uint8 reportType, bytes payload)`, requires `reportType==3`, then decodes the payload with a `liens.length==prices.length` check; (3) **strict-decimals guard** — a low-level staticcall that *reverts* on failure/≠18, NOT `BaseAdapter._getDecimals` (which silently returns 18 and would no-op the guard); (4) the **scale/units convention** — `calcScale(18, quoteDecimals, feedDecimals=quoteDecimals)` so `getQuote(1e18, LIEN, USDC)==equityMark` and equityMark is the value in USDC's 6 native decimals; (5) a **`ts>block.timestamp` reject**. No §17 *decision* reopened (event-driven Proof / no heartbeat / no value band all preserved).

**B. Non-virtual Forwarder → renounce (cross-cutting fix).** Reference-verified: `ReceiverTemplate.setForwarderAddress` AND `onReport` are non-virtual → cannot be overridden. The spec said "override to revert" at **five sites**; all corrected to: immutability is sealed by `renounceOwnership()` after identity wiring (post-renounce every `onlyOwner` setter reverts `OwnableUnauthorizedAccount`). The §4.4 alternative ("implement `IReceiver` directly with an immutable") is noted but not used in M1. This is faithful to the locked *intent* (genuinely immutable Forwarder); only the impossible *mechanism description* changed.

## Holes the harness surfaced
| # | Severity | Hole | Resolution |
|---|---|---|---|
| 1 | spec gap | §4.1 omits the controller origination-seed path + its authority (deploy-order circularity) | spec: `seedPrice` + set-once `setController`; audit S6 `setController`, L4 seed-via-controller |
| 2 | spec gap | §4.1 decode eludes the §4.4 envelope; no `reportType`/length check | spec + ticket: decode envelope, require `reportType==3`, `liens.length==prices.length` |
| 3 | spec gap | "match decimals" would be a **no-op** if built on silent-18 `_getDecimals` | strict staticcall guard (reverts); discharges WOOF-01 obligation; tests reject 6-dp + EOA |
| 4 | spec gap | equityMark units / feed-decimals unspecified | pinned `feedDecimals=quoteDecimals` → `getQuote(1e18)==equityMark` (USDC 6dp); verified exact |
| 5 | blocker | "override `setForwarderAddress` to revert" — base is **non-virtual**, won't compile | renounce-based immutability across 5 spec sites + audit S3/S6/S11/N7/L4 + 3-results |
| 6 | high (x-ticket) | identity-before-renounce only in prose, not a deploy gate (F7) | **S11 hard pre-gate**: assert `getExpectedWorkflowId()!=0` && `controller()!=0` before renounce; obligation owed by item 10 |
| 7 | med | far-future `ts` → never-stale footgun | `ts>now` write-time sanity guard (see judgment call) |
| 8 | med | forged-high-price vector mis-framed as "can't liquidate" | attack-table row reworded: names **over-borrow**, mitigated by borrowLTV gap + upstream |
| 9 | qa | many edge tests missing (atomicity, EOA reject, both-paths guards, dup liens, re-seed, empty batch, exact revert args, no-band positive proof, jumbo/truncation) | expanded Done-when test list (cold-build implemented → 24 tests) |

## Authoritative-doc edits (review)
- `claude-zipcode.md` §4.1 — added scale convention, set-once controller + `seedPrice`, two-stage decode, strict-decimals, `ts>now` guard, atomicity + sharding note; corrected Forwarder immutability. §4.4 / §9 / §10-summary / §17 line 1131 — "override to revert" → renounce-based (+ the assert-before-renounce gate).
- `audit/2.md` — S3 (lock at S11, not S3), S6 (+`setController`, post-condition), **S11 (hard pre-gate)**, N7 (expected revert → `OwnableUnauthorizedAccount`), L4 (seed via `controller.seedPrice`; `getQuote(1e18)==equityMark` exact, was `≈`).
- `audit/3-results.md` — rows 20/21/22 reworded (non-virtual/renounce; strict decimals + `reportType`/length/`ts` guards); §5 sweep gains `setController` + `seedPrice` rows; attack-table forged-value row names the over-borrow vector.

## Judgment calls (please rule)
1. **The `ts > block.timestamp` write-time reject** — slightly beyond the literal §4.1 "no on-chain band." I kept it as a *timestamp-sanity* guard (an appraisal cannot be dated after now), distinct from a forbidden *value* band, on the security critic's recommendation. **Revert if you read §4.1 as forbidding even this.**
2. **Breadth of the renounce correction** — I edited all five "override to revert" sites + the audit harness in one window (the wording was factually unbuildable everywhere). This touches the controller (§4.4) and §17, which item 6 will inherit. Confirm you want this resolved now (vs. deferred to the controller window).
3. **Re-fan vs cold-build only** — after folding the critic findings (incl. the additive `ts>now` guard) I ran only the cold-build, not a second critic round. The additions are defensive/test-coverage, fully specified; the cold-build (zero-guess, 24/24) is the gate. Flag if you want a re-fan.
4. **5 critics** (cheap-three + qa + security) for this foundational, authority-and-price-bearing contract.

## Status & next
Done + filed: items 1 (WOOF-00), 2 (WOOF-01), 3 (WOOF-02), 4 (WOOF-03). **NEXT = item 5 (`IZipcodeVenue` + `EulerVenueAdapter`, §4.7).**
