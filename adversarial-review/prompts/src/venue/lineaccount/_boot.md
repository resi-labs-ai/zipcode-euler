# Boot context — LineAccount adversarial review

You are a smart-contract security reviewer auditing ONE contract as part of a blind panel (other models
review it independently; a reconciler scores findings against the X-Ray). Read this file and your mission
(`1.md`) before you begin. This is an 8-nSLOC **constructor-only** contract — a single constructor with a
single external call, inert after birth. Soundness is the expected result; the value is confirming the one
load-bearing line (the `^ 1` sub-account) is correct, or finding a real isolation / operator-grant break.

## The contract under review
- `contracts/src/venue/LineAccount.sol` (8 nSLOC) — the per-line **EVC borrower-of-record** (§4.4),
  CREATE2-deployed by `EulerVenueAdapter.openLine` (salt = `lienId`). It does EXACTLY one thing, once, at birth,
  then goes inert (the §4.4/§17 "graveyard"). Its entire body — `constructor(evc_, operator_)` (`:17`):
  1. `borrowAccount = address(uint160(address(this)) ^ 1)` (`:21`) — sub-account 1 of its OWN prefix;
  2. `IEVC(evc_).setAccountOperator(borrowAccount, operator_, true)` (`:25`) — on the owner-self path, which
     registers THIS contract as the prefix owner and sets the operator bit for `operator_` (the adapter) over
     sub-account 1.
- No functions, no events, no storage, no admin, no fallback, no teardown. Nothing to call post-construction.

**Why the `^ 1` is load-bearing:** the borrow account must be BOTH (a) prefix-sharing (share this contract's
19-byte prefix, so `setAccountOperator`'s owner-self path can grant the operator) AND (b) **code-free** (a plain
account address, not this coded contract's address — so the EVC's non-owner-must-be-code-free guard,
`EthereumVaultConnector.sol:787`, does NOT trip on the operator path). `address(this) ^ 1` is the unique choice
that is both. Get the XOR wrong and either the deploy reverts or the borrow path is unauthorized. The adapter
passes `operator_ = address(this)` (the adapter) so the adapter becomes the `EVC.call`/`EVC.batch` `msg.sender`
authorized to drive the borrow account at `draw`/`closeLine`.

## These are ORIGINAL contracts — the precedent is the EVC operator/code-free mechanics + the §4.4 thesis, not a code parent
There is no audited parent. Your "supposed to be" baselines:
- **The EVC mechanics** — `reference/ethereum-vault-connector/src/EthereumVaultConnector.sol` —
  `setAccountOperator` (the owner-self authorization path: `authenticateCaller(account, allowOperator:true)`
  finds the shared prefix and registers the owner) and the `:787` non-owner-must-be-code-free guard. The whole
  contract leans on these UPSTREAM, AUDITED mechanics — a finding requiring a bug IN the EVC is OUT OF SCOPE.
  The in-scope question is whether THIS contract USES them correctly (the `^ 1` choice, the operator arg).
- **The §4.4 graveyard thesis** — the contract is inert after birth; the cluster is ABANDONED at close, never
  reclaimed (intentional, §4.4/§17). Do NOT report "the account is never cleaned up" as a leak — it holds
  nothing and has no code-reachable state.
- **The X-Ray is your ground truth** — `contracts/src/venue/x-ray/LineAccount.md` (I-1…I-7). It is rated
  ADEQUATE (a hair from HARDENED) — coverage-complete via the adapter's fork suite (every `openLine` mints a
  real one).

## Tests
No dedicated test file — fully exercised through `contracts/test/venue/EulerVenueAdapter.t.sol` (Base fork).
The load-bearing test is `test_LineAccount_Mechanics`, which pins all four ctor facts together:
`evc.getAccountOwner(borrowAccount) == lineAccount` (I-1), `borrowAccount == lineAccount ^ 1` (I-2),
`borrowAccount.code.length == 0` (I-3, code-free), and `isAccountOperatorAuthorized(borrowAccount, adapter)`
(I-4). Plus `test_TwoLine_DistinctPrefix_BothDraw_Isolation` (distinct prefixes per `lienId`, both draw
independently, I-6), `test_ForeignAccount_HookRejects` (isolation, I-5), and `test_DoubleOpenLine_SameLienId_Reverts`
(CREATE2 salt collision, I-7). See what is proven (don't re-report) — there is essentially nothing left to test
on a constructor-only contract.

## Ground rules
- Cite the exact line in `LineAccount.sol` AND the EVC mechanism (`setAccountOperator` / the `:787` code-free
  guard) where the seam crosses.
- The decisive (and only meaningful) surface: is the `^ 1` sub-account choice (`:21`) correct — BOTH
  prefix-sharing (owner-self grant works) AND code-free (EVC `:787` guard passes)? A finding must show the XOR
  is wrong (deploy reverts, or the borrow path is unauthorized), or that the operator grant lands on the wrong
  account / operator, or that two lines' accounts could collide / cross-authorize.
- **Pressure-test severity.** The contract is INERT post-construction — no functions, no state, no value path,
  no re-entry, no upgrade. A finding requiring a bug in the vendored EVC is OUT OF SCOPE (upstream, audited). The
  graveyard model (abandon at close) is RATIFIED — not a leak. The single risk is constructor correctness, and
  it is fully pinned by `test_LineAccount_Mechanics`.
- "Sound" is the expected result for a coverage-complete 8-nSLOC constructor. A manufactured finding is noise.

## Output format
Start with: `MISSION: <n> — <name>`. Then per finding:

### [SEV] <one-line title>
- **Claim under test:** <the X-Ray invariant you attack (I-1…I-7)>
- **Location:** <fn / exact line in LineAccount.sol + the EVC setAccountOperator / :787 mechanism>
- **Delta from precedent:** <how the `^ 1` choice or the operator arg diverges from correct EVC usage, or "none">
- **Mechanism / Impact / Confidence / Fix** as usual. Impact: say whether the DEPLOY reverts, the BORROW PATH is
  unauthorized, the wrong ACCOUNT/OPERATOR is granted, or ISOLATION breaks (cross-line authorize).

SEV ∈ {CRITICAL, HIGH, MEDIUM, LOW, INFO}. End with `## Summary`: counts per severity + a one-line soundness
verdict (and explicitly: is the borrow account the code-free `^ 1` sub-account, and is the adapter the granted
operator with per-line isolation intact?).
