# Adversarial Spec — Claude's audit methodology (zipcode-euler)

This is the prompt/methodology used for the Claude-side audit, run as a parallel fan-out of one
deep auditor per subsystem. It is deliberately different from the local model's generic 10-lens
sweep (`audit/lenses.py`). The local sweep pattern-matches bug *shapes*; this derives and **verifies
multi-step attack paths**, and — critically — refuses to count acknowledged trust assumptions as bugs.

## Core principles

1. **Invariant falsification, not pattern-matching.** The protocol ships an explicit list of *claimed
   invariants* (`system-map.md` §6) labelled "hypotheses for auditors to break." Each is treated as a
   hypothesis: construct a concrete, ordered, multi-step sequence where it fails (who calls what, in
   what order, the state transitions, the profit/impact) — or confirm, with reasoning, that it holds.

2. **Bug vs. acknowledged-trust discipline (the decisive filter).** This protocol documents its trusted
   actors and their blast radius: the Timelock can re-point almost all wiring; a compromised CRE/
   Forwarder can push arbitrary marks within its receiver partition; the engine operator is fully
   trusted and `creditFreeValue` is unbounded *by design*. A finding is only real if it (a) breaks an
   invariant the protocol **claims** holds, or (b) lets an actor **exceed** their documented blast
   radius — grief→theft-to-attacker, bounded→unbounded, isolated→contagion, honest-but-misordered→
   corruption. "Malicious Timelock steals X" is **not** a finding. This single rule is what separates a
   useful report from 200 lines of noise.

3. **Verified attack paths only.** Every finding names the exact calls, ordering, and resulting
   profit/impact, traced against the code as written. A false break (claiming an exploit that doesn't
   actually execute) is treated as worse than a miss.

4. **Seam-first.** The highest-value bugs live between contracts (`system-map.md` §4 trust boundaries).
   Each auditor reads the full system map for cross-contract context before touching its files.

5. **Negative results are deliverables.** What was attacked and *held* is reported explicitly, so the
   coverage is auditable rather than implied.

## Threat actors modelled
First depositor · MEV searcher / CoW solver · compromised CRE/DON (incl. **honest-but-out-of-order**
delivery and **replay of signed reports**) · compromised engine operator · colluding borrower ·
misconfiguration / wiring-state. The Timelock is modelled as trusted (build-phase posture) — attacks
that require a malicious Timelock are logged as posture notes, not findings.

## Per-subsystem focus (the actual fan-out prompts, condensed)

- **supply / NAV oracle** — break the `max/min(spot,twap)` bracket; the `navExit`-never-reverts
  staleness asymmetry; the first-push-bypasses-deviation-band seam; the no-LP-TWAP spot flash-skew;
  TWAP poke-spam immunity; `effectiveSupply` pending-burn exclusion; the redemption-queue par/round-down.
- **szipUSD engine** — two-token invariant (`totalSupply == loot.balanceOf(gate)`); round-down
  first-depositor; `burnFor` pure-supply-reduction; never-above-NAV integer ceiling; free-value-only
  two-layer guard; freeze-floor pinned to absolute debt; coverage-gate behaviour; reservoir borrow cap.
- **core** — report-type partition; conditional workflow-identity gate; **registry no-monotonic-guard /
  no-deviation-band** (self-flagged); origination atomicity + erebor-only draw; hook anti-spoof; CREATE2
  lien factory.
- **bridge** — `exchangeRate` non-manipulability; measured-delta mint/redeem; rate-oracle strictly-newer
  + the `exchangeRate()==0`-on-never-pushed consumer trap; CCT ctor invariants + lock/burn conservation.
- **loss** — sole-provision-writer + bound; the `totalProvision == Σ == oracle.provision()` identity;
  status machine; destination-integrity (no recipient param); no-balance-reconciliation assumption.
- **venue** — per-line router frozen at birth; erebor-only draw; `collateralAmount == 1e18`; liquidate
  reverts; isolation; LineAccount operator grant; origination atomicity vs un-asserted EE preconditions.

Output format per finding: `title / contract / function / location / class / severity / confidence /
invariant_broken / actor (+ whether it exceeds documented blast radius) / attack (numbered, verified)`.
