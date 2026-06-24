# Boot context — SellModule adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md` / `2.md` / `3.md` / `4.md`) before you begin.

## The contract under review
- `contracts/src/supply/szipUSD/SellModule.sol` (167 nSLOC) — the 8-B9 market-sell leg: the sixth engine
  Zodiac `Module`, CRE-operator-gated, enabled on the szipUSD engine Safe (`avatar == target ==
  juniorTrancheEngine`). Pure Algebra `SwapRouter.exactInputSingle` swap mechanism — **NO EVC, NO oracle, NO
  LP, NO veNFT, NO repay, NO custody.** Three operator-only entrypoints share one private `_swap` (approve →
  `exactInputSingle` → reset-approve, exactly 3 `exec`s):
  - `sellHydx(amountIn, minOut, deadline)` (`:214`) — HYDX → USDC, the strike-loop repay feeder; **size-capped
    by `maxSellHydx` (`:219`)**.
  - `buyXAlpha(...)` (`:229`) — zipUSD → xALPHA on our POL (the recycle/compound buy leg); **not** capped.
  - `sellXAlpha(...)` (`:251`) — xALPHA → zipUSD (the wind-down/unstrand hop; xALPHA has no direct USDC pool);
    **not** capped.

**Why it matters:** this is the seam where the auto-compounder touches an external AMM. The output token can
only land in the basket (the Safe), and the operator supplies only scalars — but the swap moves real value
through a third-party router. A bug here is either a **redirect** (output to a non-Safe address / an arbitrary
token pair), a **dump** (a compromised operator craters HYDX — the protocol is long it via veHYDX + the LP),
a **bad-price / stale fill** that the slippage+deadline guards should have aborted, or a **standing approval**
left dangling on the router.

## These are ORIGINAL contracts — the precedent is the §10.1 boundary posture + the Zodiac base, not a code parent
Unlike the bridge/hydrex forks there is no audited parent to diff line-for-line. Your "supposed to be"
baselines:
- **The §10.1 security boundary** (stated in the contract NatSpec `:22-32`, authoritative): the operator
  supplies ONLY scalars (`amountIn`, `minOut`, `deadline`); the module builds ALL calldata to the set-once
  wired targets; `tokenIn`/`tokenOut` are hard-pinned per entrypoint, `deployer` pinned to `address(0)`
  (base-factory pools), `recipient` pinned to the literal `juniorTrancheEngine`, `limitSqrtPrice` pinned to 0;
  `value == 0`; no generic call/exec passthrough, no delegatecall. **The strongest finding is a path where a
  pinned field becomes operator-influenced, or where the boundary leaks — output to a non-Safe destination, an
  arbitrary pair, a non-zero `value`, or a passthrough.**
- **The zodiac-core `Module` base** — `reference/zodiac-core/contracts/core/Module.sol` — supplies
  `execAndReturnData` (the Safe driver), the `setAvatar`/`setTarget` `onlyOwner` setters, and the `initializer`
  one-shot. Confirm the entry mechanism is the base's, not re-implemented; attack what the override adds on top
  (the `_exec` false-return handling, the avatar/target sync in `setJuniorTrancheEngine`).
- **`MastercopyInitLock`** — `contracts/src/supply/szipUSD/MastercopyInitLock.sol` — the SEC-14 mixin that locks
  the mastercopy's `setUp` in its constructor (a clone shares the mastercopy's bytecode → no per-clone
  `immutable`; every wired address is set-once storage written in `setUp` under `initializer`).
- **The X-Ray is your ground truth** — `contracts/src/supply/szipUSD/x-ray/SellModule.md` (per-contract,
  authoritative; I-1…I-6, X-1, the guard table). Every finding cites the invariant/guard it attacks. The
  fleet-wide pattern context is `contracts/src/supply/szipUSD/x-ray/portfolio-map.md`.

## Tests
`contracts/test/supply/szipUSD/SellModule.t.sol` — 34 unit + 4 base-fork = **38 passing** (0 fuzz, 0 invariant —
deterministic 3-exec swaps; the fork is the higher-value check). **Every mutator is exercised** (all 7 setters +
the 3 swap legs). The fully-pinned exec-shape proof decodes the `ExactInputSingleParams` for all 3 legs; the
size-cap matrix covers above/at-cap + the uncapped legs; `minOut`-too-high + past-deadline abort on the real
Algebra router; approval reset + atomic rollback. See what is proven (don't re-report it) and where the tests
STOP (the build-phase re-point window; any pair the §10.1 pins don't cover).

## Ground rules
- Cite exact lines in `SellModule.sol` AND the zodiac-core base / `ISwapRouter` line where the seam crosses.
- The decisive surfaces: (1) a path where the swap output reaches anything but `juniorTrancheEngine`, or an
  arbitrary `(tokenIn, tokenOut)` pair / non-zero `value` / passthrough leaks through the §10.1 boundary
  (a REDIRECT or arbitrary-call escalation); (2) a single `sellHydx` that exceeds `maxSellHydx` (a DUMP) or a
  cap that fails to bind; (3) a bad-price or stale swap that does NOT abort (slippage/deadline guard bypassed),
  or a standing approval left on the router; (4) an `exec` that returns `false` yet the step reports success
  (a silently-swallowed failed swap).
- **Pressure-test severity (§10.1 / X-1).** A finding that merely requires the OPERATOR to size a swap badly
  within the on-chain bounds (the recipient/pair pin + the size cap + `minOut`/`deadline`) is the documented
  X-1 operator-sizing residual — ACCEPTED-RISK / INFO, bounded to grief, not theft. A finding is HIGH/CRITICAL
  only if it breaks an on-chain guarantee the §10.1 posture promises HOLDS: output to a non-Safe address, an
  arbitrary pair, a non-zero `value`, a cap that doesn't bind, or a swallowed failure reported as success.
- The build-phase mutable wiring is a documented residual closed by the pre-prod immutable re-freeze (process,
  not code). A finding that merely restates "the Timelock can re-point a wired address" is INFO unless you show
  a re-point that **drains** rather than redirects/griefs.
- "Sound" is a valid result. For a thin swap-leg module, "wired correctly, the pins hold, here's what I diffed"
  is the expected outcome; a manufactured finding is noise.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/guard/residual you attack (I-1…I-6, X-1, G-n)>
- **Location:** <fn / exact line in SellModule.sol + the zodiac-core base / ISwapRouter line where the seam crosses>
- **Delta from posture:** <how it breaks a §10.1 on-chain guarantee, or "operator-sizing (X-1, accepted)", or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it REDIRECTS output, enables a DUMP,
  bypasses the slippage/deadline abort, or swallows a failure — and whether the §10.1 boundary already bounds it
  to grief.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness
verdict (and explicitly: do the recipient/pair pins and the size cap hold on-chain?).
