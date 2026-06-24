# SUPPLY-ADV-13 — `setLpToken` (and ctor) must reject a non-18-dp key (`_strictDecimals`), restoring the load-bearing 18-dp guard `ZipcodeOracleRegistry` enforces

> **STATUS: BUILT (2026-06-24) — SHIPPED to `main`.** Added `error InvalidLpDecimals(address lpToken)` + a strict
> `_strictLpDecimals` helper (raw `decimals()` staticcall — reverts on non-18 / code-less / failed call, NOT
> silent-18 like `BaseAdapter._getDecimals`) and called it in BOTH the ctor and `setLpToken`
> (`SzipFarmUtilityLpOracle.sol`). Built BOTH guards (not just `setLpToken`) — the registry makes a non-18-dp key
> "UNREACHABLE by design", which requires guarding every key-entry; the deploy passes the live 18-dp `polIchiVault`
> so the ctor guard is deploy-safe (verified: `DeployZipcode:401` asserts `polIchiVault == escrowVault.asset()`,
> `DeployLocal` uses `LIVE_ICHI_VAULT`). 3 regression tests added (`test_setLpToken_non18Decimals_reverts` /
> `_codeless_reverts` / `test_ctor_non18LpToken_reverts`); the LP oracle suite is **22/22** (was 19/19). Test
> fallout handled: the oracle suite's code-less `LP`/`newLp` and `ZipcodeDeployIdentityGate`'s `makeAddr` LP_TOKEN
> swapped to live 18-dp mocks (`DecimalsMock(18)` / new `MockLp18`); the `MockLpToken` deployer suites (Silo,
> JuniorTranche, FarmUtilityLoop) were already 18-dp and stayed green. `forge build` clean; scoped + all 4
> collateral suites green. Doc-sync in the same commit (X-Ray §2/I-7/I-8/§4/§5/§6 counts + line-ref refresh,
> `docs/supply/SzipFarmUtilityLpOracle.md`, `docs/wires/8-B5`). No fix divergence from the planned guard.
>
> FILED (LOW / parity hardening). On-chain change (one guard on `setLpToken`, optionally the ctor, + one
> regression test) to `contracts/src/supply/SzipFarmUtilityLpOracle.sol`. Restores the
> `ZipcodeOracleRegistry` `_strictDecimals` guard that this oracle dropped on the one mutation path that can
> violate the shared-scale 18-dp invariant.
>
> Source: adversarial-review on `contracts/src/supply/SzipFarmUtilityLpOracle.sol`
> (`adversarial-review/reports/src/supply/szipfarmutilitylpooracle/synthesis.md`, finding #1 — surfaced
> independently by missions 1 and 3, write-path omission confirmed correct by mission 2). Single-model
> (Claude Opus 4.8) baseline leg — corroborate with the codex/fugu legs before treating as panel-confirmed.

## The gap (verified in code)

`scale` is derived ONCE from the `LP_DECIMALS = 18` **constant** — never from `lpToken`'s real decimals
(`SzipFarmUtilityLpOracle.sol:78`, re-derived identically in `setQuote:87`):

```solidity
uint8 public constant LP_DECIMALS = 18;                            // :23
...
scale = ScaleUtils.calcScale(LP_DECIMALS, quoteDecimals, quoteDecimals);   // :78 (ctor) / :87 (setQuote)
```

`setLpToken` re-points the priced base key with only a zero-guard, and **never re-derives or validates
decimals** (`:92-96`):

```solidity
function setLpToken(address lpToken_) external onlyOwner {
    if (lpToken_ == address(0)) revert ZeroAddress();   // :93  <- only guard; no decimals check
    lpToken = lpToken_;
    emit WiringSet("lpToken", lpToken_);
}
```

`_writePrice` (`:115-121`) also has **no** key-decimals guard. So the 18-dp base assumption baked into
`scale` is unenforced on every path that could change the key.

**Why that mis-scales.** `calcScale(18, qd, qd) = from(qd, qd+18)` → `priceScale = 10^qd`,
`feedScale = 10^(qd+18)` (`ScaleUtils.sol:53-54`). The read (`:141`) is
`calcOutAmount(inAmount, mark, scale, false) = fullMulDiv(inAmount, priceScale·mark, feedScale)`
(`ScaleUtils.sol:74-76`), which reduces to **`inAmount · mark / 1e18`** — the base-18 term enters via
`feedScale` and the quote-decimal terms cancel. The EVK router passes `inAmount` in the base token's
*native* units. If the §17 Timelock re-points `lpToken` to a token whose `decimals() != 18`, the divisor is
still `1e18`:

