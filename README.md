# zipcode-euler — Vision & Build Plan

> **Front door.** The *why* is the **Vision** below; the *what/how* is the spec (`claude-zipcode.md`); this
> file is the **build plan** (§1 onward) — who builds what, when, → which spec §. Every §4 task points to the
> spec section that defines it.

---

## Vision

### The one-liner

**A decentralized credit protocol — a warehouse for American home equity.** Anyone can deposit USDC for a
credit dollar and stake it for yield; verified HELOC originators — already originating into established
secondary takeout markets — draw warehouse credit lines against that pool to fund home-equity loans, with
the entire underwriting and capital-allocation engine run by a decentralized network instead of a trusted
desk.

**Settlement venue.** zipcode launches with **Euler** as its on-chain settlement venue. But the core — a
credit oracle where the **Zipcode Bittensor subnet** (our own validator network) fetches and verifies every
underwriting input and **Chainlink CRE** writes the signed attestation on-chain — is **venue-agnostic by
design**: the same engine can settle on **Morpho**, **Aave**, or other lending venues. Euler is the first
configuration, not the protocol.

### The problem

Home equity is the largest pool of household wealth in the country, and the businesses that lend
against it — HELOC originators — are perpetually capital-constrained. They originate good loans, then
wait, sometimes months, to sell them to a secondary buyer before they can recycle their capital and
originate again. The funding side of lending still runs on slow, bilateral, relationship-heavy rails
even though origination itself became software a decade ago.

DeFi has solved over-collateralized crypto lending, but credit against **real-world, income-and-asset-
backed obligations** — the biggest category in traditional finance — barely exists on-chain. The
blocker has never been the capital; it's been **trustworthy underwriting**: you can't put a house in a
smart contract, and you can't splash a borrower's identity and bank data across a public network.

### The insight

You don't need the house on-chain. You need a **verifiable answer** to six questions a real underwriter
asks — who is this borrower, are they creditworthy, can they repay, do they own the home cleanly, is
there room for another lien, and what is the home worth — produced **without trusting any single party**.

Each question has a source: identity and income (Plaid), credit (Credit Karma), title and liens (Pippin,
DART), and — the keystone — **Proof**, a notarization layer over the lien's SPV documents that attests
*both* that the lien is real and ours to claim *and* its appraised value: the institution-grade appraisal
the loan was already underwritten on, surfaced from the document set rather than re-guessed by a model.

The breakthrough is how that data is gathered and verified at scale. **Zipcode is our own Bittensor
subnet.** Its validators run containers that pull each API, verify the data is correct and delivered to the
right place using **zero-knowledge proofs** so the borrower's private information is never exposed, and
reach consensus on it — acting as a **decentralized oracle network** that feeds **Chainlink CRE**, which
writes the verified, signed attestation on-chain and drives the lending venue. Doing this with a
conventional oracle would mean standing up a new price feed for every single line of credit — prohibitively
expensive and impossible to scale. Owning the subnet makes validating and transmitting any API, for any
loan, cheap programmable infrastructure. The underwriter becomes code that a network agrees on, not a
person you have to trust.

### How it works (plain version)

1. **Suppliers** deposit USDC. The default path **"zaps"** it straight through: USDC mints **zipUSD** (a
   $1 credit dollar) and auto-stakes into **szipUSD** — the junior position that earns yield by absorbing
   losses first: the protocol recycles its lending earnings into the position so its value compounds, plus a
   premium when it is term-locked through a duration squeeze. The headline yield product is **szipUSD**. (Anyone who
   just wants the flat $1 dollar can simply hold zipUSD.)
2. A **HELOC originator** applies for a credit line. The CRE workflow underwrites them from the data
   stack above and prices the specific home.
3. If approved, the protocol opens an **isolated, individually-priced credit line** — collateralized
   on-chain by a token representing the lien, while the actual lien sits in a legal vehicle off-chain
   (its existence and value notarized via **Proof**). Each line is backed by a **xALPHA** first-loss bond:
   at launch the protocol posts that bond on the originator's behalf — a xALPHA sink, and the insurance
   reserve behind the junior's bonus APR — with originators funding their own bonds via **OTC xALPHA** as
   they expand to more credit lines.
4. The originator requests **draws** through the protocol's API — they never touch the chain. The
   decentralized workflow's controller is the on-chain borrower; a banking partner (Erebor) wires the
   dollars to the originator and collects repayments. When the line is closed the collateral is burned
   and the lien released.
5. Every sensitive step — opening a line, pricing collateral, moving pool money — can **only** be done
   by the decentralized workflow. No admin can reach in and move funds.

### How the money works

You deposit USDC, and by default it **zaps** straight into the yield position: your USDC mints **zipUSD**
(a $1 credit dollar) and auto-stakes into **szipUSD**, the junior that earns yield in exchange for taking the
first loss — the protocol recycles its lending earnings into the position so its share value compounds, with an
added premium when it is locked into a Duration Bond. **szipUSD is the headline product.** When a loan
defaults the protocol still holds the legal lien on a real house, and the position is covered by an
off-chain insurance policy — so a default is a *timing* problem, not a *total-loss* problem. The junior
fronts the loss now; recovery and insurance pay it back later.

**The two tokens.**
- **zipUSD — the $1 utility dollar.** Pegged to $1, minted with USDC and redeemed back for USDC. It is the
  protocol's dollar plumbing, not the investment: it's the **exit hatch** out of szipUSD, and a
  USDC-pegged asset other money markets can lend against (against szipUSD, against a future **zipCRED**
  RWA, against other RWAs). Because the money is out working in loans, instant redemption isn't always
  possible — primary redemption runs on a roughly 30-day queue, and if you want out faster you sell zipUSD
  in a **secondary pool** at market price, paired against USDC (deliberately not xALPHA, so the dollar's
  relief valve never depends on our thinnest token). zipUSD stays $1 because the junior absorbs losses
  before it ever does.
