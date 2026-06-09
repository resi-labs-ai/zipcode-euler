# WOOF-00 — scaffold report to the superintendent

> **Original was a RETROACTIVE STUB** (the scaffold window predated the report convention). **Updated 2026-06-06
> by the superintendent** after a holistic audit found the scaffold incomplete for the item-8 / 8-Bw / bridge
> build phase. This report now reflects the **extended** scaffold (Euler compiled + everything else interface+fork).

**Item:** 1 — Foundry scaffold (`README.md` §7 / §16 → WOOF-00). **Team:** WOOF. **Status:** **MATERIALIZED +
BUILDS GREEN ON DISK (2026-06-06)** — `contracts/` now holds the real scaffold; `forge build` clean, all 3
self-checks pass (incl. a live Base-mainnet fork read). Kept, not discarded (keep-the-build doctrine).

> **UPDATE 2026-06-06 (user-directed real build).** The scaffold was actually materialized + compiled (not just
> ticket-audited), which exposed errors the prose layer could not: a CRE-selector contradiction, **10 of 25
> guessed external interface signatures were wrong**, and **two "CONFIRMED, repo-authoritative" addresses were the
> wrong contract** — the ICHI "factory" `0x7d11…` is a Gnosis Safe (real factory `0x2b52c416…`), and the Baal
> summoner labels were scrambled (`0x97Aaa…` is the AdvTokenSummoner, not the base `BaalSummoner` `0x22e0…`). All
> fixed on disk + verified against the live chain / `reference/Baal/deployments/base/*.json`. This report's
> "candidates — re-pin at build" framing below is superseded: the addresses are now on-chain-verified, with the
> corrections noted inline.

## TL;DR
The buildable Foundry skeleton every contract writes into. **Originally Euler-only** (EVK/EVC/EulerEarn/EulerRouter,
one OZ 5.0.2 copy, 9-line remaps, solc 0.8.24/cancun). **Now spans five ecosystems:** Euler is compiled from
source; **Baal, Zodiac Roles, Gnosis Safe, ICHI, Hydrex/Algebra are interface + fork** (minimal local interfaces +
Base-mainnet fork, never compiled); the Chainlink/Subtensor bridge is a sixth, source-compiled in its own (8x)
window. No protocol logic — skeleton + the integration-layer interfaces + a validated Base address book.

## What changed + why
- **The audit finding.** The scaffold predated the Baal/Zodiac szipUSD redesign + the xALPHA-bridge-into-M1
  decision. Its dep list, remaps, and `src/` tree know nothing about those — the first 8-Bw/8-B1 cold-build would
  have hit missing deps and an unbuildable config.
- **The real blocker: an OpenZeppelin version collision.** Baal pins **OZ 4.8.3**, Zodiac Roles **OZ 4.9.3**, both
  npm/Hardhat-based; Euler is **OZ 5.0.2**, Foundry. OZ 4.x↔5.x is a breaking split — you cannot compile both in
  one Foundry project. (ELI5: their LEGO and Euler's LEGO are different standards and don't snap together.)
