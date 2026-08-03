# Mainnet deploy runbook — DeployMainnet (Base 8453)

`DeployMainnet:runMainnet()` runs the full `DeployZipcode` orchestrator (P0..P9) against LIVE Base mainnet,
provisions the two create-time contracts `deploy()` assumes pre-exist (EE pool + USDC market), seeds the LP mark,
and runs the EulerEarn curator config. One team-broadcast. This is irreversible and spends real ETH.

Scripts: `DeployZipcode` = env-driven, assumes stand-ins pre-exist, skips EE config (raw, not for direct mainnet
use). `DeployLocal` = anvil fork only. `DeployMainnet` = THIS, the live-network path.

## 0. RUNMAP — which script, in what order, on which chain

The pieces live on two chains and the ordering between them matters. This is the whole map; each numbered step
links to the section or file that covers it.

| # | Step | Where | Script / doc |
|---|---|---|---|
| 1 | Fork dry-run of the FULL orchestrator | Base fork | `forge test --match-contract DeployMainnetForkTest` |
| 2 | Anvil BROADCAST rehearsal — not just a simulation | anvil fork of Base | §4 |
| 3 | Simulate against live state, no broadcast | Base | §4 |
| 4 | Broadcast the protocol | Base 8453 | §5 — `DeployMainnet:runMainnet()` |
| 5 | Post-deploy wiring (5 manual hookups) | Base | §7 |
| 6 | Deploy the 964 side of the bridge | Subtensor 964 | `bridge/PHASE-B-964-RUNBOOK.md` — ALREADY EXECUTED |
| 7 | Point the rate job at the Base oracle and staging-prove the 964 read | off-chain | `cre/szalpha-rate` |
| 8 | Staging-prove the price leg's 964 EMA + Ethereum Chainlink reads | off-chain | `cre/sharefeeds` |
| 9 | Start the monitor BEFORE pushing test values | off-chain | `cre/szalpha-watch` |
| 10 | Timelock handoff out of god mode, both chains | both | §6 + the 964 runbook step 0 |

Step 1 is new as of 2026-08-03 and replaces "dry-run on anvil" as the cheapest gate: `DeployMainnetForkTest`
runs `runMainnetWith` on a Base fork, creating a REAL EulerEarn pool off the live factory and executing the
curator config, then reads `curator()` and `supplyQueueLength()` back off the pool. Before that existed, these
scripts had only ever had a green `forge build` and every seam assert inside them was unexecuted.
Still stood in for on the fork: the ICHI vault, its gauge, and the LP oracle — the pair is zipUSD/xALPHA and the
script deploys the zipUSD, so a live pool cannot exist yet. Step 2 is where those first meet real addresses.

Step 2 is a separate gate from step 1 and from step 3, and skipping it is how the two bugs found on 2026-08-03
would have reached Base: a missing `rateTwapWindow` in `DeployLocal`/`DeployMainnet`'s own input loaders (each is
separate from `DeployZipcode._loadInputs`, so a field added in one does not appear in the others), and a
gas-estimation failure that only exists under sequential broadcast. Neither shows up in a fork test or a
simulation. Run it as:
```
anvil --fork-url $BASE_RPC_URL --fork-block-number <recent> --port 8545   # in another shell
forge script script/DeployLocal.s.sol:DeployLocal --sig "runLocal()" \
  --rpc-url http://127.0.0.1:8545 --broadcast --slow --gas-estimate-multiplier 300 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```
