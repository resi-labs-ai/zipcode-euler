# zipcode-euler — Working Plan

**Where we are:** design-exploration → synthesis. There is **no V1/V2 staging** — the protocol is one
pathway. The design-review findings are now all worked through and encoded across the specs below (kept as
separate clean docs so context stays unmuddied); the remaining step is to merge them into a single
coherent spec. Code build comes after synthesis.

---

## Doc set (status)
- `vision.md` — plain-language vision. Current.
- `claude-zipcode.md` — base technical spec. Oracle / gating / CRE→Go / flat-IRM updated; supply side
  shown as a stand-in (points to `supply-redemption.md`). Current.
- `supply-redemption.md` — supply side: zipUSD 1:1-mint, szipUSD junior, 30-day epoch redemption. Current.
- `risk-vision.md` — plain-language loss/tokenomics story. Current (loss narrative updated).
- `tokenomics-layer.md` — supply-side parts **superseded** by `supply-redemption.md`; **loss side updated
  to the concluded design** (continuous mark-to-recovery, socialized pro-rata term-lock, RESI in-kind
  bonus + priced, NAV-arithmetic waterfall). Current.
- `spv-lien-proof.md` — the open off-chain issue: the SPV + lien-perfection proof that binds the on-chain
  lien token to a real enforceable lien. Status: open.
- `todo.md` — this working plan.

## Resolved this review (pointers)
- **Draw/repay + gating** — controller is on-chain borrower-of-record on a per-market EVC sub-account;
  report-driven draws; permissionless repay (mask `OP_BORROW|OP_LIQUIDATE`) (claude-zipcode §3.3/§3.4/§6).
- **Oracle** — attestation not market price; honest equity mark + LTV cushion; validity window + 1-day
  heartbeat; timelocked router governor + immutable Forwarder; HPI sanity band (§2/§3.1/§7/§9).
- **CRE** — TypeScript → **Go** (`cre-sdk-go`), all workflow citations updated (§4).
- **Allocator** — not applicable; per-line funding + cash-reserve ratio, no optimizer (§4.2).
- **Collateral granularity** — per-lien singles by default; opt-in bundle when the exit is a bundle (§13).
- **Supply side** — specced in `supply-redemption.md`.
- **Loss side** — concluded and written into `tokenomics-layer.md`: continuous mark-to-recovery markdown,
  socialized pro-rata term-lock, RESI in-kind bonus + priced, NAV-arithmetic waterfall, recovery loop.

## Next moves (in order)
1. **Open design questions** — redemption reserve / draw-contention policy, fixed-% vs dynamic
   (`supply-redemption.md` §9/§11); the term-lock length + recovery-haircut + RESI price source
   (`tokenomics-layer.md` §9); whether a proof-of-operations demo survives as the first integration
   milestone (affects this doc + claude-zipcode §11).
2. **SPV ↔ "lien-perfected" proof schema** — off-chain/legal; the collateral premise rests on it.
   Scoped in `spv-lien-proof.md`; still undefined.
3. **Synthesis pass** — merge the exploration specs into one coherent spec/pathway.

---

## Build phase (after synthesis)
These encode the resolved design and are finalized during synthesis; not started yet.

**Setup**
- [ ] `reference/` in `.gitignore` (read-only reference).
- [ ] Foundry project; EVK/EVC/oracle deps + `remappings.txt` (model `reference/evk-periphery/remappings.txt`).
- [ ] `cre-cli` + a **Go** CRE workspace (compiles to `wasip1`; model `reference/cre-sdk-go/standard_tests`).
- [ ] Base Sepolia RPC + deployer key; chain selector `ethereum-testnet-sepolia-base-1`.

**Contracts (model from cited reference files)**
- [ ] `LienCollateralToken` (1/1 ERC-20) + `LienTokenFactory` (CREATE2, mint/burn = controller, **decimals pinned**).
- [ ] `ZipcodeOracleRegistry` `is ReceiverTemplate, BaseAdapter` — RedstoneCoreOracle *pattern*, home
      validity window (not 5-min), honest equity mark `bid==ask==mid`, `_processReport` guards
      (zero / `>uint208.max` / pinned decimals) + HPI band.
- [ ] `CREGatingHook` `is IHookTarget` — appended caller is EVC `onBehalfOfAccount` (`Base.sol:87,89,132`);
      revert unless controller; repay ungated.
- [ ] `ZipcodeController` `is ReceiverTemplate` — `_processReport` branches
      (origination/draw/revalue/close/default/liquidation); borrower-of-record on per-market sub-account.
- [ ] Supply side (per `supply-redemption.md`): `ZipDepositModule` (1:1 mint), `szipUSD` junior
      (subordination cap/floor), `ZipRedemptionQueue` (fork MIT 7540-ref + clean-room Maple pro-rata).
- [ ] Loss side (per the loss-side spec, once written).

**Wiring / deployment scripts**
- [ ] EulerEarn USDC pool (`EulerEarnFactory`); set `feeRecipient = szipUSD`, `setFee`.
- [ ] Isolated market via `GenericFactory.createProxy` (model `EdgeFactory`); `setInterestRateModel`
      (flat `IRMLinearKink(baseRate,0,0,kink)`), `setHookConfig(gatingHook, OP_BORROW|OP_LIQUIDATE)`,
      `setLTV` (LTV gap = cushion), `setGovernorAdmin(controller)`.
- [ ] EulerRouter governor → **timelock**; route `govSetConfig` through it; **immutable Forwarder**;
      `SnapshotRegistry.add`. Pool: `setIsAllocator(controller, true)`.

**CRE workflows (Go)**
- [ ] Underwriting/revaluation: `http.Trigger` + 1-day `cron.Trigger` → node-mode `http.Client.SendRequest`
      (Subnet46, HPI, proofs) → `RunInNodeMode` + consensus → `GenerateReport` → `WriteReport(runtime, …)`.
- [ ] Redemption settlement: `cron.Trigger` 30-day `settleEpoch()` against EulerEarn freeable USDC.
- [ ] Project/secrets config; DON-only `GetSecret` (no PII in node-mode consensus).

**Integration + demo (framing TBD — see Next moves #2)**
- [ ] Full loop end-to-end on Base Sepolia: underwrite → mint lien → price → open market → fund draw
      (Erebor) → permissionless repay → close → `LienReleased`.

---

## Not yet specced (later parts of the one pathway)
RESI incentive/liquidity-mining module · real Reclaim/EigenLayer + Subnet 46 integration · SPV custody
handoff · perspective-verified markets · structures TWO (P2P) and THREE (tokenized MBS).
