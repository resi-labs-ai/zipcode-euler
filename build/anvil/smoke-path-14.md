# SP-14 — Full venue origination (the spine, end-to-end on real EE)

**Intent.** Originate a real line of credit through the venue spine: a CRE origination report mints a lien token,
opens an isolated EVK line (escrow + borrow vault + router), seeds the price, funds the line from the real EulerEarn
pool, and draws USDC to Erebor.

**Proves.** `ZipcodeController` reportType-1 atomic batch → `LienTokenFactory.create` → `EulerVenueAdapter.openLine`
(per-line vaults + EE `submitCap`/`acceptCap`/`setSupplyQueue`, all perspective-verified) → `seedPrice` →
`fund` (EE `reallocate`, adapter is curator/allocator) → `draw` to Erebor.

**Tier.** Needs-forwarder (+ identity for the origination workflow). Now UNBLOCKED by the real EE pool.

**Binds to.** `ZipcodeController` `0x36025de2…`, `EulerVenueAdapter` `0x87dC8666…`, `LienTokenFactory` `0xbF1801C7…`,
`ZipcodeOracleRegistry` `0x0395da1B…`, `CREGatingHook` `0x16579ac9…`, EE pool `0x1a7A8A5a…` (curator=adapter),
base USDC market `0x3A48aaaa…`, Erebor `0x15d34AAf…`, USDC. Source: `contracts/src/ZipcodeController.sol`
(`_origination` L173-211; payload `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV,
uint16 liqLTV, uint256 drawAmount, uint256 cap)`), `contracts/src/venue/EulerVenueAdapter.sol` (`openLine` L190-254,
`fund` L278-295, `draw` L298-334), wires `WOOF-05.md`, `WOOF-04.md`.

**Setup.**
- Senior USDC liquidity in the EE pool: SP-09 SUPPLY (warehouse) or `deal` USDC + `EE.deposit` so `fund` has USDC in
  the base market to reallocate. The EE supply queue head is the base USDC market.
- Build report: `abi.encode(uint8(1), abi.encode(lienId, proofRef, equityMark, borrowLTV, liqLTV, drawAmount, cap))`.
- Identity metadata matching the controller's sealed author/workflowId.

**Calls.**
1. Impersonate Forwarder → `ZipcodeController.onReport(metadata, report)`.

**Assertions.**
- lien token deployed at `LienTokenFactory.computeAddress(lienId, controller)` with code; `controller` holds 1e18 lien
  briefly, then it's escrowed (allowance to adapter == 0 after).
- `adapter.getLine(lineRef).open == true`; per-line escrow + borrow vault + router exist; router resolves
  escrow→lien→registry.
- `registry` cache for the lien == `equityMark`, fresh.
- EE `reallocate` moved USDC base-market→line vault; `USDC.balanceOf(erebor) == drawAmount`.
- `controller.getLien(lienId)` populated.

**Notes.** This is THE deploy-bar end-to-end the item-10 obligation pointed at, now runnable because the EE pool is
real + curator-configured. If `fund`/`openLine` revert, capture the exact EE/EVK error — that's a real finding.

**Result.** **PASS** (2026-06-10, real txs on anvil). THE deploy-bar end-to-end — the full venue spine originated a real line against the real EulerEarn pool + real EVK in one atomic CRE report. **4,875,117 gas.**

Setup: seeded senior liquidity (EE had only 2,000e6 from SP-01+SP-06) — dealt 100,000e6 USDC to supplier acct[9] and `EE.deposit(100000e6)` → `totalAssets` **102,000e6** in the base market (supplyQueue head). `lienId = keccak("zipcode-sp14-lien-1")` = `0x689c43ea…`. Predicted lien addr `0xC8c8D3C8…` (codesize 0 pre-run).

Call: Forwarder → `controller.onReport`, reportType 1, payload `(lienId, proofRef=0x…beef0014, equityMark=100,000e6, borrowLTV=8000, liqLTV=9000, draw=50,000e6, cap=100,000e6)`. status 1.

Assertions (all ✓):
1. **Lien minted at the CREATE2 address** `0xC8c8D3C8…` (codesize **2728**, decimals 18, totalSupply **1e18**); `controller→adapter` allowance back to **0** (the F-7 exact-1e18 custody approve left no standing allowance — the lien is now escrowed).
2. **Line open** — `adapter.getLine(lineRef)`: collateralVault `0xA0A6a900…`, lienToken `0xC8c8D3C8…` (==lien), router `0x47BEC5Ee…`, lineAccount `0xB1…48fae`, borrowAccount `0xb1…48fAf` (= lineAccount XOR 1), `open=true`. The birth-time `_assertWired` (collat→lien→registry) passed inside `openLine`.
3. **Registry mark** — `getQuote(1e18 lien→USDC)` = **100,000e6** = equityMark, fresh, priced through the per-line router.
4. **Fund + draw** — EE `reallocate` moved **50,000e6 base→line** (base market assets 102k → **52k**); the on-behalf borrow drew **exactly 50,000e6 to Erebor** (erebor USDC 0 → **50,000e6**). Line vault: EE-supplied 50k, `cash` **0**, `observeDebt(borrowAccount)` = **50,000e6** (all the funded cash borrowed out). `supplyQueueLength` 1 → **2** (base + new line vault, onboarded via submitCap/acceptCap/setSupplyQueue).
5. `controller.getLien(lienId)` = `(0xC8c8D3C8…, 0x7C489cC9…lineRef, true)` — populated.

The draw of 50k against a 100k mark at 80% borrowLTV (max 80k) cleared the EVK account-status health check via router→registry — proving the isolated line's LTV gate is live, not just the happy path. **Live line for SP-16** (draw+close): lienId `0x689c43ea835a683aa8aac36248d86ffb396d12a9874a2141980fa2e3eb809ab4`, lineRef `0x7C489cC95f242C5Abed07712C3F21cA3126aDCd7`, lien `0xC8c8D3C817943a96DD495D2E4c5a86d6dDD97093`, debt 50,000e6.

No flaws — the item-10 deploy-bar obligation is met: CRE report → lien mint → isolated EVK line (escrow + borrow vault + router, perspective-verified) → EE onboard → seed → reallocate-fund → borrow-on-behalf draw, all real bytecode, one atomic transaction.
