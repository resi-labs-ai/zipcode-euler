# Invariant Map

> SzAlpha Bridge | 18 guards | 6 inferred | 3 not enforced on-chain

> **CURRENT STATE (2026-06-20): scope-level catalog; per-contract X-Rays are authoritative for test connection.**
> This bundled map predates the one-per-contract pass. The invariants themselves are unchanged, but each is now
> **connected to the test that proves it** (and several gained fuzz/invariant coverage) in the per-contract files —
> notably [`SzAlpha.md`](SzAlpha.md) (I-1/I-2 now under a Foundry invariant suite + round-trip fuzz; X-1 now
> characterized by a lying-mock test) and [`SzAlphaRateOracle.md`](SzAlphaRateOracle.md) (I-1 ts-monotonicity +
> the anchor-roll/APR now under fuzz + 2 invariants). The 3 thin wrappers' guards (S8/S9) are covered in
> [`SzAlphaLockReleasePool.md`](SzAlphaLockReleasePool.md) / [`SzAlphaTokenPool.md`](SzAlphaTokenPool.md) /
> [`SzAlphaMirror.md`](SzAlphaMirror.md). Use those for the test-connected, current view.

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (owner_ == address(0) || ccipAdmin_ == address(0)) revert ZeroAddress()` · `SzAlpha.sol:138` · prevents bricking the upgrade/registrar authorities at init.

#### G-2
`if (validatorHotkey_ == bytes32(0)) revert ZeroAddress()` · `SzAlpha.sol:139` · the hotkey is the staking target; a zero key would stake into nothing.

#### G-3
`if (netuid_ > type(uint16).max) revert NetuidTooLarge(netuid_)` · `SzAlpha.sol:140` · `IAlpha` takes uint16; bounds the subnet id so later `uint16(netuid)` casts are lossless.

#### G-4
`if (block.timestamp > deadline) revert DeadlineExpired()` · `SzAlpha.sol:179,224` · caller-set MEV/staleness deadline on both value-moving legs.

#### G-5
`if (amountRao == 0) revert ZeroAmount()` · `SzAlpha.sol:181` · rejects deposits below 1 rao that would stake nothing.

#### G-6
`if (stakeRaoAfter <= stakeRaoBefore) revert AddStakeEffectMissing()` · `SzAlpha.sol:192` · S4 direction check — a silent precompile no-op would otherwise mint shares against zero new backing.

#### G-7
`if (shares == 0) revert ZeroSharesOut()` · `SzAlpha.sol:197` · backstops the first-depositor/donation inflation case; a rounding-to-zero deposit reverts rather than losing funds.

#### G-8
`if (shares < minSharesOut) revert SlippageExceeded(shares, minSharesOut)` · `SzAlpha.sol:198` · caller slippage bound on the variable-price TAO→alpha swap.

#### G-9
`if (!ok) revert NativeTransferFailed()` · `SzAlpha.sol:204,248` · fail-closed on the sub-rao refund and the redeem payout.

#### G-10
`if (shares == 0) revert ZeroAmount()` · `SzAlpha.sol:225` · rejects empty redemptions.

#### G-11
`if (alphaOutRao == 0) revert ZeroAmount()` · `SzAlpha.sol:230` · floor of share→alpha can be zero for dust; reverts instead of burning for nothing.

#### G-12
`if (_readStake() >= stakeRaoBefore) revert RemoveStakeEffectMissing()` · `SzAlpha.sol:241` · S4 direction check on unstake — stake must actually fall.

#### G-13
`if (taoOut == 0) revert RemoveStakeEffectMissing()` · `SzAlpha.sol:243` · the measured native balance must rise; no payout means the unstake didn't credit TAO.

#### G-14
`if (taoOut < minTaoOut) revert SlippageExceeded(taoOut, minTaoOut)` · `SzAlpha.sol:244` · caller slippage bound on the alpha→TAO swap.

#### G-15
`if (newAdmin == address(0)) revert ZeroAddress()` · `SzAlpha.sol:307` · prevents zeroing the CCIP registrar.

#### G-16
`if (!ok || ret.length < 32) revert PrecompileCallFailed()` · `SzAlpha.sol:355,370,380,388` · validates every precompile staticcall returned a decodable word (fail-closed).

#### G-17
`if (amountRao > type(uint64).max) revert AmountOverflowsUint64()` · `SzAlpha.sol:366,376` · the Alpha swap-sim precompile takes uint64; bounds the cast.

#### G-18
`if (localTokenDecimals != 18) revert LocalDecimalsNot18(); if (rmnProxy != canonicalRmn) revert RmnNotCanonical()` · `SzAlphaLockReleasePool.sol:36-37`, `SzAlphaTokenPool.sol:27-28` · S8/S9 deploy-time invariants: equal decimals (cross-chain conservation) and canonical RMN (no spoofed risk manager).

*Oracle push guards (`InvalidReportType`, `ZeroRate`, `FutureTimestamp`, `StaleReport`) are lifted to §2 as I-3 because they constrain persistent `latest`/anchor state.*

---

## 2. Inferred Invariants (Single-Contract)

#### I-1

`Ratio` · On-chain: **Yes**

> `exchangeRate() == (stake18 + 1e0) * 1e18 / (totalSupply + 1)` — the price per szALPHA is always backing-over-supply with a 1/1 virtual offset; it can only move via real stake change or mint/burn.

**Derivation** — Ratio formula at `SzAlpha.sol:265`; `stake18` from `_readStake()*RAO` (`:360-362`), `totalSupply` from ERC20. Virtual offset `VIRTUAL_STAKE/VIRTUAL_SHARES = 1/1` (`:80-81`) guarantees no div-by-zero and a 1:1 genesis.

**If violated** — every NAV/CRE consumer misprices szALPHA.

#### I-2

`Conservation` · On-chain: **Yes**

> Shares are minted/burned only against the measured stake delta: `Δ(totalSupply) = +shares` at deposit paired with the `getStake` rise, and `Δ(totalSupply) = -shares` at redeem paired with the `getStake` fall.

**Derivation** — Δ-pair: `_mint` at `SzAlpha.sol:199` gated by the delta computed at `:191-196`; `_burn` at `:233` gated by `:227-241`. No other write site of `totalSupply` exists in scope (no admin mint/burn).

**If violated** — supply could desync from backing; here the only writers are deposit/redeem, both delta-checked.

#### I-3

`Temporal` · On-chain: **Yes**

> The oracle's stored read-time is strictly monotonic: `latest.ts` only ever increases, so no replayed or out-of-order rate can overwrite a newer one.

**Derivation** — guard-lift: `require(ts > latest.ts)` (`SzAlphaRateOracle.sol:86`) is the sole write path to `latest` (`:101`); the only other writers (`curAnchor`/`prevAnchor` at `:93-98`) are driven by the same monotonic `ts`. All write sites of `latest` enforce the guard.

**If violated** — a stale rate could become the headline value; the strictly-newer check prevents it.

#### I-4

`Bound` · On-chain: **Yes**

> `netuid <= type(uint16).max` globally — the only write site is `initialize`, which enforces it.

**Derivation** — guard-lift: `require(netuid_ <= type(uint16).max)` (`SzAlpha.sol:140`); `netuid` is written only at `:148` (init). No setter exists, so the bound holds across all calls.

**If violated** — `uint16(netuid)` casts at `:368,378` would silently truncate; bound makes them lossless.

---

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **No**

> SzAlpha assumes the *magnitude* of the precompile stake/balance change equals the true alpha received/TAO produced. Only the *direction* is checked on-chain; the amount minted (deposit) and paid (redeem) is whatever the precompile reports.

**Caller side** — `SzAlpha.sol:191-196` (deposit: `alphaDeltaRao = stakeAfter - stakeBefore` → `_previewDeposit`) and `:240-243` (redeem: `taoOut = balanceAfter - balanceBefore`).

**Callee side** — `STAKING_V2` precompile `addStake`/`removeStake`/`getStake` (`_callStaking:393`, `_readStake:351`) — **out of scope** (Subtensor runtime). The contract cannot bound what these return; it trusts magnitude after checking sign and `ret.length >= 32`.

**If violated** — a misbehaving precompile return skews share issuance or payout. (Listed as On-chain=No because the callee is outside scope and unbounded; the design accepts the precompile as trusted runtime.)

---

## 4. Economic Invariants

#### E-1

On-chain: **No**

> Cross-chain rate truthfulness: `SzAlpha.totalSupply()` continues to count bridged-out szALPHA (locked on 964, not burned), so `exchangeRate() = stake/supply` stays correct on every chain. Requires the 964 pool to be lock/release and both lanes to share 18 decimals.

**Follows from** — `I-1` (rate ratio) + `I-2` (supply only moves on local mint/redeem) + `G-18` (decimals==18 both sides).

**If violated** — if the 964 side were burn/mint instead of lock/release, local supply would shrink against unchanged stake, inflating the rate and letting 964 redeemers drain Base holders' backing. Enforcement of *which* pool variant is deployed on 964 is a deploy-time/topology choice, not checked on-chain here — hence On-chain=No. The decimals leg (`G-18`) IS enforced.
