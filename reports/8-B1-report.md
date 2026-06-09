# 8-B1 — authoring-window report to the superintendent

**From:** the builder Claude (ticket-authoring harness). **To:** the superintendent.
**Item:** 8-B1 — szipUSD Baal substrate scaffold (summon script) (§4.5 / `baal-spec.md` 8-B1).
**Date:** 2026-06-07. **Branch:** `main`.

## TL;DR
- Authored + **BUILT-VERIFIED** item 8-B1: the szipUSD junior-vault substrate — a summon script against the LIVE
  `BaalAndVaultSummoner` on Base producing Baal + main Safe + non-ragequittable sidecar + Loot/Shares clones.
- Code on disk, `forge test` green: **8/8 fork tests pass on a live Base-mainnet fork; 115/115 total, no
  regression** (`forge test --match-contract SummonSubstrateTest`). Files: `contracts/script/SummonSubstrate.s.sol`,
  `contracts/test/SummonSubstrate.t.sol`, interfaces under `contracts/src/interfaces/{baal,safe}/`.
- **Surfaced + fixed a FOUNDATIONAL spec gap, with the user in-loop:** the baal-spec "post-deploy `setShamans`"
  seam was **un-reachable** (at zero Shares the Baal is governance-inert; the summoner forces the Safe owned 1/1 by
  the Baal → nothing could ever drive it → the substrate would ship frozen). **Decision needs your sanity-check.**
- **NOT git-committed** — see "Git state" below (the whole repo working-tree is untracked).
- **NEXT = `SzipNavOracle`.**

## The spec gap + the ratified resolution (PLEASE sanity-check)
`BaalAndVaultSummoner` → `configureSafe` makes each Safe `setup(owners=[baal],1)` + `enableModule(baal)`. With
**zero Shares** no Baal proposal can be sponsored/passed (`sponsorThreshold` unmeetable; `getVotes==0`), so the only
authority over the Safe is the Baal, which can only act via a (impossible) proposal. The substrate is born frozen —
the Exit Gate could never be granted `manager`, no engine module could be `enableModule`'d.

I raised this with the user mid-window. **Ratified two-tier authority model:**
- **Admin = the team multisig, added as a Safe OWNER/signer** on both Safes (cold, trusted). Governs the module set
  (enable/disable/swap = "change what the CRE can do"), grants the Exit Gate `manager(2)` via `setShamans`, does all
  wiring through the native `Safe.execTransaction` (owner) path.
- **CRE operator = a Zodiac MODULE** the admin enables (hot key, narrow). Enabling a module = full Safe power ⇒ only
  the admin may change the set.
- **Shares stay 0 forever** (authority = Safe ownership, not votes ⇒ governance genuinely inert by design; no
  bootstrap shares).

The team owner is injected **at summon** (the only authority-injection window) via init-action `executeAsBaal(
mainSafe, 0, execTransactionFromModule(mainSafe, 0, addOwnerWithThreshold(team,1), Call))` — `executeAsBaal` calls
AS the Baal so it must route through the Safe's self-authorized owner-management (a direct `addOwnerWithThreshold`
would revert). The sidecar is created after summon, so the team (now a main-Safe owner) adds itself to the sidecar
through the main Safe. **Spec updated:** `claude-zipcode.md §4.5 item-0` + `baal-spec.md 8-B1` (Authority model +
recipe rewritten). I considered the two alternatives I offered the user (bootstrap-shares; CRE-module-via-precompute)
and the user chose the Safe-signer model — it keeps Shares at 0 (true to §17) and needs no proposal machinery.

## What the build proved on a live fork (the keepsake)
Summon shape (avatar==target==mainSafe, distinct sidecar, Loot/Shares clones); Loot+Shares paused (soulbound);
**Shares==0 / Loot==0**; governance inert (`quorum=0`, `sponsor=type(uint256).max`, `offering=0`); both Safes have
Baal enabled + threshold 1; **team owner on BOTH Safes**; sidecar registered in `vaults`. **Wireability (the core
proof):** with zero Shares, the team-admin via `execTransaction` successfully `setShamans([mockGate],[2])` AND
`enableModule(mockModule)` on both Safes. **Negative:** `submitProposal` succeeds but `sponsorProposal`/
`processProposal` revert `!sponsor`; direct `setShamans` reverts `!baal`. Address compute is salt-sensitive +
asserted == `baal.avatar()`.

