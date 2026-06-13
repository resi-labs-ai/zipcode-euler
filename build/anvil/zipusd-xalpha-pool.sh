#!/usr/bin/env bash
# zipusd-xalpha-pool.sh — stand up the zipUSD/xALPHA Hydrex (Algebra Integral) pool + a
# full-range LP position on the local anvil Base fork. This is the SUBSTRATE an ICHI YieldIQ
# vault (the 8-B6 single-sided-zipUSD LP vault, DEC-03) would wrap — we build the real pool +
# real liquidity, but stop short of deploying the ICHI vault contract itself.
#
# Idempotent-ish: re-running re-mints xALPHA depth and adds another LP position; the pool is
# only created once (createAndInitializePoolIfNecessary is a no-op if it already exists).
#
# Run:  bash build/anvil/zipusd-xalpha-pool.sh
set -euo pipefail

R=${RPC_URL:-http://127.0.0.1:8545}
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # anvil #0 = deployer/team
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# --- tokens (both 18-dp). 0xC5bd < 0xF6CA => token0 = zipUSD, token1 = xALPHA ---
ZIP=0xC5bd67f769bC0bEc5077c15E23d7AD707D5c45aF   # $1.00
XA=0xF6CAAF72A788916915ce1bF111E245e0bEABCd18    # $2.00 (pushed alphaUSD mark)
TOKEN0=$ZIP; TOKEN1=$XA

# --- Hydrex / Algebra Integral periphery (BaseAddresses.sol, on-chain verified) ---
NFPM=0xC63E9672f8e93234C73cE954a1d1292e4103Ab86   # NonfungiblePositionManager
FACTORY=0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E

# --- liquidity sizing: $20k zipUSD : $20k xALPHA (balanced at price 0.5, full range) ---
AMT0=20000000000000000000000   # 20,000 zipUSD (18-dp)
AMT1=10000000000000000000000   # 10,000 xALPHA (18-dp) = $20k at $2
DEADLINE=99999999999

# price token1/token0 = xALPHA per zipUSD = $1/$2 = 0.5 ; sqrtPriceX96 = floor(sqrt(0.5) * 2^96)
SQRTP=$(python3 -c "import math;print(int(math.isqrt(2**192//2)))")

echo "== zipUSD/xALPHA Algebra pool build =="
echo "sqrtPriceX96 = $SQRTP"
echo

echo "1) top up deployer xALPHA depth to $AMT1 (MockERC20 open mint)"
HAVE=$(cast call $XA 'balanceOf(address)(uint256)' $DEPLOYER -r $R | awk '{print $1}')
NEED=$(python3 -c "print(max(0, $AMT1 - $HAVE))")
[ "$NEED" != "0" ] && cast send $XA 'mint(address,uint256)' $DEPLOYER $NEED --private-key $PK -r $R >/dev/null
echo "   xALPHA deployer bal: $(cast call $XA 'balanceOf(address)(uint256)' $DEPLOYER -r $R | awk '{print $1}')"

echo "2) create + initialize the pool (deployer field = 0x0 => base pool)"
cast send $NFPM 'createAndInitializePoolIfNecessary(address,address,address,uint160,bytes)(address)' \
  $TOKEN0 $TOKEN1 0x0000000000000000000000000000000000000000 $SQRTP 0x --private-key $PK -r $R >/dev/null
POOL=$(cast call $FACTORY 'poolByPair(address,address)(address)' $TOKEN0 $TOKEN1 -r $R)
echo "   pool: $POOL"
TS=$(cast call $POOL 'tickSpacing()(int24)' -r $R | awk '{print $1}')
echo "   tickSpacing: $TS"
GS=$(cast call $POOL 'globalState()(uint160,int24,uint16,uint8,uint16,bool)' -r $R)
PRICE=$(echo "$GS" | awk 'NR==1{print $1}'); TICK=$(echo "$GS" | awk 'NR==2{print $1}')
echo "   globalState price=$PRICE tick=$TICK"

echo "3) full-range ticks aligned to tickSpacing"
TU=$(python3 -c "ts=int('$TS'); print((887272//ts)*ts)")   # largest aligned tick <= MAX_TICK
TL=$(python3 -c "ts=int('$TS'); print(-(887272//ts)*ts)")  # symmetric; both stay inside [-887272, 887272]
echo "   tickLower=$TL tickUpper=$TU"

echo "4) approve NFPM to pull both tokens"
cast send $ZIP 'approve(address,uint256)' $NFPM $AMT0 --private-key $PK -r $R >/dev/null
cast send $XA  'approve(address,uint256)' $NFPM $AMT1 --private-key $PK -r $R >/dev/null

echo "5) mint the LP position -> deployer"
cast send $NFPM 'mint((address,address,address,int24,int24,uint256,uint256,uint256,uint256,address,uint256))' \
  "($TOKEN0,$TOKEN1,0x0000000000000000000000000000000000000000,$TL,$TU,$AMT0,$AMT1,0,0,$DEPLOYER,$DEADLINE)" \
  --private-key $PK -r $R >/dev/null

# derive the tokenId (last NFT held by deployer)
NBAL=$(cast call $NFPM 'balanceOf(address)(uint256)' $DEPLOYER -r $R | awk '{print $1}')
TOKENID=$(cast call $NFPM 'tokenOfOwnerByIndex(address,uint256)(uint256)' $DEPLOYER $((NBAL-1)) -r $R | awk '{print $1}')
echo "   LP NFT tokenId: $TOKENID"

echo
echo "== result =="
echo "pool reserves: zipUSD=$(cast call $ZIP 'balanceOf(address)(uint256)' $POOL -r $R)  xALPHA=$(cast call $XA 'balanceOf(address)(uint256)' $POOL -r $R)"
echo "pool liquidity: $(cast call $POOL 'liquidity()(uint128)' -r $R)"
echo "position: $(cast call $NFPM 'positions(uint256)(uint88,address,address,address,address,int24,int24,uint128,uint256,uint256,uint128,uint128)' $TOKENID -r $R | tr '\n' ' ')"
echo
echo "POOL=$POOL  TOKENID=$TOKENID  (record these in zipusd-xalpha-pool.md)"
