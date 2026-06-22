# X-Ray — `LienTokenFactory.sol` (single-contract, test-connected)

> LienTokenFactory | 20 nSLOC | 46fd0c1 (`main`) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo no external audit)*

Per-contract X-Ray for `contracts/src/LienTokenFactory.sol`, the **CREATE2 minter** for
[`LienCollateralToken`](LienCollateralToken.md): deploys one fixed-supply lien token per `lienId` at a deterministic,
caller-bound address so the controller/CRE can precompute it before the origination batch. Stateless (stores no
mapping — identity is the address, recoverable via `computeAddress` + the `LienCreated` event). Exercised by
`LienToken.t.sol` (shared with the token) and consumed by the real `ZipcodeController` origination path.

> The security is entirely in the **CREATE2 address derivation**: `salt = keccak256(lienId)` but the init-code embeds
> `msg.sender` (the controller), so the deployed address is a function of *both* `(lienId, caller)`. Two consequences,
> both load-bearing: (1) **squat-proof** — a griefer reusing a `lienId` from a different caller lands at a *different*
> address and cannot pre-occupy the controller's slot; (2) **single-use forever** — the same `(lienId, caller)`
> reverts (CREATE2 collision), and burning the token's supply does NOT free the address (the contract still exists),
> so a `lienId` can never be re-minted by that caller. No gate, no admin, no state — caller-binding *is* the
> authorization.

## 1. What it is