Expect `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, then read the post-state back rather than trusting it.

Step 9 is ordered before any test traffic deliberately. `szalpha-watch` alarm 5 compares the value that landed on
Base against the 964 source, which must be EQUAL because the job transports the rate unchanged. It is the only
check that catches a transport or scaling fault, and it is worth nothing armed after the traffic it was meant to
watch. Needs `WATCH_SZALPHA`, `WATCH_RATE_ORACLE` and `WATCH_BASE_RPC_URL`.

## 1. What YOU must supply

### Funded broadcaster
- [ ] A deployer EOA private key (`DEPLOYER_PRIVATE_KEY`, or `--account`/`--ledger`) holding enough ETH on Base for
      the full P0..P9 + EE-config gas (rough order: a Timelock, ~20 contracts, ~9 Zodiac module clones, 2 Safes via
      summon, market deploy, EE cap/queue/curator calls — budget generously).
- [ ] That EOA address MUST equal `TEAM_MULTISIG` (the Safe `v==1` pre-validated path requires `msg.sender == owner`).

### Principal addresses (real EOAs you control) — REQUIRED env
- [ ] `TEAM_MULTISIG`   — broadcaster; becomes owner/signer on both summoned Safes
- [ ] `GOD_OWNER`       — transient pre-multisig (warehouse Safe/Roles handoff target)
- [ ] `CRE_OPERATOR`    — engine-module operator + M1 stand-in for the ExitGate window controller & redemption controller
- [ ] `WORKFLOW_AUTHOR` — CRE workflow owner sealed on every ReceiverTemplate (shared deploy wallet)
- [ ] `EREBOR`          — the draw off-ramp
- [ ] `ADMIN_SAFE`    — the protocol treasury Safe (loss-side xALPHA recovery custody, §11)
- [ ] `WORKFLOW_NAME_{CONTROLLER,REVALUATION,COORDINATOR,SHAREFEEDS,WAREHOUSE,RATE}` — CTR-16: the registered daemon NAME per receiver (replaces the dropped `WORKFLOW_ID`). Each non-empty — the identity pre-gate reverts on an empty name. author+name survive workflow redeploys; per-receiver names separate the separate daemons.
- [ ] `SUMMON_SALT_NONCE` — single-use unpredictable nonce (also reused by the sub-deployers)

### Live LP legs (matched ICHI-vault + ALM gauge pair) — REQUIRED env
- [ ] `POL_ICHI_VAULT` — the ICHI vault the farm utility market collateralises. Seam: must equal `escrow.asset()`.
- [ ] `POL_GAUGE`      — MUST be the vault-keyed ALM gauge `Voter.gauges(POL_ICHI_VAULT)`, NOT the per-pool CL gauge
      `Voter.gauges(pool)` (the CL gauge rejects ICHI ALM wrapper shares — reverts 0x87c5d02a).
- DECISION: for M1 this is either the real zipUSD/xALPHA ICHI vault (if created) or a live stand-in pair (DeployLocal
  uses the live WETH/USDC ICHI vault `0x07e7…` + gauge `0x4328…`). Pick one and put it here.

## 2. What the SCRIPT provisions (leave env unset/zero to auto-create)

- `IRM` — a 0%-rate model (`ZeroIRM`). Set `IRM` env to a real IRM to override; or swap one in later via the Timelock.
- `XALPHA_MIRROR` — an M1 ERC20 stand-in (no real Base xALPHA exists pre-bridge). Set env to override.
- `EE_POOL` — a real EulerEarn senior USDC pool off the live factory (owner = team). Set env to reuse an existing one.
- `USDC_RESERVOIR` — a real no-borrow USDC EVK proxy (EE supply-queue head). Set env to reuse.
- EulerEarn curator config runs ONLY when this script created the pool (so it owns it). If you supply your own
  `EE_POOL`, configure its caps/queue/curator yourself.

## 3. Numeric knobs (defaults applied; override via env only if needed)

`VALIDITY_WINDOW=31536000` `NAV_W=3600` `NAV_MAX_AGE=86400`
`TVL_CAP=100000000e18` `RECOVERY_FLOOR=0.5e18` `BORROW_CAP=1000000e6` `BORROW_LTV=8000` `LIQ_LTV=9000`
`BUYBURN_DBPS=100` `BUYBACK_CAP=1000000e18` `RATE_MAX_STALENESS=21600` `RATE_WINDOW=2592000` `RATE_APR_CAP=50000` `RATE_TWAP_WINDOW=86400`
(the three `RATE_*` knobs are `SzAlphaRateOracle` IMMUTABLES — 6h staleness / 30d APR window / 500% cap, the
8x-02 doc+test fixtures; do not lower the window or raise the staleness without re-reading 8x-02's gotchas)
`LP_TWAP_WINDOW=3600` (the fair-LP TWAP window, required non-zero — the LP oracle reads the pool's Algebra
TWAP live; no seed mark. Pre-flight: the pool's plugin must hold ≥ this much history or P5's `setLTV` reverts).

## 4. Pre-flight (do NOT skip)

- [ ] `forge build` green.
- [ ] `forge test --match-contract DeployMainnetForkTest` green. This is the real dry-run: it executes
      `runMainnetWith` on a Base fork with a REAL EulerEarn pool created off the live factory, plus the curator
      config, and asserts the post-state seams. Cheaper and stricter than the anvil route below.
- [ ] Optional, heavier: `DeployLocal:runLocal()` against `anvil --fork-url $BASE_RPC_URL`, if you want a
      persistent local chain to poke at afterwards rather than a test-process fork.
- [ ] `.env` filled with all REQUIRED vars above; broadcaster EOA == `TEAM_MULTISIG` and funded.
- [ ] Simulate WITHOUT `--broadcast` (forge runs the script against a live state read but sends nothing):
      ```
      forge script script/DeployMainnet.s.sol:DeployMainnet --sig "runMainnet()" --rpc-url base
      ```
      Inspect the trace; confirm no revert and the seam asserts pass.

## 5. Broadcast (irreversible)

```
forge script script/DeployMainnet.s.sol:DeployMainnet --sig "runMainnet()" \
  --rpc-url base --broadcast --slow --gas-estimate-multiplier 300 \
  --private-key $DEPLOYER_PRIVATE_KEY
