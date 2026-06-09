# Borrower-model rework — Step 1 (spec edit) report to the superintendent

**From:** the builder Claude (ticket-authoring harness, disposable window). **To:** the superintendent.
**Item:** the on-chain borrower-of-record rework (demand-side). **Outcome:** window concluded on a **SPEC EDIT**
(no ticket authored — that is Step 2). **Date:** 2026-06-05. **Branch:** `main`.
**Verdict requested:** ratify the resolved borrower model + the one mechanism judgment call (the per-line
`LineAccount` owner contract), confirm Step 2 (re-author 03→04→05) is clear to begin.

## TL;DR
- Replaced the on-chain borrower-of-record model in `claude-zipcode.md`: **OLD** = each line borrows on a distinct
  **EVC sub-account of the one controller address** (256 sub-accounts → hard **255**-line cap; blanket
  `setOperator(prefix, venue, ~uint256(1))`; gate = `haveCommonOwner(caller, controller)`). **NEW** = **a fresh
  EVC borrower account per line** (its own owner-prefix) with the **controller wired as that account's EVC
  operator** → **unbounded, fully disposable per-loan clusters**; the on-chain "graveyard" of dead clusters is
  explicitly accepted.
- **EVC mechanism VERIFIED against the reference — the fresh-account + operator borrow WORKS** (cited below), with
  **one mechanical constraint** that shapes the realization (a per-line owner contract is required — see the
  judgment call). No blocker.
- Edited **§4.3 / §4.4 / §4.7 / §17** (the four sections named) **+ consequence edits in §9 and the §10/M1 trace**
  (they carried stale sub-account/`wireVenueOperator` text). Did **not** touch any LOCKED §17 supply-side decision
  (yield routing / xALPHA / szipUSD freeze / Proof) — the borrower edit is additive and orthogonal.
- Marked WOOF-03/04/05 **RE-AUTHOR PENDING (borrower-model)**, struck the 255-line-ceiling carry, reworked the
  controller/item-10 operator-wiring obligations, confirmed **WOOF-10a survives untouched**. `contracts/` not touched.

## EVC mechanism verification (the load-bearing part — cited against `reference/ethereum-vault-connector/src/EthereumVaultConnector.sol`)
The prompt asked to confirm four things before writing. All confirmed:

**(a) An account can have the controller as an EVC operator without sharing its owner-prefix.** Operator
authorization is stored per the **account's address-prefix** (`operatorLookup[addressPrefix][operator]`,
`setAccountOperator :364-399`, `setOperator :343-359`); it is independent of the controller's own prefix.
`isAccountOperatorAuthorizedInternal :1205-1221` keys the check on the **account's** prefix-owner, returning
`false` for an unregistered prefix (`:1213`). So a fresh prefix can authorize the controller as operator. ✔

**(b) An operator can perform a `borrow` on-behalf of that account.** `EVC.call`/`batch`
(`callWithAuthenticationInternal :882`) authenticates via `authenticateCaller(account, allowOperator: true, …)`
which authorizes the caller when `isAccountOperatorAuthorizedInternal(account, msgSender)` (`:782-784`), then sets
`onBehalfOfAccount = account` for the target call (`callWithContextInternal :847-861`). The EVK reads that as the
borrower (`EVCClient.EVCAuthenticateDeferred :44-49` → `getCurrentOnBehalfOfAccount`), so the **borrow vault
becomes the fresh account's single controller** (single-liability). ✔

**(c) Account-status / collateral checks work for a fresh account.** `enableController`/`enableCollateral`
(`:462-479` / `:416-446`) operate per account and each calls `requireAccountStatusCheck(account)`; nothing
requires the account to be a controller sub-account. ✔

**(d) `isAccountOperatorAuthorized(account, operator)` is the right gating primitive for the hook**
(`:286-288`). It is exactly the predicate "this borrowing account has authorized the controller as its operator",
which is the venue-neutral invariant the hook must enforce now that borrowers no longer share the controller's
prefix. ✔

