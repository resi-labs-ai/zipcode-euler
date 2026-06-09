# xalpha-bridge-impl.md — Implementation spec: xALPHA wrapper + CCT bridge (canonical vs fork)

> **What this builds:** the **xALPHA liquid-staking wrapper** over Bittensor subnet alpha and its **CCIP
> cross-chain transport** (Bittensor mainnet chain **964** ↔ Base **8453**), as either (a) **canonical Project
> Rubicon xALPHA** (zero contract work) or (b) a **self-built fork (`szALPHA`)** over public precompiles + a
> self-serve CCT pool. This doc is **implementation only**: contracts, precompile addresses, ABIs, lanes, build
> sequence. The choice between canonical and fork is technical-cost framing here; the **economic rationale**
> (closed loop, POL, incentive budget, peg arb, risk knobs) lives in **`pending-docs/treasury.md`** — read that to *decide*,
> this to *build*.
> Conclusion up front: there is **no technical moat** in Rubicon — the bridge runs on a public CCIP chain
> (964) and the wrapper is a thin layer over **public Subtensor precompiles**. A fork is buildable.
> Status: **implementation-ready**, with **one open verification item** (CCT registration permission on 964, §4).
> Refs: `claude-zipcode.md` (supply zap, szipUSD), `claude-zipcode.md` §11 (exit throttle), `pending-docs/treasury.md` (economics),
> `bridge/xALPHA-apr.md` (CRE workflow reading these precompiles to compute rewards APR).
> Memory: [[zipcode-subnet-role]] (own validator), [[rubicon-fork-and-closed-loop]] (memory predates this file's rename from `rubicon-fork-and-closed-loop.md`).

## 1. What Project Rubicon is, decomposed (the reproducibility analysis)

A non-custodial liquid-staking wrapper for Bittensor subnet alpha, by General TAO Ventures (GTV) with
Chainlink/Base/Aerodrome. It mints a yield-bearing receipt token (**xAlpha**, per-subnet: xSN8, xSN35, …)
against staked alpha and bridges it to Base via CCIP. Decomposed, it is four parts — three commodity, one not:

| Component | What it is | Reproducible by us? |
|---|---|---|
| **LST wrapper** (`LiquidStakedV3` + `Blake2b` + interface contracts) | ERC-20 + exchange-rate accounting + fee logic gluing the **public** Subtensor precompiles. cToken/wstETH pattern applied to alpha stake. | **Yes** — public precompiles, ~few hundred lines. |
| **CCIP transport** | Chainlink CCIP. With the **CCT (Cross-Chain Token) standard**, the token issuer self-deploys its own token pool. | **Yes** — self-serve, no Rubicon dependency. |
| **UI** | Stake / redeem / bridge front end. | **Yes.** |
| **"Canonical" position** | GTV+Chainlink+Base+Aerodrome partnership, cohort liquidity, "Lido of Bittensor" brand. | **No** — relationship/network-effect asset, not code. **Out of scope here** (commercial; see `pending-docs/treasury.md`). |

**There is no proprietary infrastructure.** Parts 1–3 are public-precompile glue. The only non-reproducible
asset is part 4 (brand + seeded liquidity), which is a go-to-market program, not a protocol dependency — and
therefore not a build concern.

## 2. Verified facts (the build basis)

- **Wrapper contracts** (Hashlock audit, Oct 2025): `Blake2b.sol` (EVM address → SS58 pubkey),
  `LiquidStakedV2/V3.sol` (mint/redeem/yield), `MetaGraphInterface.sol`, `StakingV2Interface.sol`,
  `BalanceTransfer.sol`, `Constants.sol`. V3 is UUPS-upgradeable; fees accrue as alpha (not minted as LSA).
- **Mint/redeem has no pool dependency.** xAlpha exchange rate = `staked alpha balance ÷ xAlpha supply`,
  read from the validator stake, **not** from any DEX. No oracle, no pool price in the mint/redeem path.
  → an xAlpha/USDC pool is **never required** by the protocol; it exists only as GTV's launch seeding.
- **Validator is configurable.** `NETUID` and `VALIDATOR_UID` are set at construction (V2, immutable
  thereafter); V3 allows changing the delegate via timelocked "Community Representative Management." We point
  it at **our own validator on our own subnet** ([[zipcode-subnet-role]]).
- **Public Subtensor precompiles** (opentensor, documented): `StakingPrecompileV2` at **0x805**
  (addStake/removeStake/moveStake/getStake), metagraph precompile, address-conversion. Reference Solidity in
  `opentensor/evm-bittensor`. → the wrapper's "hard part" is public.
- **Bittensor is an onboarded CCIP chain** (`smartcontractkit/chain-selectors`, `selectors.yml`):
  - Bittensor **mainnet** — EVM chain id **964**, CCIP selector **2135107236357186872**.
  - Bittensor **testnet** — chain id 945, selector 2177900824115119161.
  - Base mainnet — chain id 8453. The Base↔Bittensor lane is between two first-class CCIP chains, and is
    live in production (Rubicon bridges it today). Chain selectors are **network-wide, not project-scoped** —
    the lane is not GTV-exclusive.
- **No native unbonding in dTAO.** Unstaking alpha is immediate, priced through the subnet TAO/alpha AMM —
  cost is **slippage, not time**. There is **no redemption queue** at the Bittensor layer. Optional
  `lock_stake` imposes ~365-day exponential-decay unlock if stickiness is wanted (policy decision → `pending-docs/treasury.md`).

## 3. Two build paths: canonical vs fork (technical deltas)

The path choice is *decided* on economic grounds in `pending-docs/treasury.md`. Its **build consequences** are:

| | **Canonical xAlpha** | **Fork (`szALPHA`)** |
|---|---|---|
| Wrapper contracts | None — use audited, deployed Rubicon wrapper | Write fresh over public precompiles (§6); own audit |
| CCT bridge | None — GTV/Chainlink operate the lane config | Self-deploy `BurnMintTokenPool`, register on 964↔8453, own rate-limit ops |
| Validator target | Set delegate to our validator via timelocked Community Rep Mgmt (V3) | Set `NETUID`/`VALIDATOR_UID` to ours at construction |
| Audit/upgrade burden | None (theirs) | Ours — UUPS upgradeability + owner controls are the trust surface; govern with timelocks |
| Build cost | **~zero contract work** | Wrapper rewrite + CCT pool deployment (not novel infra) |

**Redeem path is mandatory in either build.** Forking can lock the *swap* exit (venue control) but **not** the
*redeem* exit: the wrapper must always support `redeem → unstake → bridge → subnet AMM`, because the token's
value is anchored to NAV redeemability. Build the wrapper so redeem-to-alpha is always callable; the economic
throttling of that exit (duration lock) is configured separately (`claude-zipcode.md` §11, `pending-docs/treasury.md`).

## 4. Open technical gate: CCT registration on chain 964

**Blocks full self-issued `szALPHA` only.** New CCIP chains sometimes launch with the token-admin-registry
**allowlisted** before full self-serve. Confirm whether CCT pool registration on Bittensor mainnet is open or
still gated — ping Chainlink, or attempt a testnet CCT registration on chain **945**. This is a temporary
onboarding gate, **not** a moat. (The commercial gate — GTV pairing terms — is a `pending-docs/treasury.md` concern.)

## 5. Build sequence

1. **Prototype on canonical xAlpha** — validate the rewards-validator delegate, the bridge, and end-to-end
   mint/redeem with **zero contract work**. (Economic mechanics it unblocks: see `pending-docs/treasury.md`.)
2. **Resolve the CCT gate (§4)** in parallel — Chainlink CCT permission on 964 (testnet on 945 first).
3. **Fork to `szALPHA`** once committed to structural control. Fork = wrapper rewrite over public precompiles +
   self-serve CCT pool (964 ↔ 8453). The *trigger* for forking is economic (closed-loop control); the *work* is
   below.

## 6. Build map — everything needed, keyed to `reference/` repos

All source for a clean-room `szALPHA` fork is cloned locally. Rubicon's own wrapper is **not public** (supplied
to Hashlock via private repo), so we build over the public precompiles below — not a copy of Rubicon.