- **szipUSD — the staked junior, and the main product.** This is what the zap puts you in. Its **share value
  accretes** as the protocol recycles its earnings into the position, with an added **Duration-Bond premium**
  when it is locked through a hold — the return it earns for taking the first loss. (The loan spread itself is
  the **protocol's** — it over-collateralizes the dollar's reserves rather than paying the junior directly.) It
  is the protocol's shock absorber: the capital that covers stress the moment it happens so that zipUSD stays a
  dollar.

**xALPHA's job (and what it is *not*).** xALPHA is **not** the dollar's primary backing — the **house and the
insurance** are. xALPHA has two jobs, in order. First and mainly, it is the **duration premium**: each line
carries a **xALPHA bond** (at launch the protocol posts it on the originator's behalf — a supply sink and the
reserve behind the bonus; originators fund their own via OTC xALPHA as they scale), and when a position locks
into a Duration Bond, that xALPHA is handed *in-kind* to the locked stakers as the bonus APR that pays them
for the wait. Second and only as a last resort, xALPHA is **sold to help fill a capital hole** if insurance
falls short — a bounded, loss-driven sale, *not* peg defense. xALPHA is **priced**, and that price
substantiates the bonus APR and sizes that backstop. We deliberately **never sell xALPHA to defend the peg**
— dumping a thin token during a wave of defaults is the death-spiral we refuse to build (covering a realized
loss after insurance is a different, bounded thing).

**Two ways stress shows up.** One non-event first: an originator can't run off with the money, because **a
line is never issued until the lien is already perfected in the SPV** (notarized by Proof). The only real
risks are:
1. **A homeowner defaults (one loan).** The loan is continuously **marked to recovery** — the home's equity
   above any senior mortgage, less a haircut (HELOCs are often second liens, junior to the first mortgage in
   a foreclosure, so the mark stays conservative). The junior absorbs that markdown first, and the affected
   position becomes a **Duration Bond** — locked for a fixed term at an elevated APR. Recovery then arrives
   in layers: the protocol forecloses on the lien (partial, slow); an **off-chain insurance policy covers
   the shortfall** (the primary capital backstop that protects lenders); and only if insurance still falls
   short is **xALPHA slashed** to fill the rest. The junior is made whole as those arrive, the Duration Bond
   releases with the xALPHA premium on top, and the junior takes a permanent loss only if foreclosure *and*
   insurance *and* xALPHA all fall short. If recovery instead **exceeds** the debt, the surplus is the
   homeowner's equity and returns to them, not the protocol.
2. **A duration squeeze (the whole book).** Nobody defaults, but the secondary takeout markets freeze, so
   loans that should have sold off stay on our books, utilization stays high, and the pool can't free USDC
   fast enough. The danger isn't loss — it's a **run**: if everyone tried to exit at once they'd unstake and
   dump zipUSD on the secondary pool, breaking the peg and trapping capital. So szipUSD locks into a
   **Duration Bond** to stop the stampede, earns an elevated APR for the hold, and releases when liquidity
   returns — loans repay, the takeout reopens, or insurance clears.

In both cases the tool is the same — a **Duration Bond**: a fixed-term, higher-yield lock on the junior that
resolves with the xALPHA premium. So the junior earns a **duration premium**: the longer your capital is
bonded backstopping a recovery or a liquidity gap, the more you make. szipUSD is paid to provide instant
liquidity against slow legal recovery, and to hold the duration until the house — or the insurance, or the
reopened takeout — pays out.

### Why zipUSD stays a dollar

- zipUSD isn't backed by a volatile token — it's protected by a **stack that absorbs loss in order**: the
  **szipUSD junior** takes the first loss, an **off-chain insurance policy** covers any capital shortfall,
  **xALPHA** backstops as a last resort, and underneath it all sits a **real legal lien on a real home**.
- The junior (szipUSD) is **first-loss**: it absorbs the markdown in dollars before zipUSD is ever touched,
  so stress lands on the people paid to take it.
- The mark is **conservative**: HELOCs are often second liens, so a loan is valued at the home's equity
  *above* the first mortgage, less a haircut — the cushion is priced in, not assumed.
- **Insurance is the primary capital backstop** that protects lenders; **xALPHA** is mostly the **duration
  premium**, and only a last-resort capital backstop — it is **never sold to defend the peg**.
- The **Duration Bond** stops runs: whether one loan defaults or the whole book turns illiquid, locking
  szipUSD prevents a stampede that would depeg zipUSD through the secondary pool.
- A default is a **delay, not a wipeout**: the home is still there; recovery flows back to whoever bore the
  loss, and any surplus above the debt returns to the homeowner.

### What you can see

The protocol publishes its health in the open:
- **Total NAV** — cash plus the marked-to-recovery value of the loans.
- **zipUSD minted** and the **zipUSD peg** vs USDC (deviation is the stress signal).
- **szipUSD APR** — the headline yield, a trailing-realized return as its **share value accretes** — and the
  **bonus** paid on active Duration Bonds.
- **Utilization / free liquidity** — how much of the pool is lent out vs withdrawable; the early warning
  for a duration squeeze.
- **Insurance coverage** — the on-chain **xALPHA** insurance pool, and the off-chain policy coverage attested
  via **Proof of Insurance**.

The dollar is **fully backed whenever NAV is at least the zipUSD minted** — and the junior, the insurance,
and the home's recovery are what keep it there through stress.

### Why it compounds

Two things make this more than a lending app:

