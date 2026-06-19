package quote

import (
	"context"
	"errors"
	"math/big"
	"testing"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

func bigFromStr(s string) *big.Int { v, _ := new(big.Int).SetString(s, 10); return v }

// ---- TickMath vectors (the OWN unit test; canonical UniV3 tick→sqrtRatio) ----

func TestGetSqrtRatioAtTick_KnownVectors(t *testing.T) {
	cases := []struct {
		tick int64
		want string
	}{
		{0, "79228162514264337593543950336"}, // 2^96
		{1, "79232123823359799118286999568"},
		{-1, "79224201403219477170569942574"},
		{50, "79426470787362580746886972461"},
		{-50, "79030349367926598376800521322"},
		{100, "79625275426524748796330556128"},
		{887272, "1461446703485210103287273052203988822378723970342"}, // MAX_SQRT_RATIO
		{-887272, "4295128739"},                                       // MIN_SQRT_RATIO
		{200000, "1744244129640337381386292603617838"},
		{-200000, "3598751819609688046946419"},
	}
	for _, c := range cases {
		got := getSqrtRatioAtTick(c.tick)
		if got.String() != c.want {
			t.Errorf("getSqrtRatioAtTick(%d) = %s, want %s", c.tick, got.String(), c.want)
		}
	}
}

// getQuoteAtTick at tick 0 ⇒ ratio 1:1 ⇒ quote == baseAmount in both directions.
func TestGetQuoteAtTick_Tick0_Identity(t *testing.T) {
	base := bigFromStr("1000000000000000000") // 1e18
	if g := getQuoteAtTick(0, base, true); g.Cmp(base) != 0 {
		t.Errorf("getQuoteAtTick(0, 1e18, baseLess) = %s, want 1e18", g)
	}
	if g := getQuoteAtTick(0, base, false); g.Cmp(base) != 0 {
		t.Errorf("getQuoteAtTick(0, 1e18, !baseLess) = %s, want 1e18", g)
	}
}

// ---- scripted chain.Reader for the production Quoter ----

func sel(sig string) [4]byte {
	var s [4]byte
	copy(s[:], crypto.Keccak256([]byte(sig))[:4])
	return s
}

func encUint(v *big.Int) []byte {
	u, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u}}.Pack(v)
	return out
}

func encTwoUint(a, b *big.Int) []byte {
	u, _ := abi.NewType("uint256", "", nil)
	out, _ := abi.Arguments{{Type: u}, {Type: u}}.Pack(a, b)
	return out
}

func encAddr(a common.Address) []byte {
	t, _ := abi.NewType("address", "", nil)
	out, _ := abi.Arguments{{Type: t}}.Pack(a)
	return out
}

// encGlobalState packs (uint160 price, int24 tick, uint16, uint8, uint16, bool).
func encGlobalState(sqrtP *big.Int, tick int64) []byte {
	u160, _ := abi.NewType("uint160", "", nil)
	i24, _ := abi.NewType("int24", "", nil)
	u16, _ := abi.NewType("uint16", "", nil)
	u8, _ := abi.NewType("uint8", "", nil)
	b, _ := abi.NewType("bool", "", nil)
	out, _ := abi.Arguments{{Type: u160}, {Type: i24}, {Type: u16}, {Type: u8}, {Type: u16}, {Type: b}}.Pack(
		sqrtP, big.NewInt(tick), uint16(500), uint8(0), uint16(0), true)
	return out
}

// encTimepoints packs (int56[] tickCumulatives, uint88[] volatilityCumulatives).
func encTimepoints(cum0, cum1 int64) []byte {
	i56, _ := abi.NewType("int56[]", "", nil)
	u88, _ := abi.NewType("uint88[]", "", nil)
	out, _ := abi.Arguments{{Type: i56}, {Type: u88}}.Pack(
		[]*big.Int{big.NewInt(cum0), big.NewInt(cum1)},
		[]*big.Int{big.NewInt(0), big.NewInt(0)})
	return out
}

