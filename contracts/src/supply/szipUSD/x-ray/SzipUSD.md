# X-Ray — `SzipUSD.sol` (single-contract, test-connected)

> SzipUSD | 27 nSLOC | 2109fe5 (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/supply/szipUSD/SzipUSD.sol`, the user-facing junior-vault share
token — a plain OZ `ERC20` + `Ownable` whose **only** non-standard surface is `onlyGate` mint/burn (+ a Timelock
`setGate`). No dedicated test file; its surface is exercised through the consuming suites (`ExitGate.t.sol`,
`ZipDepositModule.t.sol`, `SzipBuyBurnModule.t.sol`, `SzipNavOracle.t.sol`), where it is the **real** token.

> The two-token model: this is the transferable user token; the soulbound, ragequit-bearing Baal `Loot` is held only
> by the Exit Gate. NAV accrues in *price* (`SzipNavOracle`), never in balance — so this is intentionally a vanilla,
> non-rebasing ERC-20 that trades on the CoW secondary. The interesting property is not in this file; it's the
> cross-contract `szipUSD.totalSupply() == loot.balanceOf(gate)` invariant the Gate maintains.

## 1. What it is

A 27-nSLOC ERC-20 with three additions over OZ stock:
- `mint(to, amount)` / `burn(from, amount)` — **`onlyGate`** (the Exit Gate is the sole minter/burner, paired 1:1 with the Gate's `mintLoot`/`burnLoot`).
- `setGate(gate_)` — `onlyOwner` (Timelock), build-phase re-point so the token survives a Gate redeploy; zero-guarded; re-freeze to immutable deferred to pre-prod.
- constructor — zero-guards the initial `gate`.

Everything else (transfer/approve/allowance/totalSupply/…) is unmodified OpenZeppelin `ERC20`.

## 2. Entry points

| Function | Access | Notes |
|---|---|---|
| `mint(to, amount)` | `onlyGate` | `NotGate` otherwise; paired with the Gate's `mintLoot` |
| `burn(from, amount)` | `onlyGate` | `NotGate` otherwise; paired with `burnLoot` |
| `setGate(gate_)` | `onlyOwner` (Timelock) | re-point the minter/burner; `ZeroAddress` guard |
| ERC-20 surface | public | stock OZ — transfer/approve/etc. |

No CRE operator. The token holds no custody beyond its own balances.

## 3. Invariants — with test connection

| ID | Property | On-chain | Proven by |
|---|---|---|---|
| I-1 | **mint/burn are Gate-only** — any other caller reverts `NotGate` | Yes | **`test_szipUSD_mint_burn_onlyGate`** (ExitGate suite — non-Gate mint AND burn revert) |
| I-2 | **mint/burn pair 1:1 with the Gate's Loot** — `totalSupply() == loot.balanceOf(gate)` always (the two-token conservation) | Yes (cross-contract) | **`invariant_twoToken_conservation_and_zeroShares`** (ExitGate stateful invariant, ~6,400 fuzzed calls) + the ExitGate deposit/burnFor happy paths — see [ExitGate.md](ExitGate.md) |
| I-3 | **non-rebasing, freely transferable** — NAV accrues in price, balances are stock ERC-20 | Yes | inherited OZ `ERC20` (transfer/approve/totalSupply unmodified); used as the real token across the consuming suites |
| I-4 | **`setGate` onlyOwner + zero-guard + effect**; constructor zero-guards `gate` | Yes | **`test_szipUSD_setGate_and_ctor_zero_guard`** — ctor rejects zero; `setGate` non-owner→`OwnableUnauthorizedAccount`, zero→`ZeroAddress`, re-point takes effect, the new gate can mint and the old gate can't |

## 4. Guards — coverage

| Guard | Test |
|---|---|
| `NotGate` (mint + burn) | `test_szipUSD_mint_burn_onlyGate` |
| `setGate` onlyOwner / `ZeroAddress` / effect | `test_szipUSD_setGate_and_ctor_zero_guard` |
| constructor `ZeroAddress` | `test_szipUSD_setGate_and_ctor_zero_guard` |

## 5. Attack surfaces

- **The only non-standard surface that matters is mint/burn gating (I-1) — and it's tested** — a token whose supply
  is controlled solely by the Gate is exactly as safe as that gate, and `test_szipUSD_mint_burn_onlyGate` confirms a
  non-Gate caller can neither mint nor burn. The supply-conservation that gives the token meaning lives in the Gate
  (the two-token invariant, now fuzzed — I-2), not here.
- **`setGate` + ctor zero-guard — now covered (I-4)** — `setGate` is the re-point of *who can mint/burn the user
  token*; `test_szipUSD_setGate_and_ctor_zero_guard` proves the ctor rejects a zero gate, `setGate` rejects a
  non-owner and a zero, and after a re-point the **new** gate can mint while the **old** gate reverts `NotGate`. With
  the mint/burn gate (I-1), every surface on the token is now exercised.
- **Standard ERC-20 is OZ — correctly not re-tested** — transfer/approve/allowance are unmodified OpenZeppelin;
  re-testing them would re-prove audited library code. The token adds no transfer hooks, no fee-on-transfer, no
  rebasing, no pausing.

## 6. Test analysis

| Category | Count | Notes |
|---|---|---|
| Dedicated unit | 0 | no `SzipUSD.t.sol` |
| Consumer (mint/burn gate) | 1 | `test_szipUSD_mint_burn_onlyGate` (`NotGate` on both) |
| Consumer (happy mint/burn + conservation) | many | every ExitGate deposit/burnFor test + the two-token stateful invariant exercise the real token |
| `setGate` / ctor-zero | 1 | `test_szipUSD_setGate_and_ctor_zero_guard` (onlyOwner/zero/effect + old-gate-loses-mint) |

The decisive non-standard surface (mint/burn gating) is tested and the supply-conservation property is under a
stateful invariant in the Gate. Coverage % uninstrumentable (project-wide stack-too-deep); green runs confirmed in
the consuming suites.

## X-Ray Verdict

**ADEQUATE** — a deliberately vanilla, non-rebasing ERC-20 whose only non-standard surface (Gate-only mint/burn) is
tested, and whose meaningful property (1:1 supply-with-Loot conservation) is proven by the Gate's fuzzed stateful
invariant. The standard ERC-20 is unmodified OZ (correctly not re-tested). **Every surface on the token is now
exercised** — the `setGate`/ctor-zero gap was closed 2026-06-20. No outstanding coverage gap; no transfer hooks, no
rebasing, no custody. Held at ADEQUATE (not HARDENED) only by the absence of an external audit.

**Structural facts:**
1. 27 nSLOC; OZ `ERC20` + `Ownable`; the transferable user share (the soulbound Loot lives in the Gate).
2. Three additions over stock OZ: `onlyGate` `mint`/`burn` + Timelock `setGate` (+ ctor zero-guard); everything else is unmodified.
3. Non-rebasing — NAV accrues in price (`SzipNavOracle`), not balance; trades on the CoW secondary.
4. Tests: 0 dedicated; the `NotGate` gate + `setGate`/ctor-zero are covered, and mint/burn + the two-token conservation are exercised via ExitGate (incl. its stateful invariant).
5. No outstanding coverage gap on the contract surface; every mutator (mint/burn/`setGate`/ctor) is exercised.
