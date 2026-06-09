# 8-B14 report — `SzipBuyBurnModule` (haircut buy-and-burn, §7)

**Status:** BUILT-VERIFIED 2026-06-08. 33/33 Base-fork, 238/238 total, zero load-bearing guesses. Kept on disk,
NOT git-committed (whole tree untracked). **NEXT = engine 8-B5…8-B13** (`baal-spec §13` order / `§10.8` specs).

## TL;DR
Built the **bid side** of the §7 buy-and-burn: a Zodiac Module on the engine Safe that posts a discounted resting
CoW `BUY szipUSD` order priced off `SzipNavOracle`, capped, and signs it on-chain via PRESIGN. The **burn side** is
the already-built `ExitGate.burnFor` (windowController) — buy and burn are split by *authority* (the burn needs the
Gate's `manager(2)`). This is the **first engine Zodiac Module**, so it sets the `is Module` / `setUp`-under-
`initializer` / `onlyOperator` / `exec(Call)` pattern for 8-B5…B13.

## What the window did
1. Authored `tickets/sodo/8-B14-buy-burn-module.md` from `baal-spec §7` + a verified reference pass (zodiac-core
   `Module`, the CoW SDK swaps helpers, live Base CoW contracts, the kept oracle/Gate/szipUSD faces).
2. Ran a 5-critic fanout (junior / spec-fidelity / ref-verifier / qa / security).
3. Triaged → 3 spec edits to `baal-spec §7` (below) + a comprehensive ticket rewrite.
4. Cold-built from the ticket alone (fresh subagent): zero load-bearing guesses; 33/33 fork tests; 238/238 total.

## Authoritative-doc edits (spec gaps fixed FIRST)
All three in **`reports/baal-spec.md §7.2 / §7.4`** (the build-grade companion; `claude-zipcode §4.5.1` only says "below NAV"
generically, no contradiction, untouched):
1. **Price reference = `navExit = min(spot, twap) × (1 − d)`**, NOT bare `twapNAV`. *Why:* the protocol is a **buyer**
   here — it must mark at the *lower* of spot/twap or it overpays off a stale-high twap when NAV is trending down
   (e.g. just after a `writeProvision` step-down). This is the §3 buyer-conservative bracket (`navEntry=max` for
   issuance, `navExit=min` for paying out). **Sanity-check me:** this is a deliberate divergence from §7.2's literal
   "twapNAV" wording, made on the security critic's argument — I believe it's strictly safer and consistent with §3,
   but flagging it as an economic-direction call.
2. **The burn caller = the CRE `windowController`** via `ExitGate.burnFor` (§7.2 read "the Gate burnLoot" but the
   built `burnFor` is `windowController`-gated; the module never burns).
3. **Dropped "Roles-scoped engine Safe"** — §10.1's plain-Module mandate governs the whole 8-B5…B14 family; the
   module exists to enforce the §7.4 bounds **on-chain**, signing PRESIGN via `Operation.Call`.

## Design decisions to sanity-check
- **Buy/burn split by authority.** The module is bid-only; the burn is `ExitGate.burnFor` (unchanged, kept). I did
  **not** edit the Gate to let the module call `burnFor` (it's windowController-gated). Cleanest + no kept-contract
  edit; the cycle `{postBid → fill → windowController:burnFor}` is a CRE-orchestrated 3-step. Confirm you're happy
  the burn isn't atomic with the buy (it can't be — async CoW fill).
- **Self-hashed uid + `setPreSignature` (Call), not delegatecall to `CowswapOrderSigner`.** The repo's CoW SDK uses
  a delegatecall to the deployed `CowswapOrderSigner`. I chose to replicate the GPv2 hashing in-module and sign via
  `setPreSignature` because (a) §10.1 mandates `Operation.Call` only, (b) it keeps the uid in-contract (emittable /
  testable), (c) it avoids handing the Safe's storage to an external delegatecall. The uid is proven against an
  out-of-band `cast` known-answer vector + the live settlement storing it. Mis-hash fails **closed** (no solver
  matches → liveness only). Trade-off: ~40 lines of canonical GPv2 hashing we own vs reusing the audited signer.
- **Single resting bid, `postBid` reverts `BidAlreadyLive`.** Outstanding signed USDC ≤ `buybackCap` by construction;
  a re-post must `cancelBid` (presig→false, approval→0) then carry a new `validTo`. This closes the partial-fill
  double-fill (stale presignature + refreshed approval) the security critic flagged.
- **Governed params bounded:** `0 < dBps < 10_000` (at setter AND re-asserted at post); `buybackCap == 0` is the
  clean kill-switch; `owner` (Timelock) `!=` `operator` asserted in `setUp`.

## Holes surfaced → resolution
- **`GPv2OrderInput` was undefined** in the first draft (junior critic, blocking) → defined a 3-field struct
  `{sellAmount, buyAmount, validTo}`; every other GPv2 field is a module-fixed constant (incl. a pinned `appData` —
  an unconstrained appData could attach hooks/partner-fees the validation never saw), so the validated struct == the
  hashed struct (no field is both operator-supplied and unvalidated).
- **"Store immutable in `setUp`" is non-compilable for clones** (junior critic) → a `ModuleProxyFactory` clone shares
  the mastercopy bytecode, so `immutable`s carry the mastercopy's construction values, not per-clone `setUp` config.
  Changed all wired addresses/params to **set-once storage** written in `setUp`.
- **Price inequality was off by a factor** in the first draft → rewrote to an exact no-truncation integer form,
  floored against the buyer; tested at the boundary incl. a non-`1e22`-divisible RHS (where rounding bugs hide).
- **Reference edit (governance miss) — YOU FLAGGED IT, corrected mid-window.** The cold-build subagent patched
  `reference/zodiac-core/contracts/core/Module.sol` to add `virtual` so it could override `setAvatar`/`setTarget` to
  revert (the ticket had mandated a hard-lock). **`reference/` is a pristine vendored dep and must never be edited.**
  I reverted it, dropped the hard-lock, and left `setAvatar`/`setTarget` as the inherited `onlyOwner` setters: the
  CRE operator (hot key) can't call them (the real property, now tested via `test_operator_cannot_redirect_safe`),
  and a Timelock redirect is a deliberate governance act (residual accepted). Re-greened with the reference pristine.
  The ticket's Do-NOT now forbids editing `reference/` outright. **Process note for the superintendent:** the
  cold-build subagent should be told reference is read-only; consider a hook.

## Judgment calls
- Picked `MAX_BID_TTL = 1 days`, `MAX_BUY_AMOUNT = 1e30`, `APP_DATA = bytes32(0)` (the ticket offered these as "e.g."
  bounds). All governed/operational, easily changed.
- Did **not** author the `audit/2`/`audit/3` audit-sweep for the buy-bid (an L-step + N-steps) — it's a doc
  deliverable best done in the item-10 / junior-acceptance integration pass when the deploy/wiring is testable
  end-to-end, same as the Exit Gate's audit-sweep deferral. Tracked OPEN in the ticket + PROGRESS.

## Proof (run it yourself)
`cd contracts && set -a && . ./.env && set +a && forge test --fork-url "$BASE_RPC_URL" --match-contract
SzipBuyBurnModuleTest` → 33/33. Full suite `forge test --fork-url "$BASE_RPC_URL"` → 238/238 (was 205 pre-window;
+33). Code: `contracts/src/supply/szipUSD/SzipBuyBurnModule.sol`, `contracts/src/interfaces/cow/IGPv2Settlement.sol`,
`contracts/test/SzipBuyBurnModule.t.sol`; `BaseAddresses.sol` (CoW addrs). `reference/` is pristine (verified
`git status --short` clean in `reference/zodiac-core`).
