# CTR-10 — Federation generalization: ISeniorPool + a non-Euler venue (LATER / P5)

> Contract-track change (EXPANSION, deferred). The last step that turns multi-pool sharding into a true federation:
> generalize the senior read behind an interface so non-Euler venues (Aave v4, MetaMorpho, an orderbook matcher)
> can be silos under the same zipUSD. Build only after CTR-02..09 land and a second venue is actually wanted.
> Spec: `claude-zipcode.md` §4.7 (venue-agnostic; "a second venue can be added behind the adapter"). **Spec
> extension owed**: the federation §.

## Why (the seam)
The venue seam (`IZipcodeVenue`) is already venue-agnostic, so a non-Euler adapter is "just another implementation."
The one Euler-specific coupling left is the senior read: `SeniorNavAggregator` (CTR-05) and `DurationFreezeModule`
read `IEulerEarnUtil` directly. To host a non-4626 senior venue, that read must go behind an interface each silo's
senior surface satisfies.

## Deliverable
1. A new `contracts/src/interfaces/supply/ISeniorPool.sol` — `{balanceOf(address), convertToAssets(uint256),
   maxWithdraw(address)}` (the exact three views the donation-immune senior read needs), generalizing
   `contracts/src/interfaces/euler/IEulerEarnUtil.sol`.
2. Point `SeniorNavAggregator` (CTR-05) at each silo's `ISeniorPool` (EulerEarn satisfies it directly; a non-4626
   venue gets a thin wrapper). `DurationFreezeModule`'s read MAY also migrate behind it (optional, larger blast).
3. A reference non-Euler adapter implementing `IZipcodeVenue` (e.g. `AaveVenueAdapter` or `MetaMorphoVenueAdapter`)
   + its `ISeniorPool` wrapper if not natively 4626 — registered under a new `siloId` via `SiloRegistry.addSilo`.
4. Admission/underwriting gate hardening: the registry's `addSilo` topology assert extended to the venue-type's
   senior surface; the federation-level admission policy (uniform underwriting standard before a curator's silo
   joins the shared senior) documented.

## Spec §
`claude-zipcode.md` §4.7 (Euler = config one; venue-agnostic core re-points behind the adapter), §11 (the
mutualization firewall — loss stays local to a silo's junior), §17.

## Binds to (verified)
- `IZipcodeVenue` (`contracts/src/venue/IZipcodeVenue.sol`) — the seam a new adapter implements (already
  Euler-type-free).
- `IEulerEarnUtil` (`contracts/src/interfaces/euler/IEulerEarnUtil.sol`) — the donation-immune read to generalize.
- `SeniorNavAggregator` (CTR-05), `SiloRegistry` (CTR-02), `DurationFreezeModule.sol:243-302` (the read site).
- The target venue's SDK/interfaces (Aave v4 / MetaMorpho) — verify the real senior-share read shape before
  claiming donation-immunity (a manipulable `convertToAssets`/`maxWithdraw` breaks both the aggregator and that
  silo's freeze floor).

## Starting state
- CTR-02..09 landed: multi-pool Euler sharding + dual structures + fee work. The aggregator + freeze read Euler
  directly. No non-Euler adapter exists.

## Do NOT
- Do NOT build this before a second venue is actually wanted (it is P5 — flagged LATER).
- Do NOT admit a non-Euler silo whose senior read is donation-skewable (the §8.2 invariant must hold for every
  venue type, not just EulerEarn's pure-allocator NAV).
- Do NOT mutualize loss across silos — each silo's junior remains its own firewall; the senior sees only a silo's
  post-wipeout residual.
- Do NOT change `IZipcodeVenue` for a new venue — if a venue cannot satisfy it, that is back-pressure (log it),
  not an interface change.

## Key requirements
1. **Donation-immune for every venue type** — each `ISeniorPool` implementation's senior read is non-manipulable;
   tested per venue.
2. **Loss locality preserved** — a non-Euler silo's default touches only its own junior/oracle/escrow.
3. **Same silo shape** — the new venue reuses the junior/loss/freeze/registry/NAV machinery unchanged; only the
   adapter + (maybe) an `ISeniorPool` wrapper are new.
4. **Admission gate** — the federation Timelock admits the new silo only after the venue-type senior surface passes
   the topology + donation-immunity checks.

## Done when (gate — `forge test`, fork)
- `forge build` green; a fork test stands up a non-Euler silo, registers it, opens a line through it, and shows
  `SeniorNavAggregator` aggregating it donation-immune; a default in it marks only its own junior.
- Cold-build with ZERO load-bearing guesses.

## Depends on / unblocks
- **Depends on:** CTR-02..09.
- **Unblocks:** the true multi-venue federation (Euler + Aave + MetaMorpho + orderbook under one zipUSD).
