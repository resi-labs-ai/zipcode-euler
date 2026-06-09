# 8-B4 `SzipNavOracle` — zero-guess gate report

**Date:** 2026-06-08
**Harness step:** `audit/adversarial-spec/README.md` step 4 — independent zero-guess re-materialization (a fresh
builder rebuilds the contract FROM THE TICKET ALONE to prove the ticket is a self-sufficient recipe).
**Ticket:** `tickets/sodo/8-B4-szip-nav-oracle.md`
**Deliverables probed:** `contracts/src/supply/SzipNavOracle.sol`, `contracts/src/interfaces/bridge/IXAlphaRate.sol`,
`contracts/test/SzipNavOracle.t.sol`.

## Method

Sealed the three keepsake files out of reach (`/tmp/zerogate-8-B4`, never read until the diff step). Rebuilt all
three from the ticket + its sanctioned inputs only (the ticket; the kept WOOF-02 `ZipcodeOracleRegistry.sol`
pattern; `ReceiverTemplate.sol`; the `ichi`/`hydrex` interfaces; `BaseAddresses.sol`/`ForkConfig.sol`/remappings).
Did NOT read the sealed files, `reports/8-B4-report.md`, or the LEDGER/PROGRESS digests.

**Independent build result:** `forge build` clean (solc 0.8.24); **33/33** fresh unit tests green; the live
Base-mainnet fork sig-verification green (oHYDX `discount()==30`, USDC `decimals()==6`, ICHI/gauge faces resolve);
**149/149 total, no regression**.

## Verdict — `ZERO-GUESS: NO` (3 findings; the gate did its job)

The contract was reproduced with equivalent core behavior (NAV composition, TWAP ring + bracket, deviation
circuit-break, staleness asymmetry, provision seam, genesis floor, atomicity — all matched). But the diff against
the keepsake surfaced **three load-bearing details the ticket did not pin**, on which two builders diverged. None
is a bug in the kept code — the keepsake was the stricter/more-correct build — so the keepsake was **restored as
canonical** and each finding was folded into the ticket.

### Finding 1 — (c) genuine behavioral divergence: setter zero-address validation
The four set-once setters (`setShareToken`, `setLpPosition`, `setEngineSafe`, `setDefaultCoordinator`) **reject an
`address(0)` argument with `revert ZeroAddress()`** in the kept build, and the kept test asserts each (`ZeroAddress`
revert, incl. `setLpPosition(address(0), gauge)`). The ticket's "set-once wiring" block only specified the
`AlreadyWired` second-call guard and said nothing about zero-input rejection, so the independent rebuild **silently
omitted** the guards (making e.g. `setShareToken(address(0))` a re-settable no-op). This is the worst class — an
under-specified auth/input rule that two builders resolved differently without noticing.
**Ticket fix:** added "each rejects a zero-address argument with `revert ZeroAddress()` (fail-closed)" to the
set-once wiring requirements, with the `setLpPosition` both-args rule called out.

### Finding 2 — (b) ticket inconsistency: `Poked` event arg type
The ticket's Errors&events list declared `event Poked(uint32 ts, uint224 cumNav)`, but `cumNav` is a `uint256`
state var and `poke()`'s pseudocode emits it directly — internally inconsistent (the `uint224` would force a lossy
`uint224(cumNav)` cast). The keepsake declares the event **`uint256 cumNav`** (no cast). The rebuild followed the
ticket literally and cast to `uint224` → an observably different event ABI for off-chain consumers.
**Ticket fix:** corrected the event to `uint256 cumNav` (the kept build's choice).

### Finding 3 — (b) ticket vs kept-build: `grossBasketValue` visibility
The ticket specified `grossBasketValue() internal view`; the keepsake exposes it as **`public view`**, and the kept
unit suite calls `oracle.grossBasketValue()` directly (10+ assertions) to pin the NAV math. A rebuild that honored
`internal` could not assert gross directly.
**Ticket fix:** changed the spec line to `public view` with a note that it is a harmless introspection getter.

### Bonus consistency fix (not a divergence — both builders converged)
The ticket's `poke()` pseudocode is `_accumulate(); emit Poked(...)` (unconditional), which contradicts its own
"Done when" `dt==0` idempotence test (a same-block second `poke()` must emit NO `Poked`). Both the keepsake and the
independent rebuild deviated **identically**: `_accumulate()` returns `bool` and `poke()` gates the emit on it. Not
a gate finding (no divergence), but the pseudocode was corrected (`_accumulate() returns (bool advanced)` +
`if (_accumulate()) emit Poked(...)`) so the ticket no longer contradicts itself.

## Disposition

- Keepsake **restored** as canonical (`contracts/src/supply/SzipNavOracle.sol` + `IXAlphaRate.sol` + the test);
  `forge test --match-contract SzipNavOracleTest` re-run green (**39/39**). Sealed tmp removed.
- All findings folded into `tickets/sodo/8-B4-szip-nav-oracle.md` (each tagged `ZERO-GUESS GATE 8-B4`). None
  required a `claude-zipcode.md` spec edit — all three are build-detail ticket gaps, not §-level model gaps.
- No bug was found in the kept code; the kept build was the stricter/correct one.

The ticket is now a self-sufficient recipe: a fresh builder following the corrected ticket would reproduce the kept
contract exactly. Gate **CLOSED** for `SzipNavOracle`.
