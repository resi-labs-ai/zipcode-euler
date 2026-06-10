# 8x-02 — xALPHA exchange-rate Base oracle (`SzAlphaRateOracle`) — report

## What it is
- The one fact native only to Bittensor is the xALPHA **exchange rate** (`staked alpha / supply`, StakingV2 `0x805`, chain 964). The Base mirror has no stake surface, so it can't be read on Base.
- A CRE workflow **pulls that one number from 964 and pushes it raw to `SzAlphaRateOracle` on Base**. The chain derives everything else (NAV, APR) from it. Nothing pre-computed is pushed.

## Design decisions (the ones that stuck)
- **Push the primitive, not the answer.** CRE transports the rate; APR/NAV derive on-chain.
- **No deviation band.** Publish the chain's value as-is. A band can't tell a real emission spike from a bad read (identical in one number) — it would reject genuine moves. DON f+1 consensus catches a misread; staleness catches a frozen feed.
- **Staleness gate is the real fund-safety control.** `SzipNavOracle` reads the rate from this oracle and **halts minting if it's stale** (`navEntry`/`fresh`), but **exit is unaffected** (`navExit` prices off the last rate). Additive — unwired = old behavior, so the 42 NAV tests pass unchanged.
- **APR derived in one expression.** `(rNow/rPrev − 1) × yr/Δ` computed without an intermediate bps truncation (see the bug below). Floored at 0, cap-clamped, advisory.
- **Cadence: hourly** → `maxStaleness` 6h, `window` 30d, all set at deploy (Timelock).

## Push guards (the only ones)
- non-zero, not-future, strictly-newer (no replay/out-of-order). That's it.

## Real-data validation (live 964, not a mock)
- Read live mainnet EVM RPC → `eth_chainId` = **964** (confirms the project; web docs saying 945 are stale). `eth_call` to the `0x802` precompile returns real `getStake`/`getEmission`. **The read works.**
- Emission unit = **per-tempo**, confirmed against a protocol constant: subnet emission summed to 296 alpha/period ÷ 360 blocks = 0.82 alpha/block ≈ the ~1 alpha/block dTAO cap.
- Real validators yield **11–21% alpha-APR** (netuid 64). Sane.

## Bug the real data caught (and fixed)
- The APR function computed `growthBps` then annualized. A live validator's per-tempo growth is **sub-bps**, so the two-step integer math **truncated to 0** — the feed would read **0%** for an earning validator on any short window. The unit tests missed it (they used a 30-day window).
- **Fixed:** single-expression annualization. Reproduces 11.4 / 19.7 / 20.7% at both 72-min and 30-day windows. Added a test using the live uid-252 numbers.

## Tests
- `SzAlphaRateOracle`: **19/19**.
- `SzipNavOracle`: **44/44** (42 pinned + 2 new gate tests).
- Full suite: **679/679**, zero failures, non-fork.

## Open / not done
- **CRE 964 access (config):** the read *pattern* is proven (`SzAlpha.exchangeRate()` uses the low-level `staticcall` workaround, `SzAlpha.sol:308`). Residual = confirm CRE has a 964 chain selector + RPC. Not a blocker.
- **Item-10:** deploy `SzAlphaRateOracle` on Base; run the `cre/szalpha-rate/` hourly pull; wire `SzipNavOracle.setXAlphaRateOracle(...)` (token stays the mirror for balances).
- **Off-chain (8-B12 / treasury):** the USD value leg (`xalphaPriceUsd`) and post-M1 incentive APR.
- **The Go workflow** (`cre/szalpha-rate/`) is the CRE-03 integration artifact — not compiled in the Foundry repo. Payload ABI + cadence pinned; go.mod/RPC/the exact 964 read are CRE-03.

## Files
- `contracts/src/bridge/SzAlphaRateOracle.sol` + `contracts/test/bridge/SzAlphaRateOracle.t.sol`
- `contracts/src/supply/SzipNavOracle.sol` (additive rate-oracle gate) + its test
- `cre/szalpha-rate/{main.go,README.md}`

**Not git-committed** (per instruction).
