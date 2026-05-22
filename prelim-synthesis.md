# prelim-synthesis.md — a letter to the next Claude

Hey. You're picking up zipcode-euler. I (the previous Claude) designed this with the user over a long
session and then sent six review sub-agents to tear it apart: one each for *is there a simpler way*,
*is there a better way*, *are the citations real*, *does it cohere*, plus two adversarial deep-dives —
one on the oracle, one comparing every CRE claim to the actual SDK source. This is what they found and
what you should do about it. I'm writing it as their reflections because they were right about more
than I was.

## What we built (so you don't have to reconstruct it)

zipcode-euler is a decentralized **home-equity credit protocol**. A USDC pool (EulerEarn) extends
warehouse credit lines to KYB'd HELOC originators. Each loan mints a **1/1 ERC-20 lien token** as
collateral in an isolated EVK market; the token is priced by a **Chainlink CRE** workflow that fans in
a Bittensor Subnet 46 home appraisal plus identity/title/lien data, push-cached into a single
multi-asset oracle registry. Every sensitive op (open line, price, move pool funds) is gated to a
CRE-driven controller. On top of that we designed a **tokenomics layer** (kept in separate docs):
`zipUSD` (a $1 credit dollar), `szipUSD` (a staked junior tranche), `RESI` as per-lien first-loss bond
+ token sink, and a **pro-rata-haircut-lock** default mechanism where the junior eats the loss now and
the home's legal recovery repays it later.

Five docs hold all this: `vision.md` and `claude-zipcode.md` (base protocol, high-level + technical),
`risk-vision.md` and `tokenomics-layer.md` (the tokenomics layer, same pair), and `todo.md` (V1 build
checklist). The base docs are committed; the tokenomics pair is not yet.

## The good news first (the citation auditor's verdict)

The contract citations are real. The auditor opened every cited `File.sol :: function()`, grepped the
line numbers, and read the bodies. ~38 of ~40 are ACCURATE — EulerEarn `reallocate`/`setIsAllocator`,
GenericFactory `createProxy`, Governance `setLTV`/`setHookConfig`, EulerRouter `govSetConfig`, the EVC
batch/operator surface, ReceiverTemplate `onReport`, and the whole tokenomics reuse set (ESynth, PSM,
EulerSavingsRate, IRMSynth, MarkdownController, USD3 waterfall, MorphoCredit settle, InsuranceFund,
RewardsDistributor) all check out at the cited lines and do what we claimed. The "ERC-7540 is used by
zero reference protocols" claim is verified by exhaustive grep. Trust the docs as a *map of the
reference code*. Three small asterisks: `getRepaymentStatus` is `internal view` (needs a wrapper to read
externally) and its enum says `GracePeriod` not "Grace"; `ReceiverTemplate` gates on a generic
"Forwarder" not a symbol literally named `KeystoneForwarder`; and `IRMBasePremium.sol` was cited without
a path and could not be located — fix or drop that one reference.

So the foundation is honestly grounded. The problems are in the *design*, not in fabricated sources.
That's the right kind of problem to have.

## The single most important thing: honor your own deferral

The "simpler" agent put it best. `todo.md` already scopes V1 to the base loop and defers the entire
tokenomics layer. **Do that.** The risk is that the tokenomics doc is so detailed it creates gravity to
build it early. Don't. V1 acceptance (claude-zipcode.md §11) is the happy-path loop with one originator
and one performing loan: underwrite → mint lien → price → open market → allocate → draw → repay → burn.
None of zipUSD/szipUSD/RESI/haircut-lock is on that path. The hardest, genuinely-novel piece in the
whole project — `HaircutLockAccountant` (the index-based pro-rata-haircut-lock, which even our own doc
admits has "no single reference contract") — is pure default-path machinery. Building unaudited novel
loss-accounting to demo a loan that never defaults is exactly backwards.