- **`<18`-dp re-point (e.g. 6-dp):** one whole share = `1e6` units → `1e6 · mark / 1e18 = mark / 1e12` —
  drastically **UNDER-values** collateral (fail-safe direction: borrows blocked / over-collateralized, no
  bad debt).
- **`>18`-dp re-point:** **OVER-values** collateral (the dangerous direction) — but `>18`-dp LP tokens are
  atypical and the wired key is the canonically-18-dp ICHI LP share.

## Delta from precedent (this is the point of the ticket)

`ZipcodeOracleRegistry` treats this exact assumption as **LOAD-BEARING** and guards it on every write
(`ZipcodeOracleRegistry.sol:19-25`):

```
/// @dev LOAD-BEARING — do not relax: the global `scale` is derived once with `baseDecimals = 18`
///      (`calcScale(LIEN_DECIMALS, quoteDecimals, quoteDecimals)`), and `_writePrice` rejects any key whose
///      `decimals() != 18` (`_strictDecimals`). ... Relaxing the 18-dp guard without first introducing
///      per-key scaling would silently mis-scale every non-18-dp mark — never loosen it in isolation.
```

enforced at `_writePrice:146` via `_strictDecimals` (`:152-156`), which staticcalls `decimals()` and
reverts on a failed/short return (strict — NOT silent-18 like `_getDecimals`):

```solidity
if (_strictDecimals(lien) != LIEN_DECIMALS) revert InvalidLienDecimals(lien);   // registry :146
```

This oracle **dropped that guard** AND added a `setLpToken` re-point the registry doesn't even expose (the
registry's key is an arbitrary `lien` map key, never re-pointed by a setter). The trustless twin is
structurally immune: `AlgebraIchiFairLpOracle.sol:36` declares `address public immutable lpToken;` — no
setter, cannot re-point. So this push-cache oracle is the only one of the three that can land a non-18-dp
key, and it is the one without the guard.

## Why it's LOW, not higher (don't over-fix)

- **Timelock-gated, build-phase, frozen pre-prod (X-3).** Only the §17 Timelock can re-point; the wiring is
  to be frozen immutable pre-prod. Not externally reachable.
- **Realistic direction is fail-safe.** The wired and any plausible LP share is `≤18`-dp, so a fat-fingered
  re-point under-values (grief / blocked borrow), not over-values. Over-valuation needs a `>18`-dp key.
- **The defect is an unenforced invariant, not a current violation.** In the wired 18-dp config the scale
  is correct and every test passes. This closes the footgun and conforms to the precedent's discipline —
  the subsystem's recurring setter-gap class (cf. SUPPLY-ADV-04/06/10/12).

So: LOW parity hardening — restore the registry's dropped load-bearing guard on the path that can break it.

## The fix (recommended)

