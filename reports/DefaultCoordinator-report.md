# Report — `DefaultCoordinator` (the loss-side orchestrator) — BUILT-VERIFIED + KEPT

**Window:** 2026-06-09 · build-only · `tickets/loss/DefaultCoordinator.md`
**Code:** `contracts/src/loss/DefaultCoordinator.sol` + `contracts/src/interfaces/loss/{ISzipNavOracle,ILienXAlphaEscrow}.sol` + `contracts/test/DefaultCoordinator.t.sol`
**Tests:** 63/63 (`forge test --match-contract DefaultCoordinator`) · 575/575 total no regression (`forge test`) · independently re-run, deterministic ×2 · ZERO load-bearing guesses · NOT git-committed (consistent with the recent loss-side/8-B* windows — your commit call).

---

## TL;DR
Built the **single loss-side orchestrator** — the contract the 8-Bx escrow + the `SzipNavOracle` provision seam were waiting on. It is a **CRE-gated `ReceiverTemplate`** (the same base the oracle uses, renounce-frozen) that holds two immutable authority bindings: it **is** the immutable `LienXAlphaEscrow.coordinator` (so it owns the full xALPHA bond lifecycle) **and** the oracle's set-once `defaultCoordinator` (the sole `writeProvision` caller). Its one piece of load-bearing on-chain logic is the **bound the oracle deliberately omits** — provisions can only be written down by `atRisk×(1−recoveryFloor)` at recognition and up by realized receipts, never an arbitrary NAV. M1-live = bond LOCK/RELEASE; M2 (built + mock-tested now) = the DEFAULT/RECOVERY/RESOLVE/WRITEOFF provision+slash flow.

You picked this item over `8x-01`/item-10; you confirmed the scope = **full orchestrator, M2 paths mock-tested** (the proven 8-Bx pattern).