### 6.1 Precompile addresses (authoritative, from `reference/subtensor/precompiles/src/*.rs`)

`INDEX` in the Rust impl is the decimal EVM address; hex shown is what the wrapper calls.

| Precompile | INDEX | Address | Rust impl | Solidity ABI (`subtensor/precompiles/src/solidity/`) | Used for |
|---|---|---|---|---|---|
| **StakingV2** | 2053 | **0x805** | `staking.rs` | `stakingV2.sol` | addStake/removeStake/moveStake/getStake — **mint, redeem, rewards-validator** |
| Staking (legacy) | 2049 | 0x801 | `staking.rs` | `staking.sol` | older staking ABI (prefer V2) |
| **Metagraph** | 2050 | **0x802** | `metagraph.rs` | `metagraph.sol` | subnet/validator state reads |
| **BalanceTransfer** | 2048 | **0x800** | `balance_transfer.rs` | `balanceTransfer.sol` | move TAO EVM↔substrate |
| **AddressMapping** | 2060 | **0x80c** | `address_mapping.rs` | `addressMapping.sol` | EVM addr → SS58 (replaces on-chain Blake2b in V3) |
| Neuron | 2052 | 0x804 | `neuron.rs` | `neuron.sol` | neuron/hotkey ops |
| Subnet | 2051 | 0x803 | `subnet.rs` | `subnet.sol` | subnet params |
| Alpha | 2056 | 0x808 | `alpha.rs` | — | alpha-specific ops |
| Ed25519Verify | 1026 | 0x402 | `ed25519.rs` | `ed25519Verify.sol` | signature verify |

