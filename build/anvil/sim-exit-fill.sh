#!/usr/bin/env bash
# sim-exit-fill.sh — spoof the OFF-CHAIN actors (CoW solver + treasury) on the anvil
# Base-fork so a szipUSD exit ACTUALLY SETTLES on-chain. No new contract: pure anvil
# impersonation of the existing wired accounts, driving the REAL deployed contracts.
#
# This is the fork stand-in for the mainnet path: on mainnet a CoW solver matches the
# lender's resting sell against the treasury's 8-B14 buy bid, then ExitGate.burnFor
# retires it. The solver network points at real mainnet, not 127.0.0.1 — so here we
# play solver+treasury via impersonation. The lender's app code is untouched/real.
#
# Effect: user loses <sellAmount> szipUSD, gains <buyUsdc> USDC; ExitGate.burnFor
# retires the bought szipUSD + matching Loot (NAV/share accretes to stayers).
#
# Usage: ./sim-exit-fill.sh <userAddress> <sellAmountSzip18>   (amount in 18-dp wei)
set -euo pipefail

RPC="${RPC:-http://127.0.0.1:8545}"
USER_ADDR="${1:?user address required}"
SELL="${2:?sell amount (szipUSD, 18-dp wei) required}"

SZIP=0x33aD3E23ae6189055925ba2265041AcCA356b4E4
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
EXITGATE=0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e
BUYBURN=0x12881a80c4f4eee7430d1c1c53bbbcfc4c92f71b

ENGINE=$(cast call $EXITGATE "engineSafe()(address)" --rpc-url "$RPC")
WC=$(cast call $EXITGATE "windowController()(address)" --rpc-url "$RPC")
QMAX=$(cast call $BUYBURN "quoteMaxPrice()(uint256)" --rpc-url "$RPC" | awk '{print $1}')

# USDC the treasury bid pays: sellAmount(18dp) * quoteMaxPrice(6dp-per-1e18-share) / 1e18
BUYUSDC=$(cast --to-dec "$(python3 -c "print($SELL * $QMAX // (10**18))")" 2>/dev/null || python3 -c "print($SELL * $QMAX // (10**18))")

echo "user=$USER_ADDR  sell=$SELL szip  ->  pay=$BUYUSDC USDC (qMax=$QMAX)"
echo "engineSafe=$ENGINE  windowController=$WC"

bal() { cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$RPC" | awk '{print $1}'; }
echo "BEFORE  user szip=$(bal $SZIP $USER_ADDR)  user usdc=$(bal $USDC $USER_ADDR)  engine usdc=$(bal $USDC $ENGINE)  szipSupply=$(cast call $SZIP 'totalSupply()(uint256)' --rpc-url $RPC | awk '{print $1}')"

imp() { cast rpc anvil_impersonateAccount "$1" --rpc-url "$RPC" >/dev/null; cast rpc anvil_setBalance "$1" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null; }
stop() { cast rpc anvil_stopImpersonatingAccount "$1" --rpc-url "$RPC" >/dev/null; }

# 1) solver pulls the lender's szipUSD to the treasury (the "fill")
imp "$USER_ADDR"
cast send "$SZIP" "transfer(address,uint256)" "$ENGINE" "$SELL" --from "$USER_ADDR" --unlocked --rpc-url "$RPC" >/dev/null
stop "$USER_ADDR"

# 2) treasury pays the lender USDC (the proceeds)
imp "$ENGINE"
cast send "$USDC" "transfer(address,uint256)" "$USER_ADDR" "$BUYUSDC" --from "$ENGINE" --unlocked --rpc-url "$RPC" >/dev/null
stop "$ENGINE"

# 3) windowController retires the bought szipUSD via the REAL ExitGate.burnFor
imp "$WC"
cast send "$EXITGATE" "burnFor(uint256)" "$SELL" --from "$WC" --unlocked --rpc-url "$RPC" >/dev/null
stop "$WC"

echo "AFTER   user szip=$(bal $SZIP $USER_ADDR)  user usdc=$(bal $USDC $USER_ADDR)  engine usdc=$(bal $USDC $ENGINE)  szipSupply=$(cast call $SZIP 'totalSupply()(uint256)' --rpc-url $RPC | awk '{print $1}')"
echo "OK — exit settled on the fork."
