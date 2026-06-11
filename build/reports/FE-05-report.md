# FE-05 report — Borrower line state + permissionless repay (§4 / §4.4e / §9 / §15)

**Window outcome:** built and shipped FE-05 through the adversarial harness. The borrower portfolio's mock draw/repay
path is replaced by **real on-chain line reads + the permissionless EVK repay** against the live Base-fork anvil. Gate
green (`npm run build`), zero load-bearing guesses, committed to the layer repo (`resi-labs-ai`, `b5fdc07`).

## What the window did
- **Back-pressure check first** (the harness §1 inversion — contract is truth). It shaped the ticket:
  - **Draw = CRE-only.** Every `EulerVenueAdapter` mutator (`openLine`/`setLineLimits`/`fund`/`draw`/`closeLine`/
    `liquidate`) is `onlyController` (`EulerVenueAdapter.sol:83`); `ZipcodeController`'s only write is `onReport`
    (Keystone-forwarder-gated) — no public borrower draw/originate. → `ZcDrawModal` rewritten **read-only**.
  - **Repay = native EVK `repay`, permissionless.** Spec §9 (838-839): *"Euler adapter: `EVault.repay` on the line's
    borrow account."* `openLine` never hooks `OP_REPAY` (`:220`). Bind = `usdc.approve(lineRef, amount)` →
    `IEVault(lineRef).repay(amount, borrowAccount)` (direct vault approve, not Permit2 — mirrors the proven
    `ReservoirLoopModule.repay:251-259`). Any wallet repays (credits `borrowAccount`; no controller-enablement).
- Drafted `build/tickets/frontend/FE-05-borrower-line-repay.md`; fanned 4 critic subagents (junior-dev, spec-fidelity,
  reference-verifier, frontend-binding); triaged (all gaps were **ticket-precision** — no spec gap, no back-pressure)
  and pinned them in a "Critic triage" section; cold-built from the ticket alone to a green gate.
- **Shipped (layer repo):** `composables/useZipLine.ts` (new), extended `composables/useZipTx.ts` (`sendRawZipTx` +
  shared `sendBuffered`), `components/zipcode/ZcLinePanel.vue` (new), rewritten `ZcDrawModal.vue` (read-only) +
  `ZcRepayModal.vue` (real approve→repay), `pages/borrower/portfolio.vue` (mock mutations dropped; panel+modals wired),
  `nuxt.config.ts`/`.env.example` (`zipDeployBlock`).

## Decisions to sanity-check
1. **`ZcDrawModal` is read-only** (no borrower draw). This is forced by the contract (draw is `onlyController` + §17
   CRE-driven), but it changes the borrower UX intent vs the original mock ("Draw Funds → bank"). If a future design
   wants a borrower-*requested* draw, that is a CRE-origination request flow (off-chain), not an on-chain UI write —
   out of M1.
2. **No "my lines" filter.** The connected wallet is NOT the borrower-of-record (disposable per-line `LineAccount`,
   §17), so the panel lists the protocol's line(s) and repay is permissionless. For a multi-originator product a
   future originator-scoped view may be wanted, but on-chain there is no wallet↔line link to filter on.
3. **`repay` gained an optional `onPhase('approve'|'repay')` callback** beyond the ticket's `{lineRef,borrowAccount,
   amount,full}` — additive, lets the modal label the two sequential txs without re-implementing the sequence. Benign
   signature addition.
4. **`zipDeployBlock` default `47096000`** (env-overridable) bounds the discovery `getLogs`. A redeploy that moves the
   origination block is repointed via `NUXT_PUBLIC_ZIP_DEPLOY_BLOCK` (not auto-detected).

## Holes → resolution
- **Live repay state-change needs drawn debt (fork-state limit, not a contract gap).** The only line on the post-smoke
  fork is **closed** (`getLine(0x7c48…).open==false`, `observeDebt==0`; the smoke suite ran the full draw→repay→close,
  SP-14/SP-16). So:
  - **Read acceptance: PASS now.** The panel reads the real line live (`equityMark` $100,000, `drawAmount` $50,000,
    owed $0.00, status released); Repay correctly disabled (`owed==0||!open`). Same `view`s I verified via `cast`.
  - **Repay binding: verified.** Real `repay(uint256,address)`/`debtOf`/`asset()==USDC` on the live `lineRef`,
    `borrowAccount` from `getLine`; the approve/repay `encodeFunctionData` + gas-estimate succeed against the contract.
  - **Live repay *state change*: deferred to a drawn line.** Re-run SP-14 origination (CRE-gated, heavy) or have the
    reviewer draw a line, then the modal's approve→repay lands and `observeDebt` drops. No obligation owed — the
    binding is correct; only the fork's current state lacks open debt.
- **Ticket-wording fix:** the ticket originally called `getLine` a "6-tuple, not a named struct" — it IS a named-tuple
  struct (viem returns an object, read by field name). Corrected in the ticket. No spec change.

## Doc edits
- `build/tickets/frontend/FE-05-borrower-line-repay.md` — filed (with the critic-triage + the struct-wording fix).
- `build/tickets/PROGRESS.md` — FE-05 marked done; the FE-05 back-pressure finding + closed-line caveat logged in
  "Open obligations / seams"; the new `sendRawZipTx` seam recorded; **NEXT set to FE-06** (solvency dashboard).
- `build/claude-zipcode.md` — **no change** (§4/§9/§15 already correct; the findings were ticket/state, not spec).

## Status + NEXT
- **FE-05: DONE.** Gate green; reads live-verified; repay binding-verified; committed to the layer repo (`b5fdc07`,
  not pushed). Critics clean (spec-fidelity ALL PASS, reference-verifier all-resolve, frontend-binding back-pressure
  PASS); cold-build zero-guess.
- **NEXT: FE-06** — the §12 solvency dashboard from direct on-chain view reads (NAV / zipUSD supply+peg / szipUSD
  NAV-share+APR / utilization+free-liquidity / coverage), reusing the FE-03 read-view template; pure reads, no
  `useZipTx`. Run the same back-pressure check first (does each §12 metric map to a real deployed `view`?).
- **STOP for review.**
