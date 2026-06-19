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

// CallUintWithUint reads a single-uint256-arg view returning a uint
// (e.g. quoteStrike(uint256)).
func CallUintWithUint(ctx context.Context, r Reader, to common.Address, sig string, arg *big.Int) (*big.Int, error) {
	packed, err := abi.Arguments{{Type: uint256T}}.Pack(arg)
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

// CallGlobalState reads an Algebra pool globalState() and returns the
// sqrtPriceX96 (1st field) and the current tick (2nd field). The full tuple is
// (uint160 price, int24 tick, uint16 lastFee, uint8 pluginConfig, uint16
// communityFee, bool unlocked) — see contracts/src/interfaces/algebra/
// IAlgebraPool.sol:20-23. Only the price + tick are load-bearing for the
// keeper's quote math; the trailing fields are decoded (so the ABI lengths line
// up) and discarded.
func CallGlobalState(ctx context.Context, r Reader, pool common.Address) (sqrtPriceX96 *big.Int, tick *big.Int, err error) {
	data, err := callView(ctx, r, pool, selector("globalState()"))
	if err != nil {
		return nil, nil, err
	}
	u160T, err := abi.NewType("uint160", "", nil)
	if err != nil {
		return nil, nil, err
	}
	i24T, err := abi.NewType("int24", "", nil)
	if err != nil {
		return nil, nil, err
	}
	u16T, err := abi.NewType("uint16", "", nil)
	if err != nil {
		return nil, nil, err
	}
	u8T, err := abi.NewType("uint8", "", nil)
	if err != nil {
		return nil, nil, err
	}
	boolT, err := abi.NewType("bool", "", nil)
	if err != nil {
		return nil, nil, err
	}
	out, err := abi.Arguments{
		{Type: u160T}, {Type: i24T}, {Type: u16T}, {Type: u8T}, {Type: u16T}, {Type: boolT},
	}.Unpack(data)
	if err != nil {
		return nil, nil, err
	}
	// uint160 → *big.Int; int24 → *big.Int (go-ethereum decodes int24 to *big.Int).
	return out[0].(*big.Int), out[1].(*big.Int), nil
}

// CallTwoUints reads a no-arg view returning two uint256 (e.g. ICHIVault
// getTotalAmounts() returns(uint256 total0, uint256 total1)).
func CallTwoUints(ctx context.Context, r Reader, to common.Address, sig string) (*big.Int, *big.Int, error) {
	data, err := callView(ctx, r, to, selector(sig))
	if err != nil {
		return nil, nil, err
	}
	out, err := abi.Arguments{{Type: uint256T}, {Type: uint256T}}.Unpack(data)
	if err != nil {
		return nil, nil, err
	}
	return out[0].(*big.Int), out[1].(*big.Int), nil
}

// uint256T is the single-uint256 ABI type, shared with encode.go (same package).

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
