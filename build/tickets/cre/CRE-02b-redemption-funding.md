# CRE-02b — redemption funding automation (the utilization-driven resting-floor refill)

> Scoping ticket (not yet built). Spec: `claude-zipcode.md` §6.1 / §8.2 / §8.3 / §8.5. Depends on: CRE-02 (the
> reactive settle/claim/escrow keeper Job — DONE), CRE-04 (`cre/warehouse`, the REDEEM/REPAY producer — DONE),
> CRE-05a (the resting-bid loop — DONE-but-parked). Ships **default-OFF / unactivated** (flip on after testing).

## What it is (plain)
The piece that **goes and gets the cash**. CRE-02's keeper is reactive — it settles + claims whatever USDC is
already in the queue, but it never funds the queue. Funding = the warehouse **REDEEM → REPAY** (free EulerEarn
shares → USDC → transfer to the queue), which is the `cre/warehouse` (R) report transport the keeper cannot emit.
CRE-02b is the off-chain glue that **sizes** the REDEEM/REPAY and **fires** them, so the redemption→buyback cycle
runs without a human posting events by hand.

## The policy — a utilization-driven floor that actively refills
One variable, derived from utilization `U`, sets the **standing redemption floor** (how much USDC capacity to keep
flowing toward the CoW buy-burn bid). The system holds the floor: top up toward it when free cash exists, let it
draw down as the bid fills, refill again. This is the funding twin of CRE-05a's bid (which already sizes the
resting bid off the live free reservoir and reposts on drift). Same idea, applied to the cash that feeds it:

- As `U` **rises** (more lent out, less free, more redemption-vs-draw contention) → the floor target **shrinks**.
- As `U` **falls** → the floor **grows** and CRE-02b refills to it.

Concretely each cycle: compute the redemption shortfall (`queue.totalPending()/scaleUp − queue free USDC`),
clamp it to the utilization-derived floor, size the REDEEM `shares` off live NAV
(`EE.convertToAssets(EE.balanceOf(warehouseSafe))`), POST `{op:"redeem", shares}` then
`{op:"repay", dest:queue, amount}` to `cre/warehouse`'s HTTP trigger. CRE-02's keeper then settles + claims.

## ⚠️ Reserve-gate caution (load-bearing — do NOT build around it)
`U` is also the **contention / freeze variable** (§6.3 redemption-vs-draw, §11 duration squeeze). The floor MUST
be derived **through the existing reserve math** — the same `covered()` outflow gate + `harvestReserve` +
`safetyBuffer` CRE-05a already uses — NOT through a new independent knob. If CRE-02b sizes the floor off a
separate utilization reading, it will fight the freeze/coverage gates over the same cash (drain the reservoir the
harvest loop + the freeze floor need). Derive the floor from utilization, but **read it via the reserve/coverage
surface, not around it.** A starved-reservoir / undercovered state must shrink the floor to 0, never over-redeem.

## The open fork (the decision this ticket must resolve)
Where does the sizing live?
- **(a) Separate orchestrator** — a small off-chain producer (its own wasip1 workflow, or a leg of the keeper
  service) that reads availability + shortfall, computes `shares`/`amount`, and POSTs the pre-sized events to
  `cre/warehouse`'s HTTP trigger. Keeps `cre/warehouse` a dumb encoder (magnitudes arrive on the trigger, its
  current shape).
- **(b) Fold into `cre/warehouse`** — make the production warehouse producer read the shortfall + reserve
  on-chain and size the REDEEM itself. CRE-04 explicitly left this hook: its note says the on-chain NAV sizing
  "is the documented production replacement of the mock `observe`." This collapses CRE-02b into CRE-04's
  production hardening rather than a new module.
- **Recommendation to weigh:** (a) keeps the report producer pure + the sizing policy testable in isolation;
  (b) is fewer moving parts but couples the (R) producer to the reserve/coverage reads. Pick at scoping.

## Default-OFF / unactivated (the ship posture)
Like CRE-02's escrow leg + CRE-05a (built-but-parked): ships inert (an enable flag / floor target that resolves
to 0 = no funding fired), flippable on once the system has more testing and real exit data to tune the
utilization→floor curve. Manual ops POSTing the two events remains the M1 path until then. The cycle is
idempotent/self-healing, so a manual or partial firing is always safe.

## Binds to (verify exact getters at scoping — no back-pressure expected)
- `cre/warehouse` HTTP trigger event `{op, amount, shares, dest}` (`cre/warehouse/workflow.go`) — REDEEM needs
  `shares` (EE 18-dp), REPAY needs `dest` (=queue) + `amount` (USDC 6-dp).
- Free reservoir: `EE.maxWithdraw(warehouseSafe)` (the donation-immune §8.2 read CRE-05a/FE-08 use).
- NAV sizing: `EE.convertToAssets(EE.balanceOf(warehouseSafe))`.
- Shortfall: `ZipRedemptionQueue.totalPending()/scaleUp()`, `usdc.balanceOf(queue) − reservedAssets()` (CRE-02's
  reads).
- Reserve gate: the `covered()` surface + `harvestReserve`/`safetyBuffer`/`buybackCap` constants (CRE-05a Config).
- Utilization `U`: **VERIFY the exact getter at scoping** — read it via the reserve/coverage surface above, not a
  bespoke reservoir read (the caution).

## Done when (when built)
- An enable-gated producer sizes REDEEM/REPAY off the utilization-derived floor (through the reserve gate) and
  fires them via `cre/warehouse`; default-OFF resolves to no emission.
- A test proves: floor shrinks to 0 when undercovered / reservoir starved (never over-redeems); floor tracks
  utilization; the sized REDEEM `shares` round-trips to the expected `amount` ≤ shortfall; default-OFF emits
  nothing.
- The fork (a vs b) is resolved + recorded.
