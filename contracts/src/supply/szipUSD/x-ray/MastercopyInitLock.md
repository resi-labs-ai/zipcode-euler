# X-Ray — `MastercopyInitLock.sol` (single-contract, test-connected)

> MastercopyInitLock | 8 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE** *(coverage-complete; benign failure mode)*

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/MastercopyInitLock.sol`, the shared init-lock base
for the szipUSD engine-module mastercopies (the SEC-14 fix). It has **no dedicated test file** — but it is the
**most consumer-covered contract in the subsystem**: inherited by **all 9 engine modules**, and its lock is
exercised by **18 tests** (9 × `test_SEC14_mastercopy_setUp_reverts` + 9 × `test_mastercopy_inert`/`_init_locked`)
across those suites.

> Tiny by design. Two statements of behavior, both directions tested nine times over. There is nothing left to test
> on this contract; the only "gap" is the absence of a *dedicated* file, which is immaterial for a 4-line mixin whose
> semantics only exist in the context of a real `Module`.

## 1. What it is

A 4-line `abstract` base extending zodiac-core `Module`. Each engine module is deployed once as a
`ModuleProxyFactory` mastercopy, then EIP-1167-cloned per Safe; the clone's wiring is written by `setUp(bytes)` under
the one-shot `initializer`. This base's constructor calls `_lockMastercopy()` — an **empty, `initializer`-guarded**
function that flips the inherited (private, in zodiac-core `Initializable`) `_initialized = true` **without running
`setUp`**, so it sidesteps `setUp`'s non-zero / `owner != operator` validation (a ctor that called
`setUp(abi.encode(zeros))` would revert `ZeroAddress`).

**Why it exists (the SEC-14 fix):** without it, the bare mastercopy's `_initialized` stays false, so anyone could
call `setUp` on it. That is *harmless* — a bare mastercopy is never `enableModule`'d on a Safe and holds no custody —
but the modules' docstrings claimed it was already locked. This base makes the claim true (defense-in-depth +
docstring honesty). EIP-1167 clones never run this constructor (a proxy does not execute the implementation's ctor;
its storage `_initialized` is fresh-zero), so clones `setUp` exactly once as before — the deploy path is unchanged.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `constructor()` | deploy-time | calls `_lockMastercopy()` (runs only on the mastercopy, never on a clone) |
| `_lockMastercopy()` | `private initializer` | empty body; the `initializer` modifier flips `_initialized` |

No public/external surface of its own. It contributes the *absence* of a callable bare-mastercopy `setUp`.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **mastercopy is locked** — after construction, `setUp` on the bare mastercopy reverts `AlreadyInitialized` | Yes | **9 × `test_SEC14_mastercopy_setUp_reverts`** (Exercise/Harvest/LpStrategy/Freeze/BuyBurn/Sell/Recycle/OffRamp/ReservoirLoop) — each deploys a bare mastercopy and asserts the revert |
| I-2 | **clones still init exactly once** — a fresh clone's storage is `_initialized==0`; it `setUp`s once, then reverts | Yes | **9 × `test_mastercopy_inert`/`_init_locked`** (fresh clone reads zero wiring, inert until `setUp`) + each module's `test_setUp_initializer_once` (a second `setUp` reverts) |
| I-3 | **the lock sidesteps `setUp` validation** — the empty `initializer` body flips the flag without the zero/owner checks (a ctor running `setUp(zeros)` would revert `ZeroAddress`) | Yes (structural) | the constructor compiles + I-1 holds (the mastercopy deploys without reverting, yet is locked) |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `initializer` one-shot (mastercopy) | the 9 SEC-14 tests (revert `AlreadyInitialized`) |
| `initializer` one-shot (clone) | the 9 `test_setUp_initializer_once` per-module tests |

## 5. Attack surfaces

- **The locked mastercopy (I-1) — proven nine times** — the only behavior this contract adds is making the bare
  mastercopy's `setUp` revert. Every engine module's SEC-14 test deploys a bare mastercopy and confirms it. There is
  no other surface.
- **Benign failure mode** — even if the lock did *not* fire, the impact is nil: a bare mastercopy is never
  `enableModule`'d on a Safe, holds no custody, and a stray `setUp` on it cannot move any value. So this is
  defense-in-depth + docstring-honesty, not a value-bearing control. That is why a coverage-complete 4-line contract
  is graded ADEQUATE rather than weighted as high-consequence.
- **Vendored dependency** — relies on zodiac-core `Initializable`'s `_initialized` semantics (private flag, one-shot
  `initializer`). Frozen vendored copy; correctness is upstream Zodiac's.
- **No fuzz/invariant — N/A** — there is no state or arithmetic; the two behaviors are boolean and exhaustively
  covered by the consumer SEC-14 tests.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Dedicated unit | 0 | no `MastercopyInitLock.t.sol` — semantics only exist via a concrete `Module` |
| Consumer SEC-14 (lock holds) | 9 | one per engine module — bare mastercopy `setUp` → `AlreadyInitialized` |
| Consumer inert/once (clone still inits once) | 9 | `test_mastercopy_inert`/`_init_locked` + `test_setUp_initializer_once` |

Both directions of the contract's contract — *mastercopy locked* and *clone still inits once* — are proven across
all 9 consumers (18 tests). Coverage % uninstrumentable (project-wide stack-too-deep); green runs confirmed in each
consumer suite this session (Exercise/Harvest/LpStrategy/Freeze drilled directly).

## X-Ray Verdict

**ADEQUATE** *(coverage-complete; benign failure mode)* — a 4-line defense-in-depth mixin whose entire behavior
(lock the mastercopy; leave clones free to init once) is proven in both directions by 18 tests across all 9 engine
modules. There is nothing further to test on this contract. Not graded higher only because the property is
defense-in-depth over an already-benign failure mode (a bare mastercopy is never enabled on a Safe), and it leans on
the vendored zodiac-core `Initializable`; not graded lower because coverage is complete and the SEC-14 claim it
exists to make true is demonstrably true.

**Structural facts:**
1. 8 nSLOC; `abstract`; extends zodiac-core `Module`; no storage, no custody, no public surface of its own.
2. Constructor → `_lockMastercopy()` (empty `initializer`) flips `_initialized` on the mastercopy without running `setUp` (sidesteps the zero/owner validation).
3. EIP-1167 clones never run the ctor → fresh-zero `_initialized` → `setUp` once, deploy path unchanged.
4. Inherited by all 9 engine modules; lock + clone-once both proven by 18 consumer tests (9 SEC-14 + 9 inert/once).
5. No dedicated test file (immaterial for a 4-line mixin); no outstanding coverage gap.
