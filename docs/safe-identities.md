# SAFE IDENTITIES
[zipcode-euler]

The protocol's Gnosis Safes and fixed value-destinations, by canonical name, after the 2026 naming
consolidation. Base (chain 8453). A "Safe" is a Gnosis multisig; a "box" is a locked address value may flow to
and nowhere else. Several of these names point at the SAME on-chain address but are kept as distinct code slots
because they play different roles (and a future deploy could split them onto different addresses).

== Junior tranche side (the szipUSD basket) ==

- juniorTrancheSafe — the Baal main / basket Safe: ragequittable junior equity (holds zipUSD + xALPHA + the
  staked ICHI LP). The freeze `commit` source / `release` destination; the redemption off-ramp avatar. It is the
  Baal avatar (`baal.avatar()`). (formerly two names: `mainSafe` and `rqSafe` — both were this same Safe.)

- juniorTrancheEngine — the SAME address as juniorTrancheSafe, but a distinct role: the avatar every yield-engine
  Zodiac module executes through, and the Safe whose transient pre-burn szipUSD is excluded from the NAV supply
  count. (formerly `engineSafe`. Deploy wires it equal to the basket Safe; kept distinct for role clarity.)

- juniorTrancheSidecar — the committed-equity, NON-ragequittable Safe: the duration-freeze bucket (`commit`
  destination / `release` source). Its value cannot fall below the senior coverage floor. A DIFFERENT address
  from juniorTrancheSafe (the deploy asserts they are distinct). (formerly `sidecar`.)

== Senior side (the warehouse) ==

- warehouseSafe — the CreditWarehouse Safe: custodies the EulerEarn senior shares + USDC; the senior backing for
  zipUSD. Asserted DISTINCT from every junior Safe (non-commingling: `warehouseSafe != juniorTrancheSafe` and
  `!= juniorTrancheSidecar`). (formerly three names for this one Safe: `warehouseSafe`, `warehouse`, and `safe`.)

- redemptionBox — the locked address the warehouse is hard-wired to send freed USDC to: the par-redemption queue
  (`ZipRedemptionQueue`). The only place redemption cash may go; the USDC raised here funds the CoW buy-burn bid.
  (formerly `repaySink`.)

== Admin and fees ==

- adminSafe — the protocol admin Safe; the single destination for protocol take. Two flows land here: (1) the
  loss-recovery slash (xALPHA, later bridged to USDC) from the escrow; (2) the per-draw origination fee (0.5%)
  from the venue adapter. (formerly two slots in two contracts: `treasurySafe` in the escrow and `feeRecipient` in
  the venue adapter.) Note: the EulerEarn pool's own `feeRecipient` (the perf-fee recipient, set to the
  warehouseSafe) is a SEPARATE thing — it is EulerEarn's, not ours, and keeps its name.

- curatorSafe — the curator's pay: the EVK fee-receiver installed on every credit-line vault; it captures the
  curator's share (about half) of each line's interest fee instead of forfeiting it to Euler. (formerly
  `curatorVault`.)

== Off-ramp ==

- erebor — the ONLY address a credit-line draw may send borrowed USDC to; it crosses to the off-chain rail
  immediately. (unchanged.)

== Not value Safes — admin/operator identities, unchanged ==
- team / TEAM_MULTISIG — the deploying / admin multisig (the k-of-n Safe in production).
- godOwner — the transient warehouse owner before the multisig handoff.
- creOperator — the on-chain keeper that drives the engine modules' operator-gated calls.
- workflowAuthor — the CRE workflow whose pushed oracle reports the receivers trust (data provenance, not a caller).
- reservoirAllocator — the two-key reservoir funder (distinct from the reservoir loop operator).

== Notes for future maintainers ==
- The deploy env keys were renamed to match the slots: `TREASURY_SAFE → ADMIN_SAFE` and
  `CURATOR_VAULT → CURATOR_SAFE` (an existing `.env` must update these two keys).
- The generic local/parameter name `safe` (e.g. `SzipNavOracle._grossValueOf(address safe)`,
  `DurationFreezeModule`/`RecycleModule` engine reads, the deploy `_enableModuleOnSafe(address safe)`) is NOT the
  warehouse Safe — it is a generic "any Safe" parameter and was deliberately left as `safe`.
