# 8-Bw — CreditWarehouse + `WarehouseAdminModule` — report to the superintendent

**TL;DR.** Authored + built + KEPT the **senior-backing custody**: a Gnosis Safe holding the `EulerEarn` shares
that back all zipUSD float, governed by a deployed **Zodiac Roles-modifier-v2** (the audited access engine), driven
by the authored **`WarehouseAdminModule is ReceiverTemplate`** — the sole Roles role member, which decodes the §8.5
CRE envelope into one of four scoped ops (SUPPLY/APPROVE/REDEEM/REPAY) and forwards via
`Roles.execTransactionWithRole`. The scope is the security boundary (params pinned, Call-only); the adapter is a thin
encoder holding no custody. **23/23 on a live Base fork, 424/424 full suite (was 401), ZERO load-bearing guesses.**
Build-only (no INFLOW — senior plumbing the CRE drives). Status **DONE**; NEXT = item 9 `ZipRedemptionQueue`.

**Run it yourself:** `cd contracts && forge test --fork-url $BASE_RPC_URL --match-contract WarehouseAdminModule`
(23/23); full no-regression `forge test --fork-url $BASE_RPC_URL` (424/424). I independently re-ran the contract
suite — green.

---

## What this window did
1. **Verified the references zero-guess BEFORE drafting** (3 parallel Explore agents + 1 focused follow-up):
   Roles-v2 API (`Roles`/`PermissionBuilder`/`Types`/`Integrity`/`PermissionChecker`/`PermissionLoader`), EulerEarn
   `deposit`/`redeem` arg order, `ReceiverTemplate`, the kept scaffold conventions, and the exact `ConditionFlat[]`
   trees — all `file:line`, with `cast code` confirming the Base addresses have live bytecode.
2. **Drafted** `tickets/sodo/8-Bw-credit-warehouse.md` (build-only).
3. **Fanned out 5 critics** (junior-developer + spec-fidelity + reference-verifier + qa-engineer + security-engineer —
   the full tier for a foundational contract custodying all senior backing). Synthesized + triaged.
4. **Fixed 2 SPEC-GAPs in `claude-zipcode.md` FIRST** (below), then revised the ticket.
5. **Cold-built from the ticket alone** (fresh builder, zero-guess gate) → `forge build` + `forge test` green, KEPT
   under `contracts/`. Folded 3 build-discovered on-chain corrections back into the ticket. Independently re-ran.
6. **Concluded:** filed the ticket, updated PROGRESS + LEDGER + the spec, wrote this report.

## Design decisions to sanity-check
1. **`WarehouseAdminModule is ReceiverTemplate`, a Roles role MEMBER — not a Zodiac `Module`.** It is `assignRoles`'d,
   has zero direct Safe authority, and every effect routes through the audited Roles engine. Only the Roles modifier
   is `enableModule`'d on the Safe. This is verbatim §4.5 :522-529. (Spec-fidelity: faithful.)
2. **The scope is the guard; the adapter is a thin encoder.** Params are pinned in the Roles policy
   (`EqualToAvatar`/`EqualTo`, Call-only `ExecutionOptions.None`), not in adapter logic. The adapter injects
   receiver/spender/owner (belt-and-suspenders) and passes only REPAY's `to` through (scope-guarded `EqualTo(repaySink)`).
   This puts the security boundary in audited bytecode, per the user-ratified "no bespoke privileged contract" decision.
3. **EulerEarn is MOCKED** (the WOOF-04/05 precedent — it pins solc 0.8.26). The novel infra is fork-real (Roles
   mastercopy + ModuleProxyFactory + Safe factory/singleton + USDC). This also dissolved the qa/junior concern that a
   freshly-created, un-allocated EulerEarn pool may not mint shares on `deposit` (allocation wiring is genuinely
   item-10). **Sanity-check:** is mocking EE acceptable here, or do you want a real-EE-pool fork variant? My read: the
   warehouse's contract responsibility is custody + Roles-gating (orthogonal to EE's allocation), so the mock is the
   right boundary, matching every prior EE-touching ticket.