Reuse a strict-decimals read (mirror `ZipcodeOracleRegistry._strictDecimals` — reject code-less / non-18
keys; `_getDecimals`'s silent-18 fallback would let a code-less EOA pass). Add a private helper and call it
from both `setLpToken` and the ctor:

```solidity
error InvalidLpDecimals(address lpToken);

function _strictLpDecimals(address lpToken_) internal view returns (uint8) {
    (bool ok, bytes memory d) = lpToken_.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
    if (!ok || d.length != 32) revert InvalidLpDecimals(lpToken_);
    return abi.decode(d, (uint8));
}
```

`setLpToken` (`:92-96`):

```solidity
function setLpToken(address lpToken_) external onlyOwner {
    if (lpToken_ == address(0)) revert ZeroAddress();
    if (_strictLpDecimals(lpToken_) != LP_DECIMALS) revert InvalidLpDecimals(lpToken_);   // + load-bearing 18-dp guard
    lpToken = lpToken_;
    emit WiringSet("lpToken", lpToken_);
}
```

ctor (`:73`, after the zero-guard): add the same `if (_strictLpDecimals(lpToken_) != LP_DECIMALS) revert
InvalidLpDecimals(lpToken_);` so a non-18-dp key cannot be deployed either.

**Verify the base API before coding (CONDUCTOR rule 6):** confirm the actual import path for a strict
`decimals()` staticcall (the contract already imports nothing exposing `IERC20Metadata` — `_getDecimals`
lives in `BaseAdapter`). The cheapest faithful form may be the raw staticcall above rather than relying on
`BaseAdapter._getDecimals` (which silent-falls-back to 18 and would NOT reject a code-less key — the very
case the registry's strict variant exists to catch). Let the compiler/gate confirm the import.

## Expected test fallout (gate it yourself)

`test_setLpToken_guards_and_effect` (`SzipFarmUtilityLpOracle.t.sol:198-205`) currently re-points to a
code-less EOA (`newLp`) and to `address(0)`. After the guard, the code-less `newLp` re-point will revert
`InvalidLpDecimals` (the staticcall fails). Update that test to re-point to an 18-dp mock (the file already
has `DecimalsMock`, `:8-13`) so the happy-path re-point still exercises the effect, and the zero / non-18
cases assert the reverts.

## Regression test

Add to `contracts/test/supply/SzipFarmUtilityLpOracle.t.sol` (use the existing `DecimalsMock`):

```solidity
function test_setLpToken_non18Decimals_reverts() public {
    address lp6 = address(new DecimalsMock(6));
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSelector(SzipFarmUtilityLpOracle.InvalidLpDecimals.selector, lp6));
    lpo.setLpToken(lp6);
}
// and: an 18-dp mock re-point SUCCEEDS and re-prices; ctor with a non-18-dp lpToken reverts InvalidLpDecimals.
```

## Documentation propagation (same commit — X-Ray is code-truth; gate on the code landing)

Grep-verified targets carrying the affected claim:

- **`contracts/src/supply/x-ray/SzipFarmUtilityLpOracle.md`** (authoritative):
  - §2 entry-point table, the `setLpToken` row (`:48`): add the `InvalidLpDecimals` (strict-18-dp) guard
    alongside the existing `ZeroAddress`.
  - §3 I-7 row (`:65`): note `setLpToken` now enforces the 18-dp key (strict-decimals), not only zero.
  - §4 guards table (`:81`): add the `InvalidLpDecimals` guard + `test_setLpToken_non18Decimals_reverts`.
  - §5 Timelock-setters bullet (`:105-108`): record that the load-bearing 18-dp assumption is now enforced
    on the `setLpToken` re-point and the ctor (parity with `ZipcodeOracleRegistry._strictDecimals`),
    closing the dropped-guard delta.
- **`docs/supply/SzipFarmUtilityLpOracle.md`** (`:32`): the mis-scale note currently warns only about a
  *quote* re-point — extend it to the symmetric `lpToken` re-point (now guarded to 18-dp).
- **`docs/wires/8-B5-FarmUtilityLoop.md`**: the `setLpToken` reference (`:87`) and the §17-wiring bullet
  (`:114`) — note the new strict-18-dp guard on `setLpToken` (and ctor).

(The `docs/wires/8-B5` `:97` ctor description already states `scale = calcScale(LP_DECIMALS=18, …)`; align
its narration with the now-enforced key constraint.)

## Cross-references

- **Precedent:** `ZipcodeOracleRegistry.sol:19-25` (the LOAD-BEARING note) + `:146`/`:152-156`
  (`_strictDecimals`). The trustless twin `AlgebraIchiFairLpOracle.sol:36` (immutable `lpToken`, immune).
- **Class:** the supply-subsystem recurring setter-gap hardening — SUPPLY-ADV-04 (freeze setter
  distinctness), -06 (exitgate conservation setter lock), -10 (removeLiquidity zero-floor), -12 (setGate
  post-issuance lock).

## Acceptance criteria

- `setLpToken` and the constructor revert `InvalidLpDecimals` when the key's `decimals() != 18` (or the
  `decimals()` call fails / returns short); an 18-dp key passes and re-prices.
- `test_setLpToken_non18Decimals_reverts` added; `test_setLpToken_guards_and_effect` updated to use an
  18-dp mock; scoped suite (`forge test --match-path 'test/supply/SzipFarmUtilityLpOracle.t.sol'`) green;
  `forge build` clean.
- X-Ray (§2 / I-7 / §4 / §5) + `docs/supply/SzipFarmUtilityLpOracle.md` + `docs/wires/8-B5` reflect the
  strict-18-dp guard on `setLpToken` and the ctor.
