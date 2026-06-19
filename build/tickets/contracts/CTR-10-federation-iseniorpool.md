# CTR-10 — Federation generalization: ISeniorPool + a non-Euler venue (RE-SCOPED 2026-06-19)

> **RE-SCOPE NOTE (2026-06-19).** A 4-critic fan-out (junior-dev / spec-fidelity / reference-verifier /
> contract-binding) found CTR-10 CANNOT cold-build to zero guesses as one ticket — same outcome pattern as
> CTR-06. It splits cleanly:
> - **CTR-10a — `ISeniorPool` extract + no-op re-type. DONE 2026-06-19.** The buildable, zero-guess half:
>   the structural senior-read generalization. Ticket: `CTR-10a-iseniorpool-extract.md`. (Full 919-test suite
>   green, byte-identical for the Euler silo.) This IS the §4.7 generalization CTR-10 set out to make.
> - **CTR-10b — the federation HOST SEAM (venue-agnostic admission). DONE 2026-06-19.** The `addSilo` hardening
>   half: a venue-neutral `ISeniorVenue.seniorPool()` getter (added to `EulerVenueAdapter`, asserted by the
>   registry in place of the Euler-specific `eulerEarn()`), the `eePool` field re-cast as the generic
>   `ISeniorPool` senior-read surface, and a plug-in recipe + proof test (a non-Euler venue stand-in with NO
>   `eulerEarn()` admits + aggregates donation-immune). RESOLVES obligation #3 (the plumbing decision — resolved
>   by REUSING `eePool` as the read surface; no new struct field, zero `SiloConfig` caller churn). A future venue
>   adapter now plugs in with NO registry change. Ticket: `CTR-10b-federation-host-seam.md`.
> - **CTR-10c — the reference non-Euler adapter + `ISeniorPool` wrapper + fork test. BACK-PRESSURE / DEFERRED
>   (P5).** The actual `IZipcodeVenue` implementation for a real venue. Still blocked on obligations #1/#2/#4
>   below (no bindable senior surface on the Base fork; venue unchosen; donation-immunity needs a real deployed
>   venue, not a mock). Build only when a second venue is actually wanted.
>
> Contract-track change (EXPANSION, deferred). The last step that turns multi-pool sharding into a true federation:
> a non-Euler venue (Aave v4, MetaMorpho, an orderbook matcher) as a silo under the same zipUSD, reading its
> senior surface through the now-extracted `ISeniorPool` (CTR-10a). Build only when a second venue is actually
> wanted. Spec: `claude-zipcode.md` §4.7. **Spec extension owed**: the federation §.

## BACK-PRESSURE (verified 2026-06-19 — obligations #1/#2/#4 still block CTR-10c; #3 RESOLVED by CTR-10b)
1. **No bindable non-Euler senior surface on the Base fork (block 47096000).** `BaseAddresses.sol` has zero
   Aave/Morpho/MetaMorpho/Centrifuge addresses. Reference clones are un-deployed (`moneymarket-contracts` USD3
   is 4626 source but no Base deployment), async (`centrifuge`/`erc7540-reference` — request/claim, not a
   synchronous `maxWithdraw`), or non-4626 id-keyed (`moneymarket` Morpho.sol). Binding a real adapter means
   first deploying a reference vault into the fork OR guessing an address — both fail the zero-guess gate. The
   ticket's own Do-NOT (a venue that can't be bound is back-pressure, not an interface change) applies.
2. **The venue is unchosen.** The Deliverable lists "e.g. AaveVenueAdapter OR MetaMorphoVenueAdapter OR an
   orderbook" — three mutually-exclusive integrations (Aave v4 isn't live; MetaMorpho is 4626; an orderbook is
   neither). Picking one is itself a load-bearing decision the ticket defers (P5: "build only after a second
   venue is actually wanted").
3. **~~Senior-surface plumbing decision unresolved~~ — RESOLVED 2026-06-19 (CTR-10b).** Resolved by REUSING
   `eePool` as the generic `ISeniorPool` senior-read surface (NOT adding a new field — that would have rippled
   into the CTR-02 struct, the `addSilo` writer/`ZeroAddress` check, and every `SiloConfig` caller). The
   `addSilo` adapter clause was generalized from `IAdapter(adapter).eulerEarn()` to the venue-neutral
   `ISeniorVenue(adapter).seniorPool()` (`EulerVenueAdapter.seniorPool()` returns `address(eulerEarn)`); the
   freeze clause already compared the freeze's senior getter to `eePool`, so it generalized for free. A non-4626
   venue sets `eePool` = its `ISeniorPool` wrapper and exposes `seniorPool()` returning the same — no struct
   change, zero `SiloConfig` caller churn. The `seniorPool()` getter lives on the concrete adapter, NOT on
   `IZipcodeVenue` (the seam stays senior-surface-free). See `CTR-10b-federation-host-seam.md`.
4. **Donation-immunity is a property of the real venue, not the interface.** Key-req #1 ("tested per venue")
   cannot be proven by a mock (a mock hardcodes immunity, proving nothing about the real venue's
   `convertToAssets`/`maxWithdraw` skewability). The Done-when "fork test" therefore genuinely needs a chosen,
   deployed venue — which contradicts the Starting state ("no non-Euler adapter exists") until #2 is resolved.

The §11 non-commingling deploy assert (`repaySink != juniorSafe`, `warehouseSafe != juniorSafe`) must be carried
into CTR-10b's admission gate explicitly (it is inherited via `SiloRegistry.addSilo` but should be named in
Done-when so a non-4626-wrapper silo cannot drop it).

## Why (the seam)
The venue seam (`IZipcodeVenue`) is already venue-agnostic, so a non-Euler adapter is "just another implementation."
The one Euler-specific coupling left is the senior read: `SeniorNavAggregator` (CTR-05) and `DurationFreezeModule`
read `IEulerEarnUtil` directly. To host a non-4626 senior venue, that read must go behind an interface each silo's
senior surface satisfies.

## Deliverable
1. ~~A new `contracts/src/interfaces/supply/ISeniorPool.sol`~~ — **DONE in CTR-10a** (interface created;
   `IEulerEarnUtil` deleted).
2. ~~Point `SeniorNavAggregator` + `DurationFreezeModule` at `ISeniorPool`~~ — **DONE in CTR-10a** (both re-typed;
   no-op for the Euler silo). The REMAINING half of #2 is CTR-10b: a non-4626 venue's thin wrapper + WHERE its
   address is stored (see BACK-PRESSURE #3 — needs a new `Silo.seniorRead` field, not the `eePool` slot).
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
