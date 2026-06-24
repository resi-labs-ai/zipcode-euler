# Boot context — EulerVenueAdapter adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md` / `2.md` / `3.md` / `4.md` / `5.md`) before you begin.

## The contract under review
- `contracts/src/venue/EulerVenueAdapter.sol` (354 nSLOC) — Config one (§4.7 #10): a per-line isolated-market
  **FACTORY** implementing `IZipcodeVenue`. `Ownable` (Timelock) + `onlyController` + `onlyFarmUtilityAllocator`.
  The most complex contract in the sweep. Three privileged callers:
  - the **controller** drives the line lifecycle: `openLine` / `setLineLimits` / `fund` / `draw` / `closeLine` /
    `liquidate` (`liquidate` reverts `NotImplemented`, §4.4e);
  - the **owner/Timelock** re-points the ~13 build-phase wiring setters + the CTR-09/CTR-13 fee setters;
  - the **`farmUtilityAllocator`** drives `fundFarmUtility` / `defundFarmUtility` (a two-key key DISTINCT from
    the loop operator).
- The load-bearing flow is **`openLine`** (`:307`): one atomic 7-step cluster mint —
  - step 0 — `new LineAccount{salt: lienId}` + the EVC operator grant; `borrowAccount = address(uint160(la) ^ 1)` (`:326-327`);
  - step 1 — escrow collateral vault (bare holding box, no oracle/UoA/governance) (`:330-333`);
  - step 2 — dedicated per-line `EulerRouter`; wire `collat → lienToken → registry` (`:336-338`);
  - step 3 — isolated USDC borrow vault (oracle = this line's router, UoA = USDC, IRM, curator `feeReceiver`,
    hook `OP_BORROW|OP_LIQUIDATE`) (`:341-348`);
  - step 4 — onboard EVAULT to `EulerEarn`: `submitCap`+`acceptCap` bounded to ONLY the new vault, supply-queue
    append (`:353-361`);
  - step 5 — custody the 1e18 lien into `collat` for `borrowAccount` (`:365-367`);
  - step 6 — **freeze the router** (`transferGovernance(address(0))`, `:371`);
  - step 7 — birth-time wire-check `_assertWired` (W3) (`:374`).

**Why it matters:** the security model IS the wiring discipline. A factory mis-step leaks, mis-prices, or
orphans. The decisive surfaces are all about *how the fresh markets are wired*: the draw receiver pinned to
`erebor` (F2, `draw:455`), the `submitCap` bounded to the minted vault (F3, `:353`), reallocate sizing read off
the EE **tracked** balance (SEC-11, `_eeSupplyAssets:413`), the per-line router frozen (`:371`), and the
SEC-06/CTR-04 dual queue-slot reclaim on close that keeps origination from bricking at the 30-market
`EulerEarn` cap. A bug is a mid-cluster orphan, a draw to a non-`erebor` receiver, a `submitCap` on a foreign
market, a donation that griefs reallocate, a leaked queue slot, a foreign borrow account that draws, or a fee
that escapes the cap.

## These are ORIGINAL contracts — the precedent is the verified `EdgeFactory.deploy()` + the §4.7 posture, not a code parent
Unlike the bridge/hydrex forks there is no audited parent to diff line-for-line. Your "supposed to be"
baselines:
- **`EdgeFactory.deploy()`** — `reference/evk-periphery/src/EdgeFactory/EdgeFactory.sol` — the verified
  evk-periphery factory `openLine` is **modeled inline on** (NOT imported — evk-periphery is un-remapped). The
  strongest finding is a **delta from it**: a cluster-mint step `EdgeFactory` performs and the adapter omits (a
  governance handoff left open, a hook config skipped, an LTV/cap left unset, an unwrap/resolve wiring missed),
  or an ordering that orphans on a mid-cluster revert. Diff the two factories step-for-step.
- **The documented invariants** (the X-Ray I-1…I-17, authoritative): atomic cluster mint (I-1), per-line
  isolation + foreign-account hook rejection (I-2), draw pinned to `erebor` (I-3/F2), `submitCap` bounded to the
  minted vault (I-4/F3), donation-immune reallocate sizing (I-5/SEC-11), dual queue-slot reclaim on close
  (I-6/SEC-06+CTR-04), defund-to-base on close (I-7/SEC-07), close guards on repayment + reclaims the lien
  (I-8), EE-timelock precheck (I-9/SEC-08), CTR-09 per-draw fee (I-10), CTR-13 line IRM + curator fee (I-11),
  `_assertWired` (I-12/W3), AmountCap round-trip (I-13), authority gates (I-14), farm-utility two-key JIT
  (I-15), build-phase setters (I-16), `seniorPool()` (I-17).
- **The trusted external base (out of scope to distrust)** — the EVK `GenericFactory`/`EVault`
  (`reference/euler-vault-kit/`), the EVC (`reference/ethereum-vault-connector/src/EthereumVaultConnector.sol`),
  `EulerEarn` (`reference/euler-earn/src/EulerEarn.sol` + `interfaces/IEulerEarn.sol`), `EulerRouter`, the
  `CREGatingHook` (`contracts/src/CREGatingHook.sol`), and the `ZipcodeOracleRegistry` price source are audited
  dependencies used per-line. A finding must show the adapter **mis-USING** an honest dependency, not "the
  dependency could misbehave".
- **The X-Ray is your ground truth** — `contracts/src/venue/x-ray/EulerVenueAdapter.md` (I-1…I-17, the guard
  table). The §4.7 venue layer overview is `docs/venue.md`; the cross-contract seam catalog is
  `docs/wires/SYSTEM-SEAM-MAP.md`.

## Tests
`contracts/test/venue/EulerVenueAdapter.t.sol` — a **~53-test Base-fork suite** against the real EVK
`GenericFactory`, EVC, `EulerEarn`, `EulerRouter`, plus a `MisWiringAdapter` harness subclass to reach the
defensive `_assertWired` branch. The farm-utility fund/defund cluster is covered **cross-suite** in
`contracts/test/supply/szipUSD/FarmUtilityLoopModule.t.sol`. The densest cluster is the SEC-06/CTR-04 dual
queue-slot reclaim (9 tests: prune, leaves-other-fundable, churn-past-cap, concurrent-reuse, bricks-without-
close). See what is proven (don't re-report) and where the tests STOP.

## Ground rules
- Cite exact lines in `EulerVenueAdapter.sol` AND the seam line where it crosses (the `EdgeFactory` step it
  diffs from, the EVC `setAccountOperator`/`batch`/`call` site, the `EulerEarn` `reallocate`/`submitCap`/
  `setSupplyQueue`/`updateWithdrawQueue` site).
- The decisive surfaces: (1) a mid-cluster orphan — `openLine` reverts AFTER some state is built but the tx
  doesn't fully unwind (it's one tx, so confirm atomicity); (2) a draw to a non-`erebor` receiver (F2 break) —
  incl. via the optional fee leg; (3) a `submitCap` on a market other than the freshly-minted vault (F3 break);
  (4) a reallocate sizing read that a share donation can skew (SEC-11 break → `InconsistentReallocation`
  grief); (5) a leaked EE queue slot (supply OR binding withdraw) that permanently bricks origination at the
  30-market cap; (6) a foreign borrow account drawing, or a line's grant touching another line; (7) a fee that
  exceeds `MAX_FEE_BPS`, is levied without being financed, or breaks F2.
- **Pressure-test severity.** External-infra trust (EVK/EVC/EE/router/hook/registry) is the ACCEPTED base —
  distrusting it is INFO unless the adapter mis-uses an honest read. The two-key deploy invariant
  (`farmUtilityAllocator` ≠ loop operator) is a KNOWN residual with no on-chain handle — confirm the gate
  fires, don't re-flag the residual. Build-phase mutable wiring (§17) is a documented residual closed by the
  pre-prod re-freeze — a bare re-point restatement is INFO unless it DRAINS or breaks an invariant. `liquidate`
  reverting `NotImplemented` and the CREATE2 graveyard are ratified design.
- "Sound" is a valid result. If the cluster mints atomically, F2/F3 hold, reallocate is donation-immune, and
  the dual reclaim keeps origination unbricked, say so.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/guard you attack (I-1…I-17, F2/F3/W3/SEC-06/07/08/11, CTR-04/07/09/13)>
- **Location:** <fn / exact line in EulerVenueAdapter.sol + the EdgeFactory / EVC / EulerEarn line where the seam crosses>
- **Delta from precedent:** <how it diverges from `EdgeFactory.deploy()` or breaks a documented invariant, or "external-infra trust / ratified residual", or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it ORPHANS a cluster, breaks F2
  (non-`erebor` draw), breaks F3 (foreign `submitCap`), GRIEFS reallocate (donation), LEAKS a queue slot
  (bricks origination), breaches ISOLATION (foreign borrow account), or escapes the FEE cap.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness
verdict (and explicitly: does the cluster mint atomically, do F2/F3 hold, is reallocate donation-immune, and
does close reclaim BOTH queue slots?).
