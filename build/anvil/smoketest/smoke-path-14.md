# SP-14 — Full venue origination (the credit spine, end-to-end on real EE; CTR-03)

**Intent.** Originate a real line of credit through the venue spine: one CRE origination report mints a lien token,
opens an isolated EVK line (escrow + borrow vault + router), seeds the price, funds the line from the real EulerEarn
pool, and draws USDC to Erebor — routed by `siloId` through the `SiloRegistry` (CTR-03).

**Proves.** `ZipcodeController` reportType-1 atomic batch with the **8-field payload** (`siloId` last) →
`_venueFor(siloId)` via `SiloRegistry.venueOf` → `LienTokenFactory.create` → `EulerVenueAdapter.openLine`
(per-line vaults + EE cap onboarding) → `seedPrice` → `fund` (EE `reallocate`) → `draw` → `incrementLineCount`.
Sources: `docs/ZipcodeController.md`, `docs/SiloRegistry.md`, `EulerVenueAdapter`, wires `WOOF-05.md`/`WOOF-04.md`.

**Tier.** Needs-forwarder (origination workflow identity; ~6M gas — use `gas-limit ≥ 8M`).

**Binds to** (by name): `ZipcodeController`, `SiloRegistry`, `EulerVenueAdapter`, `LienTokenFactory`,
`ZipcodeOracleRegistry`, `CREGatingHook`, EE pool (curator=adapter), base USDC market, Erebor, USDC.
`LOCAL_SILO_ID = 0x0309d2cf…febebd`.

**Setup.** `seed_marks`; seed senior liquidity (`deal` 100,000e6 USDC to a supplier, `EE.deposit`). Report =
`abi.encode(uint8(1), abi.encode(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV,
uint16 liqLTV, uint256 drawAmount, uint256 cap, bytes32 siloId))`.

**Calls (happy).** 1. origination report `(lienId, beef0014, 100,000e6, 8000, 9000, 50,000e6, 100,000e6, LOCAL_SILO_ID)`.

**Calls (fuzzy / negative).** 2. same report with an **unknown siloId** → `_venueFor` reverts `SiloUnrouted` (CTR-03
fail-closed routing). (A zero-address registry would revert `RegistryUnset`.)

**Assertions** (On-chain=Yes): lien minted at the CREATE2 address (code present, 18-dp, supply 1e18);
`getLien(lienId)` = (lien, lineRef, open=true); per-line escrow+borrow vault+router exist; registry `getQuote(1e18 lien)
== equityMark` fresh; EE `reallocate` moved 50,000e6 base→line; `USDC.balanceOf(erebor) == drawAmount`;
`SiloRegistry` line count bumped.

**Notes.** THE item-10 deploy-bar end-to-end, now also `siloId`-routed (the CTR-03 drift the old SP predated). The
draw of 50k against a 100k mark at 80% borrowLTV clears the per-line EVK health check via router→registry — the
isolated LTV gate is live.

**Result.** **PASS** (2026-06-24, live fork; one atomic report, ~6M gas; lien `0x689c43ea…`).
- Lien minted at **`0xAA69847B…`** (CREATE2, **2728** bytes, supply 1e18). `getLien(lienId)` = (`0xAA69847B…`,
  lineRef `0x61a6bba7…`, **open=true**). ✓
- Registry mark: `getQuote(1e18 lien→USDC)` = **100,000e6** == equityMark, fresh (priced via the per-line router). ✓
- Fund + draw: EE `reallocate` 50,000e6 base→line; `LineDrawn` to erebor; **`USDC.balanceOf(erebor)` = 50,000e6**;
  `incrementLineCount(LOCAL_SILO_ID)` fired. ✓
- **(neg)** an unknown `siloId` resolves to address(0) → `SiloUnrouted` (CTR-03 fail-closed). ✓
- **No flaws** — CRE report → lien mint → isolated EVK line → EE onboard → reallocate-fund → on-behalf draw, all real
  bytecode, `siloId`-routed, one transaction. Live line carried into SP-16.