Concretely, the simpler agent's recommended V1 surface:
- **3 net-new contracts, not ~10:** `ZipcodeController` (fold the oracle registry into it — both are
  `is ReceiverTemplate`; §13 even asks whether to merge them, so merge them), `CREGatingHook`, and
  `LienCollateralToken`. Keep the lien token (EVK can't take native NFT collateral); defer its
  CREATE2 factory.
- **0 live CRE workflows for the first loop.** Keep `ZipcodeController is ReceiverTemplate` but point
  `s_forwarderAddress` at a trusted operator EOA/multisig for the demo and at the real Forwarder later.
  This needs **no contract change** — it's the cleanest seam in the design. Build the real DON workflow
  as a fast-follow that writes to the same `onReport`.
- **Plain EulerEarn 4626 shares** as the liability side for V1, not the two-token stack.
- **Drop the allocation workflow entirely for V1** — with one market there is nothing to optimize; do
  the single `reallocate` inline in origination.
- Skip perspective verification and `SnapshotRegistry` for a self-governed one-originator demo.
- Use `EdgeFactory` (already cited) instead of hand-wiring the market in todo.md P2.

Every one of these deferrals preserves an *interface*, not just a feature. That's why it's safe: the
trusted operator writes to the same `onReport` the DON will; the plain pool shares get wrapped by
zipUSD/szipUSD later exactly as tokenomics-layer.md §8's merge-map describes. That merge-map is, in
effect, your de-risked upgrade plan.

## The oracle is the scariest part. Take the adversarial agent seriously.

This is where I most underestimated the risk. A 1/1 lien token has **no market, no AMM, no arbitrageur,
no second price source** — the registry IS the price, and EVK consumes it as unconditional ground truth
for borrow solvency AND liquidation (verified: `LiquidityUtils.sol:113-116`, `Liquidation.sol:128-153`).
There is no circuit breaker in that stack. The agent's critical findings, in priority order:

1. **`getQuotes` returns `bid == ask` by default (`BaseAdapter.sol:24-27`), which silently nukes EVK's
   liquidation buffer.** EVK deliberately uses bid for collateral, ask for liability, mid for
   liquidation to build a conservative spread. With bid==ask==mid that conservatism collapses to one
   number. **Cheapest, highest-leverage fix in the whole project:** override `getQuotes` to emit a real
   bid/ask haircut sized for illiquid real estate. Do this.
2. **The "model on RedstoneCoreOracle" instruction is a trap.** It hardcodes `MAX_STALENESS_UPPER_BOUND
   = 5 minutes` (`RedstoneCoreOracle.sol:24,60`). Home prices move on weeks. Inherit it literally and
   every market's `getQuote` reverts 5 minutes after each push — borrow and **liquidation** both DoS.
   So you must write your own staleness window, which means you've thrown away the only guard the
   reference had. Decouple liquidation triggering from per-home price freshness — route it off
   **delinquency status** (`MorphoCredit.getRepaymentStatus`), not just oracle health.
3. **One registry prices all liens with zero content validation.** `onReport` checks the report's
   *signer*, never its *contents* (`ReceiverTemplate.sol:78-120`). One bad/buggy/manipulated report (a
   units bug that 10×'s every price; a compromised controller key) repoints every market in one tx.
   Add **on-chain per-report sanity bounds** in `_processReport`: reject prices that deviate beyond a
   band or sit outside an HPI-derived sanity range; cap per-update magnitude; reject zero and
   `> type(uint208).max` (a zero price hits a free-seize path at `Liquidation.sol:155-163`). Consider
   per-cohort registries so blast radius ≤ one cohort.
4. **`govSetConfig` has no timelock (`EulerRouter.sol:56`)** — the governor key can repoint any lien to
   an attacker oracle in one tx, a total-compromise path that doesn't even need a DON report. Timelock
   the router governor; make the forwarder immutable (never allow `setForwarderAddress(0)`, which the
   contract itself warns turns the oracle into a permissionless faucet).
5. **Decimals.** A multi-asset registry must compute `scale` per lien from each token's actual decimals,
   and `BaseAdapter._getDecimals` silently returns 18 on a failed `decimals()` staticcall — an
   off-by-decimal here is a silent 10× mispricing. Pin `LienCollateralToken` decimals to a constant in
   the factory and fail closed.

The "better" agent independently reached the same place from the design side and added: promote the
Data Streams **regional-HPI sanity bound** from "future swappable adapter" (§7) to a **mandatory P1
requirement** — a per-home AVM with no independent bound is the single most manipulable input in the
system, and Subnet 46's model competition is itself gameable.

## The CRE story has two real bugs and one conflation. Fix before writing workflow code.

The CRE source agent verified the receiver/forwarder/identity gating and the push-cache write path as
solidly real. But:

1. **The determinism fix in §4.2 is conflated and TypeScript-wrong.** Median aggregation reconciles
   divergent *observations* (HTTP fetches), NOT divergent *code paths*. The allocator's `Math.random()`
   won't be saved by median. Worse: the consensus-safe `runtime.Rand()` the CRE docs prescribe is
   **Go-only — there is no equivalent in the TypeScript SDK** (verified against `runtime.ts`). In TS,
   determinism is entirely your burden. So the "better" agent's recommendation becomes mandatory: **drop
   stochastic optimization entirely.** Use a deterministic marginal-APY equalizer (sort markets by
   marginal blended APY, fill to caps/equalization). It's reproducible by construction, no seed, easier
   to audit than annealing-with-a-PRNG. Do not seed from block hash (reorg/proposer-influence risk).
2. **The `writeReport` signature in §4/§6 is wrong.** Real call is `evmClient.writeReport(runtime, {
   receiver, report })` — `runtime` is a required first positional arg we omitted, and `gasConfig` is
   optional. Stubs written from the doc as-is won't compile. (`client_sdk_gen.ts:446`,
   `on-chain-write/index.ts:160`.)
3. **Secrets can't be fetched in node mode.** `getSecret` lives on the DON `Runtime`, not
   `NodeRuntime` (there's a standard test `secrets_fail_in_node_mode` proving it). The PII/proof path
   must keep raw PII out of any consensus observation — only proofs/derived bounds. We *said* we intended
   that; the SDK shape forces it, so architect explicitly.

Minor: batch sizing is bound by the **5M gas/tx** write limit, not just the 5KB report cap, so size
cohorts against gas. "f+1 DON sigs" isn't CRE-documented terminology (they say BFT/honest-majority) —
keep the trust claim, drop the specific threshold. The HTTP trigger is still `1.0.0-alpha`; prefer Cron
for V1.

## The holistic blockers (what actually stops the build)

The coherence agent confirmed the base docs are internally consistent and buildable, the tokenomics
layer's separation is *mostly* clean, and — importantly — most scary unknowns are off-chain/legal and
correctly deferred, not Solidity blockers. But it found one architectural blocker hiding in plain sight:

- **The draw/repay model contradicts the gating hook.** `CREGatingHook` gates `OP_BORROW`/`OP_REPAY` to
  the controller *only* (claude-zipcode.md §3.3), but the originator is described as drawing/repaying a
  revolving line over time. Either every draw needs a fresh DON report, or the gating model needs an
  originator-allowed path. **Decide this before writing P3/P4.** It's the one thing that will bite you
  immediately.

Then the seams to specify before any tokenomics merge (not V1 blockers, but the layer's biggest
undefined plumbing):
- **zipUSD ↔ EulerEarn:** how does USDC deposited for a $1 synth actually fund the EulerEarn pool that
  lends? Is EulerEarn still the pool or does the synth/PSM replace it? This is the layer's biggest
  undefined seam.
- **The on-chain recovery rail:** "report a recoveryAmount" is not "deliver dollars." How recovered USD
  arrives on-chain, against what proof, is the least-specified link — and the entire "default is a
  timing problem, not a loss" thesis depends on it.
- **SPV ↔ Reclaim "lien perfected" proof schema** (open in §13): the collateral premise rests on a proof
  that doesn't exist yet.

And a framing risk worth holding in your head: the "better" and oracle agents both flagged that we
imported 3Jane's **time-linear** markdown (`MarkdownController.calculateMarkdown` writes a loan to zero
over a fixed clock — an *unsecured-credit* decay curve) while our entire thesis is that the home backs
the loan. **Write a recovery-aware markdown** that marks down to expected recovery value (home value ×
lien position × haircut), not to zero-over-time. Reusing an audited contract whose *semantics you've
inverted* is worse than honest new code.

One more from the "better" agent that I think is right: **move zipUSD's fast-exit secondary off RESI and
onto USDC.** We chose zipUSD/RESI because we're RESI-rich and it's cheap to bootstrap, but it makes the
senior dollar's relief valve price against our thinnest, most reflexive token in exactly the stress
scenario the peg needs to hold. The user was firm on zipUSD/RESI; raise it again, because the
reflexivity is real.

## Your punch list, in order

1. Decide the **draw/repay vs gating-hook** model (the one true V1 blocker).
2. Override **`getQuotes` for a real bid/ask spread** (cheapest critical oracle fix).
3. Add **on-chain sanity bounds + zero/overflow guards** in `_processReport`; cap blast radius.
4. **Don't inherit RedstoneCoreOracle's staleness**; design a real window; trigger liquidation off
   delinquency status, not oracle freshness.
5. **Timelock the router governor**; immutable forwarder; mandate the **HPI sanity bound**.
6. Replace the stochastic allocator with a **deterministic equalizer** (TS has no `runtime.Rand()`).
7. Fix the **`writeReport(runtime, {...})` signature** everywhere before writing workflow code.
8. **Build V1 small:** 3 contracts, trusted-operator stub, plain EulerEarn shares, inline allocation.
   Defer the whole tokenomics layer per your own todo.md.
9. Add a one-line "liability side is provisional, see tokenomics-layer.md" flag to the base docs so a
   reader of claude-zipcode.md alone doesn't get the wrong mental model.
10. Pin lien-token decimals; per-lien scale; recovery-aware markdown when you do build the default path.

## Parting thought

The bones are right. The EVK/EVC/EulerEarn reuse is correct, the CRE-as-verifiable-underwriter bet is
the right thesis, the citations are honest, and the docs are unusually candid about their own open
questions. What the six agents collectively show is that the *narrative* got ahead of the *adversarial
detail* — we designed a beautiful loss-tranche-and-recovery story before we'd hardened the one number
that the entire EVK stack trusts unconditionally (the oracle) and before we'd checked that the CRE
determinism story actually holds in the language we're writing in (it doesn't, in TS). Build the spine,
prove the loop with a trusted operator and a hardened oracle, then let the DON and the liability layer
plug into the seams that are already shaped for them. Resist the gravity of the tokenomics doc. It's the
roadmap, not the V1.

Good luck. Be a hardass about the oracle.

— the previous Claude, via six agents who were paid to disagree with me

---

*Reviewers: simpler-way, better-way, citation-audit, holistic-coherence, oracle-adversarial,
cre-source-adversarial. All read the five docs and verified against `reference/` source. Their full
findings informed every claim above; where they cite `File.sol:line`, it was opened and confirmed.*
