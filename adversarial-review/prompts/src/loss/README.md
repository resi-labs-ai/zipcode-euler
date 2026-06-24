# Loss subsystem group — adversarial review prompts

> **Running a cycle?** Read `adversarial-review/CONDUCTOR.md` first. This file is the map.

Mirrors `contracts/src/loss/`. Two tightly-coupled contracts — the orchestrator + its custody half.

| Contract | nSLOC | Missions | Surfaces |
|---|---:|---:|---|
| `defaultcoordinator/` | 158 | 3 | provision arithmetic / conservation+oracle seam · status machine + dispatch + the two-call resolve · §13 CRE trust-ceiling + MAX-allowance/wiring blast radius |
| `lienxalphaescrow/` | 96 | 2 | destination integrity + per-lien conservation + lifecycle · reentrancy/CEI + MAX-allowance + X-2 sink re-point |

## These are ORIGINAL contracts — the differential is the spec posture + (for the escrow) a real precedent
Unlike the bridge (diffed vs Rubicon) and hydrex-demo-fork (diffed vs their own prod parents), the loss
contracts have **no audited code parent to diff line-for-line**. The "supposed to be" baselines are:
- **DefaultCoordinator** — the **§13 residual-trust posture** (in the contract NatSpec `:22-43`,
  authoritative): the contract BOUNDS and ROUTES, it does NOT validate a default is real. The on-chain
  promise is grief-not-theft: a compromised CRE/DON can down-mark NAV, slash a healthy bond, or reclaim a
  fresh bond via a hostile originator, but CANNOT steal to an arbitrary address or inflate NAV. The base
  precedent is `ReceiverTemplate` (the Forwarder + workflow-identity gate).
- **LienXAlphaEscrow** — a documented **clean-room replication of `InsuranceFund.bring`**
  (`reference/moneymarket-contracts/src/InsuranceFund.sol:33`): the single-authorized-caller + gated
  `safeTransfer` custody pattern. The escrow's whole defense is DESTINATION INTEGRITY (no recipient
  parameter; xALPHA reaches only originator/adminSafe/juniorTrancheSafe). Diff the generalization (pull-in
  at lock + per-lien book + three destinations) against the original.

## The two contracts share a seam — every panelist reads both
The coordinator's `_resolve`/`_writeOff` make a TWO-CALL cross-contract sequence into the escrow
(`slashXAlphaToCapital` → a `bondAmount` read → `slashXAlphaToCohort`), WITHOUT pre-asserting bounds — it
relies on the escrow's `ExceedsBond`/`NoBond` reverts to roll the whole report back (CEI). Neither
contract's resolve/slash safety is judgeable in isolation; each `_boot.md` requires reading the sibling.

## Pressure-test severity hard (carry into every synthesis)
The §13 grief ceiling (X-1) and the build-phase mutable wiring (X-2) are **ratified residuals**, not vulns:
- A finding that merely requires distrusting the CRE/DON within the documented grief ceiling is
  ACCEPTED-RISK / INFO (the X-1 precedent — like the SzAlpha ADV-01 precompile-distrust deflation).
- A finding that merely restates "the Timelock can re-point a sink in the build phase" is INFO unless it
  shows a re-point that **drains** rather than griefs/redirects. The sharpest such question is the
  coordinator's MAX-allowance re-point (`setEscrow` → an attacker escrow gets a MAX allowance over the
  launch reserve) — the X-Ray calls the MAX allowance "safe because the escrow is non-sweepable"; mission 3
  asks whether that justification is correct, understated, or wrong (an ERC-20 allowance lets the SPENDER
  move funds anywhere — the escrow's own sweepability is beside the point once the spender is hostile).
- A finding is HIGH/CRITICAL only if it breaks an on-chain guarantee the posture promises HOLDS: theft to
  an attacker-chosen address, NAV inflation, a `totalProvision==Σ==oracle.provision()` desync, or an illegal
  status transition.

Both contracts are among the **best-tested reviewed** (coordinator: 66u+1f+3inv; escrow: 44u+1f+2inv+5
reentrancy), with the load-bearing seams fuzz/invariant-asserted. "Sound" is the expected result — a
manufactured finding is noise. The value is a precise grief-vs-theft boundary plus any concrete escalation.

## Run
Per `CONDUCTOR.md`: prompts authored ✅ (this tree); X-Rays exist ✅ (`contracts/src/loss/x-ray/` —
per-contract `DefaultCoordinator.md` / `LienXAlphaEscrow.md` are authoritative; `invariants.md` /
`entry-points.md` are the scope-level catalog). Each mission's `context.files` inlines the contract + its
sibling + the base/precedent + the test suite for non-agentic (Fugu) panelists.
