# X-Ray — `LienCollateralToken.sol` (single-contract, test-connected)

> LienCollateralToken | 18 nSLOC | 46fd0c1 (`main`) | Foundry | 20/06/26 | **Verdict: HARDENED** *(modulo no external audit)*

Per-contract X-Ray for `contracts/src/LienCollateralToken.sol`, the **1/1 fixed-supply lien collateral token**
(WOOF-01): exactly `1e18` minted once to the controller at construction, one instance per lien (the lien's identity
IS this token's address), controller-only burn, no mint path, no admin. Exercised by `LienToken.t.sol` (shared with
its `LienTokenFactory` sibling) and used as the **real** lien token across `ZipcodeController.t.sol`,
`EulerVenueAdapter.t.sol`, and `ZipcodeOracleRegistry.t.sol`.

> The whole point is **scarcity + immutability**: a fixed `1e18` supply that can only shrink (controller burn at
> close), with an immutable controller and no mint path. That fixed supply is load-bearing for the venue —
> `EulerVenueAdapter.openLine` requires `collateralAmount == 1e18` and the close path reclaims exactly `1e18` before
> burn, so a token that could mint more or start at a different supply would break the line lifecycle. The interesting
> property is therefore not in this file's logic (it's a near-vanilla OZ `ERC20`) but in the *invariant it upholds for
> consumers*: one whole token, ever, per lien.

## 1. What it is