```

(Prefer `--account <keystore>` or `--ledger` over a raw key. `--slow` serialises txs — required for the
summon/Safe-exec ordering.)

⚠️ **`--gas-estimate-multiplier 300` is NOT optional.** Measured on an anvil Base fork 2026-08-03: without it
the run dies mid-deploy on `SzipNavOracle.setJuniorTrancheEngine`, out of gas, `gasUsed == gasLimit` with empty
revert data — which reads like a revert and is not one. Forge estimates each transaction against the SIMULATED
state, where `_checkpointBestEffort()` early-returns; by the time the same call is broadcast sequentially the
accumulator has real work to do and writes an observation, so the true cost exceeds the estimate. Any phase
whose gas grows between simulation and execution has the same shape. Simulation passing tells you nothing about
this — the simulation was green on the run that then failed on-chain.

Leaving a partial deploy behind is the expensive failure here, so buy the buffer.

## 6. Post-deploy posture

- Build-phase per [[oracle-replaceable-timelock-wiring]]: nothing is renounced. Every owned contract is
  `transferOwnership(timelock)`; the 2-day Timelock (deployer = sole proposer/executor, retained admin) governs
  re-pointing. Immutability is DEFERRED to pre-prod.
- `ZipDepositModule` has no ownable surface — its only admin is the immutable deployer (this script). Re-deploy to
  re-home if needed.
- Save the broadcast artifact (`broadcast/DeployMainnet.s.sol/8453/run-latest.json`) — it is the address book of the
  live deployment.

## 7. Post-deploy wiring checklist (the hookups the broadcast does NOT finish)

The broadcast wires most things, but five cross-component hookups are either keeper-side, operator-invoked, or
inherently manual. Do them in this order before the system is live; each notes what the script already did.

1. **Controller ↔ SiloRegistry (before the FIRST origination — else `RegistryUnset`/`NotController`).**
   - Script already did: `siloRegistry.setController(controller)` + `adapter.setController(controller)`.
   - YOU do: `controller.setRegistry(siloRegistry)`; register silo #0 `siloRegistry.addSilo(siloId, SiloConfig{…})`
     (its `adapter` MUST equal the controller's ctor venue seed); then assert
     `siloRegistry.controller() == address(controller)`. (Federation silos: `SiloDeployer` returns the handle; the
     Timelock calls `addSilo` — see `SiloDeployer` NatSpec.)

2. **Redemption queue ↔ off-ramp + keeper signer roles.**
   - Script already did: `queue.setRedeemController(juniorTrancheSafe)`.
   - YOU do: assert the keeper's configured `ZipRedemptionQueue` == `OffRampModule.queue()`, and that the single
     keeper signer is BOTH `OffRampModule.operator()` AND `ZipRedemptionQueue.controller()`.

3. **Buy-burn CRE report socket (only if driving buy-burn via the CRE report path; the operator path works without).**
   - Script does NOT wire this — the `SzipBuyBurnModule` clone ships forwarder-inert (`onReport` reverts
     `InvalidForwarder`, fail-closed).
   - YOU do: `SzipBuyBurnModule.setForwarder(CRE_KEYSTONE_FORWARDER)` + `setExpectedWorkflowId(WORKFLOW_ID)`
     (optionally `setExpectedAuthor`). Mirror the §9 `setExpectedWorkflowId(...) != 0` assert before the Timelock
     hand-off.

4. **Bridge `acceptAdminRole` — both chains (CCT token-admin handoff).**
   - Script (`DeploySzAlphaBridge`) `transferAdminRole`'d to the durable authority (964 → `ccipAdmin`, Base →
     `timelock`) but can't accept mid-broadcast.
   - YOU do: the durable authority calls `ITokenAdminRegistry(tokenAdminRegistry).acceptAdminRole(token)` on each
     chain; verify `getTokenConfig(token).administrator == <durable>`. Until then the deploy Script remains a live
     registry admin — accept promptly.

5. **`ExitGate.setBaal` parity (only if you ever re-point the Baal).**
   - Before any `setBaal`, assert the target Baal's `managerLock() == false` — else the Gate's `manager(2)` grant
     can't be re-set and deposits/`burnFor` brick (fail-closed). Trusted-Timelock action; no code guard.

## 8. 964 bridge leg (DeploySzAlphaBridge) — pre-deploy precompile verification battery

The szALPHA bridge's 964 leg (`DeploySzAlphaBridge:deploy964`) is a SEPARATE broadcast on Bittensor EVM
(chainid 964). Before it, run this read-only cast battery against a 964 RPC (e.g.
`https://lite.chain.opentensor.ai`) with the REGISTERED netuid — it re-proves the precompile unit semantics
the wrapper is built on (verified against SN64; expected output *shapes* below, values vary):

