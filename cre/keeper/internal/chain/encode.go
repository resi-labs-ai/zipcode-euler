package chain

import (
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
)

// uint256T is the single-uint256 ABI type, built once at package init (mirrors
// the read.go decodeUint idiom). abi.NewType("uint256",…) cannot fail for a
// compile-time-constant type string, so the error is dropped with _.
var uint256T, _ = abi.NewType("uint256", "", nil)

// PackUintCall builds write calldata for a one-uint256-arg call:
// selector(sig) ++ abi.encode(uint256 v). It is exported so jobs (in package
// job) can build write calldata — the package-private selector already in
// read.go is reused here (same package).
//
// The signature returns NO error by design: a uint256 arg takes a *big.Int and
// abi.Arguments.Pack(*big.Int) cannot fail for that type, so the error is
// dropped with _. (Contrast the native-uint32/uint8 quirk in
// cre/buyburn-bid/workflow.go:248-252 — uint256 takes a *big.Int, not a native
// int, so there is no type-mismatch failure mode to surface.)
func PackUintCall(sig string, v *big.Int) []byte {
	enc, _ := abi.Arguments{{Type: uint256T}}.Pack(v)
	return append(selector(sig), enc...)
}

// PackCall builds calldata for a no-arg call: just the 4-byte selector(sig).
// Used by StrikeLoopJob for claimReward().
func PackCall(sig string) []byte {
	return selector(sig)
}

// PackUintsCall builds write calldata for an N-uint256-arg call:
// selector(sig) ++ abi.encode(uint256 v0, uint256 v1, …). It is the multi-arg
// companion to PackUintCall, used by StrikeLoopJob for the 3-uint256 legs
// exercise(uint256,uint256,uint256) / sellHydx(uint256,uint256,uint256) /
// addLiquidity(uint256,uint256,uint256). The signature returns NO error by
// design (same rationale as PackUintCall: a *big.Int packed into a uint256 arg
// cannot fail), mirroring the abi.Arguments.Pack idiom in
// cre/buyburn-bid/workflow.go:248-252.
func PackUintsCall(sig string, vs ...*big.Int) []byte {
	args := make(abi.Arguments, len(vs))
	vals := make([]interface{}, len(vs))
	for i, v := range vs {
		args[i] = abi.Argument{Type: uint256T}
		vals[i] = v
	}
	enc, _ := args.Pack(vals...)
	return append(selector(sig), enc...)
}
