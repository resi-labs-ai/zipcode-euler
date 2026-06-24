# Boot context — SzipNavOracleDemoVAMM.sol adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores every finding against the contract's X-Ray). Read this file
and your mission (`1.md` / `2.md` / `3.md`) before you begin.

## Contract under review
`contracts/src/hydrex-demo-fork/SzipNavOracleDemoVAMM.sol` (294 nSLOC). The szipUSD junior-vault
**NAV-per-share pricing primitive** (demo variant): both issuance and exit price off it. It composes the
junior basket NAV on-chain across the main + sidecar Safes, CRE-pushes the off-chain leg marks (alphaUSD,
HYDX/USD) it can't read on Base, maintains an on-chain TWAP, and serves a bracketed share price:
`navEntry = max(spot, twap)` (issuance, reverts on stale), `navExit = min(spot, twap)` (exit). The
`DefaultCoordinator` writes an impairment `provision` that `spotNavPerShare` subtracts.

## The differential — this is a FORK; the precedent is its own audited prod parent
A fork of the **audited** prod `SzipNavOracle` (8-B4), **identical in every respect EXCEPT the LP-leg
valuation**. Prod values an ICHI vault (`getTotalAmounts()` + a farm-utility escrow collateral leg). The
demo values a live Solidly **pair** directly: `heldShares/totalSupply × getReserves()`, reserve tokens
(HYDX/USDC) priced via `_legPriceOfToken` (HYDX = the pushed leg; USDC = `1e30` for the 6→18-dp $1 fold).
**The demo has NO farm-utility leg.**

**So your diff baseline is the prod parent, not an external repo.** A finding is one of:
1. the seam swap **dropped/broke an accounting or pricing property the audited parent had**, or
2. the swap **introduced new behavior the parent never had to handle** — chiefly that the LP leg is now
   valued at **spot `getReserves()`, manipulable in-block** (vs the ICHI `getTotalAmounts()`), defended
   ONLY by the `min/max(spot, twap)` bracket; and the dropped farm-utility leg.

## Source of truth (read FIRST, then diff)
- `contracts/src/supply/SzipNavOracle.sol` — the **audited prod parent**. Everything but the LP-leg
  valuation is byte-identical; diff `grossBasketValue` / the LP-leg path against its ICHI valuation, and
  confirm the CRE-push guards, the spot/twap bracket, freshness, provision gating, and the genesis NAV
  survived the fork intact.
- `contracts/src/interfaces/hydrex/IVammPair.sol` — the swapped seam (`getReserves`, `totalSupply`,
  `token0`/`token1`). Spot reserves are manipulable in-block (a swap moves them) — the new hazard.
- `contracts/test/hydrex-demo-fork/SzipNavOracleDemoVAMM.t.sol` — the ported suite (23 unit + 1 fuzz,
  24/24 green) incl. `MockVammPair`. See what's proven (don't re-report) and what the mock *assumes* (an
  honest, non-adversarial reserve — it does not model an in-block reserve push).

## Scope note (set expectations)
Self-declared **DEMO/SHOWCASE, outside the audited core** — invisible to the prod oracle (different pair/
gauge addresses than the prod ICHI vault, so prod `grossBasketValue` is unaffected; the SP-06 trap is
avoided). It IS deployed on mainnet (`DeployShowcaseVAMM.s.sol`) and consumers (ExitGate) read
`navEntry`/`navExit`/`fresh` off it for the demo. Frame findings as **demo-scoped**. The X-Ray notes the
NAV-hub residuals (raw-balance donation seam, in-block spot-LP, unbounded provision) are **inherited from
the prod design, not introduced by the fork** — so distinguish "fork-introduced" from "prod-inherited" in
every finding.

## Ground rules
- Cite exact lines in `SzipNavOracleDemoVAMM.sol` AND the corresponding prod-parent / IVammPair line.
- Highest-value findings are **deltas from the prod parent** or **spot-`getReserves()`-specific hazards**
  the ICHI parent never faced. A prod-inherited residual restated as a fork finding is noise — say
  "inherited" and move on; the panel's job on those is to confirm the bracket/gate actually fences them.
- The CRE Forwarder + the DefaultCoordinator are documented-trusted writers; findings that assume their
  dishonesty are `Confidence: low` and must name the trust broken.
- "Sound" is a valid result; if the seam swap is faithful and the bracket/guards intact, say so + name what you diffed.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/residual or prod-parent property you attack>
- **Location:** <fn / line in SzipNavOracleDemoVAMM.sol + the prod-parent or IVammPair line>
- **Delta from precedent:** <how it differs from the prod parent / what getReserves-spot behavior it must handle; or "inherited — not fork-introduced">
- **Mechanism / Impact / Confidence / Fix** as usual.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness verdict.