// scriptedReader returns canned values keyed by (toAddr, selector). Used to drive
// the production Quoter without live contracts.
type scriptedReader struct {
	// keyed responses
	globalState map[common.Address][]byte  // toAddr -> globalState() return
	timepoints  map[common.Address][]byte  // plugin -> getTimepoints return
	addrs       map[[4]byte]common.Address // selector -> address (token0/token1/pool/plugin)
	uints       map[[4]byte]*big.Int       // selector -> uint (totalSupply)
	twoUints    map[[4]byte][2]*big.Int    // selector -> two-uint (getTotalAmounts)
	err         error
}

func (s *scriptedReader) CallContract(ctx context.Context, call ethereum.CallMsg, _ *big.Int) ([]byte, error) {
	if s.err != nil {
		return nil, s.err
	}
	var sg [4]byte
	copy(sg[:], call.Data[:4])
	to := *call.To
	switch sg {
	case sel("globalState()"):
		if v, ok := s.globalState[to]; ok {
			return v, nil
		}
	case sel("getTimepoints(uint32[])"):
		if v, ok := s.timepoints[to]; ok {
			return v, nil
		}
	case sel("totalSupply()"):
		return encUint(s.uints[sg]), nil
	case sel("getTotalAmounts()"):
		v := s.twoUints[sg]
		return encTwoUint(v[0], v[1]), nil
	default:
		if a, ok := s.addrs[sg]; ok {
			return encAddr(a), nil
		}
	}
	return nil, errors.New("scriptedReader: unexpected call")
}

// TestHydxToUsdc_DecimalsCorrect: token0=HYDX(18dp), token1=USDC(6dp), so
// out = amountIn·sqrtP²/2¹⁹² yields 6dp USDC directly (no 1e12 error). With a
// sqrtP chosen for ≈ $0.018/HYDX, HydxToUsdc(1e18) ≈ 18000 (USDC 6dp) and
// HydxPriceUsdc == HydxToUsdc(1e18).
func TestHydxToUsdc_DecimalsCorrect(t *testing.T) {
	pool := common.HexToAddress("0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2")
	// sqrtPriceX96 for price1/0(raw) = 0.018 * 1e6 / 1e18 = 1.8e-14.
	// sqrtP = sqrt(1.8e-14) * 2^96. Computed offline ≈ 1.062566e22. Use the exact
	// value and assert the formula result independently rather than a magic number.
	sqrtP := bigFromStr("10625666170418502828032") // ≈ 1.0626e22
	r := &scriptedReader{
		globalState: map[common.Address][]byte{pool: encGlobalState(sqrtP, -310830)},
	}
	q := NewProdQuoter(r, pool, 3600)

	amountIn := bigFromStr("1000000000000000000") // 1 HYDX (1e18)
	got, err := q.HydxToUsdc(context.Background(), amountIn)
	if err != nil {
		t.Fatalf("HydxToUsdc: %v", err)
	}
	// independent recompute: amountIn * sqrtP^2 / 2^192.
	want := new(big.Int).Mul(amountIn, new(big.Int).Mul(sqrtP, sqrtP))
	want.Div(want, new(big.Int).Lsh(big.NewInt(1), 192))
	if got.Cmp(want) != 0 {
		t.Errorf("HydxToUsdc = %s, want %s", got, want)
	}
	// sanity: the 6dp price is in the right ballpark ($0.017–$0.019 → 17000–19000).
	if got.Cmp(big.NewInt(17000)) < 0 || got.Cmp(big.NewInt(19000)) > 0 {
		t.Errorf("HydxToUsdc(1 HYDX) = %s (6dp), want ≈18000 (no decimals error)", got)
	}

	// HydxPriceUsdc == HydxToUsdc(1e18).
	pr, err := q.HydxPriceUsdc(context.Background())
	if err != nil {
		t.Fatalf("HydxPriceUsdc: %v", err)
	}
	if pr.Cmp(got) != 0 {
		t.Errorf("HydxPriceUsdc = %s, want == HydxToUsdc(1e18) = %s", pr, got)
	}
}

