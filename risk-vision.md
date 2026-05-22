# zipcode-euler — Risk & Tokenomics Vision

> The high-level companion to [`tokenomics-layer.md`](./tokenomics-layer.md). This is the plain-language
> story of the money: the dollar people deposit, the yield they can stake for, the token that aligns
> originators, and what actually happens when a loan goes bad. It is a **composable layer** on top of
> the base protocol described in [`vision.md`](./vision.md) — kept separate until a deliberate merge.

## The shape in one paragraph

You deposit USDC and receive **zipUSD**, a credit dollar worth a dollar. That capital funds home-equity
loans to vetted lenders. If you want yield, you stake zipUSD into **szipUSD**, the junior position that
earns the loan spread in exchange for absorbing losses first. Every loan is minted with a **RESI** bond
posted by the originator — their skin in the game, locked up while the loan is live, and slashed if it
defaults. And critically: when a loan does default, the protocol still holds the legal lien on a real
house, so a default is a *timing* problem, not a *total-loss* problem. The junior fronts the loss now;
the home's recovery pays it back later.

## The two dollars

**zipUSD — the senior dollar.** Pegged to $1. You mint it with USDC and redeem it back for USDC. Because
the money is out working in loans, instant redemption isn't always possible — so primary redemption runs
on a queue (roughly 30 days, the time it takes capital to free up). If you want out faster, you sell
zipUSD in the **zipUSD/RESI pool** at the market price; if it dips below a dollar there, arbitrageurs who
are willing to wait the queue buy it back up. zipUSD holders sit at the top of the stack and are meant to
stay whole.

**szipUSD — the staked junior.** You stake zipUSD to get it. It earns more, because it takes the first
loss. szipUSD is the protocol's shock absorber: it's the capital that covers a default the moment it
happens so that zipUSD stays a dollar.

## RESI's job (and what it is *not*)

RESI is **not** what backs the dollar. The house backs the dollar. RESI does three things, none of which
require it to be deeply liquid:

- **Aligns the originator.** To mint a loan's synthetic lien, the originator posts RESI. It's their
  equity in the deal — they lose it if the loan defaults. Skin in the game.
- **Sinks supply.** RESI is locked for the life of the loan, then released on repayment.
- **Drives demand.** A lender who wants to originate has to acquire and lock RESI, so loan growth pulls
  RESI off the market.

We deliberately never sell RESI to defend the peg — its liquidity is thin, and dumping it during a wave
of defaults is exactly the death-spiral we refuse to build. RESI is the alignment-and-bridge token; the
real backstop is the home.

## What happens when a loan defaults

This is the heart of the design — a **pro-rata-haircut-lock**:

1. **Haircut.** The defaulted loan is marked down. szipUSD stakers absorb that markdown in dollar terms,
   so zipUSD never breaks the buck.
2. **Insurance payout.** The originator's RESI bond is slashed and handed to the affected stakers, in
   kind (we don't fire-sell it).
3. **Lock.** The slice of your szipUSD exposed to that loan is locked until the default resolves — you
   can't exit the bad position to dump the loss on someone slower, and you can't pile in at the last
   second to grab the rebound. If you were in when it broke, you're in until it clears.
4. **Recovery.** The protocol pursues the legal lien on the home. Months later, the recovery comes in and
   repays the locked slice — restoring most or all of the haircut, with the home as the real source of
   funds.

So szipUSD stakers are paid to do one specific job: **provide instant liquidity against slow legal
recovery, and hold the duration until the house pays out.** That's where the junior yield comes from.

## Why the senior is safe

- The senior dollar is backed by **real residential equity**, recovered through a real legal lien — not
  by a volatile token.
- The junior (szipUSD) absorbs losses first, in dollars, so a default hits the people paid to take it.
- RESI adds an equity cushion and aligns the originator, but it is never the thing that has to be sold to
  keep the peg.
- A default is a delay, not a wipeout: the home is still there, and recovery flows back to whoever bore
  the loss.

## Status

This layer is designed and the underlying mechanics are mapped to real, audited contracts (3Jane's
markdown/settle/tranche stack and Euler's synth/savings/peg stack) in
[`tokenomics-layer.md`](./tokenomics-layer.md). It is intentionally kept separate from the base
[`vision.md`](./vision.md) / [`claude-zipcode.md`](./claude-zipcode.md) until a deliberate merge.