An 18-nSLOC OZ `ERC20` ("Zipcode Lien Collateral" / "zLIEN") with exactly three additions over stock:
- **constructor(controller_)** — zero-guards the controller, mints the entire `1e18` supply to it, no other mint path exists;
- **`decimals()`** — pinned to `18` via a constant `pure` override (so a base-contract change can't silently shift the scale the oracle infers);
- **`burn(amount)`** — `controller`-only (`NotController`), burns from the controller's own balance (the close path).

`controller` is `immutable`. There is no owner, no admin, no setter, no upgrade, no pause, no second mint. Everything
else (transfer/approve/allowance/totalSupply/…) is unmodified OZ `ERC20`.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `constructor(controller_)` | deploy | zero-guard (`require`); mints `1e18` to `controller`; sets immutable `controller` |
| `burn(amount)` | `controller`-only | `NotController` otherwise; `_burn` from the controller's balance |
| `decimals()` | public pure | constant `18` |
| ERC-20 surface | public | stock OZ — transfer/approve/allowance/totalSupply/etc. |

No mint path post-construction. The token holds no custody beyond its own balances.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **fixed 1e18 supply minted once to the controller** (the WOOF-01 1/1 primitive) | Yes | **`test_TokenShape`** (name/symbol/decimals/`totalSupply == 1e18`/controller holds it) |
| I-2 | **supply can only shrink — no mint path** — burn reduces supply; there is no post-construction mint | Yes | **`test_BurnByControllerDropsSupplyAndEmits`** (supply drops + `Transfer` to zero) + the absence of any mint function (structural) |
| I-3 | **burn is controller-only** | Yes | **`test_BurnByNonControllerReverts`** (`NotController`) |
| I-4 | **burn edge behavior** — `burn(0)` is a no-op; over-balance burn reverts | Yes | **`test_BurnZeroNoOp`**, **`test_BurnOverBalanceReverts`** (OZ `_burn` underflow) |
| I-5 | **decimals pinned to 18** (constant `pure`) | Yes | **`test_DecimalsPin`** |
| I-6 | **constructor zero-guards the controller** | Yes | **`test_ConstructorRevertsOnZeroController`** |
| I-7 | **freely transferable** (stock OZ ERC-20) | Yes | **`test_Transferable`** + used as the real collateral token across the venue/controller/registry suites |
| I-8 | **the 1e18 fixed supply is what the venue relies on** — `openLine` requires `collateralAmount == 1e18`, close reclaims exactly `1e18` before burn | Yes (cross-contract) | `EulerVenueAdapter.t.sol` (`test_OpenLine_InvalidCollateralAmount_*`, `_CloseLine_NoDebt_ReclaimsLien`) — see [venue/x-ray/EulerVenueAdapter.md](../venue/x-ray/EulerVenueAdapter.md) |

## 4. Guards — coverage

| Guard | Site | Test |
|---|---|---|
| `require(controller_ != 0)` (ctor) | `:19` | `test_ConstructorRevertsOnZeroController` |
| `NotController` (burn) | `:33` | `test_BurnByNonControllerReverts` |
| OZ `_burn` balance check | `:34` | `test_BurnOverBalanceReverts` |

Every non-standard surface (the once-only mint, the controller-only burn, the decimals pin, the ctor zero-guard) is
directly tested; the stock ERC-20 surface is unmodified OZ (correctly re-proven only as "transferable", not
re-audited).

## 5. Attack surfaces

- **The decisive property — fixed `1e18`, mint-once, supply-only-shrinks — is structural and proven.** There is no
  mint function after construction, the constructor mints exactly `1e18`, and burn is the only supply mutator
  (controller-gated). `test_TokenShape` + `test_BurnByControllerDropsSupplyAndEmits` pin the shape and the
  shrink-only behavior; the no-mint-path is enforced by the absence of any mint surface.
- **Immutable controller = no privileged-key drift.** Unlike the rest of the subsystem, this token has NO
  build-phase mutable wiring — `controller` is `immutable`, set once at deploy. There is no setter to mis-point, no
  owner to compromise, no upgrade path. The only authority is burn-from-own-balance, which cannot move value to a
  third party (it only destroys the controller's own tokens).
- **The 1e18 invariant is load-bearing for the venue (I-8).** `EulerVenueAdapter.openLine` rejects any
  `collateralAmount != 1e18`, and the close path reclaims exactly `1e18` before burn — so the fixed supply is what
  lets a line open cleanly and close without a reclaim underflow. A token that minted more, or started at a different
  supply, would break the line lifecycle; this token makes that impossible by construction.
- **Standard ERC-20 is unmodified OZ** — no transfer hook, no fee-on-transfer, no rebasing, no pausing; re-testing it
  would re-prove audited library code. `test_Transferable` confirms the transfer path works for the lien-custody flow
  (the adapter pulls it into the escrow vault at `openLine`).
- **No residual beyond the audit gap.** No mutable wiring, no admin, no custody, no upgrade — there is nothing to
  freeze pre-prod and nothing to mis-wire. The only thing standing between this and a clean bill is the project-wide
  absence of an external audit.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Token shape / decimals / ctor-zero | 3 | `test_TokenShape`, `_DecimalsPin`, `_ConstructorRevertsOnZeroController` |
| Burn (happy / non-controller / zero / over-balance) | 4 | `test_Burn*` |
| Transferability | 1 | `test_Transferable` |
| Consumer (real lien token) | many | `ZipcodeController.t.sol`, `EulerVenueAdapter.t.sol`, `ZipcodeOracleRegistry.t.sol` exercise it as the real collateral |

Coverage % uninstrumentable (project-wide `Stack too deep`); the dedicated `LienToken.t.sol` suite is green and every
surface of the token is exercised, with the 1e18 invariant additionally proven through the venue consumer. No
coverage gap — a fixed-supply, immutable-controller token has no untested surface here.

## X-Ray Verdict

**HARDENED** *(modulo no external audit)* — a deliberately minimal 1/1 fixed-supply collateral token whose every
non-standard surface is directly tested (mint-once-to-controller, controller-only burn incl. the zero/over-balance
edges, the decimals pin, the ctor zero-guard) and whose decisive invariant (fixed `1e18`, supply-only-shrinks) is
both structural and proven — and additionally load-bearing-and-tested through the venue adapter's
`collateralAmount == 1e18` gate and `1e18` reclaim-on-close. It has **no admin, no mutable wiring, no upgrade, no
mint path, no custody** — uniquely among the subsystem it carries none of the build-phase-wiring residual, so the
only thing below a clean bill is the absence of an external audit. The standard ERC-20 is unmodified OZ (correctly
not re-audited).

**Structural facts:**
1. 18 nSLOC; OZ `ERC20`; three additions over stock — ctor `1e18`-once mint, `decimals()==18` pin, `controller`-only `burn`.
2. `controller` is `immutable`; no owner/admin/setter/upgrade/pause/second-mint — supply can only shrink via the controller's burn.
3. The fixed `1e18` is the WOOF-01 1/1 primitive: `EulerVenueAdapter.openLine` requires it and close reclaims exactly `1e18`, so the supply invariant is load-bearing for the line lifecycle.
4. Tests: 8 dedicated (`LienToken.t.sol`) covering every surface + used as the real lien token across the controller/venue/registry suites.
5. No coverage or code gap; no build-phase residual (immutable controller); capped only by no external audit.