**THE ONE CONSTRAINT (not a blocker, but it shapes the design — flagging for ratification):** an operator may
only act on-behalf of a **code-free** account — `authenticateCaller :786-789`:
`if (authenticated && owner != account && account.code.length != 0) authenticated = false;`. **And** the fresh
prefix's owner must be **registered** and must **grant** the operator bit (op-auth keyed on the prefix-owner,
`:1213`; the bit is set only by the prefix owner via `setAccountOperator`, owner-self path `:368-377`). A brand-new
prefix has no registered owner and no key the protocol holds. Therefore the borrow account cannot simply be "any
fresh address" — **something at that prefix must interact with the EVC once to register the owner and grant the
operator bit**, and the actual *borrow* account must be **code-free**.

## The resolved model (please sanity-check)
**Per line, the venue adapter (inside `openLine`) CREATE2-deploys a minimal per-line owner contract
(`LineAccount`, salt = `lienId`).** Its deterministic address establishes a **fresh owner-prefix**. On init it
registers its prefix and calls `EVC.setAccountOperator(borrowAccount, controller, true)` (`:364`) for a
**code-free sub-account it owns** (e.g. sub-account 1 of its own prefix — never the contract's own coded address,
which would trip `:787`). That code-free sub-account is the **line's borrow account**: the lien is the collateral
enabled on it; the per-line USDC borrow vault is its controller. The controller then borrows as operator:
`EVC.call(borrowVault, borrowAccount, 0, borrowData)`; the gating hook clears it via
`isAccountOperatorAuthorized(borrowAccount, controller)`.

- **Unbounded lines** — each line is its own prefix, so the 255 cap is gone (the cap was the controller's own
  256-sub-account space).
- **Strictly MORE isolated** than the old blanket grant (the security-engineer lens): **one** operator grant per
  line, over **one** borrow account on its **own** prefix — no shared sub-account space, no blanket
  `setOperator(prefix,…,~uint256(1))`. A buggy/compromised operator grant on one line **cannot** reach another
  line's account (separate prefixes). In the old model the blanket grant + `subId` discipline was the *only*
  isolation boundary and a buggy adapter could cross-collateralize; that whole F-2 surface dissolves.
- **Disposable** — the whole cluster (LineAccount + borrow account + USDC vault + escrow vault + lien token +
  per-line router) is abandoned at close (zero ongoing cost; user-accepted graveyard).

## The §-by-§ edits
- **§4.3 (gating hook).** Gate primitive `haveCommonOwner(caller, controller)` → **`isAccountOperatorAuthorized(caller,
  controller)`** (`:286`), with the rationale (fresh per-line prefix → owner-check is false for every line). Rewrote
  the "caller semantics" bullet: the appended caller is the on-behalf borrow account; it passes only when that
  account authorized the controller as operator.
