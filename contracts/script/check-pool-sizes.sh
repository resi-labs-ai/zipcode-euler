#!/usr/bin/env bash
# check-pool-sizes.sh — the EIP-170 guard for the two CCT pool contracts.
#
# Both pools exceed the 24,576-byte runtime limit at the repo's default optimizer_runs = 20_000
# (found in the Phase-B deploy — forge tests never enforce runtime size, so nothing red happens
# until a mainnet deploy reverts with "max code size exceeded"). Production deploys use the
# `pools` profile (optimizer_runs = 200); this script asserts that profile still fits, so the trap
# cannot re-arm silently as the contracts grow. Run it in CI or before any pool deploy.
set -euo pipefail
cd "$(dirname "$0")/.."

LIMIT=24576
POOLS=(SzAlphaLockReleasePool SzAlphaTokenPool)

fail=0
for c in "${POOLS[@]}"; do
    bytecode=$(FOUNDRY_PROFILE=pools forge inspect "$c" deployedBytecode 2>/dev/null | tr -d '\n' | tail -c +1)
    if [[ -z "$bytecode" || "$bytecode" == "0x" ]]; then
        echo "FAIL  $c: could not read deployedBytecode (build error?)"
        fail=1
        continue
    fi
    size=$(( (${#bytecode} - 2) / 2 ))
    if (( size > LIMIT )); then
        echo "FAIL  $c: $size bytes > $LIMIT (EIP-170) under the pools profile — deploy WILL revert"
        fail=1
    else
        echo "ok    $c: $size bytes <= $LIMIT (pools profile, optimizer_runs=200)"
    fi
done

exit $fail