- **The engine is the moat, and its fees compound across venues.** The durable asset isn't any one market
  — it's the underwriting engine: our Bittensor subnet validating the data, Chainlink CRE signing it, and
  the oracle pricing the collateral. Every credit line throws off fees as it turns over, and because the
  engine is **venue-agnostic**, the same machine runs on Euler today and Aave or Morpho next — so the fee
  base compounds as we add venues, not only as we add loans.
- **From a price feed to our own secondary market.** Every loan we write produces a fresh, verified,
  notarized valuation for a specific property. Accumulate enough and you have a dense, trust-minimized
  record of American home values — and eventually the ability to run oracles on those properties and, via
  **Securitize**, place them into **our own** secondary markets. Today we plug into the takeout markets
  that already exist (Figure, Saluda Grade); the endgame is to *become* one. (Not a now thing — but the
  architecture is shaped for it.)

The three structures share one oracle and collateral backbone: **ONE** — the credit warehouse we build
first; **TWO** — a peer-to-peer marketplace matching outside lenders to borrowers, one market per loan;
**THREE** — tokenized mortgage-backed securities via Securitize, the standing buyer that closes the loop
and lets the warehouse recycle capital far faster. Stage THREE is the secondary market that makes stage
ONE spin — first someone else's, eventually our own.

### What we're building first

A working **proof of operations**: one originator, one home, the full loop running end-to-end on Euler
(our first venue) on Base — underwrite from the proof stack (lien, value, insurance), open the line, draw,
repay, release — with the real **zap** supply side wired in (deposit USDC → zipUSD → szipUSD, earning the
headline APR). Enough to prove the machine works and to keep raising. The loss/default flow
(mark-to-recovery, the **Duration Bond**, insurance, the xALPHA premium, recovery) follows as a second
milestone, since it needs an engineered default to demonstrate. The architecture is deliberately shaped so
other venues (Aave, Morpho), the marketplace, and the securitization layer plug into the same engine,
collateral tokens, and oracle later.

### North star

Make the capital-markets side of home lending run as software — open, verifiable, and always on —
so that good loans never wait on capital, and anyone can earn yield from American home equity without
trusting a desk to underwrite it for them.

---

**Build plan.** The *what/how* is the spec (`claude-zipcode.md`); below is the *who builds what, when, →
which §*. Every task points to the section of the spec that defines it.

---

## 1. Read these in this order

