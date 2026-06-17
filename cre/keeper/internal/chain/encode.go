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