4. **REPAY `to` = a single configured `repaySink`** (generalizing the spec's stale `LOANBOOK` noun). M1 sink =
   `ZipRedemptionQueue` (item 9); a second sink is an owner re-scope (`Or` of `EqualTo`s), not a redeploy. **The
   security critic flagged `repaySink` as the residual chokepoint/SPOF** — a compromised CRE can REDEEM→REPAY to it —
   so I logged (as item-10/8-B11 obligations) that the queue MUST be immutable/non-sweepable and ELEVATED the optional
   Delay-Modifier / `WithinAllowance` rate-limit to *recommended*. Sanity-check that elevation.
5. **Resolved the 3 §4.5/§8.5 "open items"** in-ticket + folded to spec: redeem owner-is-3rd-arg; redeemed USDC →
   Safe-then-REPAY (`receiver==owner==Safe`, fully avatar-pinned) rather than direct-to-sink; APPROVE `amount`
   scope-free with the CRE passing exact-amount (never standing-infinite — a CRE-policy obligation since EulerEarn is
   factory-deployed and may carry a curator surface).

## Holes surfaced → resolution
- **SPEC-GAP 1 (fixed in `claude-zipcode.md` §4.5 + §8.5):** REPAY `to==LOANBOOK` was a **stale noun** (no LOANBOOK
  contract exists; it predates the queue/recovery split) → generalized to `to==<pinned sink>` (queue M1 / recovery M2).
- **SPEC-GAP 2 (fixed in §4.5 :517 + §8.5 :1555 + §8.3):** the REDEEM producer payload `(shares, receiver)` +
  `receiver==<pinned>` was stale/open → resolved to `(shares)` + `receiver==owner==SAFE`. (The §8.5 reconcile note also
  flipped from "RECONCILE BEFORE BUILD" to "RECONCILED" + pinned opType bytes 1/2/3/4.) Both edits are mechanism
  consistency, not new decisions; no §17 reopened. spec-fidelity confirmed.
- **TICKET-GAP (both builders flagged the same blocker):** `ISafe.setup(...)` was absent from the interface →
  added the exact 8-arg signature; specified the Safe-deploy via `createProxyWithNonce(SAFE_L2_SINGLETON_1_4_1, setup, salt)`.
- **TICKET-GAP:** `IRoles` lacked `scopeFunction` + `ConditionFlat` → extended (the WOOF-00 minimal surface had
  deliberately omitted them); the 4 condition trees were reference-verified to pass `Integrity.enforce`.
- **QA/security additions folded into Done-when:** constructor reverts; the inner-exec-fail → `ModuleTransactionFailed`
  branch (zero-SUPPLY, SUPPLY-without-APPROVE, REDEEM/REPAY > held); malformed payload; atomicity; re-entrancy via the
  Forwarder gate; `WarehouseOp` `expectEmit`; pinning the `ConditionViolation` Status ordinal; `assertApproxEqAbs` on
  the NAV mark; the `to==safe` escalation-blocked test (`TargetAddressNotAllowed`); and the requirement that tree D's
  `to` be `EqualTo`, never `Pass`/parameterized.
- **2 build-discovered ON-CHAIN corrections (the deployed Roles mastercopy `0x9646…D337` is NEWER than the vendored
  `reference/zodiac-modifier-roles`):** (a) a non-member reverts **`NotAuthorized`** (the zodiac-core `moduleOnly` gate
  fires before the inner `NoMembership` — `assignRoles` registers the member in `modules[]`), not `NoMembership`;
  (b) a non-owner reverts **`OwnableUnauthorizedAccount`** (zodiac-core OZ-5 custom error), not the OZ-4 string the
  vendored package implied. Both folded into the ticket Done-when 8/9 — the build follows the live chain.
- **Build-discovered structural detail:** the deploy library must be the **transient** Safe + Roles owner during
  wiring (the 1/1 pre-validated `execTransaction` requires `msg.sender == owner`, and `scope*`/`assignRoles` are
  `onlyOwner`), then hand off to GOD-EOA via `swapOwner` + `transferOwnership`. Net effect identical; folded into the
  deploy-lib steps.

## Authoritative-doc edits this window
- `claude-zipcode.md` §4.5 (op table: opType bytes + REDEEM `receiver==SAFE` + REPAY pinned-sink; the "open items"
  bullet → RESOLVED with the decisions + the elevated drain-defense). §8.5 (the producer table: opType bytes,
  payloads, REDEEM `(shares)`, REPAY pinned-sink; RECONCILE→RECONCILED). §8.3 (REDEEM `receiver==SAFE` + the
  REDEEM→REPAY→settle order).
- `tickets/PROGRESS.md` — 8-Bw row → DONE (built-verified detail); CURRENT-STATE NEXT pointer → item 9; the 8-B5
  reservoir-resting-vault obligation → ROUTED to item-10; 4 NEW obligation rows; the spec-gap log entry.
- `tickets/LEDGER.md` — the 8-Bw digest.
- `tickets/sodo/8-Bw-credit-warehouse.md` — filed (with the build-discovered corrections folded in).
- **No `audit/2.md` / `audit/3-results.md` edit** — the warehouse deploy/wire audit sweep is DEFERRED to the item-10
  / engine-integration pass (consistent with 8-B5..B10; logged as an OPEN obligation), since a Phase-S deploy trace is
  not authorable against a standalone un-wired warehouse.

## Judgment calls (revert if you disagree)
1. **EulerEarn mocked, not a real fork pool** (decision 3). I judged the warehouse's contract scope is custody +
   Roles-gating, orthogonal to EE allocation (item-10), matching every prior EE-touching ticket. If you want a real-EE
   variant, it's an additive fork test.
2. **Audit-sweep deferred to item-10** rather than authored now (consistent with all engine modules). The 8-Bw row's
   text says "author into audit/2 Phase S" — I read that as the item-10 deploy script's job (it owns S1–S12), and a
   standalone warehouse can't be Phase-S-traced. Logged as an OPEN obligation, not dropped.
3. **NEXT = item 9 `ZipRedemptionQueue`** (the senior exit, now unblocked by the warehouse REDEEM/REPAY seam;
   `baal-spec §13` puts the queue after 8-Bw). Alternatives the superintendent may prefer: the **WOOF-06/INFLOW-06
   cold-build** (the interface is still pending), the **8x xALPHA bridge** (M1), or **8-Bx `LienXAlphaEscrow`**
   (M1-adjacent).
4. **`repaySink` SPOF mitigations elevated** from the spec's "optional M2" to "recommended item-10" (Delay
   Modifier / `WithinAllowance` rate-limit + immutable queue). This is a recommendation logged as an obligation, not a
   contract change — confirm the elevation.

## Status + NEXT
**DONE — built-verified + kept, NOT git-committed** (the whole tree is untracked, consistent with every recent 8-B
entry; the commit decision is yours). Code at `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol` (+ the
deploy lib, test, mock, and the 3 interface files). **NEXT = item 9 `ZipRedemptionQueue`.**
