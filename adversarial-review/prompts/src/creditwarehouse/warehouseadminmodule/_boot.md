# Boot context — WarehouseAdminModule adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md` / `2.md`) before you begin.

## The contract under review
- `contracts/src/supply/CreditWarehouse/WarehouseAdminModule.sol` (110 nSLOC) — the thin CRE adapter for the
  SENIOR-side `CreditWarehouse` (§4.5/§8.5). It is the **sole Roles role-member** of a deployed Zodiac
  Roles-modifier-v2 instance that is `enableModule`'d on the warehouse Safe (which custodies the `EulerEarn`
  shares backing all outstanding zipUSD float). It holds **NO custody** and enforces **NO scope** — a pure
  encoder: `_processReport` (`:179`) decodes the §4.4/§8.5 envelope `(uint8 opType, bytes payload)` into
  exactly one of four ops (SUPPLY/APPROVE/REDEEM/REPAY) and forwards it through
  `roles.execTransactionWithRole(to, 0, data, Call, roleKey, true)` (`:211`). Ownership is the Timelock (six
  build-phase wiring setters).

**Why it matters:** this routes every senior-side warehouse movement of USDC ↔ EulerEarn shares — the
backing of all outstanding zipUSD. A bug here either (a) lets a dangerous call reach the Safe (a value
transfer, a delegatecall, a redirected receiver/REPAY-sink → drain), or (b) fails-closed and bricks senior
par-redemption liveness.

## READ THIS FIRST — the security boundary is NOT this bytecode (load-bearing)
The contract self-describes as a *pure encoder*. The decisive control is the **Zodiac Roles-modifier-v2
scope config** attached to the warehouse Safe — params pinned (SUPPLY/REDEEM `receiver == avatar`, APPROVE
`spender == EqualTo(eePool)`, REPAY `to == EqualTo(redemptionBox)`), Call-only, no delegatecall. That scope
is **off-chain deploy config (X-1, On-chain=No)**, not in this file. The design trick this contract relies
on: **hardcode everything dangerous, inject everything addressable.** `value`=0, `operation`=Call (literal
0), `shouldRevert`=true are constants — never payload-decoded. Receiver/spender/redeem-owner are injected
from storage immutables; only the REPAY `to` comes from the payload, and it is BOTH self-checked
(`dest != redemptionBox` reverts) AND scope-pinned. Your job is to find where that discipline leaks, or
where the contract's reliance on the off-chain scope is misplaced.

## The precedent — diff against the REAL Zodiac Roles-modifier-v2 (this is a thin adapter on an audited base)
There is no audited parent for the encoder itself, but the engine it forwards to IS audited and vendored:
- **`reference/zodiac-modifier-roles/packages/evm/contracts/Roles.sol`** (`execTransactionWithRole` L153,
  `assignRoles` L69) and **`PermissionBuilder.sol`** (`scopeTarget` L86, `scopeFunction` L133,
  `allowFunction` L102). Confirm the adapter's `execTransactionWithRole(to, value, data, operation, roleKey,
  shouldRevert)` call shape, the `Operation` enum (0=Call/1=DelegateCall), and the `ExecutionOptions` enum
  (0=None,1=Send,2=DelegateCall,3=Both) match the real modifier. The local mirror is
  `contracts/src/interfaces/zodiac/IRoles.sol` (claims byte-for-byte parity, verified) — attack
  whether the encoded calldata + the `(to, operation, roleKey, shouldRevert)` args are what the real modifier
  + its scope will actually accept (a mismatch is fail-closed DoS, not a leak — say which).
- **`ReceiverTemplate`** — `reference/x402-cre-price-alerts/contracts/interfaces/ReceiverTemplate.sol` — the
  Forwarder + workflow-identity gate fronting `_processReport`.
- **The X-Ray is your ground truth** — `contracts/src/supply/CreditWarehouse/x-ray/WarehouseAdminModule.md`
  (per-contract, authoritative) + `invariants.md` (I-1…I-4, X-1/X-2/X-3, G-1…G-10). Every finding cites the
  invariant/guard it attacks.

## Tests
`contracts/test/supply/CreditWarehouse/WarehouseAdminModule.t.sol` — **28 fork-integration units against the
real deployed Zodiac Roles modifier** (0 fuzz, 0 invariant — correctly judged: a deterministic encoder, no
arithmetic). The suite's strength is that it drives the REAL scope (a second `MockMember` raw-calls
`execTransactionWithRole` with redirected params and is rejected). See what is proven — the full
scope-rejection matrix (redirected receiver → `ParameterNotAllowed`, wrong REPAY dest, value →
`SendNotAllowed`, delegatecall → `DelegateCallNotAllowed`, target/selector escalation → `TargetAddressNotAllowed`/
`FunctionNotAllowed`, non-member → `NotAuthorized`), avatar-parity enforced at the setter, all six setters —
and where it stops (the scope tree is exercised but its *correctness as deployed* is the off-chain audit
artifact; no amount bound on SUPPLY/APPROVE/REDEEM; the `setRoles`/external-`setAvatar` parity-desync path).

## Ground rules
- Cite exact lines in `WarehouseAdminModule.sol` AND the real `Roles.sol`/`PermissionBuilder.sol` line or
  the `IRoles` mirror where the seam crosses a contract.
- The decisive surfaces: (1) any path where a DANGEROUS attribute (value≠0, delegatecall, a redirected
  receiver/spender/REPAY-sink) reaches the forwarded call despite the hardcode/inject discipline → a real
  drain; (2) a place where the contract's reliance on the off-chain scope is unsound (it builds calldata the
  scope can't pin, or assumes a pin the scope doesn't have); (3) a wiring re-point that escalates from
  fail-closed grief into a value redirect.
- **Pressure-test severity hard.** This is HARDENED with the boundary out-of-file. A finding that requires
  DISTRUSTING the off-chain Roles scope (X-1) is the documented trust boundary — it's the #1 audit artifact,
  not an encoder vuln; classify it as X-1 accepted unless you show the *encoder* itself leaks. A finding that
  merely requires DISTRUSTING the build-phase Timelock (X-3) is accepted-risk, closed by the deferred pre-prod
  immutable re-freeze — INFO unless you show a re-point that drains rather than grief/fails-closed. A
  CRE-supplied unbounded `amount`/`shares` is grief bounded by the modifier/EE revert (CRE trust) — not a
  vuln unless it escapes that bound.
- "Sound" is the expected result for a defensively-hardcoded thin encoder. Say so and show why; a
  manufactured finding is noise.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant/guard/residual you attack (I-1…I-4, X-1/X-2/X-3, G-n)>
- **Location:** <fn / exact line in WarehouseAdminModule.sol + the Roles.sol/PermissionBuilder.sol/IRoles line where the seam crosses>
- **Delta from precedent/discipline:** <how it breaks the hardcode-dangerous/inject-addressable discipline or diverges from the real modifier's API/semantics, or "scope-trust (X-1, accepted)", or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it DRAINS (a value/receiver/sink redirect reaches the Safe) or merely FAILS-CLOSED (DoS/grief).

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line
soundness verdict (and explicitly: does the hardcode-dangerous / inject-addressable discipline hold — can
any dangerous attribute reach the forwarded call?).
