#!/usr/bin/env bash
# lp-add-liquidity.sh — test the 8-B6 LpStrategyModule: move basket zipUSD into the zipUSD/xALPHA
# ICHI LP (vault 0x4731), with the LP share landing in the engine Safe.
#
# The PROD LpStrategyModule clone (0xc242…) is pinned to the WETH/USDC stand-in pair (token0/token1
# are set-once at setUp, NOT re-pointable), so it cannot deposit our pair. This script clones a FRESH
# LpStrategyModule wired to our vault (setUp reads token0=zipUSD/token1=xALPHA), enables it on the
# engine Safe, re-points SzipNavOracle.setLpPosition at our vault (so NAV values the moved LP — the
# wires "same LP address everywhere" invariant), then drives addLiquidity as the CRE operator.
#
# Run AFTER zipusd-xalpha-ichi-vault.sh (needs the vault + basket zipUSD). Resets on anvil restart.
#   bash build/anvil/lp-add-liquidity.sh           # add 100,000 zipUSD (default)
#   bash build/anvil/lp-add-liquidity.sh 50000     # add 50,000 zipUSD
set -euo pipefail

R=${RPC_URL:-http://127.0.0.1:8545}
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # deployer
OPK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # CRE operator (anvil #3)
D=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

ZIP=0xC5bd67f769bC0bEc5077c15E23d7AD707D5c45aF
XA=0xF6CAAF72A788916915ce1bF111E245e0bEABCd18
VAULT=0x4731d24b32e173e82788cF0d1eFf7d3b92fCa5dd       # our zipUSD/xALPHA ICHI vault (the LP token)
SAFE=0x0B9C95c7fc6048Bd4B568b637707D7dC5381B2ac        # engine / main Safe (holds basket zipUSD + LP)
NAV=0x0C3E77314D97e8e001e0F626A559992479A3C79e
ROUTER=0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e
FACTORY=0x000000000000aDdB49795b0f9bA5BC298cDda236      # ZODIAC_MODULE_PROXY_FACTORY
MC=0xf627bfb1af95ef1152bb7aeddf79a375382bbabc           # LpStrategyModule mastercopy (from the prod clone)
TL=0x89ae086561ed831C4f5ebF31d825f0364C8c3B27           # Timelock (module + oracle owner)
OP=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC           # CRE operator addr
GAUGE=0x4328CE8ADC23F1c4E5A3049F63Ffbdd8e73F99Ce        # placeholder gauge (addLiquidity never touches it)
SALT=88888
NEWLP=0x9898F48785b18fB2D5776a5F99be7397C504aaeA        # deterministic clone addr for (MC, setUp, SALT)

AMT=$(cast to-wei "${1:-100000}")

# --- one-time setup (idempotent) ---
if [ "$(cast code $NEWLP -r $R)" = "0x" ]; then
  echo "setup: clone LpStrategyModule -> our vault"
  SETUP=$(cast abi-encode 'f(address,address,address,address,address)' $TL $SAFE $OP $VAULT $GAUGE)
  INIT=$(cast calldata 'setUp(bytes)' $SETUP)
  cast send $FACTORY 'deployModule(address,bytes,uint256)' $MC $INIT $SALT --private-key $PK -r $R >/dev/null
fi
if [ "$(cast call $SAFE 'isModuleEnabled(address)(bool)' $NEWLP -r $R)" != "true" ]; then
  echo "setup: enableModule on engine Safe"
  cast rpc anvil_setBalance $SAFE 0xde0b6b3a7640000 -r $R >/dev/null
  cast rpc anvil_impersonateAccount $SAFE -r $R >/dev/null
  cast send $SAFE 'enableModule(address)' $NEWLP --from $SAFE --unlocked -r $R >/dev/null
  cast rpc anvil_stopImpersonatingAccount $SAFE -r $R >/dev/null
fi
if [ "$(cast call $NAV 'ichiVault()(address)' -r $R | tr 'A-F' 'a-f')" != "$(echo $VAULT | tr 'A-F' 'a-f')" ]; then
  echo "setup: SzipNavOracle.setLpPosition -> our vault (so NAV values the LP)"
  cast rpc anvil_setBalance $TL 0xde0b6b3a7640000 -r $R >/dev/null
  cast rpc anvil_impersonateAccount $TL -r $R >/dev/null
  cast send $NAV 'setLpPosition(address,address)' $VAULT $GAUGE --from $TL --unlocked -r $R >/dev/null
  cast rpc anvil_stopImpersonatingAccount $TL -r $R >/dev/null
fi

# --- seed an Algebra oracle timepoint (the vault's deposit reads a TWAP) + warp past twapPeriod ---
echo "seeding oracle timepoint (mint 1 xALPHA -> swap -> warp)"
cast send $XA 'mint(address,uint256)' $D 1000000000000000000 --private-key $PK -r $R >/dev/null
cast send $XA 'approve(address,uint256)' $ROUTER 1000000000000000000 --private-key $PK -r $R >/dev/null
cast send $ROUTER 'exactInputSingle((address,address,address,address,uint256,uint256,uint256,uint160))(uint256)' \
  "($XA,$ZIP,0x0000000000000000000000000000000000000000,$D,99999999999,1000000000000000000,0,1461446703485210103287273052203988822378723970341)" \
  --private-key $PK -r $R >/dev/null
cast rpc evm_increaseTime 120 -r $R >/dev/null; cast rpc evm_mine -r $R >/dev/null

# --- the test: operator drives addLiquidity (single-sided zipUSD) ---
echo "addLiquidity($(cast from-wei $AMT) zipUSD, 0, minShares=1) as operator"
SAFE_ZIP_PRE=$(cast call $ZIP 'balanceOf(address)(uint256)' $SAFE -r $R | awk '{print $1}')
SAFE_LP_PRE=$(cast call $VAULT 'balanceOf(address)(uint256)' $SAFE -r $R | awk '{print $1}')
cast send $NEWLP 'addLiquidity(uint256,uint256,uint256)' $AMT 0 1 --private-key $OPK -r $R >/dev/null

echo
echo "== result =="
echo "module:           $NEWLP"
echo "engine Safe zipUSD: $SAFE_ZIP_PRE -> $(cast call $ZIP 'balanceOf(address)(uint256)' $SAFE -r $R | awk '{print $1}')"
echo "engine Safe LP:     $SAFE_LP_PRE -> $(cast call $VAULT 'balanceOf(address)(uint256)' $SAFE -r $R | awk '{print $1}')"
echo "vault getTotalAmounts: $(cast call $VAULT 'getTotalAmounts()(uint256,uint256)' -r $R | tr '\n' ' ')"
echo "grossBasketValue:   $(cast call $NAV 'grossBasketValue()(uint256)' -r $R | awk '{print $1}')  (value conserved: raw zipUSD -> LP)"
echo "standing approval (must be 0): $(cast call $ZIP 'allowance(address,address)(uint256)' $SAFE $VAULT -r $R | awk '{print $1}')"