- **§4.4 (borrower of record).** Replaced the sub-account paragraph with the **fresh per-line account +
  controller-as-operator** mechanism (the `LineAccount` owner-contract, the code-free-account + prefix-owner
  constraints with cited lines, the operator-`call` borrow). Removed the 256/255 cap, the blanket `setOperator`,
  and the F-1 (exclude sub 0) / F-2 (shared-operator-surface) reasoning. Updated the orchestrator-roles paragraph
  (controller = operator of each line's account), the ctor note (no EVC handle; per-line grant at origination), the
  "controller is borrower of record" sentence, and the branch-(a) Euler-realization note.
- **§4.7 (venue).** `openLine` now also **deploys/designates the per-line `LineAccount` + wires the operator grant**
  (one grant per line, at origination); `draw` row → `EVC.call(borrowVault, lineBorrowAccount, 0, borrow)`
  (controller-as-operator); portable-core/adapter table row + the closing borrower-of-record paragraph updated.
- **§17.** Added a new **"Resolved 2026-06-05 (borrower-of-record rework)"** block: (1) fresh per-line account +
  controller-as-operator, unbounded disposable lines, graveyard accepted, 256/255 cap removed; (2) the hook gates on
  `isAccountOperatorAuthorized`. Annotated the now-superseded "Hook gating uses an EVC owner check" line as
  SUPERSEDED. **Did not touch the supply-side resolved block** (yield routing / xALPHA / szipUSD freeze / Proof) —
  stacked on top, as instructed.
- **§9 (consequence).** Removed the controller-level `wireVenueOperator`/blanket `setOperator`-before-renounce step
  (now per-line in `openLine`); updated the origination-trace realization note + the repay note.
- **§10 / M1 trace (consequence).** "draw on the controller's sub-account" → "draw on the line's fresh borrower
  account (controller-as-operator)".

## Design decisions to sanity-check (please rule)
1. **The per-line `LineAccount` owner contract** is the one *mechanism* I introduced (the prompt's model is "a fresh
   account with the controller as operator"; the EVC forces a registered-owner + code-free-account to make that
   work, and a per-line minimal owner contract is the deterministic, key-free way to discharge it). It is faithful
   to the EVC (not invented around it) and is the *minimum* needed. **If the superintendent prefers a different
   discharge** (e.g. a single shared "account-factory" contract that owns one prefix per line via CREATE2-per-line,
   or accepting an off-chain per-line key), that is a Step-2 venue-design choice — but *some* registered, code-free
   per-line account is mechanically mandatory. Flagging because it adds a tiny per-line contract deploy.
2. **Graveyard accepted, no cleanup.** I specced abandon-at-close with zero teardown (per the user's explicit
   acceptance). No `selfdestruct`/reclaim. Confirm that's the intended end state (it is the user's stated preference).
3. **Hook now reads `isAccountOperatorAuthorized` on the appended borrow account.** This is strictly the borrowing
   account's authorization — correct and fail-closed for unregistered prefixes (`:1213`). Confirm this is the gating
   principle you want stated (the WOOF-03 *contract* is re-authored in Step 2).

## Judgment calls
- **Edited §9 + the §10/M1 trace beyond the four named sections** — they carried stale `wireVenueOperator` /
  "sub-account" borrower text that the rework makes wrong; leaving them would contradict §4.4. Faithful consequence
  edits, no decision changed.
- **Left the README WOOF-05 line's "override `setForwarderAddress`→revert"** untouched — it is a *separate*
  known-stale item (the renounce correction), out of this rework's scope; I only fixed borrower-model phrasing in
  README §4 (WOOF-03 hook + WOOF-04 venue).
- **Did NOT reopen any supply-side decision** and did not touch `contracts/`.

## Step-2 re-author plan (dep-order 03 → 04 → 05)
1. **WOOF-03 (`CREGatingHook`)** — re-author first: gate `haveCommonOwner` → `isAccountOperatorAuthorized(caller,
   controller)`; drop the "sub-account 0 only" reasoning; the `isProxy`-guarded caller extraction stays. (The gate
   primitive constrains everything downstream.)
2. **WOOF-04 (`IZipcodeVenue` + `EulerVenueAdapter`)** — `openLine` deploys the per-line `LineAccount` (CREATE2,
   salt=lienId), which registers its prefix + grants `setAccountOperator(borrowAccount, controller, true)` on a
   code-free sub-account; `draw` borrows via `EVC.call(borrowVault, lineBorrowAccount, …)`; retire the `subId`-per-line
   counter (each line is its own prefix now). Per-line vault/escrow/frozen-router design carries forward.
3. **WOOF-05 (`ZipcodeController`)** — remove `wireVenueOperator` / blanket `setOperator` / the EVC ctor parameter;
   the controller takes no EVC handle. The `create→openLine→seed→setLineLimits→fund→draw` ordering + identity/renounce
   gate carry forward unchanged.

**WOOF-10a is independent and untouched.** Item-10's `wireVenueOperator`-before-renounce obligation is removed (the
grant is per-line in `openLine`); its identity/renounce pre-gate (WOOF-10a) is unaffected.

## Status & next
Spec edit filed (§4.3/§4.4/§4.7/§17 + §9/§10 consequence); ledgers updated (PROGRESS + LEDGER + README §4);
`contracts/` untouched (no cold-build this window). **NEXT: Step 2 — re-author WOOF-03 (then 04, then 05) in fresh
windows.**
