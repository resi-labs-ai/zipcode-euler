#!/usr/bin/env bash
# zipusd-xalpha-ichi-vault.sh — deploy the REAL single-sided-zipUSD ICHI YieldIQ vault over the
# zipUSD/xALPHA Hydrex pool (built by zipusd-xalpha-pool.sh) and mint the fungible ERC20 LP share.
# That share IS the collateral token for the farm utility EVK market (8-B6 / DEC-03).
#
# Run AFTER zipusd-xalpha-pool.sh. Resets on anvil restart + redeploy.
#   bash build/anvil/recipes/zipusd-xalpha-ichi-vault.sh
set -euo pipefail

R=${RPC_URL:-http://127.0.0.1:8545}
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # anvil #0 = deployer
D=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

ZIP=0xC5bd67f769bC0bEc5077c15E23d7AD707D5c45aF   # token0, $1
XA=0xF6CAAF72A788916915ce1bF111E245e0bEABCd18    # token1, $2
POOL=0x7878816e26113fBE3B43d51917018cD582a0e27f

# Real Hydrex/ICHI infra (BaseAddresses.sol, on-chain verified)
FACTORY=0x2b52c416F723F16e883E53f3f16435B51300280a   # ICHI_VAULT_FACTORY
ADMIN=0x7d11De61c219b70428Bb3199F0DD88bA9E76bfEE     # factory owner = ICHI admin safe (impersonate)
ROUTER=0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e    # Algebra SwapRouter

# deterministic vault address for (deployer=admin, zipUSD, xALPHA, true, false)
V=0x4731d24b32e173e82788cF0d1eFf7d3b92fCa5dd
DEPOSIT=10000000000000000000000   # 10,000 zipUSD single-sided

echo "== single-sided zipUSD ICHI vault =="

if [ "$(cast code $V -r $R)" = "0x" ]; then
  echo "1) createICHIVault(zipUSD, allow=true, xALPHA, allow=false) via factory (impersonate admin safe)"
  cast rpc anvil_setBalance $ADMIN 0xde0b6b3a7640000 -r $R >/dev/null
  cast rpc anvil_impersonateAccount $ADMIN -r $R >/dev/null
  cast send $FACTORY 'createICHIVault(address,bool,address,bool)' $ZIP true $XA false --from $ADMIN --unlocked -r $R >/dev/null
  # fork-pool TWAP is young: shrink the 3600s default so the deposit's oracle read resolves
  cast send $V 'setTwapPeriod(uint32)' 60 --from $ADMIN --unlocked -r $R >/dev/null
  cast rpc anvil_stopImpersonatingAccount $ADMIN -r $R >/dev/null
  echo "   vault: $V  symbol=$(cast call $V 'symbol()(string)' -r $R)  allow0=$(cast call $V 'allowToken0()(bool)' -r $R) allow1=$(cast call $V 'allowToken1()(bool)' -r $R)"
else
  echo "1) vault $V already exists — skipping create"
fi

echo "2) seed an Algebra oracle timepoint (a fresh pool has none until a swap writes one), then warp past twapPeriod"
cast send $ZIP 'approve(address,uint256)' $ROUTER 100000000000000000000 --private-key $PK -r $R >/dev/null
cast send $ROUTER 'exactInputSingle((address,address,address,address,uint256,uint256,uint256,uint160))(uint256)' \
  "($ZIP,$XA,0x0000000000000000000000000000000000000000,$D,99999999999,100000000000000000000,0,4295128740)" \
  --private-key $PK -r $R >/dev/null
cast rpc evm_increaseTime 120 -r $R >/dev/null; cast rpc evm_mine -r $R >/dev/null

echo "3) deposit $DEPOSIT zipUSD single-sided (deposit0=amount, deposit1=0) -> LP shares to deployer"
cast send $ZIP 'approve(address,uint256)' $V $DEPOSIT --private-key $PK -r $R >/dev/null
cast send $V 'deposit(uint256,uint256,address)(uint256)' $DEPOSIT 0 $D --private-key $PK -r $R >/dev/null

echo
echo "== result =="
echo "LP token (ICHI vault): $V"
echo "  totalSupply:    $(cast call $V 'totalSupply()(uint256)' -r $R | awk '{print $1}')"
echo "  deployer shares:$(cast call $V 'balanceOf(address)(uint256)' $D -r $R | awk '{print $1}')"
echo "  getTotalAmounts:$(cast call $V 'getTotalAmounts()(uint256,uint256)' -r $R | tr '\n' ' ')"
echo "  backed zipUSD:  $(cast call $ZIP 'balanceOf(address)(uint256)' $V -r $R | awk '{print $1}')"