```bash
RPC=https://lite.chain.opentensor.ai; NETUID=<registered netuid>
# 1) Alpha spot price — 18-dp TAO per alpha; MUST be non-zero (e.g. SN64 → 67215024000000000 ≈ 0.067e18)
cast call --rpc-url $RPC 0x0000000000000000000000000000000000000808 "getAlphaPrice(uint16)(uint256)" $NETUID
# 2) 1-TAO swap sim — alpha out, 9-dp; non-zero, ≈ 1e9 * 1e18 / price (SN64 → 14870056727 ≈ 14.87 alpha)
cast call --rpc-url $RPC 0x0000000000000000000000000000000000000808 "simSwapTaoForAlpha(uint16,uint64)(uint256)" $NETUID 1000000000
# 3) 1-alpha reverse sim — TAO out in rao, 9-dp; ≈ price/1e9 minus fee (SN64 → 67181154)
cast call --rpc-url $RPC 0x0000000000000000000000000000000000000808 "simSwapAlphaForTao(uint16,uint64)(uint256)" $NETUID 1000000000
# 4) Size-impact sanity — 1000-TAO sim should be measurably BELOW 1000x the 1-TAO sim (AMM is size-aware)
cast call --rpc-url $RPC 0x0000000000000000000000000000000000000808 "simSwapTaoForAlpha(uint16,uint64)(uint256)" $NETUID 1000000000000
# 5) Validator stake read — alpha 9-dp for (HOTKEY, any coldkey, netuid); shape-check getStake decodes
cast call --rpc-url $RPC 0x0000000000000000000000000000000000000805 "getStake(bytes32,bytes32,uint256)(uint256)" $VALIDATOR_HOTKEY $ANY_COLDKEY $NETUID
```

If any probe reverts or returns zero, STOP — the netuid is wrong, the subnet pool doesn't exist, or the
runtime changed; `deploy964`'s `_assertAlphaPrecompile` would also fail. Unit table + provenance:
`docs/wires/8x-01-szALPHA-bridge.md`, `reference/rubicon/README.md`.

Pre-`deploy964`: fund the deployer with ≥ ~1 TAO. **`deploy964` now seeds the genesis stake in-broadcast**
(seed shares auto-burned to `0xdead`); there is NO manual post-deploy seed step.

Post-`deploy964` (in order; see 8x-01 item-10):
- [ ] Timelock calls `lockBox.acceptOwnership()` (2-step handoff).
- [ ] Timelock calls `pool.acceptOwnership()` — `deployBase` already PROPOSED the pool-ownership handoff
      in-broadcast; only the 2-step accept is manual. Then `setRemoteLane` per direction (ops rate limits).
