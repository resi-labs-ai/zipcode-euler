# Boot context — LienTokenFactory adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md` / `2.md`) before you begin. This is a deliberately minimal 20-nSLOC stateless CREATE2 minter — soundness
is the expected result; the value is confirming the one non-standard surface (the caller-bound address derivation)
holds, NOT re-proving OZ `Create2` or the EVM's CREATE2 semantics.

## The contract under review
- `contracts/src/LienTokenFactory.sol` (20 nSLOC) — the stateless CREATE2 minter for `LienCollateralToken`. One
  constant, one event, two functions. The entire safety model is the CREATE2 address derivation:
  - `create(lienId)` (`:24-30`) — `Create2.deploy(0, salt, initCode)` with `salt = keccak256(abi.encode(lienId))`
    (`:25`) and `initCode = creationCode ++ abi.encode(msg.sender)` (`:26-27`). The init-code embeds the CALLER, so
    the deployed address is a function of BOTH `(lienId, caller)`. Emits `LienCreated(lienId, lien)` (`:29`).
  - `computeAddress(lienId, controller)` (`:37-42`) — the pure two-arg precompute (a prediction has no `msg.sender`
    authority, so anyone must be able to predict any lien's address). Returns the deterministic CREATE2 address.
  - `LIEN_DECIMALS = 18` (`:15`) — the canonical pin the `ZipcodeOracleRegistry` validates every priced key's
    `decimals()` against.
  There are NO `require`/custom-error guards in the factory itself — no owner, no admin, no setter, no state/mapping,
  no upgrade. `create` is permissionless because the authorization is STRUCTURAL: whoever calls becomes the token's
  controller and the address binds to that caller, so there is nothing to gate.

**Why it matters:** a permissionless `create` is only safe if a griefer cannot pre-occupy the controller's predicted
slot. The whole property turns on the init-code embedding `msg.sender` (`:27`): a foreign caller reusing the same
`lienId` lands at a DIFFERENT address (keyed to the attacker), leaving the controller's `(lienId, controller)` slot
free. Combined with CREATE2 collision-revert (`FailedDeployment`) and a token that never self-destructs, a `lienId`
is single-use forever per caller. This is the lien-identity model: the lien's identity IS the token's address.

## These are ORIGINAL contracts — the precedent is OZ Create2 + the EVM's CREATE2 determinism, not a code parent
Your "supposed to be" baselines:
- **OpenZeppelin `Create2`** (`@openzeppelin/contracts/utils/Create2.sol`) — the audited base. `Create2.deploy`
  (which reverts `Errors.FailedDeployment` on a collision/empty-code) and `Create2.computeAddress` are audited
  library code; re-testing or re-auditing them is out of scope (it would re-prove audited code). The EVM's CREATE2
  address = `keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))[12:]` is the determinism guarantee — also
  trusted. Attack ONLY the factory's contribution: the salt assembly (`:25`/`:38`) and the init-code assembly
  (`:26-27`/`:39-40`), and confirm the two assemblies agree between `create` and `computeAddress`.
- **The token it deploys** — `contracts/src/LienCollateralToken.sol`. Fixed-supply 1e18-to-the-controller, immutable
  `controller` set from the constructor arg, `decimals()` pinned `pure` to `18` (`:26-28`), a controller-only `burn`,
  and crucially NO `selfdestruct` — so a burned-to-zero token still occupies its CREATE2 slot.
- **The real consumer** — `contracts/src/ZipcodeController.sol` `_origination` (`:212-251`): it calls
  `computeAddress(lienId, address(this))` (`:232`) then `create(lienId)` (`:233`) and asserts they match (`revert
  PrecomputeMismatch()` `:234`). The controller is the only real caller; it carries its own `LienExists` dup-guard
  (`:229`) AHEAD of the factory's `FailedDeployment` (belt-and-suspenders).
- **The X-Ray is your ground truth** — `contracts/src/x-ray/LienTokenFactory.md` (I-1…I-7, the guard table). Rated
  HARDENED; soundness is expected.

## Tests
**7 dedicated tests** in `contracts/test/LienToken.t.sol` (shared with the token). The factory's whole surface is
covered: `test_PrecomputeMatchesDeploy` (precompute == deploy), `test_PrecomputeKeyedOnLienIdAndController` (distinct
lienId OR distinct caller → distinct address), `test_CreateCallerBoundSquatProof` (an attacker's `create` lands at the
attacker-keyed slot, the controller's slot stays free), `test_DedupSameCallerReverts` (re-`create` of the same
`(lienId, caller)` → `FailedDeployment`), `test_BurnThenRecreateStillReverts` (burn to 0 supply, re-`create` still
reverts — the slot stays occupied), `test_LienCreatedEvent` (the indexed link), `test_DecimalsPin`
(`LIEN_DECIMALS == 18`). See what is proven (don't re-report) and what is intentionally NOT re-tested (OZ `Create2`,
EVM CREATE2 determinism).

## Ground rules
- Cite exact lines in `LienTokenFactory.sol` AND the OZ `Create2` behavior, the `LienCollateralToken` constructor, or
  the `ZipcodeController._origination` call site.
- The decisive surfaces: (1) a path where a FOREIGN caller can occupy the controller's `(lienId, controller)` address
  — i.e. the caller-binding fails (the init-code does NOT actually embed `msg.sender`, or `create` and
  `computeAddress` assemble the init-code/salt differently so precompute disagrees with deploy); (2) a re-mint of a
  retired `(lienId, caller)` slot — a double-create that does NOT revert, or a burn/self-destruct path that frees the
  slot; (3) a `LIEN_DECIMALS` mismatch with the token's `decimals()` or the registry's expected pin.
- **Pressure-test severity.** Do NOT report OZ `Create2` behavior (the `deploy`/`computeAddress` internals, the
  `FailedDeployment` revert) as findings — it's unmodified audited code. Do NOT report the EVM's CREATE2 determinism
  as a finding — it's the trusted base. Do NOT report "`create` is permissionless" as a vuln — that's the design
  (caller-binding IS the authorization). The factory has NO build-phase residual (stateless, no admin, no mutable
  wiring) — there is nothing to mis-wire or re-freeze; do not invent one.
- "Sound" is the expected result for a 20-nSLOC stateless CREATE2 factory. A manufactured finding is noise.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant you attack (I-1…I-7)>
- **Location:** <fn / exact line in LienTokenFactory.sol + the OZ Create2 behavior / token ctor / controller call site>
- **Delta from precedent:** <how the salt/init-code assembly differs from a faithful OZ Create2 use, or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether it lets a FOREIGN caller occupy the
  controller's slot, lets precompute DISAGREE with deploy, lets a retired `(lienId, caller)` be RE-MINTED, or
  introduces a DECIMALS mismatch with the token/registry.

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness verdict
(and explicitly: does `computeAddress` match `create`, is the address keyed on both `lienId` and caller, is a
`(lienId, caller)` single-use forever, and is `LIEN_DECIMALS` coherent with the token/registry?).
