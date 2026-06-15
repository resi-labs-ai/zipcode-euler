# SEC-03 — CCIP token-admin handoff (H4)

**Track:** SEC (auditor-prep) · **Source docs:** `build/kill-list.md` H4 (escalated DECIDE→FIX, HIGH);
audit `role-based-findings.md`, `reference-diff-findings.md`; `reference/chainlink-ccip/.../tokenAdminRegistry/TokenAdminRegistry.sol` ·
**Status:** PROPOSED

> Scope authored 2026-06-15. Pass-2 escalated this to HIGH: the CCIP admin loss is **guaranteed on every
> deploy, both chains** — not an interruption-window risk. The "atomic deploy + runbook" option is NOT
> viable (the durable admin cannot `acceptAdminRole` inside the script broadcast); the real fix is a
> 2-step `transferAdminRole` + a runbook `acceptAdminRole`.

## Deliverable
Hand the **registry administrator** role for the szALPHA token to the durable authority (964 → `ccipAdmin`,
Base → `timelock`) via `transferAdminRole`, document the unavoidable 2-step `acceptAdminRole` runbook step,
and assert `pendingAdministrator` is the durable authority (not the throwaway deploy script).

## What it does / what's being fixed (plain language)
A CCIP token's pool wiring (`setPool` to re-point / delist the bridge pool) can only be changed by the
token's **registry administrator** in `TokenAdminRegistry`. During deploy, the script registers itself and
calls `acceptAdminRole`, so the **script** becomes that administrator. The follow-up `setCCIPAdmin(...)`
only mutates the token's `getCCIPAdmin()` view — which the registry already consumed at registration and
never re-reads — so the registry's `administrator` slot stays pinned to the **ephemeral deploy script**.
After deploy nobody can ever re-point or delist the pool (RMN/CCIP upgrades, incident response). The `:131`
`getCCIPAdmin == ccipAdmin` assert gives false confidence — it checks the wrong slot.

## Binds to (verified file:line — 2026-06-15)
- **Bug evidence:** `contracts/script/DeploySzAlphaBridge.s.sol`
  - `deploy964`: `acceptAdminRole(token)` `:121` (script becomes registry admin) → `setPool` `:122` →
    `setCCIPAdmin(ccipAdmin)` `:126` (token-view only) → assert `getCCIPAdmin()==ccipAdmin` `:131` (false confidence).
  - `deployBase`: `acceptAdminRole(token)` `:154` → `setPool` `:155` → `setCCIPAdmin(timelock)` `:162` (token-view only).
- **Interface to extend:** `contracts/src/interfaces/bridge/ICctRegistry.sol` — `ITokenAdminRegistry` (`:18-27`)
  currently exposes only `acceptAdminRole` / `setPool` / `getPool`.
- **Reference truth (verified):** `reference/chainlink-ccip/chains/evm/contracts/tokenAdminRegistry/TokenAdminRegistry.sol`
  - `transferAdminRole(address localToken, address newAdmin)` `:141-149` — `onlyTokenAdmin`, sets
    `config.pendingAdministrator = newAdmin` (2-step; the new admin must `acceptAdminRole`).
  - `getTokenConfig(address) returns (TokenConfig{address administrator; address pendingAdministrator; address tokenPool;})` `:73-77`, struct `:34-38`.

## Key requirements
1. **Extend `ICctRegistry.ITokenAdminRegistry`:** add
   `function transferAdminRole(address localToken, address newAdmin) external;` and a read for the assert —
   either `struct TokenConfig {address administrator; address pendingAdministrator; address tokenPool;}` +
   `function getTokenConfig(address token) external view returns (TokenConfig memory);` (mirror the reference
   names exactly). Keep the existing selectors. Update the file's header note (it documents which selectors are used).
2. **`deploy964`:** after `setPool` (`:122`), call
   `ITokenAdminRegistry(cfg.tokenAdminRegistry).transferAdminRole(address(token), ccipAdmin);` — hand the
   registry admin to the SAME durable target the existing `setCCIPAdmin(ccipAdmin)` intends. Keep
   `setCCIPAdmin(ccipAdmin)` (keeps `getCCIPAdmin()` aligned for any future re-registration).
3. **`deployBase`:** after `setPool` (`:155`), call `transferAdminRole(address(token), timelock)`. Keep
   `setCCIPAdmin(timelock)` (`:162`).
4. **Replace the false-confidence assert.** Change `deploy964`'s `:131` (and add the analogue to `deployBase`)
   to assert `getTokenConfig(address(token)).pendingAdministrator == <durable admin>` (964 → `ccipAdmin`,
   Base → `timelock`). NOTE: `administrator` is still the script until the runbook accept lands, so assert
   **pendingAdministrator**, per the kill-list.
5. **Runbook.** Document (in the function NatDoc + the report) the unavoidable post-deploy step: the durable
   admin (`ccipAdmin` on 964, `timelock` on Base) must call
   `ITokenAdminRegistry(tokenAdminRegistry).acceptAdminRole(token)` to finalize the 2-step. Until then the
   script remains a live admin — flag this as the one residual interruption window (mitigated by accepting promptly).

## Do NOT
- Do NOT try to `acceptAdminRole` on the durable admin's behalf inside the broadcast — not viable (the
  timelock/ccipAdmin can't sign mid-script). The 2-step + runbook is the accepted resolution.
- Do NOT remove `setCCIPAdmin` — `getCCIPAdmin()` is read by `registerAdminViaGetCCIPAdmin` for any future
  re-registration; keep it aligned to the durable admin.
- Do NOT assert `administrator == durable` at deploy time (it isn't, pre-accept) — assert `pendingAdministrator`.
- Do NOT widen scope to other kill-list groups.

## Done when
- `cd contracts && forge build` clean (interface + script compile).
- `forge test` green, **plus a new `SEC03_*` regression test** in `test/bridge/` that fails before / passes after:
  - Add a small **mock `TokenAdminRegistry`** to `test/bridge/BridgeMocks.sol` (no mock registry exists today)
    that records `administrator` / `pendingAdministrator`, enforces `onlyTokenAdmin` on `transferAdminRole`/`setPool`,
    and implements `registerAdminViaGetCCIPAdmin` / `acceptAdminRole` / `getTokenConfig` against the reference
    semantics, plus a mock `RegistryModuleOwnerCustom`.
  - Drive `deploy964` (and `deployBase`) against the mocks; assert **post-deploy**:
    `getTokenConfig(token).administrator == address(deployScript)` (still, pre-accept) AND
    `getTokenConfig(token).pendingAdministrator == ccipAdmin` (964) / `== timelock` (Base).
  - **Pre-fix assertion** (proves the bug): without the fix, `pendingAdministrator == address(0)` and the
    script stays the sole `administrator` — the test's pending-admin assert fails.
  - **Runbook finalize:** `vm.prank(ccipAdmin/timelock); registry.acceptAdminRole(token);` then assert
    `administrator == <durable>` and the script is no longer admin (a script-side `setPool` reverts `onlyTokenAdmin`).
- Quote the actual `forge test` output in this ticket's done note.

> Deploy-script note: the real CCT infra (router/RMN/registry) is not on the local anvil Base fork, so the
> driver's "re-run deploy against a fresh fork" is satisfied by the mock-registry forge test above, not a
> live fork deploy.

## Depends on
- None. On land: `PROGRESS.md` "Just done — SEC-03" with the finding note + the standing runbook obligation
  (durable admin must `acceptAdminRole` post-deploy).