A 20-nSLOC stateless factory. One constant, one event, two functions:
- **`LIEN_DECIMALS = 18`** — the canonical pin the `ZipcodeOracleRegistry` validates every priced key's `decimals()` against.
- **`create(lienId)`** — `Create2.deploy` with `salt = keccak256(abi.encode(lienId))` and init-code `= creationCode ++ abi.encode(msg.sender)`; emits `LienCreated(lienId, lien)`. The new token's authority is the caller. Reverts `FailedDeployment` if `(lienId, caller)` is already occupied.
- **`computeAddress(lienId, controller)`** — the pure precompute (two-arg: a prediction has no `msg.sender` authority, so anyone can predict any lien's address). Returns the deterministic CREATE2 address.

No owner, no admin, no setter, no mapping, no upgrade. The factory holds nothing and authorizes nothing beyond the
implicit caller-binding baked into the salt+init-code.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `create(lienId)` | permissionless (caller-bound) | deploys the token authorized to `msg.sender`; `FailedDeployment` on a re-use of `(lienId, caller)`; emits `LienCreated` |
| `computeAddress(lienId, controller)` | public view | deterministic precompute keyed on both args |
| `LIEN_DECIMALS` | public const | `18` (the registry's decimals pin) |

`create` is permissionless because the authorization is structural — whoever calls it becomes the token's controller,
and the address is bound to that caller, so there is nothing to gate.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **precompute matches deploy** — `computeAddress(lienId, caller)` equals the address `create(lienId)` from `caller` lands at | Yes | **`test_PrecomputeMatchesDeploy`** |
| I-2 | **address keyed on BOTH `lienId` and `controller`** — different `lienId` or different caller ⇒ different address | Yes | **`test_PrecomputeKeyedOnLienIdAndController`** |
| I-3 | **squat-proof (caller-binding)** — a different caller reusing the same `lienId` deploys to a DIFFERENT address; it cannot occupy the controller's slot | Yes | **`test_CreateCallerBoundSquatProof`** |
| I-4 | **single-use dedup** — the same `(lienId, caller)` reverts `FailedDeployment` (CREATE2 collision) | Yes | **`test_DedupSameCallerReverts`** |
| I-5 | **burn does NOT free the slot** — a `lienId` cannot be re-minted by the same caller even after the token's supply is burned (the contract still exists at the address) | Yes | **`test_BurnThenRecreateStillReverts`** |
| I-6 | **`LienCreated` event links `lienId -> lien`** (both indexed, for off-chain recovery) | Yes | **`test_LienCreatedEvent`** |
| I-7 | **`LIEN_DECIMALS == 18`** (the registry's validation constant) | Yes | **`test_DecimalsPin`** (`factory.LIEN_DECIMALS() == 18`) + `ZipcodeOracleRegistry.t.sol` |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `FailedDeployment` (CREATE2 collision = dedup) | `create:28` (OZ `Create2.deploy`) | `test_DedupSameCallerReverts`, `test_BurnThenRecreateStillReverts` |
| caller-binding (init-code embeds `msg.sender`) | `create:27` | `test_CreateCallerBoundSquatProof`, `_PrecomputeKeyedOnLienIdAndController` |

There are no `require`/custom-error guards in the factory itself — the safety is the CREATE2 derivation, and both of
its load-bearing consequences (squat-proof, single-use) are directly tested.

## 5. Attack surfaces

- **The squat-proofing is the crux — and it's proven (I-3).** Because the init-code embeds `msg.sender`, an attacker
  cannot front-run a controller by calling `create(lienId)` first: their token lands at a *different* address (keyed
  to the attacker), leaving the controller's precomputed `(lienId, controller)` address still free. The controller's
  origination can always deploy to its own predicted address. This is the property that makes a permissionless
  `create` safe.
- **Single-use-forever is enforced by CREATE2 + the non-destructing token (I-4/I-5).** A re-`create` of the same
  `(lienId, caller)` reverts because code already exists at the address; `LienCollateralToken` never self-destructs,
  so even a fully-burned lien permanently occupies its slot. `test_BurnThenRecreateStillReverts` pins this — a `lienId`
  is genuinely one-shot per caller, which is what the lien-identity model relies on.
- **Stateless = nothing to corrupt or mis-wire.** The factory stores no mapping (identity is the address + the
  event), has no admin, no setter, no owner, no upgrade. Like its token, it carries NONE of the build-phase
  mutable-wiring residual that caps the rest of the subsystem.
- **Inherent trust:** OZ `Create2` (`deploy`/`computeAddress`) is audited library code; the determinism guarantee is
  the EVM's CREATE2 semantics. The factory adds no logic on top beyond assembling the salt + init-code.
- **The `LIEN_DECIMALS` constant is a cross-contract contract** — the registry trusts `18` and validates every key's
  `decimals()` against it; the token pins `decimals()` to the same `18`. Both ends asserted (I-7 + the token's
  decimals pin), so the scale the oracle infers is coherent across the three contracts.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Precompute (match / keying) | 2 | `test_PrecomputeMatchesDeploy`, `_PrecomputeKeyedOnLienIdAndController` |
| Squat-proof + dedup + burn-then-recreate | 3 | `test_CreateCallerBoundSquatProof`, `_DedupSameCallerReverts`, `_BurnThenRecreateStillReverts` |
| Event + decimals constant | 2 | `test_LienCreatedEvent`, `_DecimalsPin` |
| Consumer (real origination) | via `ZipcodeController.t.sol` | the factory mints the real lien in the origination batch |

Coverage % uninstrumentable (project-wide `Stack too deep`); the `LienToken.t.sol` suite is green and every factory
surface — both functions, the constant, the event, and both CREATE2 consequences — is exercised. No coverage gap; a
stateless CREATE2 factory has no untested surface here.

## X-Ray Verdict

**HARDENED** *(modulo no external audit)* — a minimal, stateless CREATE2 factory whose entire safety model (the
caller-bound, deterministic address derivation) is directly proven: precompute matches deploy, the address is keyed
on both `lienId` and caller, a different caller cannot squat a `lienId`, the same `(lienId, caller)` is single-use
(dedup revert), and burning the supply never frees the slot. It has **no admin, no state, no mutable wiring, no
upgrade** — none of the build-phase residual — so the only thing below a clean bill is the project-wide absence of an
external audit. The CREATE2 primitive itself is audited OZ.

**Structural facts:**
1. 20 nSLOC; stateless; `LIEN_DECIMALS=18` + `LienCreated` event + `create`/`computeAddress`; no admin/state/upgrade.
2. `salt = keccak256(lienId)`; init-code embeds `msg.sender` ⇒ address keyed on `(lienId, caller)` — caller-binding is the authorization (no gate).
3. Squat-proof (a foreign caller lands at a different address) and single-use-forever (CREATE2 collision + non-destructing token), both tested.
4. `computeAddress` is two-arg and pure-prediction — anyone can predict any lien's address; the CRE/controller uses it to pre-derive the lien address before origination.
5. Tests: 7 dedicated (`LienToken.t.sol`) covering both functions + both CREATE2 consequences + the decimals constant; consumed by the real `ZipcodeController` origination. No gap; capped only by no external audit.