| Doc | What it is |
|---|---|
| [`claude-zipcode.md`](./claude-zipcode.md) | **The spec** — token model, primitives (§3), net-new contracts (§4; venue boundary §4.7), supply/yield (§5), redemption (§6), oracle (§7), CRE (§8), control-flow (§9), lifecycle (§10), loss (§11), NAV/dashboard (§12), trust (§13), demo (§15), repo map (§16), **locked decisions (§17)**, glossary (§18). |
| [Vision](#vision) (above) | The *why* — problem, the CRE-underwriter insight, the two tokens, the three structures. |
| [`spv-lien-proof.md`](./pending-docs/spv-lien-proof.md) | The one open off-chain leg: SPV custody + the **Proof** family (lien/value/insurance). Collateral is **mocked** until this lands. **§6 lists the open risks** (Proof capability, insurance product, legal/regulatory, liquidation path). |
| [`audit/`](./audit/) — [`2.md`](./audit/2.md) / [`3-results.md`](./audit/3-results.md) / [`adversarial-spec/`](./audit/adversarial-spec/) | The is-it-garbage layer: **2** the M1 tx-by-tx acceptance harness (Foundry tests) · **3-results** the authority/gating wiring audit (no orphans — passed) · **`adversarial-spec/README.md`** = the **live ticket-authoring harness** (draft → critics → triage → keep-the-build). *(`audit/1-results.md`'s I1–I5 money-model invariants are **RETIRED** — they audited the deleted `J×p`/convert-on-stake/withhold model; under the two-token redesign invariants now derive **per-component at ticket time** via the critic fanout, not a standalone pass.)* |

(Roadmap that is **not** M1/M2 build spec lives in [§8 Future Development](#8-future-development).)

---

## 2. MVP scope

**In the end-July MVP** — the M1 loop live on **Base mainnet** (Euler venue) + supply side + visible product
(deploy + test on mainnet — the farm/vault deps are 8453-only; see `tickets/PROGRESS.md`):
- **Loop:** underwrite (Proof gates, mocked) → mint lien → seed Proof-of-Value → `openLine/fund/draw` (Erebor)
  → permissionless repay → close → `LienReleased`. (§15)
- **Supply side:** the **zap** (deposit → zipUSD → **NAV-proportional szipUSD** via the Exit Gate), NAV-accretion
  yield routing, 30-day epoch redeem (senior zipUSD); junior exit = the Gate's **windowed ragequit at NAV** +
  **CoW** secondary + buy-and-burn, with the structural **Duration-Bond freeze**. (§5/§6)
- **Engine:** Shape-B CRE workflows; the Zipcode-subnet container/DON layer. (§7/§8)
- **Frontend:** `euler-lite` (Vue) with the Inflow surfaces + the solvency dashboard. (§12)

**Explicitly deferred** (do not build for the MVP):
- Full **M2 loss/default machinery** — `DefaultCoordinator`/`LienXAlphaEscrow` are **M1-sketch interfaces only**.
- **Real Proof/SPV integration** — collateral stays mocked.
- **Shape A** (subnet-as-DON), **venue 2** (Aave/Morpho), **structures TWO/THREE** (P2P / MBS), the **post-M1
  xALPHA reward layer** (depositor incentive emission + the zipUSD/xALPHA POL pair + the treasury-buyback closed
  loop, §17). **NOTE — the Hydrex farm loop is NOT deferred:** it is part of the **M1 `szipUSD` vault** (the 8-B
  chain). The **xALPHA CCIP bridge is now pulled INTO M1** (2026-06-06) to source it; dev validates
  builds against a **stand-in test xALPHA token** so nothing stalls on CCT registration (see the §4 bridge note).

**Two clocks:** **2026-06-11 demo** (frontend "real enough" to show) · **end-July MVP** (the above, live).

---

## 3. Locked design decisions (recap — authoritative in `claude-zipcode.md` §17)

1. Cash-reserve ratio → **fixed-%**. 2. Redemption epoch → **30d, no mid-epoch cancel**. 3. **Duration Bond**
+ haircut → governed (≈180d / ≈0.65); fires on default OR duration squeeze. 4. xALPHA price → **CRE feed**.
5. szipUSD = a **transferable ERC-20 share** the **Exit Gate** mints **NAV-proportionally** vs **soulbound
gate-held Loot** (the Gate is the sole Loot custodian + ragequitter — no raw-ragequit footgun), over a
**Baal/Moloch-v3 + Zodiac** Gnosis-Safe basket; **NAV (`SzipNavOracle`) is the issuance/exit pricing primitive**;
**exit** = the Gate's windowed ragequit at `min(spot,twap)` NAV (partial-fill) + a **CoW** secondary + **8-B14
buy-and-burn**; **no cap**; **first-loss = a conservative pari-passu provision-that-recovers** (small day-one
markdown, writes back up on verified recovery — **NOT** withhold-no-markdown); the **coverage floor is the
structural freeze**; zipUSD = **$1 utility**; the **zap**. *(2026-06-07 two-token model — supersedes the prior
Loot-share / ragequit-in-kind / WITHHOLD recap.)*
6. Surplus recovery → originator/homeowner; shortfalls → **insurance first, xALPHA last-resort (sold for
realized loss, never peg defense)**; unrecoverable residual socializes **passively** (the provision marks NAV
down → smaller NAV-per-share for every holder), never a seizure. 7. Demo → M1 base loop + supply / M2 loss. 8. Valuation → **event-driven
Proof** (no heartbeat/AVM/HPI). 9. Perspectives → **dropped**. 10. **Venue-agnostic**, Euler = config one
(§4.7). 11. Underwriting fabric → **Zipcode subnet** (Shape B for M1, Shape A endgame). 12. Attestation →
the **Proof family** gates before mint.

Full text + rationale: **§17**.

---

## 4. Build tasks — per team

> Conventions: `[ ]` = task; **§** = the defining section in `claude-zipcode.md`. "M2" tasks are deferred
> (sketch only for the MVP).
>
> **Authority:** this section is the static **task ↔ spec-§ index** (who builds what → which §). The **live
> status and what's `NEXT`** live in `tickets/PROGRESS.md` — do **not** track progress here. The `[x]`/`[ ]`
> marks are a coarse at-a-glance only; **`PROGRESS.md` wins on any conflict.**

### WOOF — contracts + wiring (Base mainnet, Euler venue)
**Setup**
- [x] Foundry project; EVK/EVC/oracle deps + `remappings.txt` (model `reference/evk-periphery`). §16 — **materialized + builds green** (`contracts/`, WOOF-00, 2026-06-06); interfaces + Base address book on-chain-verified.
- [x] `reference/` in `.gitignore`; **Base mainnet** RPC + deployer; selector `ethereum-mainnet-base-1`. (RPC in gitignored `contracts/.env`.)

**Deploy + configure (vanilla Euler/OZ/Chainlink — no code change).** §3 / §16
- [ ] `EulerEarn` pool (`EulerEarnFactory`); `setFeeRecipient(szipUSD)`, `setFee(f)`, `setIsAllocator(adapter)`. §9
- [ ] Isolated market via `GenericFactory.createProxy` (model `EdgeFactory`); flat `IRMLinearKink(baseRate,0,0,kink)`;
      `setHookConfig(gatingHook, OP_BORROW|OP_LIQUIDATE)`; `setLTV` (gap=cushion); `setGovernorAdmin(adapter)`. §9
- [ ] Per-line `ROUTER_i` minted + wired `escrowVault→LIEN_i→registry` + frozen (`transferGovernance(0)`) inside `openLine` (NO shared router / NO `govSetFallbackOracle` — per-line-router redesign); OZ `TimelockController` (≈2d) governs §17 params only; cash-reserve fixed-%. §4.1/§4.7/§9
- [ ] `ESynth` (zipUSD) instance; capacity → `ZipDepositModule` + `szipUSD`; **renounce `ESynth` ownership** after. §9

**Build — net-new contracts** (model from the cited reference; build behind the `IZipcodeVenue` boundary, §4.7).
- [x] `LienCollateralToken` (fixed 1e18 @18dec; constant name/symbol; identity=address) + `LienTokenFactory` (CREATE2 salt=keccak256(lienId)). §4.2 — **built + 14/14 tests green** (`contracts/`, 2026-06-06)
- [x] `ZipcodeOracleRegistry` (RedstoneCoreOracle *pattern*; long validity window; mark = Proof-of-Value − senior debt; guards zero/`uint208`/decimals; **no HPI band**; event-driven writes; venue-neutral cache). §4.1 — **built + 34/34 tests green** (`contracts/`, 2026-06-06)
- [x] `CREGatingHook` (EVC `isAccountOperatorAuthorized` operator-check — each line borrows on a fresh per-line account, **borrowDriver/adapter**-as-operator, §4.4; borrow+liquidate gated, repay ungated). §4.3 — **built + 8/8 tests green** (`contracts/`, 2026-06-06; error `NotAuthorizedOperator()` `0x3d9adf1c`)
- [x] `ZipcodeController` (report ABI `(reportType, payload)` with `proofRef`, **no `regionalHPI`**; drives venue via `IZipcodeVenue`; **no EVC handle / no `wireVenueOperator`** — the per-line operator grant is the adapter's `LineAccount` job inside `openLine`, §4.4/§4.7; Forwarder immutability via `renounceOwnership` (base `setForwarderAddress`/`onReport` are non-virtual) + set identity **before** renounce). §4.4 — **MATERIALIZED + BUILT-VERIFIED 2026-06-06** (`contracts/src/ZipcodeController.sol`; `forge build` green + **26/26 tests on a live Base-mainnet fork**, 102/102 total; zero EVC coupling, no-controller-operator-wiring borrow proven; zero-spec-guess keepsake)
- [x] **`IZipcodeVenue` + `EulerVenueAdapter` + `LineAccount`** (openLine — deploys a fresh per-line borrower account (`LineAccount`) + wires the-adapter-as-operator / setLineLimits/fund/draw (operator `batch`)/observeDebt/liquidate; adapter holds the Euler roles). §4.7 — **MATERIALIZED + BUILT-VERIFIED 2026-06-06** (`contracts/src/venue/`; `forge build` green + **20/20 tests on a live Base-mainnet fork**, 76/76 total; EVK/EVC/EulerRouter live, EulerEarn mocked at 0.8.26)
- [x] `ZipDepositModule` (the **`zap`** = deposit USDC → 1:1 `ESynth` mint → **Gate `depositFor` → NAV-proportional szipUSD**; USDC parks in `EulerEarn` with the **`CreditWarehouse` Safe** as the share `receiver`). §4.5 — **BUILT-VERIFIED 2026-06-08** (`contracts/src/supply/ZipDepositModule.sol`; 29/29, fork-proven vs the real Exit Gate). *(`INFLOW-06` frontend interface = the alla-prima sweep, post-deploy.)*
- [x] **`CreditWarehouse` (8-Bw)** — the senior-backing custody **Gnosis Safe** holding the `EulerEarn` pool shares; owner **GOD-EOA → governance multisig**; routine ops (SUPPLY/APPROVE/REDEEM/REPAY) via the **Zodiac Roles Modifier v2** (audited Gnosis Guild infra), scoped by an owner-applied permissions policy + a thin CRE-Forwarder-gated role-member adapter (`WarehouseAdminModule`). **No bespoke privileged contract.** §4.5 — **BUILT-VERIFIED 2026-06-09** (`contracts/src/supply/CreditWarehouse/`; 23/23 fork; the scope IS the security boundary).
- [x] **`szipUSD` = the Baal/Moloch-v3 + Zodiac junior NAV vault (item 8 — decomposed into the 8-B chain, all BUILT-VERIFIED).** The **Exit Gate** mints a **transferable ERC-20 szipUSD share NAV-proportionally** vs **soulbound gate-held Loot**; a **Gnosis Safe** holds the basket (zipUSD + xALPHA + the zipUSD/xALPHA ICHI LP gauge-farmed on Hydrex); **NAV (`SzipNavOracle`) is the issuance/exit pricing primitive**; **exit = the Gate's windowed ragequit at NAV (partial-fill) + CoW secondary + 8-B14 buy-and-burn**; **first-loss = a conservative provision-that-recovers** (NOT withhold); the coverage floor is the **structural sidecar freeze**. **Depositor return = NAV accretion** (the HYDX-vamp free value recycled into the basket weekly, realized on exit at NAV; real lending APR/fees are the protocol's → treasury → xALPHA, §17). Built: **8-B1** substrate · **`SzipNavOracle`** · **Exit Gate + `SzipUSD`** · engine **8-B5** reservoir-loop / **8-B6** LP / **8-B7** harvest-vote / **8-B8** exercise / **8-B9** sell / **8-B10** `RecycleModule` (single sink) · **8-B14** buy-and-burn — Baal shamans + Zodiac modules driven by the (off-chain) **8-B11** CRE strategy-admin robot. **No cap.** §4.5 / §4.5.1 / §6.4 / §11
- [ ] `ZipRedemptionQueue` (fork MIT `erc7540-reference` + clean-room Maple pro-rata; 30d epoch, no mid-epoch cancel; funded by the warehouse REDEEM→REPAY seam). §4.5 / §6.1 — **NEXT**
- [ ] **(M2 + the M1-adjacent custody half, `8-Bx`)** `LienXAlphaEscrow` (per-lien xALPHA bond custody — `lockXAlpha`/`releaseXAlpha` is **M1-adjacent**, slash half `slashXAlphaToCapital` alpha→TAO→USDC / `slashXAlphaToCohort` goes live with the M2 default flow) + `DefaultCoordinator` (**M2**: writes the bounded conservative **provision-that-recovers** into `SzipNavOracle` + runs the recovery waterfall secondary→insurance→xALPHA; the freeze is structural/Exit-Gate-owned, NOT here). §4.6 / §11
- [ ] **(M2)** Systemic **duration-squeeze freeze** (Duration Bond **trigger B**): on-chain utilization-floor trigger + the structural sidecar **freeze** (gates the Gate's windowed exit), utilization-sized; **no xALPHA premium** (no slash). §11 / §6.4 / §8.2
- [ ] **(resolved — M1 scope)** No on-chain economic liquidation: `liquidate` is a **defensive gate only** (block external seizure of an interest-underwater line); the controller never calls it. Default→resolution is **off-chain** (secondary purchase / insurance + foreclosure) surfaced as permissionless `repay`; the **provision/recovery** bookkeeping is `DefaultCoordinator` (**M2** — a bounded conservative provision-that-recovers marked on `SzipNavOracle` + the recovery waterfall, NOT withhold). §4.3 / §4.4e / §11

### CRE — Go workflows, Shape B (user or WOOF)
- [ ] Underwriting/origination: `http.Trigger` → node-mode **Proof family** fetch (+ identity/income/credit/title proofs) → identical-consensus → `GenerateReport`/`WriteReport`; **event-driven re-pricing, no heartbeat/Subnet-46/HPI**. §8.1
- [ ] Redemption settle: 30-day `cron.Trigger` → `settleEpoch()`. §8.3
- [ ] xALPHA price feed (Duration Bond premium NAV + szipUSD bonus APR). §7 / §8
- [ ] Project/secrets config; DON-only `GetSecret` (no PII in node-mode consensus). §8
- [ ] **(M2)** Default/recovery report `(lienId, status, foreclosure+insurance)` → `DefaultCoordinator`. §8.4

### Subnet dev — Bittensor / Zipcode subnet
- [ ] Validator/miner **containers**: fetch each API + **zk-verify** (no PII) + consensus. §7 / §8.1
- [ ] **Proof-family fetch** (lien/value/insurance) into the containers. §8.5
- [ ] **DON → CRE (Shape B)** integration — subnet-validated inputs feed a standard Chainlink CRE DON that signs. §7 / §13

### Inflow team — frontend surfaces (Vue, inside `euler-lite`)
- [ ] Originator onboarding surface. §15 (KYB'd originator path)
- [ ] USDC depositor / **zap** UX (deposit → zipUSD → szipUSD). §5
- [ ] Map surfaces onto `euler-lite` pages (earn / borrow / onboarding).
- [ ] Solvency **dashboard** — NAV, zipUSD supply, peg, szipUSD APR, utilization, insurance coverage. §12

### Branding / Designer
- [ ] `euler-lite` (Nuxt/Vue) fork, branded for zipcode (the team convergence point).

### Off-chain / legal (user) — mocked for the MVP, real for production
- [ ] **Proof** integrations (lien/value/insurance notarization API). `spv-lien-proof.md` / §8.5
- [ ] **SPV** custody partner + the on-chain↔legal handoff. `spv-lien-proof.md`
- [ ] **Erebor** dollar leg (off-ramp on draw, on-ramp on repay). §9
- [ ] **Insurance** carrier (the off-chain policy covering capital shortfalls). §11 / `spv-lien-proof.md`
- [ ] **Verify Proof's capability** — can it attest lien / ownership / value / insurance per-lien, in a CRE-consumable form? `spv-lien-proof.md` §6.1
- [ ] **Source the insurance product** — carrier / policy terms / premium for second-lien HELOC default coverage. `spv-lien-proof.md` §6.2
- [ ] **Legal / regulatory scoping** — lending licenses, securities analysis (xALPHA / szipUSD / Duration Bond), SPV structure, KYB/AML. `spv-lien-proof.md` §6.3

### Subgraph / indexing — **owner TBD** (recommend shared WOOF/Inflow or infra)
> **Stack:** a The Graph subgraph for event-aggregated metrics (NAV/APR/utilization history, epochs) + direct
> view reads for cheap point-in-time values (`debtOf`, supply, share price); the frontend queries the subgraph
> directly (GraphQL). Starts once WOOF pins the event signatures; runs concurrently. (Subgraph-vs-custom-indexer
> is a hosting choice — same entity schema; confirm at kickoff.)
- [ ] Index the §9 events: `LienCreated`/`LienReleased`, `Borrow`/`Repay`/`Allocation`, deposit/`zap`/mint, stake/unstake, `EpochSettled`/`Claimable`, `RegistryPriceSeed`; *(M2)* default/Duration-Bond/recovery. Plus pool/registry state: EulerEarn `totalAssets`/`totalSupply`/share-price, per-line `debtOf`, registry `cache[lien]`, zipUSD `totalSupply`, szipUSD shares. §9
- [ ] Derive the §12 dashboard metrics: (1) NAV = idle USDC + marked loan value; (2) zipUSD minted + peg (= secondary-AMM price, §6.2); (3) szipUSD APR + Duration-Bond premium APR; (4) utilization / free liquidity (the §6.3 / §11-trigger-B squeeze early-warning); (5) insurance coverage = on-chain xALPHA fund (`LienXAlphaEscrow`) + CRE-published off-chain policy figure (Proof of Insurance, §8.5). Optionally surface the live solvency checks (senior `NAV_s/Z ≥ 1`; szipUSD NAV-per-share vs genesis). §12

### xALPHA bridge (**M1**) + treasury closed loop (**post-MVP**) — (owner TBD)
> **The xALPHA bridge is now M1 (2026-06-06)** — it sources the xALPHA the M1 `szipUSD` farm-loop basket + the
> first-loss bond require: an xALPHA liquid-staking wrapper over Bittensor subnet alpha + a CCIP (964↔8453)
> bridge. **Build:** [`tickets/bridge/8x-01-szalpha-wrapper-cct.md`](./tickets/bridge/8x-01-szalpha-wrapper-cct.md) (wrapper + CCT bridge,
> canonical-vs-fork, precompile/ABI map). **Don't stall on external gates** (CCT registration on chain 964, the
> canonical-vs-fork call): **validate builds against a stand-in test xALPHA token** on the Base fork and swap the
> real token in when the lane is live — plan the real path, no blocking. **Still post-MVP:** the closed-loop
> *economics* (treasury buyback / peg-arb / POL / depositor incentive budget) — **post-M1; the `treasury.md` decision doc was removed 2026-06-09, to be re-authored**;
> it consumes the protocol, not the reverse.
- [ ] ~~**`sdVAULT` — separate szipUSD/xALPHA autocompounder**~~ **FOLDED INTO item 8 (2026-06-06).** The
      auto-compounder engine (ICHI-LP-on-Hydrex + the oHYDX farm/exercise/range-sell/recycle loop + the CRE harvest
      robot) is **no longer a separate post-MVP `sdVAULT`** — it **IS** the `szipUSD` vault's core strategy set
      (Baal shamans + Zodiac modules), now specced in `claude-zipcode.md` §4.5 and decomposed into the **8-B
      ticket chain** (WOOF item 8 above; full design `pending-docs/auto-compounder.md`). **Yield routing is
      RESOLVED** (real lending yield is the protocol's → treasury → buys xALPHA; depositors subsidized by xALPHA +
      the HYDX/USDC pool, §17). **SCOPE RESOLVED (2026-06-06):** the **full Hydrex farm loop is IN the M1 staking
      vault** — the whole 8-B chain (incl. 8-B5…8-B11: reservoir/borrow, LP, harvest, exercise, range-sell,
      recycle, CRE robot) is M1, not deferred. **xALPHA source RESOLVED (2026-06-06):** the **CCIP bridge is
      pulled INTO M1** (it feeds the basket + the bond), and **dev validates builds against a stand-in test xALPHA
      token** — plan the real lane, don't block on CCT registration. §4.5 / `auto-compounder.md`
- [ ] Decide canonical xAlpha vs self-built `szALPHA` fork (economic call — post-M1 treasury economics, doc TBD; `DEC-03`).
- [ ] Resolve the open CCT-registration gate on chain 964 (testnet-945 attempt or Chainlink ping) — **plan it, don't block; dev validates against a stand-in test xALPHA token meanwhile.** `tickets/bridge/8x-01-szalpha-wrapper-cct.md`
- [ ] Build per the chosen path: wrapper over public Subtensor precompiles + CCT pool (964↔8453). `tickets/bridge/8x-01-szalpha-wrapper-cct.md`

---

## 5. Sequencing — first vs concurrent

**Now → the 2026-06-11 demo:** the visible piece is the **Inflow + Designer** frontend (`euler-lite` fork +
branding + Vue surfaces). Subnet, CRE, and off-chain are **represented as mock** at the demo.

**Concurrent tracks toward end-July:**
1. **WOOF** — net-new contracts behind `IZipcodeVenue` + the vanilla-Euler wiring.
2. **Subnet dev** — containers + Proof fetch + DON integration.
3. **CRE** — origination + redemption workflows.
4. **Off-chain** — Proof/SPV/insurance; **partly blocked → mocked** so it doesn't gate M1.
5. **Subgraph** — indexing + metrics (feeds the dashboard).

**Critical path = the M1 loop on Base mainnet:** vanilla-Euler config + the net-new contracts + the CRE
origination workflow. Because **collateral is mocked**, the open off-chain leg does **not** block the M1
build (§15) — that's the point of mocking it. Frontend + subgraph run in parallel and converge on the live
loop for the end-July MVP.

---

## 6. Genuinely open (off-chain/integration — not Solidity blockers)
- **SPV custody partner + Proof integrations** — Proof addresses the attestation; the SPV partner, the
  Proof-of-Insurance policy terms, and the CRE wiring of each Proof endpoint are still to pin
  (`spv-lien-proof.md`). Collateral mocked until they land.
- **Shape A (subnet-as-DON)** — the endgame where subnet validators are the signing DON; requires Chainlink
  provisioning; not M1-blocking (§7/§13).

---

## 7. Repo layout & conventions

Where each §4 task's deliverable lands (the "Deliverable" path on every ticket resolves here):

```
zipcode-euler/
├── README.md  claude-zipcode.md  nextsteps.md   # build map · the spec · handoff
├── kickoff.md  superintendent.md   # ticket-authoring: builder-window prompt · persistent reviewer role
├── tickets/          # the authored tickets (the product)
│   ├── PROGRESS.md   # process ledger — DONE/NEXT, open spec gaps ("what's next")
│   ├── LEDGER.md     # component design digest + cross-ticket obligations (final review)
│   └── woof/ …       # per-team ticket folders
├── reports/          # one builder-window report per item → the superintendent's review trail
├── pending-docs/     # decide / why / open — not the contract build spec
│   └── spv-lien-proof.md   # the open off-chain leg (the *why* now lives in this file's Vision section)
├── audit/            # is-it-garbage layer: conformance oracles + the authoring harness
│   ├── 1-results.md  # money-model proof — I1–I5 RETIRED (two-token redesign; invariants now derive per-component at ticket time)
│   ├── 2.md          # M1 tx-by-tx acceptance harness (→ contracts/test/)
│   ├── 3-results.md  # authority/gating audit (matrix + negative-test source)
│   └── adversarial-spec/   # README.md = the LIVE ticket-authoring harness (draft → critics → triage → keep-the-build)
├── reference/        # read-only reference repos (already here)
├── contracts/        # Foundry — WOOF
│   ├── src/
│   │   ├── LienCollateralToken.sol  LienTokenFactory.sol
│   │   ├── ZipcodeOracleRegistry.sol  CREGatingHook.sol  ZipcodeController.sol
│   │   ├── venue/    IZipcodeVenue.sol  EulerVenueAdapter.sol
│   │   ├── supply/   ZipDepositModule.sol  ZipRedemptionQueue.sol
│   │   │   ├── szipUSD/        # the Baal/Moloch-v3 + Zodiac junior NAV vault (item 8 / 8-B): transferable szipUSD
│   │   │   │                   #   share + Exit Gate (Loot custody/mint/windowed-RQ) + SzipNavOracle + Zodiac engine
│   │   │   │                   #   modules (8-B5…B10, B14) + the (off-chain) 8-B11 CRE robot
│   │   │   └── CreditWarehouse/ # senior EE-share custody Safe + Zodiac Roles Modifier v2 admin + CRE adapter (8-Bw)
│   │   └── loss/     LienXAlphaEscrow.sol  DefaultCoordinator.sol   # xALPHA bond custody (8-Bx, M1-adjacent) + the M2 provision-that-recovers/recovery-waterfall
│   ├── script/       # deployment / wiring
│   ├── test/         # Foundry tests = the audit/2.md acceptance harness + the per-component fork suites (kept)
│   └── foundry.toml  remappings.txt
├── cre/              # Go CRE workflows (wasip1) — CRE team
├── subnet/           # Bittensor containers + Proof fetch — subnet dev
├── subgraph/         # indexing — TBD owner
└── frontend/         # the euler-lite (Vue) fork, branded + Inflow surfaces — Inflow + Designer
```

**Conventions**
- **`reference/` is read-only.** Model from it, never edit it. It holds the Euler / CRE / 3Jane / euler-lite
  source that everything is built against.
- **One contract per file**, named exactly as the symbol (`ZipcodeOracleRegistry.sol`). Folders group by
  role: `venue/` (the `IZipcodeVenue` boundary), `supply/`, `loss/` (M2-sketch).
- **Ownership by folder:** `contracts/` = WOOF · `cre/` = CRE · `subnet/` = subnet dev · `subgraph/` = TBD ·
  `frontend/` = Inflow + Designer.
- **One deliverable path per task:** each §4 task produces the file at its path here (e.g. the
  `EulerVenueAdapter` task → `contracts/src/venue/EulerVenueAdapter.sol`).

---

## 8. Future Development

Post-MVP structured-product components that are **designed but deliberately out of the M1/M2 build spine**. Not
blockers, not authored as tickets yet — captured here so the intent is not lost. Pull each into the regular
one-item-per-window ticketing when its dependencies land.

### 8-B9b — Patient range-sell module (HYDX→USDC spike-harvesting LP)

**What it is.** A second HYDX→USDC selling mode that *complements* (does **not** replace) the 8-B9 `SellModule`
immediate market-sell. The HYDX/USDC pool is thin and net-draining, so a weekly market-sell bleeds ~3% slippage
(~$10k on a 300k-HYDX clip — acceptable, "gets the job done"). But HYDX **spikes roughly once every 6–8 weeks**, and
patient liquidity can sell *into* those spikes at far better prices than dumping into a dead pool.

**Mechanism (a single-sided concentrated sell ladder).**
- Deposit **single-sided HYDX** as an Algebra/UniV3-style concentrated-liquidity band, **+5% → +50% above the
  deposit mark price** (a passive sell ladder: as price rises through the band, the position auto-converts HYDX →
  USDC). This is the HYDX/USDC **UniV3-style deposit capacity that lives OUTSIDE the ICHI vault** (distinct from the
  8-B6 ICHI ALM position).
- **Auto-withdraw** the LP once price reaches **+50% from the initial deposit mark** (the position is then mostly/
  fully USDC); collect + close.
- Plumbing = the Algebra **NonfungiblePositionManager** (`mint`/`decreaseLiquidity`/`collect`/`burn`) — the
  `INonfungiblePositionManager` interface already exists in the repo (Algebra `deployer` field verified). This is a
  **new Zodiac module** (NFPM-driven, recipient-pinned to the engine Safe) **plus a new CRE automator** to manage
  deposit timing + the +50% withdrawal trigger. (Reconciles the superseded "UP-regime range-rest of the residual"
  note in `pending-docs/auto-compounder.md §9.1` / `hydrex.md §9.1` — that ladder is THIS module, now specced.)

**The tension that keeps it a COMPLEMENT, not a replacement.** The strike-repay leg carries an **open borrow accruing
interest** (8-B5) and an unstaked LP slice (no emissions) — it cannot wait 6–8 weeks for a spike, so it MUST stay the
8-B9 immediate market-sell. Patient range-sell fits only the **non-time-critical HYDX**: the residual/free-value HYDX
above the strike, the veHYDX-rebase HYDX, and any regime where the strike is treasury-USDC-financed (no borrow). So
the mature engine runs **8-B9 (immediate, repay leg) + 8-B9b (patient, spike-harvest) side by side**, the CRE robot
routing each clip to the right path.

**Depends on.** 8-B9 (the immediate baseline) + a new CRE automator + the out-of-ICHI HYDX/USDC range capacity.
**Status:** deferred (M2/post-MVP), tracked as `8-B9b` in `tickets/PROGRESS.md`.
- **Foundry:** `remappings.txt` models `reference/evk-periphery/remappings.txt`; deps point into `reference/`.
  Tests in `contracts/test/` **are** the acceptance harness — `audit/2.md` (tx-by-tx M1) + the per-component
  fork suites kept under `contracts/test/` (the I1–I5 standalone money-model pass is retired; invariants derive
  per-component at ticket time).
- **`frontend/` is a fork of `reference/euler-lite`** (Nuxt/**Vue**), branded; Inflow authors surfaces in Vue
  inside it (not React).
- **`cre/` workflows are Go → `wasip1`** (model `reference/cre-sdk-go/standard_tests`).
- **`subnet/`** holds the validator/miner container code + the Proof-family fetch; feeds CRE (Shape B).
- **The spec is the source of truth.** Every file traces to a `claude-zipcode.md` § (see §4 above).
  Don't invent mechanisms the spec doesn't define — log it as a finding.
- **`loss/` is M2-sketch** (interface sketches only for the MVP; full state machines detailed before M2).