// TestZipToShares_ScriptedFormula drives ZipToShares through scripted vault +
// pool reads and asserts the result == the pure ichiSingleSidedShares kernel
// (price/twap at the scripted ticks), proving the production path wires the
// formula correctly.
func TestZipToShares_ScriptedFormula(t *testing.T) {
	vault := common.HexToAddress("0xfF8B29e9f536F9A43DA7868011b7B667fa8d73f7")
	pool := common.HexToAddress("0x51f0B932855986B0E621c9D4DB6Eee1f4644D3D2")
	plugin := common.HexToAddress("0xe33a242990780Ab872Ae986AD68206478Fc85Ae1")
	token0 := common.HexToAddress("0x0000000000000000000000000000000000000001") // zipUSD side (token0 < token1)
	token1 := common.HexToAddress("0x0000000000000000000000000000000000000002")

	totalSupply := bigFromStr("1000000000000000000000") // 1000e18
	pool0 := bigFromStr("500000000000000000000")        // 500e18 token0
	pool1 := bigFromStr("500000000000000000000")        // 500e18 token1

	// spot tick 0; TWAP window 3600s; cumulatives chosen so mean tick = 0:
	// (cum1 - cum0) / 3600 = 0.
	r := &scriptedReader{
		globalState: map[common.Address][]byte{pool: encGlobalState(getSqrtRatioAtTick(0), 0)},
		timepoints:  map[common.Address][]byte{plugin: encTimepoints(1000, 1000)},
		addrs: map[[4]byte]common.Address{
			sel("token0()"): token0,
			sel("token1()"): token1,
			sel("pool()"):   pool,
			sel("plugin()"): plugin,
		},
		uints:    map[[4]byte]*big.Int{sel("totalSupply()"): totalSupply},
		twoUints: map[[4]byte][2]*big.Int{sel("getTotalAmounts()"): {pool0, pool1}},
	}
	q := NewProdQuoter(r, pool, 3600)

	depositZip := bigFromStr("100000000000000000000") // 100e18
	got, err := q.ZipToShares(context.Background(), vault, depositZip)
	if err != nil {
		t.Fatalf("ZipToShares: %v", err)
	}

	// independent recompute via the kernel (price==twap at tick 0 → both 1e18).
	price := getQuoteAtTick(0, precision, token0.Cmp(token1) < 0)
	want := ichiSingleSidedShares(depositZip, totalSupply, pool0, pool1, price, price)
	if got.Cmp(want) != 0 {
		t.Errorf("ZipToShares = %s, want %s", got, want)
	}

	// At spot==twap==1:1 and 50/50 pool, depositing 100e18 token0 into a 1000e18-share
	// pool (1000e18 total value) ⇒ shares = 100e18*1000e18 / (500e18*1 + 500e18) = 100e18.
	wantExact := bigFromStr("100000000000000000000")
	if got.Cmp(wantExact) != 0 {
		t.Errorf("ZipToShares (balanced 1:1) = %s, want 100e18 exactly", got)
	}
}

// TestZipToShares_WorseBetterPriceSelection: spot != twap ⇒ the deposit is valued
// at the WORSE (min) price and the pool at the BETTER (max) price (a strictly
// LOWER share count than valuing both at the same favorable price — the
// conservative floor).
func TestZipToShares_WorseBetterPriceSelection(t *testing.T) {
	depositSide0 := bigFromStr("100000000000000000000")
	totalSupply := bigFromStr("1000000000000000000000")
	pool0 := bigFromStr("500000000000000000000")
	pool1 := bigFromStr("500000000000000000000")

	price := bigFromStr("1200000000000000000") // 1.2 (token1 per token0)
	twap := bigFromStr("1000000000000000000")  // 1.0

	got := ichiSingleSidedShares(depositSide0, totalSupply, pool0, pool1, price, twap)
	// depositPricedIn1 = 100e18 * min(1.2,1.0) = 100e18*1.0 = 100e18
	// denom = pool0*max(1.2,1.0) + pool1 = 500e18*1.2 + 500e18 = 600e18+500e18 = 1100e18
	// shares = 100e18 * 1000e18 / 1100e18 = 90.909...e18
	want := bigFromStr("90909090909090909090")
	if got.Cmp(want) != 0 {
		t.Errorf("ichiSingleSidedShares (worse/better) = %s, want %s", got, want)
	}
}

func TestZipToShares_ReaderErrorPropagates(t *testing.T) {
	r := &scriptedReader{err: errors.New("rpc down")}
	q := NewProdQuoter(r, common.Address{}, 3600)
	if _, err := q.ZipToShares(context.Background(), common.Address{}, big.NewInt(1)); err == nil {
		t.Fatal("expected read error to propagate")
	}
}
