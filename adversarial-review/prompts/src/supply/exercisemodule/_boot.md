# Boot context — ExerciseModule adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md` / `2.md` / `3.md`) before you begin.

## The contract under review
- `contracts/src/supply/szipUSD/ExerciseModule.sol` (95 nSLOC) — the 8-B8 **paid-exercise** leg: the fifth
  engine Zodiac `Module`, CRE-operator-gated, enabled on the szipUSD engine Safe (`avatar == target ==
  juniorTrancheEngine`). It owns the paid exercise of the harvest sell-slice. One operator action,
  `exercise(amount, maxPayment, deadline)` (`:178`), runs **exactly 3 `exec`s**: (1) `paymentToken.approve(oHYDX,
  maxPayment)` (`:185`), (2) `oHYDX.exercise(amount, maxPayment, juniorTrancheEngine, deadline)` (`:186` — burns
  the Safe's oHYDX, pulls the strike USDC, mints liquid HYDX to the Safe), (3) `paymentToken.approve(oHYDX, 0)`
  (`:187`). Plus a `quoteStrike(amount)` view (`:203`). **NO oracle, NO EVC, NO LP, NO veNFT, NO repay** — pure
  exercise mechanism.

**Why it matters:** the exercise burns the Safe's oHYDX and pays a USDC strike to mint liquid HYDX. A bug is
either a **redirect** (HYDX minted somewhere other than the Safe), an **overpay** (the strike pull exceeds the
slippage bound), a **standing approval** left on oHYDX, or a **silently-swallowed failure** reported as success.
This is the FIRST fleet-module the X-Ray drilled — it validates the shared shape (pinned recipient, fixed
3-exec sequence, slippage delegated to the external option, no standing approval) that Sell/Recycle/Harvest/
OffRamp reuse.

## These are ORIGINAL contracts — the precedent is the §10.1 boundary posture + the Zodiac base, not a code parent
Unlike the bridge/hydrex forks there is no audited parent to diff line-for-line. Your "supposed to be"
baselines:
- **The §10.1 security boundary** (contract NatSpec `:23-32`, authoritative): the operator supplies ONLY scalars
  (`amount`, `maxPayment`, `deadline`); the module builds ALL calldata to the set-once wired targets (`oHYDX`,
  `paymentToken`); the exercise `recipient` is hard-pinned to the literal `juniorTrancheEngine`; `value == 0`,
  `Operation.Call`, no passthrough/delegatecall. The strongest finding is a path where a pinned field becomes
  operator-influenced, or where the boundary leaks.
- **`maxPayment` is the slippage guard, delegated to the external option.** oHYDX (immutable, non-proxy, verified
  on Base) computes the strike from its OWN TWAP and pulls exactly that, reverting if it would exceed
  `maxPayment`. The on-chain belt-and-suspenders: the approval is capped at `maxPayment` (so even a misreporting
  return can't pull more) AND a `PaymentExceedsMax` re-assert on the decoded return (`:194`). The trust in oHYDX
  is deliberate and documented (X-1).
- **The zodiac-core `Module` base** — `reference/zodiac-core/contracts/core/Module.sol` — `execAndReturnData`, the
  `setAvatar`/`setTarget` `onlyOwner` setters, the `initializer` one-shot. Attack what the override adds on top.
- **`MastercopyInitLock`** — `contracts/src/supply/szipUSD/MastercopyInitLock.sol` — the SEC-14 mixin locking the
  mastercopy's `setUp` in its constructor.
- **The X-Ray is your ground truth** — `contracts/src/supply/szipUSD/x-ray/ExerciseModule.md` (I-1…I-7, X-1, the
  guard table). The fleet-wide pattern context is `contracts/src/supply/szipUSD/x-ray/portfolio-map.md`.

## Tests
`contracts/test/supply/szipUSD/ExerciseModule.t.sol` — 26 unit + 4 base-fork = **30 passing** (0 fuzz, 0
invariant — a deterministic 3-call sequence with no arithmetic). **Every mutator is exercised** (all 4 setters +
the operator action). The exec-shape proof decodes the exercise calldata (arg 3 == Safe); the bubble/atomicity
matrix covers custom error / empty / short return; `maxPayment`-too-low + past-deadline abort on the real Base
oHYDX; the same-block `paymentAmount == quoteStrike` check ties the view to the charge. See what is proven
(don't re-report) and where the tests STOP (the `maxPayment`-cushion sizing — off-chain 8-B11; the build-phase
re-point window).

## Ground rules
- Cite exact lines in `ExerciseModule.sol` AND the zodiac-core base / `IOptionToken` line where the seam crosses.
- The decisive surfaces: (1) HYDX minted anywhere but `juniorTrancheEngine`, or an arbitrary call / non-zero
  `value` / passthrough leaking through the §10.1 boundary; (2) a strike pull that exceeds `maxPayment` (the
  approval cap + the `PaymentExceedsMax` re-assert should make this impossible — find the hole); (3) a standing
  approval left on oHYDX after a swap or a failed swap; (4) an `exec` that returns `false` yet the step reports
  success.
- **Pressure-test severity (§10.1 / X-1).** A finding that merely requires the OPERATOR to size `(amount,
  maxPayment, deadline)` badly within the bounds — or that requires DISTRUSTING the immutable Base-verified oHYDX
  (its TWAP, its strike math) — is the documented X-1 residual: ACCEPTED-RISK / INFO, bounded to grief. A finding
  is HIGH/CRITICAL only if it breaks an on-chain guarantee the §10.1 posture promises HOLDS: a redirect, an
  overpay past `maxPayment`, a swallowed failure, or a `paymentToken` that drifts from oHYDX's actual one.
- The build-phase mutable wiring is a documented residual closed by the pre-prod immutable re-freeze (process,
  not code). A re-point restatement is INFO unless you show a re-point that **drains** rather than redirects.
- "Sound" is a valid result. For a thin exercise-leg module, "the pins hold, the slippage is bounded, here's what
  I diffed" is the expected outcome; a manufactured finding is noise.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/guard/residual you attack (I-1…I-7, X-1, G-n)>
- **Location:** <fn / exact line in ExerciseModule.sol + the zodiac-core base / IOptionToken line where the seam crosses>
- **Delta from posture:** <how it breaks a §10.1 on-chain guarantee, or "operator-sizing / oHYDX-trust (X-1, accepted)", or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it REDIRECTS the minted HYDX, enables an
  OVERPAY past `maxPayment`, leaves a standing approval, or swallows a failure — and whether §10.1 bounds it to grief.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness
verdict (and explicitly: does the recipient pin hold and is the strike bounded by `maxPayment` on-chain?).
