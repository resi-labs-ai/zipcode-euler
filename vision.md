# zipcode-euler — Vision

## The one-liner

**A decentralized credit protocol for American home equity.** Anyone can deposit USDC and earn yield;
verified HELOC originators borrow against that pool to fund home-equity loans — with the entire
underwriting and capital-allocation engine run by a decentralized network instead of a trusted desk.

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
there room for another lien, and what is the home worth — and you need that answer produced **without
trusting any single party**.

Each of those questions now has a data source: identity and income (Plaid), credit (Credit Karma),
title and liens (Pippin, DART), and — the keystone — a live appraisal from **Bittensor Subnet 46
(resi)**, a model competition that prices homes, with a mandatory regional home-price index that bounds
any model-wide error. The breakthrough is running all of it through a
**Chainlink CRE workflow**: a decentralized network fetches the data, verifies it with cryptographic
proofs (Reclaim + EigenLayer) so no private data is ever exposed, and writes a verified, signed credit
attestation on-chain. The underwriter becomes code that a network agrees on, not a person you have to trust.

## How it works (plain version)

1. **Lenders** deposit USDC into a credit pool and earn yield (bootstrapped with RESI token incentives).
2. A **HELOC originator** applies for a credit line. The CRE workflow underwrites them from the data
   stack above and prices the specific home.
3. If approved, the protocol opens an **isolated, individually-priced credit line** — collateralized
   on-chain by a token representing the lien, while the actual lien sits in a legal vehicle off-chain.
4. The originator requests **draws** through the protocol's API — they never touch the chain. The
   decentralized workflow's controller is the on-chain borrower; a banking partner (Erebor) wires the
   dollars to the originator and collects repayments. When the line is closed the collateral is burned
   and the lien released.
5. Every sensitive step — opening a line, pricing collateral, moving pool money — can **only** be done
   by the decentralized workflow. No admin can reach in and move funds.

## Why it compounds

Two things make this more than a lending app:

- **An oracle network for housing.** Every loan we write produces a fresh, verifiable valuation for a
  specific property. Do this thousands of times and you've built something nobody else has: a dense,
  trust-minimized price feed for American homes — independently valuable, and the foundation for
  everything below.
- **A closed capital loop.** Three structures share the same oracle and collateral backbone and form one machine:
  - **ONE — the credit pool** (the first structure): fund originators against home equity.
  - **TWO — a peer-to-peer marketplace**: match outside lenders directly with borrowers, one market per
    loan.
  - **THREE — tokenized mortgage-backed securities** (via Securitize): a standing buyer that purchases
    the loans, fractionalizes them, and sells the pieces — which gives originators an instant secondary
    and lets the credit pool recycle its capital far faster.

The oracle is the spine connecting all three; stage THREE is the secondary market that makes stage ONE
spin faster.

## What we're building first

A working **proof of operations**: one originator, one home, the full loop running end-to-end on Base —
underwrite, price, open the line, draw, repay, release. Enough to prove the machine works and to keep
raising. The architecture is deliberately shaped so the marketplace and the securitization layer plug
into the same collateral tokens and oracles later.

## North star

Make the capital-markets side of home lending run as software — open, verifiable, and always on —
so that good loans never wait on capital, and anyone can earn yield from American home equity without
trusting a desk to underwrite it for them.

---

*For the engineering scope (contracts, interfaces, call paths), see [`claude-zipcode.md`](./claude-zipcode.md).
For the build plan, see [`todo.md`](./todo.md).*
