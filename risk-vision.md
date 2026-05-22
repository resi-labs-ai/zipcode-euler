# zipcode-euler — Risk & Tokenomics Vision

> The high-level companion to [`tokenomics-layer.md`](./tokenomics-layer.md). This is the plain-language
> story of the money: the dollar people deposit, the yield they can stake for, the token that aligns
> originators, and what actually happens when a loan goes bad. It is a **composable layer** on top of
> the base protocol described in [`vision.md`](./vision.md) — kept separate for clean context, to be
> synthesized into one pathway.

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
zipUSD in a **secondary pool** at the market price — paired against USDC, deliberately not RESI, so the
dollar's relief valve never depends on our thinnest token. If it dips below a dollar there, arbitrageurs
willing to wait the queue buy it back up. zipUSD holders sit at the top of the stack and are meant to stay whole.

**szipUSD — the staked junior.** You stake zipUSD to get it. It earns more, because it takes the first
loss. szipUSD is the protocol's shock absorber: it's the capital that covers a default the moment it
happens so that zipUSD stays a dollar.

## RESI's job (and what it is *not*)

RESI is **not** what backs the dollar — the house backs the dollar. RESI is a **junior-only bonus**:

- **Aligns the originator.** To mint a loan's synthetic lien, the originator posts RESI. It's their
  equity in the deal — slashed if the loan defaults. Skin in the game. (It also sinks supply while the
  loan is live and pulls RESI off the market as lending grows.)
- **Pays the junior.** On default, the slashed RESI is handed in-kind to the locked szipUSD stakers as
  their bonus. RESI is **priced** — that price is what substantiates the bonus APR the junior earns for
  serving the duration. It holds the *insurance-bonus* value, a line separate from the dollar's backing.

We deliberately never sell RESI to defend the peg — its liquidity is thin, and dumping it during a wave
of defaults is the death-spiral we refuse to build. RESI is the alignment-and-bonus token; the real
backstop is the home.

## What happens when a loan defaults

A default is a *timing* problem, not a wipeout — the home is still there. The sequence:

1. **Mark to recovery.** The loan is continuously marked to what the home can actually recover (its
   equity, less a haircut), not written to zero on a clock. The junior (szipUSD) absorbs that markdown
   automatically — the junior *is* whatever's left after the senior dollar's claim, so the loss eats the
   junior first and zipUSD stays $1.
2. **Lock, pro-rata, for a term.** To stop anyone fleeing before the loss resolves, the protocol locks a
   **pro-rata slice of every staker's position** for a fixed term — the same fraction for everyone, sized
   to the amount at risk. You don't pick which loans you're exposed to; if you were staked when it broke,
   a slice of your stake is locked until it clears: "xx% of your position is locked for YY days; it
   resolves with the insurance bonus."
3. **Insurance bonus.** The originator's RESI bond is slashed and handed to the locked stakers in kind
   (never fire-sold). Priced, it's the bonus that pays them for the lock-up.
4. **Recovery.** The protocol pursues the legal lien. When the home sells, the recovery repays the loan,
   the pool's value heals, the junior is made whole, and the lock releases — with the RESI bonus on top.

So the junior earns a **duration premium**: the longer your capital is locked backstopping a recovery,
the more you make — repaid with yield + the RESI bonus when it resolves as a timing problem. If recovery
genuinely falls short of the debt (beyond what RESI covers), the junior takes the residual — that's the
job of first-loss capital. szipUSD is paid to provide instant liquidity against slow legal recovery and
hold the duration until the house pays out.

## Why the senior is safe

- The senior dollar is backed by **real residential equity** (recovered through a real legal lien) and by
  the **junior's capital**, which absorbs any loss first — not by a volatile token.
- The junior (szipUSD) is the residual: it takes the loss in dollars before the senior is touched, so a
  default hits the people paid to take it.
- RESI is a junior bonus, not senior backing — it's never sold to defend the peg.
- A default is a delay, not a wipeout: the home is still there, and recovery flows back to whoever bore
  the loss.

## What you can see

The protocol publishes its solvency in the open: total NAV (the cash plus the recoverable value of the
loans), total zipUSD minted, the zipUSD price vs USDC, the insurance pool's size, and the bonus APR paid
to locked positions. The dollar is fully backed whenever NAV is at least the zipUSD minted — and the
junior plus the home's recovery are what keep it there through defaults.

## Status

This is the plain-language story; the contract-cited mechanics — continuous recovery-aware markdown, the
socialized pro-rata term-lock, RESI pricing, and the EulerEarn-backed dollar — are specified in
[`tokenomics-layer.md`](./tokenomics-layer.md) (loss side) and [`supply-redemption.md`](./supply-redemption.md)
(the dollar + redemption). These are separate specs for clean context, to be synthesized into one pathway.
