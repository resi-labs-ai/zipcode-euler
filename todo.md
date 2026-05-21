# zipcode-euler — V1 Build Checklist

Scope: the **V1 demo loop only** — one originator, one lien, end-to-end on Base Sepolia with
mocked-but-realistic oracle/proof inputs. See `claude-zipcode.md` for the full technical scope.
Each task names the reference file to model from and a verify check.

---

## P0 — Setup
- [ ] Decide `reference/` git handling: add `reference/` to `.gitignore` (keep as read-only reference) — recommended.
- [ ] Init Foundry project (`forge init`, `foundry.toml`), Solidity `0.8.x`.
- [ ] Add EVK/EVC/oracle deps as libs + `remappings.txt` (model on `reference/evk-periphery/remappings.txt`).
- [ ] Install `cre-cli`; scaffold a CRE TS workspace (model on `reference/cre-templates`).
- [ ] Configure Base Sepolia RPC + deployer key; confirm chain selector (`ethereum-testnet-sepolia-base-1`).
- [ ] Verify: `forge build` clean; `cre --version` works.

## P1 — Contracts (model from cited reference files)
- [ ] `LienCollateralToken` (1/1 ERC-20) + `LienTokenFactory` (CREATE2, mint/burn = controller only).
      _Verify:_ unit test mint/burn auth + deterministic address.
- [ ] `ZipcodeOracleRegistry` `is ReceiverTemplate, BaseAdapter` — model on
      `reference/euler-price-oracle/src/adapter/redstone/RedstoneCoreOracle.sol`. Batch `_processReport`,
      stale-checked `_getQuote`, `ScaleUtils`.
      _Verify:_ test getQuote returns scaled price; reverts when stale.
- [ ] `CREGatingHook` `is IHookTarget` — model on `reference/evk-periphery/src/HookTarget/BaseHookTarget.sol`.
      Extract appended caller; revert unless controller.
      _Verify:_ test borrow reverts for non-controller, passes for controller.
- [ ] `ZipcodeController` `is ReceiverTemplate` — `_processReport` branches (origination/revalue/close/default).
      _Verify:_ test each branch with a crafted report; KeystoneForwarder gate.

## P2 — Wiring / deployment scripts
- [ ] Deploy EulerEarn USDC pool (`reference/euler-earn/src/EulerEarnFactory.sol`).
- [ ] Deploy isolated market via `GenericFactory.createProxy(USDC, EulerRouter, USDC)`
      (model on `reference/evk-periphery/src/EdgeFactory/EdgeFactory.sol`).
- [ ] Configure market: `setInterestRateModel`, `setHookConfig(gatingHook, OP_BORROW|OP_REPAY|OP_LIQUIDATE)`,
      `setLTV(lien, …)`, `setGovernorAdmin(controller)`.
- [ ] Oracle: `EulerRouter.govSetConfig(lien, USDC, registry)`; `SnapshotRegistry.add(registry, lien, USDC)`.
- [ ] Pool: `EulerEarn.setIsAllocator(controller, true)`; (optional) `EVC.setAccountOperator`.
      _Verify:_ Foundry fork/integration test asserts all roles + configs set.

## P3 — CRE workflows
- [ ] Underwriting workflow: HTTP trigger → mocked Reclaim/Subnet46 inputs → `consensusMedianAggregation`
      → `runtime.report` → `writeReport({receiver: ZipcodeController})` (model on
      `reference/x402-cre-price-alerts/cre/alerts`).
- [ ] Allocation workflow: cron → `callContract` reads → ported objective from `reference/euler-allocator-bot`
      with **deterministic RNG** → report → `reallocate`.
- [ ] `workflow.yaml` / `project.yaml` / `config.json` for Base Sepolia; secrets via `secrets.yaml`.
      _Verify:_ local simulation produces a valid report; testnet deploy via `cre workflow deploy`.

## P4 — Integration (end-to-end on Base Sepolia)
- [ ] Drive full loop: underwrite → mint lien token → price via registry → open market →
      allocate pool USDC → originator draws → repay → burn → `LienReleased`.
      _Verify:_ assert each tx + event; collateral priced; line opened/closed; lien released.

## P5 — Demo harness + fundraising doc
- [ ] Scripted/recorded walkthrough of the loop with mocked inputs.
- [ ] Short README mapping the demo to `vision.md` / `claude-zipcode.md`.
      _Verify:_ a non-author can run the demo from the README.

---

## Deferred (post-V1, tracked in `claude-zipcode.md` §13)
- Senior/junior tranching · RESI incentive module · real Reclaim/EigenLayer + Subnet 46 integration ·
  SPV custody handoff · perspective-verified markets · structures TWO (P2P) and THREE (tokenized MBS).
