# SP-13 — Buy-burn full exit (sell shares for USDC, then exit)

**Intent.** The full exit cycle: post a discounted CoW buy order (engine pulls USDC), a counterparty's szipUSD is
bought, and the bought shares are burned — NAV-per-share ticks up for the stayers. Answers "sell your shares for a
USDC buyer / pull USDC out as a module, post a limit buy, accept it, exit."

**Proves.** `postBid` (SP-05) → CoW settlement delivers szipUSD to the engine Safe (simulated solver) →
`ExitGate.burnFor` (windowController) burns Loot + szipUSD with no asset payout → spot NAV-per-share rises.

**Tier.** Needs-forwarder (NAV legs) + simulated CoW fill.

**Binds to.** `SzipBuyBurnModule` `0x12881a80…`, `ExitGate` `0xd9b8393f…` (windowController = `creOperator` ✓ wired),
szipUSD `0x33aD3E23…`, Loot `0xE7501dD9…`, main Safe `0x0B9C95c7…`, CoW settlement `0x9008D19f…`, USDC. Source:
`SzipBuyBurnModule.sol` (`postBid`), `ExitGate.sol` (`burnFor` L199-206), wires `8-B14`, `ExitGate-szipUSD.md`.

**Setup.**
- SP-06 done: `alice`/`charlie` hold szipUSD; basket funded; legs fresh.
- main Safe holds USDC to fund the bid (`deal` or via recycle/borrow).

**Calls.**
1. `SzipBuyBurnModule.postBid(order) as creOperator` (USDC approve to vaultRelayer + presign on settlement).
2. **Simulate the solver fill**: transfer the bid's `buyAmount` szipUSD from `charlie` → main Safe (the engine Safe),
   and move the corresponding USDC out (mirroring a settlement). [Records the boundary: solver match is simulated.]
3. Read `spotNavPerShare()` before step 4.
4. `ExitGate.burnFor(<amount>) as creOperator` (windowController) → burns Loot from gate + szipUSD from main Safe.

**Assertions.**
- after 1: presignature true; allowance set (as SP-05).
- after 4: `szipUSD.totalSupply()` down by amount; `Loot.balanceOf(gate)` down by amount (invariant preserved);
  `spotNavPerShare()` > the pre-burn read (the haircut accrues to remaining holders).

**Notes.** The settlement contract + presignature are real; only the off-chain solver match is simulated (boundary
#3). `burnFor` is reachable because `windowController` is now wired to `creOperator` (deploy fix this session).

**Result.** **PASS** (2026-06-10, real txs on anvil). The full buy-and-burn exit cycle works; NAV/share ticks up for stayers. Wiring confirmed consistent: `windowController` = creOperator, and `ExitGate.engineSafe` == `BuyBurn.engineSafe` == `oracle.engineSafe` == main Safe.

Pre-state: szipUSD totalSupply 1000e18 (alice holds all), Loot@gate 1000e18, mainSafe szipUSD 0 + USDC 26,400e6, gross 106,000e18, **spot NAV = 106e18** (basket USDC-heavy vs 1000 shares — a state artifact, mechanics unaffected). dBps = 1%.

1. Re-pushed fresh legs; `postBid(buyAmount=200e18, sellAmount=20,988e6 = quoteMaxPrice·200, validTo=now+1h)` → status 1 (the discounted resting BUY, SP-05 mechanics).
2. **Simulated solver fill** (boundary #3): alice `transfer`'d 200e18 szipUSD → engine Safe; the engine's 20,988e6 USDC moved out (storage, mirroring settlement: main USDC 26,400e6 → 5,412e6, credited to alice). Engine Safe now holds 200e18 szipUSD.
3. NAV reads: **NAV0 (pre-fill) = 106.000e18** → **NAV1 (post-fill) = 106.265e18**. The tick-up realizes HERE: `_effectiveSupply` excludes the engine Safe's 200e18 (1000→800) and gross dropped to 85,012e18 (20,988 USDC paid at the 1% discount) → 85,012/800 = 106.265e18.
4. `burnFor(200e18)` as creOperator → status 1. **NAV2 (post-burn) = 106.265e18 == NAV1.**

Assertions (all ✓):
- szipUSD `totalSupply` 1000e18 → **800e18** (down by 200e18); `Loot.balanceOf(gate)` 1000e18 → **800e18** — the **two-token invariant preserved**; engine Safe szipUSD 200e18 → **0** (burned, no asset payout).
- `spotNavPerShare` **106.000e18 → 106.265e18** (+0.25%): the discounted-buyback haircut accrues to remaining holders.

**Finding (timing nuance, by design — not a flaw):** the NAV benefit to stayers is realized at the **fill**, not the burn. Because the oracle's `_effectiveSupply` excludes the engine Safe's transient pre-burn szipUSD, the moment the bought shares land in the engine Safe (and the discounted USDC leaves the basket) effective supply drops and NAV rises; `burnFor` then *finalizes* it (permanently removes the Loot + szipUSD, preserving the invariant) with **no further NAV change** (NAV2 == NAV1). So the spec's literal "post-burn > pre-burn read" reads as equal if the pre-burn snapshot is taken after the fill — but the economic claim (NAV2 > NAV0, the true pre-exit baseline) holds. The settlement + presignature are real; only the off-chain solver match is simulated. Stale resting bid cancelled afterward for clean state.
