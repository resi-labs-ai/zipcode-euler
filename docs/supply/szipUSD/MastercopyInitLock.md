# SZIPUSD ENGINE — MastercopyInitLock
[zipcode-euler/contracts/src/supply/szipUSD]

The four-line mixin that locks each module's master copy. Base (chain 8453). Solidity 0.8.24.

* Each engine module is deployed once as a master copy, then cloned per vault; the clone is configured once. The bare master copy is never used directly and holds no funds.
* This mixin makes the master copy's one-time setup unusable, so the master copy can never be configured. The modules' documentation claimed this was already true; this makes the claim true.
* Clones are unaffected — they never run this code and configure exactly once, as before.

==================================================================================
What it does

- MastercopyInitLock.sol → master-copy init lock
A small base every engine module inherits. Its constructor flips the one-time-setup flag without running setup, so the deployed master copy is already initialized and its setup reverts. A clone does not run the constructor, so it starts fresh and configures once — the deploy path is unchanged.
[contracts/src/supply/szipUSD/MastercopyInitLock.sol]
[../../wires/8-B14-SzipBuyBurnModule.md]

Summaries:
This mixin has no dedicated wiring map; it is documented inline in each engine module's wiring map (the SEC-14 note in 8-B5 through 8-B14, DurationFreezeModule, OffRampModule). It is also absent from the wires coverage manifest.
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md]

==================================================================================
Security X-Ray (audit fidelity)

Rated ADEQUATE (coverage-complete; benign failure mode) — a defense-in-depth mixin whose entire behavior is proven in both directions by 18 tests across all nine engine modules.

[contracts/src/supply/szipUSD/x-ray/MastercopyInitLock.md]
[contracts/src/supply/szipUSD/x-ray/portfolio-map.md] — engine subsystem overview

* The master copy is locked: its setup reverts after deploy (proven once per engine module).
* Clones still initialize exactly once: a fresh clone starts unconfigured and configures one time (proven once per engine module).
* Failure mode is benign even in theory — a bare master copy is never enabled on a vault and holds no value — so this is documentation honesty and defense-in-depth, not a value-bearing control.

==================================================================================
References:

- Inherited by all nine engine modules (Exercise, Harvest, LpStrategy, Freeze, BuyBurn, Sell, Recycle, OffRamp, FarmUtilityLoop).
- It relies on the vendored Zodiac one-time-initializer semantics; correctness there is upstream Zodiac's.