### 6.2 Component → where to build it

| System piece | Source in `reference/` | Notes |
|---|---|---|
| **Wrapper: mint/redeem/yield** (the `LiquidStakedV3` equivalent) | Write fresh; call **StakingV2 `0x805`** per `subtensor/precompiles/src/solidity/stakingV2.sol`. Pattern examples in `evm-bittensor/solidity/stakeV2.sol`. | Exchange-rate accounting (`alpha balance ÷ supply`) is our own code — no pool/oracle dependency (§2). |
| **Rewards-validator staking** | Same StakingV2 `0x805` (`addStake`/`moveStake`); optional `lock_stake` policy | Point `VALIDATOR_UID`/`NETUID` at our own subnet+hotkey. Lock policy decided in `pending-docs/treasury.md`. |
| **EVM→SS58 address derivation** | **AddressMapping `0x80c`** (`addressMapping.sol`) | V3 dropped on-chain Blake2b in favor of this precompile — use it, don't reimplement Blake2b. |
| **TAO EVM↔substrate movement** | **BalanceTransfer `0x800`** (`balanceTransfer.sol`) | |
| **Subnet/validator reads** (NAV checks, weights) | **Metagraph `0x802`** (`metagraph.sol`) | |
| **CCT bridge: token + pool** (`szALPHA` cross-chain) | `chainlink-ccip/chains/evm/contracts/pools/` → inherit `TokenPool.sol`, `BurnMintTokenPool.sol` (or `LockReleaseTokenPool.sol`) | Burn/mint pool is the usual CCT pattern for a mint-controlled token. |
| **Bridge deployment + lane wiring** | `ccip-starter-kit-foundry/` → `test/fork/CCIPv1_5BurnMintPoolFork.t.sol`, `CCIPv1_5LockReleasePoolFork.t.sol` | End-to-end CCT register/configure/rate-limit patterns. |
| **Chain ids / selectors** | `chain-selectors/selectors.yml` | Bittensor mainnet chainid **964** / selector **2135107236357186872**; Base mainnet **8453**. |
| **Local CCIP testing** | `chainlink-local/src/ccip/CCIPLocalSimulator(Fork).sol` | Simulate Base↔Bittensor message passing without testnet. |
| **CCIP offchain (reference only)** | `chainlink/` (Go) | DON/plugin internals; not needed to build, useful to read. |

### 6.3 Minimum build path

1. **Wrapper** over `0x805` + `0x80c` + `0x800` (subtensor Solidity ABIs) → mint/redeem/yield for `szALPHA`,
   pointed at our validator. Test against a Subtensor EVM node.
2. **CCT pool** (`BurnMintTokenPool` from `chainlink-ccip`) → register `szALPHA` on the 964↔8453 lane using the
   `ccip-starter-kit-foundry` patterns; simulate with `chainlink-local`. Gated on §4 (CCT permission).
3. **Hand off to treasury wiring** — pool seeding, rewards-validator emissions, peg-arb keeper. These are
   economic/operational and specified in `pending-docs/treasury.md`.

## Sources

- Hashlock, *Rubicon Smart Contract Audit* (Final v6, Oct 2025) — contract set, mint/redeem, NETUID/VALIDATOR_UID, centralization.
- `smartcontractkit/chain-selectors` → `selectors.yml` — Bittensor mainnet chainid 964 / selector 2135107236357186872.
- Chainlink CCIP — Cross-Chain Token (CCT) standard, self-service token pools.
- Subtensor EVM — `opentensor/subtensor/precompiles/src/` (Rust impls + canonical Solidity ABIs, addresses in §6.1); `opentensor/evm-bittensor` example Solidity.
- Bittensor dTAO FAQ / btcli docs — no unbonding; `lock_stake`/`unlock_stake` decay.