- **Strategy A (interface + fork) dissolves it.** We never compile their OZ-4.x source: we author minimal local
  interface files and fork live Base mainnet for the real, already-deployed, already-audited contracts. The
  collision can't arise because the conflicting source is never in our build. This is the standard way to build
  on top of deployed protocols and is exactly what the 8-B tickets already assumed ("fork-tested against live
  Base"). **User-locked.**

## Validated Base deployments (on-chain verified 2026-06-06 — corrections noted inline)
Interface **signatures** were verified by selector-probing the live contracts (10 of 25 guesses were wrong →
corrected) + vendored source for Baal/Zodiac. **Addresses** were each checked on-chain (code + identity getter /
deployment JSON) — **two were the wrong contract and are corrected below.**

| Family | Key Base address(es) | Verification (pass 2026-06-06) |
|---|---|---|
| CRE (Base **mainnet + Sepolia**) | KeystoneForwarder `0xF8344CFd5c43616a4366C34E3EEE75af79a74482` (**same addr on both**); **deploy-target selector = `ethereum-mainnet-base-1` (the MVP ships to mainnet)**; `ethereum-testnet-sepolia-base-1` is the optional secondary | **CONFIRMED on-chain** — `typeAndVersion()` → `"KeystoneForwarder 1.0.0"` (this pass, via the Alchemy RPC) + Chainlink forwarder directory. `ReceiverTemplate` **inherited (compiled)**, not interfaced. |
| Euler (8453) | EVC `0x5301c7dD…8989`, eVaultFactory `0x7F32…f8D0`, eulerEarnFactory `0x75F4…FAE6`, oracleRouterFactory `0xA928…c116`, edgeFactory `0x4B93…0e4A` | **CONFIRMED (repo-authoritative)** — `EulerChains.json` chainId 8453 / production. **Base Sepolia addresses NOT in reference → source at build.** Core compiled; we fork the deployed **factories**. |
| Safe (8453) | ProxyFactory 1.3.0 `0xa6b71e26…6ab2`; L2 singleton 1.4.1 `0x29fcB43b…C762` | **BOTH CONFIRMED on Basescan** — ProxyFactory verified `GnosisSafeProxyFactory`; singleton verified `SafeL2`. |
| Baal (8453) | **CORRECTED** — `BaalSummoner` `0x22e0…E098`; `BaalAndVaultSummoner` `0x2eF2…0c5D` (DAO+Safe); `BaalSingleton` `0xE0F33E95…`; `BaalAdvTokenSummoner` `0x97Aaa…3E11` (impl `0xD69e…e387`) | **Labels were SCRAMBLED** — the prior "BaalSummoner `0x97Aaa`" is actually the AdvTokenSummoner. Corrected against `reference/Baal/deployments/base/*.json` + on-chain `template()` (BaalSummoner `0x22e0`.template() → `0xE0F33E95…` = the Baal.json singleton). |
| Zodiac (8453) | Roles mastercopy `0x9646fDAD…D337`; ModuleProxyFactory `0x0000…cDda236` | **BOTH CONFIRMED on Basescan** — Roles verified `Roles` (correct surface); factory verified `ModuleProxyFactory` (`deployModule`), also in `reference/zodiac-core` tooling. |
| Hydrex/Algebra/ICHI (8453) | **see `pending-docs/hydrex.md`** — but **ICHI factory CORRECTED** to `0x2b52c416…` (the old `0x7d11…` was a Gnosis Safe, not the factory) | On-chain verified 2026-06-06: HYDX/oHYDX/veHYDX symbols, Voter `VoterV5Proxy`, NFPM `ALGB-POS`, pool `token0()`=HYDX all confirmed; the ICHI "deployer" was the wrong contract (fixed in `hydrex.md` + `BaseAddresses.sol` + the ticket). |
| **Dynamically created** | zipUSD/xALPHA **ICHI vault** + its **Hydrex gauge** — no fixed address; created on demand and **gated on the Hydrex whitelist (OTC)** | fork tests use a stand-in until the gate clears (mirrors the xALPHA stand-in-token decision). |

## Holes surfaced → resolution
| # | Hole | Resolution |
|---|---|---|
| 1 | A single-file EVC import is not a sufficient build probe | Self-check 1 pins the `ESynth` + `BaseAdapter` cross-repo probe (the OZ/EVC dedup hard case). |
| 2 | SPDX license unpinned | Pinned `GPL-2.0-or-later` for every authored `contracts/` file (imports GPL evk/EVC → derivative stays GPL; GPL-compatible with OZ MIT). |
| 3 | **[EXT]** Scaffold knew only the Euler ecosystem; item-8/bridge deps absent; **OZ 4/5 collision** if their source were compiled | **Strategy A:** interface+fork for Baal/Zodiac/Safe/ICHI/Hydrex; only OZ-free `zodiac-core` (and, in 8x, Chainlink) compiled. New `src/interfaces/`, Base-mainnet fork profile, `BaseAddresses.sol`/`ForkConfig.sol`, and a 3-part cross-ecosystem probe. |
| 4 | **[EXT]** The deployed protocols (Baal/Safe/Zodiac/ICHI/Hydrex) live on Base **mainnet**; Base Sepolia lacks the farm/vault deps | **Decision 2026-06-06: ship to Base mainnet, test there** (Base gas is cheap; deploy-target = fork-target = where the deps live). `base = "${BASE_RPC_URL}"` is the primary RPC; `base_sepolia` optional. |

## Design decisions to sanity-check
1. **Interface + fork over vendor/compile** — locked; dissolves the OZ-4/5 collision.
2. **Deploy + test on Base mainnet** (2026-06-06 decision) — Sepolia lacks the farm/vault deps (Baal/Safe/ICHI/
   Hydrex are 8453-only), so deploy-target = fork-target = Base mainnet. `base` is the primary RPC.
3. **`zodiac-core` `Module` compiled-from-source (OZ-free) vs interfaced** — one remap added; per-ticket whether a
   shaman actually inherits it.
4. **The bridge (8x) is the lone source-compiled external** — its OZ/forge-std dedup + solc compat is **re-verified
   in the 8x window**, not assumed here.

## Status & next
- **The scaffold is materialized + builds green on disk** (`contracts/`): `forge build` clean (52 files, solc
  0.8.24), all 3 self-checks pass (the Euler OZ-dedup probe, the cross-ecosystem coexistence probe with NO OZ-4/5
  collision, and a **live Base-mainnet fork read** via the Alchemy RPC). The scaffold-completion obligation in
  `PROGRESS.md` is **DISCHARGED** (no longer "owed to a future window").
- **Kept, not discarded** (keep-the-build doctrine, now in `kickoff.md` + `audit/adversarial-spec/README.md`):
  the materialized `contracts/` is the proof and is committed. The RPC lives in gitignored `contracts/.env`.
- **Known boundary (honest):** 9 addresses are identity-confirmed by getter/name; the interface families ICHI/
  Hydrex/Algebra had no vendored source, so their signatures were selector-verified on-chain (good) but a few
  return-type tuples (e.g. NFPM `positions`) rest on live-decode sanity, not a verified-source struct.
- **WOOF-06 coordination — RESOLVED (2026-06-06).** That agent's work is complete and its `contracts/src` is back
  to skeleton. The re-authored WOOF-06 **mocks** both seams — the `CreditWarehouse` is a plain EOA address in tests
  (`EE_POOL.deposit(usdc, WAREHOUSE_SAFE)`) and the junior stake goes through a proposed `ISzipUSD.depositFor(zipAmount,
  receiver)` seam — so it authored **no real `ISafe`/`IBaal`**. **No divergent interface copies exist.** The scaffold's
  `interfaces/safe/ISafe.sol` + `interfaces/baal/IBaal.sol` serve the **real** consumers (8-Bw / 8-B1 / 8-B2). The
  one live seam to honor: WOOF-06's `ISzipUSD.depositFor` is pinned as an **8-B2 mint-shaman obligation** — 8-B2 must
  match that signature.
