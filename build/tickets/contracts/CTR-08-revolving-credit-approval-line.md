# CTR-08 — Structure-2: revolving insurance-underwritten credit lines

> Contract-track change (EXPANSION) — but **smaller than first scoped**: the existing venue already supports
> redraw-on-an-open-line and oracle-mark-driven qualification, so structure 2 is mostly a persistent-token +
> oracle-mark-meaning + don't-auto-close change, NOT a `CREGatingHook` rewrite. Adds a revolving line keyed to a
> BORROWER (not a specific lien) alongside the built repurchase model.
> Spec: `claude-zipcode.md` §4.x (origination/draw) / §4.7 / §17.
> **Decision (session): accommodate BOTH structures; repo is the safe default, this is the revolving option for
> when an insurance policy exists.**

## Why (the seam — and what already works)
Structure 1 (repo): `LienCollateralToken` is one-token-per-lien (`contracts/src/LienCollateralToken.sol:7-9`),
priced by its Proof-of-Value mark (`ZipcodeOracleRegistry`, keyed on token address). Two facts the as-built code
ALREADY gives us, that make revolving cheap:
1. **Redraw on an open line already works.** `ZipcodeController._draw` (`contracts/src/ZipcodeController.sol:215-230`)
   requires only `r.open`, re-seeds the mark, then `fund` + `draw` again. EVK `repay` is permissionless. So
   borrow → repay → redraw cycles on ONE open line TODAY — the only thing that closes a line is an explicit
   `RT_CLOSE` (`:233-249`) which burns the token.
2. **Qualification is already enforceable via the oracle mark + LTV.** A draw's borrow runs the EVK account-status
   check against the per-line router → `ZipcodeOracleRegistry`; a stale or zeroed mark fails the borrow closed
   (`ZipcodeOracleRegistry._getQuote` reverts `TooStale`/`NotSupported`, `:172-178`). So "borrow only while you
   qualify" = the CRE keeps a fresh, positive credit-approval mark; on disqualification it revalues the mark down
   (or lets it lapse) and new borrows fail — repay always allowed. **No `CREGatingHook` change needed.**

So structure 2 = key the line/token/mark to the BORROWER as an approved allocation, redraw via the existing path,
and simply don't `RT_CLOSE` until disqualification.

## Deliverable
1. **A per-borrower credit-approval collateral token** — the `LienCollateralToken.sol` shape (1e18, controller =
   sole authority, `decimals()==18` so it passes the registry's strict-18 guard, `ZipcodeOracleRegistry.sol:146`).
   It represents the borrower's revolving line, NOT a one-shot lien. (Pin: this may be `LienCollateralToken`
   reused verbatim — the "don't burn per repayment" behavior is already just "don't send `RT_CLOSE`"; a distinct
   token is only needed if per-borrower naming/registry differs. Resolve in critics whether a new token is needed
   at all vs reusing the lien token under revolving semantics.)
2. **Oracle mark = the approved allocation.** Reuse `ZipcodeOracleRegistry` unchanged (a blind keyed cache); the
   CRE seeds/revalues the key as the borrower's insured/credit allocation rather than a lien appraisal. NO
   registry change.
3. **A revolving origination/draw mode** — open the line once (existing `RT_ORIGINATION`), then drive redraws via
   the existing `_draw` path; the CRE does NOT issue `RT_CLOSE` on repayment. The line stays open + the slot is
   reused by revolving (not close/reopen). Close+burn only on disqualification/retirement.
4. **(Optional hardening, flag — do NOT build unless required):** a per-account qualification flag on
   `CREGatingHook` for a hard on-chain block independent of mark freshness. Default is mark-driven qualification
   (above) — no hook change.

## Spec §
`claude-zipcode.md` §4.7 (`IZipcodeVenue` carries both structures as opaque `lineRef`s), §4.x, §17.

## Binds to (verified)
- The redraw path: `ZipcodeController._draw` (`contracts/src/ZipcodeController.sol:215-230`) + `RT_DRAW` routing
  (`:40,158-159`).
- The mark-driven qualification: `ZipcodeOracleRegistry.seedPrice`/`_getQuote`/`_writePrice`
  (`contracts/src/ZipcodeOracleRegistry.sol:113,141,166-180`) — strict-18 guard (`:146`), stale fail-closed
  (`:175-178`).
- The token shape: `LienCollateralToken.sol` (`:7-36`).
- The borrow gate that stays unchanged: `CREGatingHook` (`contracts/src/CREGatingHook.sol:107-113`).
- `IZipcodeVenue` (`contracts/src/venue/IZipcodeVenue.sol`) — unchanged seam.

## Starting state
- Structure 1 built + fork-tested. `_draw` redraw-on-open and mark-driven LTV gating exist. CTR-02/03 (registry +
  routing) exist; this composes with CTR-09 (per-draw fee).

## Do NOT
- Do NOT rewrite `CREGatingHook` for qualification — the oracle mark + LTV already enforces it (default path).
- Do NOT change `IZipcodeVenue` — revolving is a mode behind the seam.
- Do NOT change `ZipcodeOracleRegistry` — reuse it with the allocation-mark meaning.
- Do NOT `RT_CLOSE`/burn on repayment (that makes it one-shot) — close only on disqualification.
- Do NOT remove/weaken structure 1 — both coexist (decision: accommodate both).
- Do NOT build the CRE qualification/marking workflow here — that's a CRE-track item; this exposes the on-chain
  surface it drives.

## Key requirements
1. **Revolving reuses one slot/key.** borrow → repay → redraw on the SAME open line, oracle key, and EE slot — a
   test proves redraw with no new market/slot/token/key.
2. **Mark-driven qualification.** A draw succeeds while the mark is fresh+positive; after the CRE revalues it down
   (or it lapses past `validityWindow`), new draws fail closed; repay still works. Test both.
3. **Coexistence.** A repo line (structure 1, closes+burns) and a revolving line (structure 2, persists) open in
   the same EE pool, each one slot.
4. **Bounded keys.** A revolving borrower is ONE persistent oracle key for the line's life (vs n→∞ for repo
   revolves) — document the contrast.
5. **Minimal contract surface.** The ticket resolves whether ANY new contract is needed beyond (optionally) a
   renamed token — if structure 2 is achievable purely by reusing the lien token under revolving semantics + the
   CRE pattern, say so and ship the smaller change.

## Done when (gate — `forge test`, fork)
- `forge build` green; new/updated tests green: borrow→repay→redraw on one open line; mark-revalue-down blocks the
  next draw; lapse-past-window blocks; repo + revolving lines coexist in one pool; one persistent key per revolving
  borrower. If a new token is added, it passes the registry strict-18 guard.
- Cold-build with ZERO load-bearing guesses (incl. the "new token: yes/no" decision resolved).

## Depends on / unblocks
- **Depends on:** CTR-02, CTR-03 (routing); composes with CTR-09 (per-draw fee — revolving maximizes volume).
- **Unblocks:** insurance-backed offerings once a policy exists; the volume-dependent revenue model.
