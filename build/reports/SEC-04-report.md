# SEC-04 report — `_xAlphaUSD()` fail-close on unseeded rate (kill-list H5)

**Window:** 2026-06-15 · **Track:** SEC (auditor-prep) · **Status:** DONE · **NEXT:** SEC-05 (M4 — seal `lpOracle` CRE identity in P9)

## What the window did
Closed kill-list **H5** (audit subsystem finding #6 / interconnection C1, escalated HIGH): `SzipNavOracle._xAlphaUSD()`
priced the xALPHA basket leg as `exchangeRate() × alphaUSD`, and `exchangeRate()` returns **0 without reverting** when
the CRE-pushed cross-chain rate has never been seeded (genesis/uninitialized). So the entire xALPHA leg was silently
valued at **0**, and three *ungated* consumers read the understated number:
- **`navExit`** → underpays junior exits,
- the freeze module's **`coverageValue`** → under-counts the senior-coverage floor → can mis-gate outflow (`release`/
  `removeLiquidity`/`postBid`),
- **`ExitGate`** tvlCap → under-reads gross → lets deposits exceed the real cap.

The narrow, correct fix (per the kill-list's settled DECIDE) is to **fail closed on the unseeded (genesis) zero only** —
distinct from a stale-but-seeded mark — and to **keep the §7 max-entry/min-exit asymmetry** (do NOT gate exit/coverage
on `fresh()`).

**Fix (1 file, `contracts/src/supply/SzipNavOracle.sol`), exactly as ticketed:**
- Declared `error RateUnseeded();`.
- `_xAlphaUSD()` (now `:517-525`) captures the rate into a local and guards:
  ```solidity
  address rateSrc = xAlphaRateOracle == address(0) ? xAlpha : xAlphaRateOracle;
  uint256 rate = IXAlphaRate(rateSrc).exchangeRate();
  if (rate == 0) revert RateUnseeded();
  return rate * legCache[LEG_ALPHA_USD].price / 1e18;
  ```
- Docstring updated to state fail-closed-on-unseeded (≠ stale); staleness still NOT gated here.
- The guard sits in the **shared internal**, so all four consumers inherit the revert with **zero consumer edits**.

## Decisions to sanity-check (reviewer)
1. **Unseeded ≠ stale — and the "gate on `fresh()`" alternative was deliberately NOT taken.** Both the audit (#6, C1)
   and the kill-list floated "gate every `_xAlphaUSD` consumer on `fresh()`". That half is **rejected on purpose**: it
   would break the ratified §7 last-good-mark exit asymmetry (`exit-topology-intentional`). SEC-04 fences only the
   genesis zero. The **upward-stale-after-slash** scenario in interconnection C1 is therefore *accepted residual* —
   the TWAP-lag (`min(spot,twap)`) + the per-push deviation band remain its defense. C1 is marked **PARTIALLY**
   resolved for that reason; if it must ever be fully closed, it needs a rate-specific deviation/sanity bound on the
   **bridge push** (not a `fresh()` gate on exit).
2. **Both directions revert on unseeded — intended.** Because the guard is in the shared internal, `navEntry` AND
   `navExit` both revert `RateUnseeded` at `rate==0`. That is correct fail-close (an absent rate must halt issuance
   *and* exit); it does not collapse the asymmetry, which is about *staleness*, proven by
   `test_SEC04_asymmetry_preserved_when_stale`.
3. **Test placement.** The regression spans three suites so each consumer is exercised against a REAL oracle (not a
   settable mock): oracle-level reads in `SzipNavOracle.t.sol`, the freeze `coverageValue()` over the real oracle in
   `DurationFreezeModule.t.sol::SzipNavOracleParityTest`, and the real `ExitGate.depositFor` path in `ExitGate.t.sol`.

## Holes → resolution
- **Could the alphaUSD leg also be silently 0?** (the ticket's flagged back-pressure check.) **Resolved — no:**
  `_processReport` rejects `ZeroPrice` on every leg write, so `legCache[LEG_ALPHA_USD].price` can never be *seeded* to
  0; only the rate's genesis zero slipped through. Scope correctly stayed on the rate; no contract surface owed.
- **Stale ticket line cites** (`508-518`, etc.) — the function had drifted to `517-525` (SEC-01/02/03 edits above it).
  Corrected in the ticket's DONE bindings + the wire doc.

## Doc edits (full doc-sync-checklist run)
- **Ticket** `build/tickets/sec/SEC-04-xalphausd-fail-close.md` — Status → DONE; full DONE note + quoted output.
- **`build/tickets/PROGRESS.md`** — SEC-04 DONE, SEC-05 set NEXT, SEC-track table + header line, "Just done — SEC-04".
- **`build/kill-list.md`** — H5 `[ ]`→`[x]` + **DONE 2026-06-15 (SEC-04)** note; line cite refreshed to `:517-525`.
- **`build/audit-claude/`** — `findings.md` #6 (summary row + body RESOLVED, with the rejected-alternative rationale +
  residual note); `SUMMARY.md` H5 row ✅ RESOLVED; `interconnection-findings.md` C1 ✅ **PARTIALLY** resolved (genesis
  half fixed, upward-stale half intended residual).
- **`build/wires/8-B4-SzipNavOracle.md`** — leg-3 fail-close behavior + the `navExit` `RateUnseeded` caveat.
- **No `build/claude-zipcode.md` change** — interface-level fix; §7 intent unchanged (the spec already prescribed
  fail-closed-on-stale for issuance; this fences a genesis hole it implicitly assumed away).

## Status + NEXT
**DONE.** `forge build` clean; `forge test` **774 passed / 0 failed / 3 skipped** (+5 over SEC-03's 769). 5 new
`test_SEC04_*` regressions, fail-before/pass-after confirmed (reverting the guard reproduces all 3 unseeded-revert
tests as "next call did not revert as expected"). No spec change, no back-pressure, no new obligation.

**NEXT: SEC-05** — seal `lpOracle` CRE identity in `DeployZipcode.s.sol` P9 + extend `requireIdentityWired`, both
conditional on `d.lpOracle != 0` (kill-list M4). Ticket: `build/tickets/sec/SEC-05-seal-lporacle-identity.md`.