## Build-discovered correction (code is truth)
The BaalSummoner's Safe proxy factory is **`0xC22834581EbC…`** (verified by reading BaalSummoner storage slot 208 on
Base), NOT the `0xa6B7…` `SAFE_PROXY_FACTORY_1_3_0` in `BaseAddresses`. My first compute used the wrong factory and
the **`compute==avatar` fail-closed assert caught it** (exactly the WOOF-00 lesson applied — a computed-then-verified
address, not a blind hardcode). New constant `BaseAddresses.BAAL_SAFE_PROXY_FACTORY`; `gnosisSingleton` (read live) =
`0x69f4D178…`.

## Critic fanout (5) → folded
junior-dev / spec-fidelity / ref-verifier / qa / security. spec-fidelity = clean PASS (model consistent across both
spec files, no §17 reopened). ref-verifier = PASS (every cited line verified; flagged the `gnosisSafeProxyFactory`
internal-no-getter, handled). Folded: concrete sidecar owner-add via the OWNER `execTransaction` path (was
under-specified); **corrected a false negative test** (qa caught it — `submitProposal` does NOT revert at zero
offering; the dead-end is downstream); before/after sidecar-owner asserts; salt-sensitivity; `vaultIdx` sourcing;
enumerated the interface members; extended the existing `ISafeProxyFactory`/`ISafe` rather than duplicating.

## Security findings → recorded as cross-ticket obligations (your call on timing)
All HIGH findings are about DOWNSTREAM wiring, not 8-B1's substrate (low real exploitability now: the Baal is inert,
`executeAsBaal` is avatar-only). Recorded in PROGRESS obligations:
- **Exit Gate / all manager-holders MUST be unable to call `mintShares`** (`manager` grants both mint paths; any
  Shares mint breaks zero-Shares inertness). Assert `totalShares()==0` in every downstream test. (F4.2)
- **Item 10:** real `TEAM_MULTISIG` must be a k-of-n (k≥2) Safe, not an EOA (threshold-1 delegates all admin security
  to the multisig's own quorum); **remove Baal as a Safe OWNER** post-bootstrap (keep it only as the ragequit
  module); enable the CRE operator **Roles-modifier-v2-scoped** (never bare — the `mockModule` enable is test-only);
  use an **unpredictable single-use `saltNonce`** + private submission (fixed salt is front-run-griefable, fail-closed
  but a cheap grief). (F3.1/F3.2/F5.1/F1.1)
- **Item 9:** gate any sidecar funding on `isOwner(team)==true`. (F6.2)

## Judgment calls
- **Team as a Safe OWNER (signer), not a module** — per the user's "you need a safe that has a signer on it." Uses the
  native Safe multisig flow; the production path is identical, with real m-of-n sigs instead of the test's
  pre-validated single-owner form.
- Kept Baal as a vestigial Safe owner (addOwnerWithThreshold, threshold stays 1) for build simplicity; flagged
  removing it as an item-10 hardening (F3.1) rather than doing it in 8-B1.
- Cosmetic: internal token names `"Zipcode szipUSD Junior"`/`"zJR"` (Loot/Shares are never user-facing — Loot is
  Gate-held, Shares=0). The user share szipUSD is a separate NET-NEW ERC20 the Gate mints (item 3).

## Git state (please decide)
**Nothing in this window is git-committed.** The whole repo working-tree is **untracked** — `git ls-files contracts/`
returns 0 files; `contracts/`, `tickets/`, `reports/`, `baal-spec.md`, `audit/` are all `??`. The prior
"BUILT-VERIFIED … committed under contracts/" claims in PROGRESS are **working-tree only** — git is not tracking the
build. I did NOT commit: it's a large ambiguous action (whole untracked tree) on the default branch `main`, and the
keep-the-build proof is the green `forge test` on disk, not a commit. **Recommend you decide how to bring the repo
under version control** (e.g. an initial commit of the whole build tree, or a `.gitignore` review — note `out/` and
`cache/` should be ignored). Until then the work lives on disk only.

## Status
8-B1 **DONE** (built-verified on disk, not committed). PROGRESS + LEDGER updated; spec gap fixed in
`claude-zipcode.md` + `baal-spec.md`; memory `[[szipusd-safe-authority-model]]` written. **NEXT = `SzipNavOracle`**
(`baal-spec.md §3`).
