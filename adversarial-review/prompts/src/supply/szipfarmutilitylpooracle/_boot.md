# Boot context — SzipFarmUtilityLpOracle adversarial review

You are a smart-contract security reviewer auditing ONE unit as part of a blind panel (other models review
it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md` / `2.md` / `3.md`) before you begin.

## The unit under review
- `contracts/src/supply/SzipFarmUtilityLpOracle.sol` (80 nSLOC) — the **CRE-fed push-cache** LP-collateral
  price oracle for the 8-B5 farm-utility loop (§4.5.1). It is the EVK `_getQuote(lpShares) → USDC` face the
  farm utility's `EulerRouter` resolves LP collateral through — but the price is **pushed off-chain by CRE**
  (a per-LP-share USD mark) instead of reconstructed on-chain from the pool TWAP. Two faces in one contract:
  a **CRE receiver** (`ReceiverTemplate` — the Forwarder pushes the mark via `onReport` → `_processReport`)
  and an **EVK read-adapter** (`BaseAdapter`/`IPriceOracle` — `getQuote` reads the cached mark).
- It is the **twin** of `contracts/src/supply/AlgebraIchiFairLpOracle.sol` (the trustless, on-chain-TWAP
  alternative). The deploy chooses between them: `DeployZipcode` P5 `lpTwapWindow == 0` ⇒ THIS oracle (the
  default); `!= 0` ⇒ the fair oracle. **The defining difference is the liveness dependency** — a stale or
  missing mark must fail the borrow CLOSED.

**Why it matters:** this is COLLATERAL pricing. A mis-price flows straight into the EVK borrow market →
over-valued collateral → bad debt. Unlike the trustless twin, this oracle trusts an off-chain mark, so the
fail-closed staleness contract IS the safety story.

## These are ORIGINAL contracts — the precedent is the pattern + the bases, not a code parent
There is no audited code parent to diff line-for-line. Your "supposed to be" baselines:
- **The push-cache pattern it is modeled on** — `contracts/src/ZipcodeOracleRegistry.sol` and the bridge's
  `contracts/src/bridge/SzAlphaRateOracle.sol` (the SEC-01 strictly-newer write guard + the
  `ReceiverTemplate` forwarder gate live there; this oracle is the same shape with three deltas: a SINGLE
  fixed key `(lpToken)` not a per-key map, a dedicated `LP_MARK = 7` reportType, and NO controller-seed path
  — the Forwarder push is the only writer). Diff THIS oracle's write/read path against those.
- **The trustless twin** — `contracts/src/supply/AlgebraIchiFairLpOracle.sol` — the same EVK face without a
  liveness dependency. The strongest finding is a delta: a path where this push-cache opens a borrow the
  twin's fail-closed read would have blocked, or a mis-scale the twin's on-chain math cannot exhibit.
- **`ReceiverTemplate`** — `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol` — the
  forwarder-only `onReport` gate (`InvalidSender`) + the report decode. The forwarder trust is the ratified
  base (the Chainlink Forwarder is the trusted writer) — attack how THIS contract USES `onReport`/decodes
  the payload, not the Forwarder itself.
- **`BaseAdapter` / `ScaleUtils`** — `reference/euler-price-oracle/src/adapter/BaseAdapter.sol` +
  `reference/euler-price-oracle/src/lib/ScaleUtils.sol` — the `IPriceOracle.getQuote` contract the EVK router
  relies on and the `calcOutAmount(..., false)` round-DOWN scaling. `scale` is
  `calcScale(18, quoteDecimals, quoteDecimals)`, re-derived in `setQuote`.

## Tests
`contracts/test/supply/SzipFarmUtilityLpOracle.t.sol` — 19/19 (4 write-staleness + 15 added later:
read-path liveness fail-closed, write-value guards, forwarder gate, reportType pin, the three Timelock setters,
ctor zero-guards). See what's proven (don't re-report) and aim PAST it — most valuably a mis-scale on a setter
re-point or a fail-open the read-path tests don't model.

## Ground rules
- Cite exact lines in the oracle AND the precedent (`ZipcodeOracleRegistry` / `SzAlphaRateOracle`) or the
  `ReceiverTemplate` / `ScaleUtils` line where relevant.
- The decisive surfaces: (1) any path where a stale/unset/missing mark does NOT fail the borrow closed (the
  liveness contract this oracle trades manipulation-resistance for); (2) a write-value guard a malformed CRE
  push slips past (`mark==0`, `mark>uint208.max`, `ts>now`, non-strictly-newer `ts`); (3) a setter re-point
  (`setQuote` re-derives `scale`) that silently mis-scales every subsequent quote; (4) a wrong-pair / wrong-
  reportType read or write that returns a usable price instead of reverting.
- **Pressure-test severity** (carry into the finding): forwarder/CRE trust is the ratified base — "the CRE
  could push a bad mark" is accepted-risk INFO unless THIS contract fails to fail-closed on a malformed one.
  Build-phase mutable wiring (the Timelock setters, frozen pre-prod) is the subsystem-wide residual (X-3) —
  a bare re-point restatement is INFO unless it DRAINS or breaks the liveness/scale invariant.
- "Sound" is a valid result; if the fail-closed semantics hold and the scale derivation is faithful, say so
  and show why. A manufactured finding is noise.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/residual you attack (I-1…I-8, X-3)>
- **Location:** <fn / line in the oracle + the precedent / ReceiverTemplate / ScaleUtils line>
- **Delta from precedent:** <how it differs from ZipcodeOracleRegistry / SzAlphaRateOracle / the trustless twin, or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it OVER-values collateral (the dangerous direction) or fails open.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness verdict.
