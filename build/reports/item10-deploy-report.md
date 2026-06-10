# item-10 deploy — fork-execution report (2026-06-10)

## What this window did
Spun up a local **anvil forking Base mainnet @ block 47096000** and ran the full item-10 deploy/wire orchestrator
against it, end to end. The orchestrator (`script/DeployZipcode.s.sol`) was `forge build`-green but had **never been
executed** — this is its first live run. Result: **ONCHAIN EXECUTION COMPLETE & SUCCESSFUL**, all phases P0..P9.

Driver: `script/DeployLocal.s.sol` — a `DeployZipcode` subclass that provisions the six `(T)` stand-ins and runs the
phases in one team-broadcast. Stand-ins:
- `ZeroIRM`, `MockERC20` (xALPHA mirror), `MockEulerEarn` ×2 (EE pool + base USDC market) — deployed inline.
- live HYDX **ICHI vault** `0x07e72E46C319a6d5aCA28Ad52f5C41a7821989Ad` + **Hydrex gauge**
  `0xAC396CabF5832A49483B78225D902C0999829993` (the matched pair the module fork tests already use) — POL legs.
- principals = anvil deterministic accounts (acct[0]=team/broadcaster, [1]=godOwner, [2]=creOperator, [3]=workflowAuthor,
  [4]=erebor, [5]=capitalSink).

## Run command
```
anvil --fork-url $BASE_RPC_URL --fork-block-number 47096000 &
forge script script/DeployLocal.s.sol:DeployLocal --sig "runLocal()" \
  --rpc-url http://127.0.0.1:8545 --broadcast --slow \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

## Four latent deploy-blocking bugs found + fixed
Each would have reverted the deploy on first execution — exactly what "never fork-executed" hid.

1. **Warehouse adapter stranded under a dead contract.** `CreditWarehouseDeployer` built the `WarehouseAdminModule`
   (a CRE `ReceiverTemplate`, `Ownable(msg.sender)`) so its owner was the throwaway deployer instance; P9 then called
   `setExpectedAuthor`/`transferOwnership` on it as `team` → `OwnableUnauthorizedAccount`. **Fix:** added a
   `receiverAdmin` param; the adapter is handed to the item-10 broadcaster (Safe/Roles still go to godOwner), so P9
   seals + re-homes it to the Timelock uniformly with every other receiver.
2. **Redundant P9 module re-transfer.** Engine modules are cloned in P6 with `owner_ == tl`, and zodiac `Module.setUp`
   runs `_transferOwnership(owner_)`, so they are Timelock-owned from birth. P9's `transferOwnership(tl)` as `team`
   reverted. **Fix:** removed the P9 module-transfer loop.
3. **Queue built before its token.** P4 built `ZipRedemptionQueue` with `address(0)` zipUSD (intending a P3
   `setTokens` re-point), but the queue ctor zero-checks `zipUSD` AND reads `.decimals()`. **Fix:** deploy the zipUSD
   `ESynth` (EVC-only dependency) at the top of P4, before the queue.
4. **Escrow built before its coordinator.** P7 built `LienXAlphaEscrow` with `address(0)` coordinator, but the ctor
   zero-checks it. **Fix:** deploy `DefaultCoordinator` first (its ctor takes no escrow — `setEscrow` closes the
   cycle), then the escrow with the real coordinator.

Plus one **deploy-ordering seam** (handled in the local harness, owed to prod runbook): P5's reservoir `setLTV` makes
EVK call `getQuote` on the CRE-pushed `SzipReservoirLpOracle`, which reverts `PriceOracle_NotSupported` until a mark
exists. `DeployLocal._seedLpMark` seeds an initial $1.00 LP mark by briefly pointing the oracle's forwarder at the
broadcaster. **In production this is a CRE `LP_MARK` push between oracle-create and market-build** — the orchestrator
must guarantee it.

## Post-state verified on the live node (all green)
- `controller.venue() == adapter`; `registry.controller() == controller`
- `navOracle.shareToken() == gate.shareToken() == szipUSD`; `escrow.coordinator() == coordinator`;
  `queue.zipUSD() == ESynth`
- ownership → **Timelock**: controller, registry, adapter, navOracle, lpOracle, rateOracle, coordinator, gate, szip,
  queue, escrow, **warehouse adapter**, and all **9 engine-module proxies**
- ownership → **godOwner**: warehouse Roles modifier + warehouse Safe (by design)
- `lpOracle.getQuote(1e18, ICHI, USDC) == 1e6`; reservoir escrow `asset() == ICHI vault`
- 31 product contracts + stand-ins deployed (97 txs); broadcast at
  `contracts/broadcast/DeployLocal.s.sol/8453/runLocal-latest.json`

## To sanity-check
- The 4 fixes touch the REAL orchestrator (`DeployZipcode.s.sol` + `CreditWarehouseDeployer.sol`), not just the local
  harness — they are production-correctness fixes, not test scaffolding. Affected unit/fork suites
  (WarehouseAdminModule / OffRampModule / ZipRedemptionQueue) re-run **87 passed / 0 failed**.
- `DeployLocal.s.sol` collapses no roles improperly: team and godOwner are distinct accounts; the receiverAdmin path
  is what makes the single team-broadcast complete.

## Holes → resolution
- **EE pool is a `MockEulerEarn`.** A real `createEulerEarn` + curator config (`setIsAllocator(adapter)` / `setCurator`
  / `setFeeRecipient(warehouse.safe)` / `setFee` + point the supply queue at the reservoir borrow vault) is
  origination-time, not deploy-time. Still gates a live **CRE-01** origination trace.
- `DeployZipcode.t.sol`'s three `vm.skip(true)` tests remain skeletons; this run is the missing fork-execution they
  describe. Folding `DeployLocal`'s provisioning into that harness to un-skip them is a natural follow-up.

## Status
item-10 deploy: **fork-executes green.** NEXT (per `PROGRESS.md`) is still **CRE-00** unless the reviewer prioritises
un-skipping `DeployZipcode.t.sol` / the EE-pool curator runbook first.
