package chain

import (
	"context"
	"math/big"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// Reader is the minimal view-read seam jobs read through (Chain and the raw
// clients all satisfy it). Block arg nil = latest.
type Reader interface {
	CallContract(ctx context.Context, call ethereum.CallMsg, blockNumber *big.Int) ([]byte, error)
}

// selector returns the 4-byte function selector for a canonical signature,
// e.g. "operator()" — mirrors cre/buyburn-bid/workflow.go:289.
func selector(sig string) []byte {
	return crypto.Keccak256([]byte(sig))[:4]
}

// callView dispatches a view call (From left zero) and returns the raw ABI bytes.
func callView(ctx context.Context, r Reader, to common.Address, data []byte) ([]byte, error) {
	return r.CallContract(ctx, ethereum.CallMsg{To: &to, Data: data}, nil)
}

// CallUint reads a no-arg view returning a single uint (uint256/uint48/… all
// decode into *big.Int).
func CallUint(ctx context.Context, r Reader, to common.Address, sig string) (*big.Int, error) {
	data, err := callView(ctx, r, to, selector(sig))
	if err != nil {
		return nil, err
	}
	return decodeUint(data)
}

// CallUintWithAddr reads a single-address-arg view returning a uint
// (e.g. balanceOf(address)).
func CallUintWithAddr(ctx context.Context, r Reader, to common.Address, sig string, arg common.Address) (*big.Int, error) {
	addrT, err := abi.NewType("address", "", nil)
	if err != nil {
		return nil, err
	}
	packed, err := abi.Arguments{{Type: addrT}}.Pack(arg)
	if err != nil {
		return nil, err
	}
	data, err := callView(ctx, r, to, append(selector(sig), packed...))
	if err != nil {
		return nil, err
	}
	return decodeUint(data)
}

// CallBool reads a no-arg view returning a single bool.
func CallBool(ctx context.Context, r Reader, to common.Address, sig string) (bool, error) {
	data, err := callView(ctx, r, to, selector(sig))
	if err != nil {
		return false, err
	}
	boolT, err := abi.NewType("bool", "", nil)
	if err != nil {
		return false, err
	}
	out, err := abi.Arguments{{Type: boolT}}.Unpack(data)
	if err != nil {
		return false, err
	}
	return out[0].(bool), nil
}

// CallAddress reads a no-arg view returning a single address.
func CallAddress(ctx context.Context, r Reader, to common.Address, sig string) (common.Address, error) {
	data, err := callView(ctx, r, to, selector(sig))
	if err != nil {
		return common.Address{}, err
	}
	addrT, err := abi.NewType("address", "", nil)
	if err != nil {
		return common.Address{}, err
	}
	out, err := abi.Arguments{{Type: addrT}}.Unpack(data)
	if err != nil {
		return common.Address{}, err
	}
	return out[0].(common.Address), nil
}

func decodeUint(data []byte) (*big.Int, error) {
	u256, err := abi.NewType("uint256", "", nil)
	if err != nil {
		return nil, err
	}
	out, err := abi.Arguments{{Type: u256}}.Unpack(data)
	if err != nil {
		return nil, err
	}
	return out[0].(*big.Int), nil
}
