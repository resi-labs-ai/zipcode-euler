# INTERFACES — DEPENDENCY SURFACE (overview)
[zipcode-euler/contracts/src/interfaces]

This is the index for the interfaces folder: the protocol's external trust surface in one place. The per-vendor summaries are the simple read; this page is the security map over them, mirrored from the X-Ray.

* 32 interfaces across 10 external vendors + 6 internal seams.
* All 32 are local "minimal mirror" interfaces — hand-written to expose ONLY the methods Zipcode calls, each carrying on-chain verification evidence in NatSpec (live address, selector, decoded staticcall, verification date). This is the biggest de-risker: the #1 interface bug — selector/signature drift from the real contract — is guarded per file.
* We do not import the vendors' real code (the WOOF-00 "declare locally, don't import the remap" posture) — it avoids solc-version/OZ conflicts; the cost is manual sync with upstream.

==================================================================================
Security X-Ray (audit fidelity)

Interfaces have no bodies, state, entry points, or tests, so the standard X-Ray does not apply. The interfaces-scoped equivalent is the dependency-surface map — every external contract Zipcode trusts, what it can do, who calls it, and where the trust is sharpest. It is the authoritative security artifact for this folder.

[contracts/src/interfaces/x-ray/dependency-surface.md] — the full trust-surface map
[../wires/SYSTEM-SEAM-MAP.md] — the cross-contract joints (seams S1–S13); this folder is the external-trust half

Trust tier = blast radius if the external contract misbehaves or is mis-wired. The four highest-trust external surfaces an auditor should trace into their consumers:

* IBaal.executeAsBaal — a raw arbitrary call AS the DAO avatar. Consumer: ExitGate (szipUSD). The whole model rests on who is the avatar/shaman and whether governance is inert.
* IRoles (Zodiac Roles Modifier v2) — has delegatecall-capable ExecutionOptions. Consumer: WarehouseAdminModule. The interface deliberately includes the param-pinning scopeFunction because allowFunction skips all param checks; policy must never grant the delegatecall option.
* ISafe.execTransactionFromModule — how every enabled Zodiac module moves Safe funds. Consumer: DurationFreezeModule + every module. A module's power is "what the Safe will execute for it."
* IGPv2Settlement (CoW) — buy-and-burn approves the vaultRelayer and presigns orders. Consumer: SzipBuyBurnModule. The risk is the relayer approval + order parameters, not the settlement contract.

Trust tiers by vendor (full detail in the X-Ray; per-vendor surface in the docs below):

* CRITICAL — Subtensor precompiles (sole staking backing + payout magnitudes for the LST; magnitude is trusted, only direction guarded — see bridge X-1); IBaal (arbitrary DAO call).
* HIGH — Gnosis Safe (module exec); Zodiac Roles (delegatecall-capable permissioning); CoW (relayer approval); Algebra (spot/TWAP pricing inputs to NAV); ICHI (prod LP valuation + mint); Euler (ERC-4626 senior NAV mark via convertToAssets).
* MEDIUM–HIGH — Hydrex (the oHYDX yield + vote-emission loop and the demo vAMM LP).
* MEDIUM — Chainlink CCT registry (deploy-time registrar wiring only).

Two things an auditor should hold onto:

* Staleness is the residual. Every interface cites a live address + selector + date, but none is re-validated at build. Algebra/ICHI/Euler/Safe/Baal are all live, governed, or upgradeable — an external upgrade can drift from the mirror silently. Worth a periodic cast-diff of declared selectors vs live bytecode.
* 4 interfaces are STAGED, not dead. IAlgebraFactory, INonfungiblePositionManager, IICHIVaultFactory, IICHIDepositGuard are declared but referenced by no src/script/test today (verified: 0 src consumers each) — intentional forward scaffolding for the prod ICHI/Algebra LP path + a future range-sell ladder, labeled STATUS: STAGED in-file. Treat as not-yet-live, not cruft.

==================================================================================
Per-vendor summaries (the simple read)

Each links its wires catalog (the code-truth, file-by-file detail).

External vendors:
[interfaces-bridge.md] — Subtensor precompiles + Chainlink CCT registry + the IXAlphaRate seam
[interfaces-baal.md] — Baal (Moloch v3 DAO)
[interfaces-safe.md] — Gnosis Safe
[interfaces-zodiac.md] — Zodiac Roles + ModuleProxyFactory
[interfaces-cow.md] — CoW Protocol settlement
[interfaces-algebra.md] — Algebra Integral DEX
[interfaces-ichi.md] — ICHI automated liquidity manager
[interfaces-hydrex.md] — Hydrex (Solidly-style emissions) + the demo vAMM pair
[interfaces-euler.md] — Euler (ERC-4626 USDC vault) + the IZipUSD seam

Internal seams (intra-protocol coupling, lower attack value):
[interfaces-loss.md] — ISzipNavOracle, ILienXAlphaEscrow
[interfaces-supply.md] — ISzipNavBasket, ISeniorPool (with its donation-immunity contract)

Takeaway: the interface layer is well-disciplined, not a weak point — minimal surfaces, on-chain-verified signatures, clear vendor separation. The real audit work this map points to is in the IMPLEMENTATIONS that consume the four sharpest surfaces (Baal, Safe, Roles, CoW), and in keeping the verified selectors current against live external contracts.
