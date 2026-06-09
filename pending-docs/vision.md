# zipcode-euler — Vision

## The one-liner

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

## The problem

Home equity is the largest pool of household wealth in the country, and the businesses that lend
against it — HELOC originators — are perpetually capital-constrained. They originate good loans, then
wait, sometimes months, to sell them to a secondary buyer before they can recycle their capital and
originate again. The funding side of lending still runs on slow, bilateral, relationship-heavy rails
even though origination itself became software a decade ago.

DeFi has solved over-collateralized crypto lending, but credit against **real-world, income-and-asset-
backed obligations** — the biggest category in traditional finance — barely exists on-chain. The
blocker has never been the capital; it's been **trustworthy underwriting**: you can't put a house in a
smart contract, and you can't splash a borrower's identity and bank data across a public network.

## The insight

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

## How it works (plain version)

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

## How the money works

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

## Why zipUSD stays a dollar

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

## What you can see

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

## Why it compounds

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

## What we're building first

A working **proof of operations**: one originator, one home, the full loop running end-to-end on Euler
(our first venue) on Base — underwrite from the proof stack (lien, value, insurance), open the line, draw,
repay, release — with the real **zap** supply side wired in (deposit USDC → zipUSD → szipUSD, earning the
headline APR). Enough to prove the machine works and to keep raising. The loss/default flow
(mark-to-recovery, the **Duration Bond**, insurance, the xALPHA premium, recovery) follows as a second
milestone, since it needs an engineered default to demonstrate. The architecture is deliberately shaped so
other venues (Aave, Morpho), the marketplace, and the securitization layer plug into the same engine,
collateral tokens, and oracle later.

## North star

Make the capital-markets side of home lending run as software — open, verifiable, and always on —
so that good loans never wait on capital, and anyone can earn yield from American home equity without
trusting a desk to underwrite it for them.

---

*For the engineering scope (contracts, interfaces, call paths), see [`claude-zipcode.md`](./claude-zipcode.md).
For the build plan, see [`README.md`](./README.md). The off-chain leg — SPV custody and the Proof attestation
layer (lien, value, insurance) — is in [`spv-lien-proof.md`](./spv-lien-proof.md).*
