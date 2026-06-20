# X-Ray — `SzAlphaMirror.sol` (single-contract, test-connected)

> SzAlphaMirror | 5 nSLOC | e634d9f (`main`, working tree) | Foundry | 20/06/26 | **Verdict: ADEQUATE**

Dedicated single-contract X-Ray for `contracts/src/bridge/SzAlphaMirror.sol`. Connected to
`test/bridge/SzAlphaBridge.t.sol`. **The thinnest contract in the repo** — zero authored logic; the audit value
is confirming the config pins and the *deliberate absence* of surface. Depth is proportionate.

## 1. What it is

The Base (8453) bridged mirror of szALPHA: a **plain canonical Chainlink `BurnMintERC20` (18-dp)** with mint/burn
gated to the Base CCT pool. It has **ZERO** staking / redeem / precompile / `IXAlphaRate` surface — Base has no
Subtensor precompiles, so the native leg lives only on 964 (`SzAlpha`). Being a *separate contract* (not an init
flag on `SzAlpha`) is the point: it keeps dead precompile code off Base and shrinks the Base audit surface. All
value accrual happens on 964 and is read via `SzAlpha.exchangeRate()`; the mirror is a pure transport token.

## 2. Authored surface (the entire delta vs the base)

```solidity
constructor(string memory name_, string memory symbol_) BurnMintERC20(name_, symbol_, 18, 0, 0) {}
```

That is the whole contract. Three pinned config values, no new state, no new functions, no overrides:

| Pin | Value | Why |
|---|---|---|
| `decimals` | **18** | cross-chain conservation requires equal decimals with the 964 side |
| `maxSupply` | **0** (unlimited) | local supply is bounded by the 964 lock/release custody, not here |
| `preMint` | **0** | no genesis supply on Base |

Everything operational — `mint`/`burn`/`grantMintAndBurnRoles`/role admin/`getCCIPAdmin`/ERC20 transfer — is
**inherited from the audited Chainlink `BurnMintERC20`** and out of scope. Roles (`DEFAULT_ADMIN_ROLE` + CCIP
admin) are the deployer at construction; the deploy script hands them to the timelock/multisig and revokes the
deployer (a deploy-time step, not enforced in this contract).

## 3. Invariants — with test connection

| Property | On-chain | Proven by |
|---|---|---|
| `decimals() == 18` (constructor-pinned; matches the pools' S8) | Yes | `test_mirror_decimalsAndNoStakeSurface` |
| no staking/redeem/precompile/`IXAlphaRate` surface exists | Yes (by absence) | `test_mirror_decimalsAndNoStakeSurface` |
| mint/burn gated to the MINTER/BURNER role (the CCT pool) | Yes (inherited) | `test_mirror_mintBurnGatedToPool` |
| mirror `totalSupply()` == szALPHA locked in the 964 lockbox (1:1) | **No** (cross-chain) | the lane round-trip tests on the 964 side (`test_lane_roundTrip_rateInvariant`) — the CCIP relay + lock/release topology enforce it, not this contract |

## 4. Attack surfaces

- **Mint authority = the whole risk, and it's inherited + deploy-time.** A compromised or mis-granted
  MINTER role could mint unbacked mirror tokens on Base. That lives in the inherited `BurnMintERC20` role
  machinery and in the deploy-time role handoff (deployer → timelock/multisig → revoke), **not** in this
  contract. Worth confirming the deploy grants mint/burn ONLY to the CCT pool and revokes the deployer.
- **No local supply cap (`maxSupply = 0`)** — cross-chain supply is bounded *only* by the 964 lock/release
  custody (seam E-1 / S2 in the system map). If the lane's burn/mint ever desynced from 964 lock/release,
  nothing here would cap it. The bound is the CCIP lane + the pools, not the mirror.

## 5. Test analysis

| Category | Count | Notes |
|---|---|---|
| Authored config unit | 2 | decimals/no-surface + role-gated mint/burn |
| Fuzz / invariant | 0 | n/a — there is no authored logic to fuzz |

## X-Ray Verdict

**ADEQUATE** — there is no authored logic to break: a plain audited `BurnMintERC20` with three pinned config
values, both meaningful pins (18-dp, role-gated mint/burn) tested, and the security thesis is *subtraction* (no
precompile/stake surface), also tested. The only real risks are inherited (the mint role) and deploy-time (the
role handoff) — neither in this contract. Cross-chain 1:1 backing is seam E-1/S2, enforced by the lane, not here.

**Structural facts:**
1. 5 nSLOC; plain subclass of audited `BurnMintERC20`; 0 authored functions beyond a config-only constructor.
2. Pins: 18 decimals, maxSupply 0, preMint 0.
3. Both config pins tested; part of the 55/55 green bridge suite.
4. Mint/burn authority is inherited role machinery; role handoff (deployer → timelock, revoke) is deploy-time.
5. Local supply uncapped by design — cross-chain conservation is enforced by the CCIP lane + 964 custody (E-1/S2).