## What the window did
1. **Spec surgery (harness step 3 — the gaps were genuine).** The §4.6 `DefaultCoordinator` bullet was a prose sketch and §8.4 was an explicit "M2 sketch"; the report ABI + the coordinator's concrete shape were undefined. I detailed:
   - **§4.6** — the build-grade bullet (CRE-gated ReceiverTemplate; IS the escrow coordinator + the oracle's sole writer; holds the launch xALPHA reserve; per-lien `(status, provision)` + `totalProvision`; the bound; recoveryFloor immutable; the reportType-8 action family; does NOT engage the freeze). Also amended the §4.6 M2-scope banner to reflect the 2026-06-09 build-scope pull (the contract is built in M1; the default DEMO stays M2, §15).
   - **§4.4** — added the **reportType-8** row → `DefaultCoordinator` direct: `payload = (uint8 action, bytes actionData)`, the LOCK/RELEASE/DEFAULT/RECOVERY/RESOLVE/WRITEOFF family, distinct from the bare reportType-5 default-status report that goes to the controller.
   - **§8.4** — the producer-level action decode (units, the off-chain split) + reconciled the two CRE-01 map rows.
2. **Drafted the ticket** (build-only, no INFLOW — internal plumbing).
3. **5-critic fanout** (junior/spec-fidelity/ref-verifier/qa/security). **Spec-fidelity FAITHFUL**; ref-verifier confirmed every signature/line against the real `ReceiverTemplate`/`SzipNavOracle`/`LienXAlphaEscrow` (no wrong paths/sigs). Folded all findings (below) — all convergent clarifications/test-hardening of already-intended surface, so **no re-fan** (README §3a).
4. **Cold-build** (fresh subagent, from the ticket alone): 63/63 + 575/575, zero guesses. Independently re-verified in the main session.

## Design decisions to sanity-check
1. **The DefaultCoordinator IS `LienXAlphaEscrow.coordinator` (derived, not chosen).** The escrow's `coordinator` is immutable and is the sole caller of all four state-changers (lock/release/slash). Since it can never be swapped and the coordinator must drive slash, the DefaultCoordinator must be that wired coordinator **from deploy** — which means it also owns LOCK (launch bonding, M1-live) + RELEASE (clean repay, M1-live). This is forced by the already-built escrow, not an expansion of scope. Consequence: the coordinator **custodies the launch xALPHA reserve** and `forceApprove(escrow, max)`s it (so `lockXAlpha`'s `safeTransferFrom(coordinator, …)` pull works).
2. **Pure CRE-driven, renounce-immutable, recoveryFloor as an immutable ctor param.** Everything flows through `_processReport` (reportType 8) — including LOCK/RELEASE. I chose this over keeping a live governance owner because a live owner would break the renounce-immutable Forwarder/identity seal that the controller/registry/oracle all use. The cost: `recoveryFloor` (a governed value) is fixed at deploy, and bond LOCK is a CRE-attested action rather than a treasury call. **This is the one place the design leans on "route the protocol's bond posting through the DON" — flagging it for your eye.**
3. **The escrow↔coordinator circular deploy is broken with a set-once `setEscrow`** (frozen by renounce — the oracle's set-once pattern), not a CREATE2 precompute. `navOracle` stays an immutable ctor param (the oracle is deployed first; no circularity there).
4. **The bound semantics:** DEFAULT sets `provision = atRisk×(1e18−recoveryFloor)/1e18` (round-down, conservative); RECOVERY reduces by `min(provision, recoveryProceeds)` (floored 0 — NAV can never be written above the un-impaired basket); RESOLVE heals to 0; **WRITEOFF leaves the residual provision in `totalProvision` permanently** (that residual IS the realized loss — it does NOT call `writeProvision`). `totalProvision == Σ lienLoss.provision == oracle.provision()` is the maintained invariant.
5. **Status machine** {None, Bonded, Defaulted, Resolved, WrittenOff}: LOCK only from None, RELEASE only from Bonded, DEFAULT only from Bonded, RECOVERY/RESOLVE/WRITEOFF only from Defaulted. Notably **LOCK-on-terminal is blocked by the coordinator's status guard** — the escrow would otherwise allow a re-lock at `bondAmount==0`.

## Holes surfaced → resolution
- **Spec gaps (fixed in spec FIRST):** the §8.4 report ABI + the coordinator's concrete shape were under-defined → the §4.6/§4.4/§8.4 surgery above. Spec-fidelity confirmed this was **detailing, not a mechanism change / §17 reopen.**
- **Critic catches folded into the ticket pre-build (no re-fan):**
  - *junior:* the unit tests need a `MockNavOracle` (ungated `writeProvision` + public `provision`) — the ticket only spec'd the real oracle; added it. The OZ-vs-`forge-std` `IERC20` trap (`forceApprove` needs the OZ one) — pinned. Added `bondOriginator` to the interface; dropped the misleading "active set" wording (WrittenOff provision persists).
  - *qa:* the drafted provision-bound fuzz was **tautological** (recomputed the formula) → replaced with a **stateful invariant handler + an independent `ghost_cap`**. Added the floor boundaries (0, `1e18-1` flooring a small atRisk to a 0 provision, the `atRisk=3, floor=0.5e18→1` truncation pin), RECOVERY status-stays-Defaulted + double-no-op, the **full status×action illegal-transition matrix**, WRITEOFF↔RESOLVE parity, and the **atomic-rollback assertion** on a bubbled `ExceedsBond` (provision/status unchanged after the revert).
  - *security:* the **residual-trust NatSpec block** (the §13 boundary stated plainly — bounds+routes, does NOT validate a default; `atRisk` is CRE-supplied so the bound constrains the transform not the magnitude; grief-not-theft; NAV never above the basket); the **hard tested renounce gate** as an item-10 obligation (renounce-before-`setEscrow` bricks both contracts; renounce-before-identity opens a workflow-blind grief surface); the WRITEOFF-must-not-decrement-`totalProvision` Do-NOT.
- **Build-exposed (folded back into the ticket):** the `MockNavOracle` must `emit ProvisionWritten` (else the co-emit / no-co-emit assertions are untestable); asserting a non-emit needs `vm.recordLogs()` + `import {Vm}`.

## Authoritative-doc edits
- `claude-zipcode.md` **§4.6** (DefaultCoordinator bullet + the M2-scope banner), **§4.4** (reportType-8 row + the intro line), **§8.4** (action decode), and the two **CRE-01 map rows** (§8.11). No `audit/2.md` / `audit/3-results.md` edits — the default flow is M2 and its integration sweep is deferred to item-10 (logged as an obligation); no change to M1 acceptance.
- No memory writes (nothing non-obvious beyond what the spec/ledger now record).

## Judgment calls
- Treated the DefaultCoordinator-IS-the-escrow-coordinator and the renounce-immutable/CRE-driven-LOCK as **derivations from locked seams**, not new decisions — but they are the load-bearing architectural calls of the window, so I flagged them above (decisions #1, #2) for your ratification.
- Did NOT build a `setRecoveryFloor` or any live-owner governance path (immutable floor) — keeps the loss-side "fully immutable after renounce" ethos. If you want `recoveryFloor` governable post-deploy, that reopens the renounce-immutability and is a different shape — say so and I'll re-author.

## Status + NEXT
**DONE — BUILT-VERIFIED + KEPT.** Both inbound obligations (provision-bound to `SzipNavOracle`; slash-driver to 8-Bx) **DISCHARGED**. Obligations **created** (logged in PROGRESS): the item-10 circular-deploy + hard renounce-gate `require`s; the xALPHA just-in-time funding discipline (non-sweepable, feeless token); the CRE §8.4 off-chain arithmetic; the item-10/M2 audit sweep.

**Remaining M1 on-chain (contract track):** `8x-01` (szALPHA bridge, ticket build-ready) · item 10 (deploy/wiring) · the **duration-squeeze freeze** (the last loss-side row). **NEXT = your pick.**

---

## POST-REVIEW AMENDMENT (2026-06-09, superintendent + user)
Superintendent review accepted the build. Then, **user-directed**, the loss side joined the repo-wide build-phase
**Timelock-settable wiring** decision (§17, memory [[oracle-replaceable-timelock-wiring]]):
- `DefaultCoordinator` is now **Timelock-owned (not renounced)**; `navOracle`, `xAlpha`, `escrow`, and `recoveryFloor`
  are Timelock-re-pointable (no `AlreadyWired` lock). `setEscrow` re-points + re-approves.
- The "immutable / renounce-frozen / set-once" language above describes the FIRST-pass build; it is superseded for the
  build phase — those guarantees are **deferred to the pre-production lock-down**. The provision-bound + status-machine
  logic is unchanged; only the wiring mutability changed. **64/64 (DC) + 633/633 total green** after the change.
