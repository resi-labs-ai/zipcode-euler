#!/usr/bin/env bash
# _harness.sh — shared smoke-path harness for the live anvil board (Base fork @ 47096000).
# Source it:  source build/anvil/smoketest/_harness.sh
#
# Binds by NAME to the current board. Engine modules are the live CLONES (re-derived from the main Safe's
# module list, NOT the mastercopies in older docs). Provides: address book, CRE metadata builder, report
# push, the universal rate+legs seed preamble, USDC dealing, and snapshot/revert isolation.
set -uo pipefail
R=${RPC_URL:-http://127.0.0.1:8545}
FWD=0xF8344CFd5c43616a4366C34E3EEE75af79a74482   # CRE KeystoneForwarder
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
SNAPFILE="/Users/root1/zipcode-euler/build/anvil/smoketest/.baseline_snapshot"

# ---- address book (current board; standalone contracts + engine CLONES) --------------------------------
declare -A A=(
  [TimelockController]=0x0395da1BBCD51A0b48EEBf40F4F39E5985d6CA1A
  [ZipcodeController]=0x5bF6a1503F6A0f43Cf16f417FB033A9d3677dF01
  [EulerVenueAdapter]=0x36025de2F0753789058eAE99003BbE2131b63810
  [ZipcodeOracleRegistry]=0xbF1801C78593aF0Ef7BcB4415Eaf146993Ec7A01
  [CREGatingHook]=0x87dC8666F0c31Fb4B205240003DD733E327E14F3
  [LienTokenFactory]=0x16579ac952BBf5cC0844959699A2876eA885808C
  [SiloRegistry]=0x86C2ba30C5Ce01479eF797897FAA6791402FeDf2
  [SeniorNavAggregator]=0x10Fff7de38A99e5f7F86E982d5dF1B0ECE7f5b01
  [zipUSD]=0xabe34eC6072F35F956450159D7238bCB719Fde6a
  [szipUSD]=0x783A08cb688a94cb6bCaE9f74eDe6762b44f3ACd
  [ZipDepositModule]=0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e
  [ExitGate]=0xB8fB416FbF1cfd793eCacF9135174bEf92a4b97F
  [SzipNavOracle]=0x33aD3E23ae6189055925ba2265041AcCA356b4E4
  [ZipRedemptionQueue]=0x7b5C04034b6531C36E0F10890056D95F6f6153F9
  [SzipFarmUtilityLpOracle]=0xc933fc2f0d97a14e08071778F6F2AA83ECb1309b
  [WarehouseAdminModule]=0x24D7910DCaF4cd27F07e877C588F8EEA0e992A3a
  [DefaultCoordinator]=0xAC07DBEEf61E773fc4d745EA83b70D7A18263a01
  [LienXAlphaEscrow]=0x97Fe77c24831ee77D6Fb4923aEd8138D7A79f02E
  [SzAlphaRateOracle]=0x46C89c1A4E86b7F025871C35f08aa7da95F79d8f
  [RolesModifier]=0x2f1f2e5cCB88E0B543A5d3B6c8e0095c754FE984
  # engine module CLONES (enabled on the Safes)
  [SzipBuyBurnModule]=0x8B7B057bB2B9A7F06929BdB89132005C1Fafd294
  [FarmUtilityLoopModule]=0xea9b76bB08d14E40f04409393B1F113E4999Efb2
  [LpStrategyModule]=0x25cf123dB6700650aC387515519c287031c48aD8
  [HarvestVoteModule]=0xf1DEbc425Da983d08FC713a06E655D1018556C1e
  [ExerciseModule]=0xaD54085b62Ef94923f980314444b63c526Aac4e2
  [SellModule]=0x1fCe5c71C12E5786A9966455375Cdb2843B8BEAa
  [RecycleModule]=0x28b0109B3ac79fA14F2E1914D44872BD6b32B97f
  [OffRampModule]=0x2e0Ba43db83E0D3bBc2537836955890F3fAA7434
  [DurationFreezeModule]=0x3Bcd8BD1282B083C10bdba2a5E205Bc9A094f2FE
  # safes / venues / tokens
  [mainSafe]=0x0B9C95c7fc6048Bd4B568b637707D7dC5381B2ac
  [sidecarSafe]=0x39D229610e52A1229cF5728CAb0A862F650AF6f0
  [warehouseSafe]=0x7975E1eFB09690E42C5B574B1768cdFA11e8693c
  [eePool]=0x1a7A8A5a6A2B34895201CFBC997C4eC419ba8A3d
  [baseUsdcMarket]=0x3A48aaaa90CF3938290f12F6A1E58C1aeb54699D
  [farmBorrow]=0x1aFc8c641BE6E8a0849f00f3c90a27D44710D267
  [farmEscrow]=0x8A5FA36779693584E0e52246f05C5b0bF55Df1b1
  [USDC]=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
  [xALPHA]=0x237C95e376FCA422316a18264936C426BBc686B6
  # principals
  [team]=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  [creOperator]=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
  [workflowAuthor]=0x90F79bf6EB2c4f870365E785982E1f101E93b906
  [alice]=0x976EA74026E726554dB657fA54763abd0C3a0aa9
  [bob]=0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f
)
LOCAL_SILO_ID=0x0309d2cf8d22de7d0626162a4ba1d7bff931531432937d085bcaf163f0febebd
addr() { echo "${A[$1]}"; }

# ---- helpers -------------------------------------------------------------------------------------------
give_eth()   { cast rpc anvil_setBalance "$1" 0xde0b6b3a7640000 -r $R >/dev/null; }
imp()        { cast rpc anvil_impersonateAccount "$1" -r $R >/dev/null; }
unimp()      { cast rpc anvil_stopImpersonatingAccount "$1" -r $R >/dev/null; }
deal_usdc()  { cast rpc anvil_setStorageAt $USDC "$(cast index address "$1" 9)" "$(cast to-uint256 "$2")" -r $R >/dev/null; }
bal_usdc()   { cast call $USDC 'balanceOf(address)(uint256)' "$1" -r $R | awk '{print $1}'; }

# 62-byte CRE metadata for a receiver, read from its on-chain expected identity (getExpected*).
meta_for() {
  local rx="$1" wfid wfname author
  wfid=$(cast call "$rx" 'getExpectedWorkflowId()(bytes32)' -r $R 2>/dev/null);   [ -z "$wfid" ] && wfid=0x$(printf '0%.0s' {1..64})
  wfname=$(cast call "$rx" 'getExpectedWorkflowName()(bytes10)' -r $R 2>/dev/null); [ -z "$wfname" ] && wfname=0x$(printf '0%.0s' {1..20})
  author=$(cast call "$rx" 'getExpectedAuthor()(address)' -r $R 2>/dev/null)
  cast concat-hex "$wfid" "$wfname" "$author"
}
# push a report to a receiver as the Forwarder.  push_report <receiver> <reportBytes>
push_report() {
  local rx="$1" report="$2" meta; meta=$(meta_for "$rx")
  give_eth $FWD; imp $FWD
  cast send "$rx" 'onReport(bytes,bytes)' "$meta" "$report" --from $FWD --unlocked --gas-limit 9000000 -r $R >/dev/null 2>&1
  local rc=$?; unimp $FWD; return $rc
}

# universal preamble: bump time, seed NAV legs (reportType 7) + xALPHA rate (reportType 8) so NAV reads/ops
# stop reverting RateUnseeded/StalePrice. Args: [alphaUsd=100000000] [hydxUsd=100000000] [rate=1e18]
seed_marks() {
  local aP="${1:-100000000}" hP="${2:-100000000}" rate="${3:-1000000000000000000}" ts
  cast rpc evm_increaseTime 5 -r $R >/dev/null; cast rpc evm_mine -r $R >/dev/null
  ts=$(cast block latest -f timestamp -r $R)
  push_report "$(addr SzipNavOracle)"   "$(cast abi-encode 'f(uint8,bytes)' 7 "$(cast abi-encode 'f(uint8[],uint256[],uint32)' '[0,1]' "[$aP,$hP]" "$ts")")"
  push_report "$(addr SzAlphaRateOracle)" "$(cast abi-encode 'f(uint8,bytes)' 8 "$(cast abi-encode 'f(uint256,uint48)' "$rate" "$ts")")"
}

# snapshot isolation
revert_baseline() {
  local snap; snap=$(cat "$SNAPFILE" 2>/dev/null)
  [ -n "$snap" ] && cast rpc evm_revert "$snap" -r $R >/dev/null
  local new; new=$(cast rpc evm_snapshot -r $R | tr -d '"'); echo "$new" > "$SNAPFILE"
}
