#!/usr/bin/env bash
# baal-deposit-zipusd.sh — deposit zipUSD into the Baal / szipUSD junior vault.
#
# Issuance gates on NAV freshness (ExitGate.depositFor -> SzipNavOracle.navEntry), and on a fresh
# fork the CRE-pushed marks go stale, so this helper FIRST re-pushes the current marks with a fresh
# timestamp (the fiddly part), THEN deposits via ExitGate.depositFor (mints szipUSD + soulbound Loot).
#
# Refreshes two ReceiverTemplate oracles, impersonating the Chainlink Forwarder:
#   - SzipNavOracle  reportType 7 = leg marks (ALPHA, HYDX)   -> re-pushes the CURRENT legCache prices
#   - SzAlphaRateOracle reportType 8 = xALPHA cross-chain rate -> re-pushes the CURRENT exchangeRate
# Both share the 62-byte CRE identity metadata abi.encodePacked(workflowId, workflowName, author).
#
# Usage:
#   bash build/anvil/baal-deposit-zipusd.sh         # drain the deployer's ENTIRE zipUSD balance
#   bash build/anvil/baal-deposit-zipusd.sh 17900   # deposit 17,900 zipUSD
# Resets on anvil restart + redeploy.
set -euo pipefail

R=${RPC_URL:-http://127.0.0.1:8545}
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
D=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266   # deployer = depositor + szipUSD receiver

ZIP=0xC5bd67f769bC0bEc5077c15E23d7AD707D5c45aF
SZ=0x33aD3E23ae6189055925ba2265041AcCA356b4E4
GATE=0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e   # ExitGate (sole szipUSD minter; depositFor)
NAV=0x0C3E77314D97e8e001e0F626A559992479A3C79e
RATE=0x7251A305FE860099CdC842fcFbde8aB6002Afe72
FWD=0xF8344CFd5c43616a4366C34E3EEE75af79a74482     # Chainlink Forwarder (the CRE write path)

# 62-byte identity = abi.encodePacked(workflowId(32) ++ workflowName(10 zero bytes) ++ author(20)).
# Both oracles expect author 0x90F7…/id 0x..01/name 0x00 (getExpectedAuthor/WorkflowId/WorkflowName).
META=0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000090F79bf6EB2c4f870365E785982E1f101E93b906

# amount: arg1 in whole zipUSD, else drain the deployer's full balance
if [ "${1:-}" != "" ]; then AMT=$(cast to-wei "$1"); else AMT=$(cast call $ZIP 'balanceOf(address)(uint256)' $D -r $R | awk '{print $1}'); fi
echo "depositing $(cast from-wei $AMT) zipUSD into the Baal vault"

# bump fork time so the re-pushed marks are strictly newer than the prior push (no-replay guard)
cast rpc evm_increaseTime 3 -r $R >/dev/null; cast rpc evm_mine -r $R >/dev/null
TS=$(cast block latest -f timestamp -r $R)

echo "refreshing issuance (NAV legs reportType 7 + xALPHA rate reportType 8) ..."
A_PRICE=$(cast call $NAV 'legCache(uint8)(uint256,uint48)' 0 -r $R | awk 'NR==1{print $1}')
H_PRICE=$(cast call $NAV 'legCache(uint8)(uint256,uint48)' 1 -r $R | awk 'NR==1{print $1}')
RATE_NOW=$(cast call $RATE 'exchangeRate()(uint256)' -r $R | awk '{print $1}')
NAV_REPORT=$(cast abi-encode 'f(uint8,bytes)' 7 $(cast abi-encode 'f(uint8[],uint256[],uint32)' '[0,1]' "[$A_PRICE,$H_PRICE]" $TS))
RATE_REPORT=$(cast abi-encode 'f(uint8,bytes)' 8 $(cast abi-encode 'f(uint256,uint48)' $RATE_NOW $TS))

cast rpc anvil_setBalance $FWD 0xde0b6b3a7640000 -r $R >/dev/null
cast rpc anvil_impersonateAccount $FWD -r $R >/dev/null
cast send $NAV  'onReport(bytes,bytes)' $META $NAV_REPORT  --from $FWD --unlocked -r $R >/dev/null
cast send $RATE 'onReport(bytes,bytes)' $META $RATE_REPORT --from $FWD --unlocked -r $R >/dev/null
cast rpc anvil_stopImpersonatingAccount $FWD -r $R >/dev/null
echo "  fresh=$(cast call $NAV 'fresh()(bool)' -r $R)  navEntry=$(cast call $NAV 'navEntry()(uint256)' -r $R | awk '{print $1}')"

echo "depositing ..."
SHARES=$(cast call $GATE 'previewDeposit(address,uint256)(uint256)' $ZIP $AMT -r $R | awk '{print $1}')
cast send $ZIP 'approve(address,uint256)' $GATE $AMT --private-key $PK -r $R >/dev/null
cast send $GATE 'depositFor(address,uint256,address)(uint256)' $ZIP $AMT $D --private-key $PK -r $R >/dev/null

echo
echo "== result =="
echo "minted szipUSD (~):   $(cast from-wei $SHARES)"
echo "deployer szipUSD:     $(cast call $SZ 'balanceOf(address)(uint256)' $D -r $R | awk '{print $1}')"
echo "deployer zipUSD left: $(cast call $ZIP 'balanceOf(address)(uint256)' $D -r $R | awk '{print $1}')"
echo "szipUSD totalSupply:  $(cast call $SZ 'totalSupply()(uint256)' -r $R | awk '{print $1}')"
echo "grossBasketValue:     $(cast call $NAV 'grossBasketValue()(uint256)' -r $R | awk '{print $1}')"
