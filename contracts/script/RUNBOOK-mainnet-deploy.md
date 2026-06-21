# Mainnet deploy runbook — DeployMainnet (Base 8453)

`DeployMainnet:runMainnet()` runs the full `DeployZipcode` orchestrator (P0..P9) against LIVE Base mainnet,
provisions the two create-time contracts `deploy()` assumes pre-exist (EE pool + USDC market), seeds the LP mark,
and runs the EulerEarn curator config. One team-broadcast. This is irreversible and spends real ETH.

Scripts: `DeployZipcode` = env-driven, assumes stand-ins pre-exist, skips EE config (raw, not for direct mainnet
use). `DeployLocal` = anvil fork only. `DeployMainnet` = THIS, the live-network path.

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

`VALIDITY_WINDOW=31536000` `NAV_W=3600` `NAV_MAX_AGE=86400` `NAV_MAX_DEVIATION_BPS=1000`
`TVL_CAP=100000000e18` `RECOVERY_FLOOR=0.5e18` `BORROW_CAP=1000000e6` `BORROW_LTV=8000` `LIQ_LTV=9000`
`BUYBURN_DBPS=100` `BUYBACK_CAP=1000000e18` `RATE_MAX_STALENESS=21600` `RATE_WINDOW=2592000` `RATE_APR_CAP=50000`
(the three `RATE_*` knobs are `SzAlphaRateOracle` IMMUTABLES — 6h staleness / 30d APR window / 500% cap, the
8x-02 doc+test fixtures; do not lower the window or raise the staleness without re-reading 8x-02's gotchas)
`LP_SEED_MARK=1e6` (6-dp USD per 1e18 LP share — set to the chosen ICHI vault's real per-share value).

## 4. Pre-flight (do NOT skip)

- [ ] `forge build` green.
- [ ] Dry-run the full orchestrator on a Base-mainnet fork first: `DeployLocal:runLocal()` against
      `anvil --fork-url $BASE_RPC_URL`. Confirms P0..P9 + EE config are green against real deps before live gas.
- [ ] `.env` filled with all REQUIRED vars above; broadcaster EOA == `TEAM_MULTISIG` and funded.
- [ ] Simulate WITHOUT `--broadcast` (forge runs the script against a live state read but sends nothing):
      ```
      forge script script/DeployMainnet.s.sol:DeployMainnet --sig "runMainnet()" --rpc-url base
      ```
      Inspect the trace; confirm no revert and the seam asserts pass.

## 5. Broadcast (irreversible)

```
forge script script/DeployMainnet.s.sol:DeployMainnet --sig "runMainnet()" \
  --rpc-url base --broadcast --slow --private-key $DEPLOYER_PRIVATE_KEY
```

(Prefer `--account <keystore>` or `--ledger` over a raw key. `--slow` serialises txs — required for the
summon/Safe-exec ordering.)

## 6. Post-deploy posture

- Build-phase per [[oracle-replaceable-timelock-wiring]]: nothing is renounced. Every owned contract is
  `transferOwnership(timelock)`; the 2-day Timelock (deployer = sole proposer/executor, retained admin) governs
  re-pointing. Immutability is DEFERRED to pre-prod.
- `ZipDepositModule` has no ownable surface — its only admin is the immutable deployer (this script). Re-deploy to
  re-home if needed.
- Save the broadcast artifact (`broadcast/DeployMainnet.s.sol/8453/run-latest.json`) — it is the address book of the
  live deployment.

## 7. 964 bridge leg (DeploySzAlphaBridge) — pre-deploy precompile verification battery

The szALPHA bridge's 964 leg (`DeploySzAlphaBridge:deploy964`) is a SEPARATE broadcast on Bittensor EVM
(chainid 964). Before it, run this read-only cast battery against a 964 RPC (e.g.
`https://lite.chain.opentensor.ai`) with the REGISTERED netuid — it re-proves the precompile unit semantics
the wrapper is built on (verified 2026-06-12 against SN64; expected output *shapes* below, values vary):

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
`build/wires/8x-01-szALPHA-bridge.md`, `reference/rubicon/README.md`.

Post-`deploy964` (in order; see 8x-01 item-10):
- [ ] `seedDeposit{value: ~1 TAO}(token)` — genesis seed; transfer the seed shares to `0xdead`.
- [ ] Timelock calls `lockBox.acceptOwnership()` (2-step handoff).
- [ ] `setRemoteLane` per direction (ops rate limits), then pool `transferOwnership(timelock)` + accept.
