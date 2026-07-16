# WOOF-01 — LienCollateralToken + LienTokenFactory (wiring map)

> **X-Ray (security verdict):** both rated **HARDENED** — uniquely in the subsystem they carry no build-phase
> mutable wiring (immutable controller / stateless factory). `LienCollateralToken`: fixed 1e18 mint-once,
> controller-only burn, supply-only-shrinks. `LienTokenFactory`: caller-bound CREATE2 (squat-proof, single-use
> forever). Reports under `contracts/src/x-ray/` (`LienCollateralToken.md`, `LienTokenFactory.md`). ELI20:
> `docs/LienCollateralToken.md`, `docs/LienTokenFactory.md`. This doc is the code-truth wiring map.

> Source of truth = `contracts/src/{LienCollateralToken,LienTokenFactory}.sol`. Ticket
> `tickets/woof/WOOF-01-lien-collateral-token.md` + report `reports/WOOF-01-report.md` are intent.

## Role
The on-chain identity of a single lien. Each originated lien gets **one** `LienCollateralToken` — a 1/1
fixed-supply (exactly `1e18`) ERC20 minted once to the controller. **The token's address IS the lien**
(`LIEN_i`), and that same address is the oracle key in `ZipcodeOracleRegistry` and the collateral asset of
the per-line escrow vault. The factory CREATE2-deploys these deterministically so the controller/CRE can
precompute `LIEN_i` from `lienId` before the origination batch runs.

## Contracts involved (what each does)
| Contract | What it does |
|---|---|
| `LienCollateralToken` (`is ERC20`) | Mints `1e18` once to `controller` at construction; `decimals()` pinned `pure → 18`; `burn(amount)` controller-only (from the controller's own balance). No mint path, no admin, no other authority. |
| `LienTokenFactory` | `create(bytes32 lienId)` CREATE2-deploys a token authorized to `msg.sender`; `computeAddress(lienId, controller)` pure-predicts the address; `LIEN_DECIMALS = 18` constant; `LienCreated(lienId, lien)` event. Stores no mapping — identity is the address. |

## Wiring — internal
- `LienCollateralToken.controller` — **immutable, = the `create` caller** (`msg.sender`), threaded as the
  CREATE2 init-code constructor arg. There is no setter and no gate: caller-binding *is* the authorization.
- Salt = `keccak256(abi.encode(lienId))`. The init-code embeds the caller, so the deployed address is a
  function of `(lienId, caller)` — an attacker's `create(lienId)` lands at a **different** address and cannot
  squat the canonical `LIEN_i` the controller will deploy. Re-`create` of the same `(lienId, caller)` reverts
  `FailedDeployment` (single-use lienId forever, per caller).
- `LIEN_DECIMALS = 18` on the factory is the canonical scale the registry validates a key against.

## Wiring — cross-component (who points at whom)
- **`ZipcodeController` → factory.** At origination the controller calls `LIEN_FACTORY.create(lienId)`; the
  new token's `controller` becomes the `ZipcodeController` (the caller). The controller precomputes the
  address first via `computeAddress(lienId, ZIP_CONTROLLER)` and asserts the slot is empty.
- **Token address → `ZipcodeOracleRegistry` key.** `LIEN_i` is the oracle key the controller seeds with the
  equity mark (`registry.seedPrice(LIEN_i, equityMark)`); the registry's strict-decimals guard staticcalls
  `LIEN_i.decimals()` and requires `== 18` (= `LIEN_DECIMALS`) before caching — **the WOOF-01 decimals
  obligation the registry discharges** (`PROGRESS.md` row "3 · ZipcodeOracleRegistry").
- **Token address → per-line escrow vault asset.** `EulerVenueAdapter.openLine` mints an escrow collateral
  EVault whose `asset() == LIEN_i`; the controller holds the `1e18`, `approve`s the adapter, the adapter
  deposits it into the escrow as collateral.
- **Close path.** The controller reclaims the `1e18` from the escrow **before** calling `LIEN_i.burn(1e18)`
  (else `ERC20InsufficientBalance`) — the §4.4c reclaim-before-burn ordering obligation.

## Item-10 deploy facts
- Factory deployed at **S4** by `CONTROLLER_OWNER`: `new LienTokenFactory()` (no constructor args).
- Post-assert: `LIEN_FACTORY.LIEN_DECIMALS() == 18`.
- Tokens are **not** deployed at setup — they are minted per-lien inside `VENUE.openLine` at origination (L4).
- No ownership/renounce on either contract (factory is stateless-authority; token authority is the immutable
  controller). Nothing for the Timelock to hold here.

## Gotchas
- `require(cond, CustomError())` is 0.8.26+; on the 0.8.24 pin the zero-controller guard uses a string
  `require` (`"LienCollateralToken: zero controller"`), and other guards use `if (!cond) revert`.
- The token is **transferable** (plain ERC20) — only mint (none post-construction) and `burn` are gated.
