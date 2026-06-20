package quote

import (
	"context"
	"fmt"
	"math/big"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"cre-keeper/internal/chain"
)

// precision is the canonical ICHIVault.deposit PRECISION (1e18) — the fixed-point
// scale getQuoteAtTick is computed in (token1 out for 1e18 token0). Confirmed
// against the canonical ICHIVault.deposit formula pinned in the ticket and the
// _fetchSpot/_fetchTwap = getQuoteAtTick(tick, PRECISION, tokenIn, tokenOut)
// form.
var precision = func() *big.Int { v, _ := new(big.Int).SetString("1000000000000000000", 10); return v }()

// Quoter is the off-chain price/share seam. Each method returns the RAW quote;
// the StrikeLoopJob applies its own cushion floor. Injectable so the Job tests
// use a scripted fake (no live Algebra/ICHI contracts).
type Quoter interface {
	// HydxToUsdc returns the USDC (6dp) out for amountIn HYDX (18dp), from the
	// HYDX/USDC pool globalState() sqrtPrice: outUsdcRaw = amountInRaw·sqrtP²/2¹⁹²
	// (token0=HYDX, token1=USDC → yields 6dp directly). Used for sellHydx minOut.
	HydxToUsdc(ctx context.Context, amountIn *big.Int) (*big.Int, error)
	// HydxPriceUsdc returns the USDC (6dp) per ONE HYDX (= HydxToUsdc(1e18)), the
	// taper/halt level check.
	HydxPriceUsdc(ctx context.Context) (*big.Int, error)
	// ZipToShares returns the expected ICHI shares for depositing depositZip on
	// the zipUSD side of the vault (single-sided), per the EXACT canonical
	// ICHIVault.deposit formula, AND which side of the vault the recycled zipUSD
	// is (zipIsToken0). The production impl resolves zipUSD off the recycle module
	// (recycle.zipDepositModule().zipUSD()) and compares it to vault.token0(); the
	// Job uses the flag to build addLiquidity on the correct side. Used for
	// addLiquidity minShares + deposit-side routing.
	ZipToShares(ctx context.Context, recycle, vault common.Address, depositZip *big.Int) (shares *big.Int, zipIsToken0 bool, err error)
}

// ProdQuoter binds the Quoter methods to live pools + ICHI vault views via a
// chain.Reader. It is re-pointable-safe: it holds only the HYDX/USDC pool and the
// TWAP window; the LP vault is passed per-call (the Job reads it off
// LpStrategyModule.ichiVault() each tick) and the LP pool is read off
// vault.pool().
type ProdQuoter struct {
	r          chain.Reader
	hydxPool   common.Address // the HYDX/USDC Algebra pool (token0=HYDX, token1=USDC)
	twapWindow uint32         // the ICHI TWAP window in seconds (ZipToShares mean tick)
}

// NewProdQuoter builds the production Quoter.
func NewProdQuoter(r chain.Reader, hydxPool common.Address, twapWindow uint32) *ProdQuoter {
	return &ProdQuoter{r: r, hydxPool: hydxPool, twapWindow: twapWindow}
}

// HydxToUsdc reads the HYDX/USDC pool globalState() sqrtPrice and computes
// outUsdcRaw = amountInRaw·sqrtP²/2¹⁹². token0=HYDX (18dp), token1=USDC (6dp), so
// the raw price already bakes in the decimals: the result is 6dp USDC directly,
// NO extra 1e12 factor (binding #1).
func (q *ProdQuoter) HydxToUsdc(ctx context.Context, amountIn *big.Int) (*big.Int, error) {
	sqrtP, _, err := chain.CallGlobalState(ctx, q.r, q.hydxPool)
	if err != nil {
		return nil, fmt.Errorf("quote: globalState on HYDX/USDC pool %s: %w", q.hydxPool.Hex(), err)
	}
	// out = amountIn * sqrtP^2 / 2^192 (token0 -> token1).
	sqp := new(big.Int).Mul(sqrtP, sqrtP)
	return mulDiv(amountIn, sqp, two192), nil
}

// HydxPriceUsdc = HydxToUsdc(1e18).
func (q *ProdQuoter) HydxPriceUsdc(ctx context.Context) (*big.Int, error) {
	return q.HydxToUsdc(ctx, precision)
}

// ZipToShares replicates the canonical ICHIVault.deposit single-sided share math
// EXACTLY (binding #2) and resolves which vault side is the recycled zipUSD so the
// Job can route the single-sided deposit correctly. For a single-sided deposit on
// the zipUSD side, the OTHER side's deposit = 0, totalSupply > 0:
//
//	spotTick = the LP pool globalState() current tick
//	meanTick = the LP pool TWAP-mean tick over twapWindow (the _meanTick logic
//	           from contracts/src/supply/lib/IchiAlgebraFairReserves.sol:75-87)
//	price = getQuoteAtTick(spotTick, 1e18, token0, token1)  // token1 per 1e18 token0
//	twap  = getQuoteAtTick(meanTick, 1e18, token0, token1)
//	(pool0, pool1) = ICHIVault.getTotalAmounts()
//	numerator        = depositZip * min(price,twap) / 1e18   if zipUSD == token0
//	                 = depositZip                             if zipUSD == token1 (already in token1 terms)
//	shares           = numerator * totalSupply / (pool0*max(price,twap)/1e18 + pool1)
//
// Side determination (§17 re-pointable, read each tick, never cached): zipUSD is
// resolved off the recycle module — recycle.zipDepositModule() → zdm.zipUSD() —
// then zipIsToken0 = (zipUSD == vault.token0()). price/twap are ALWAYS computed in
// token0->token1 terms regardless of which side is deposited; only the numerator
// (whether the deposit is priced by min(price,twap)) depends on the side. If
// zipUSD matches NEITHER vault token the vault is not the zipUSD/xALPHA vault (a
// bad re-point) and a descriptive error is returned.
func (q *ProdQuoter) ZipToShares(ctx context.Context, recycle, vault common.Address, depositZip *big.Int) (*big.Int, bool, error) {
	// Resolve the recycled zipUSD off the recycle module: recycle.zipDepositModule() → zdm.zipUSD().
	zdm, err := chain.CallAddress(ctx, q.r, recycle, "zipDepositModule()")
	if err != nil {
		return nil, false, fmt.Errorf("quote: zipDepositModule() on recycle %s: %w", recycle.Hex(), err)
	}
	zipUSD, err := chain.CallAddress(ctx, q.r, zdm, "zipUSD()")
	if err != nil {
		return nil, false, fmt.Errorf("quote: zipUSD() on zipDepositModule %s: %w", zdm.Hex(), err)
	}

	// token0 / token1 off the vault (for the getQuoteAtTick address-order direction AND the side flag).
	token0, err := chain.CallAddress(ctx, q.r, vault, "token0()")
	if err != nil {
		return nil, false, fmt.Errorf("quote: token0() on vault %s: %w", vault.Hex(), err)
	}
	token1, err := chain.CallAddress(ctx, q.r, vault, "token1()")
	if err != nil {
		return nil, false, fmt.Errorf("quote: token1() on vault %s: %w", vault.Hex(), err)
	}
	// Side determination: zipUSD must be one of the vault's two tokens.
	zipIsToken0 := zipUSD == token0
	if !zipIsToken0 && zipUSD != token1 {
		return nil, false, fmt.Errorf("quote: recycled zipUSD %s matches neither token0 %s nor token1 %s on vault %s (not the zipUSD/xALPHA vault — bad re-point)",
			zipUSD.Hex(), token0.Hex(), token1.Hex(), vault.Hex())
	}
	// The LP pool the vault provides liquidity to (the spot/TWAP source).
	pool, err := chain.CallAddress(ctx, q.r, vault, "pool()")
	if err != nil {
		return nil, false, fmt.Errorf("quote: pool() on vault %s: %w", vault.Hex(), err)
	}
	// totalSupply + getTotalAmounts off the vault.
	totalSupply, err := chain.CallUint(ctx, q.r, vault, "totalSupply()")
	if err != nil {
		return nil, false, fmt.Errorf("quote: totalSupply() on vault %s: %w", vault.Hex(), err)
	}
	pool0, pool1, err := chain.CallTwoUints(ctx, q.r, vault, "getTotalAmounts()")
	if err != nil {
		return nil, false, fmt.Errorf("quote: getTotalAmounts() on vault %s: %w", vault.Hex(), err)
	}

	// spot tick from the LP pool globalState() (2nd return field).
	_, spotTickBig, err := chain.CallGlobalState(ctx, q.r, pool)
	if err != nil {
		return nil, false, fmt.Errorf("quote: globalState() on LP pool %s: %w", pool.Hex(), err)
	}
	// TWAP-mean tick via the pool's oracle plugin getTimepoints — the _meanTick logic.
	meanTickBig, err := q.meanTick(ctx, pool)
	if err != nil {
		return nil, false, err
	}

	baseLess := token0.Cmp(token1) < 0 // baseToken(token0) < quoteToken(token1)?
	price := getQuoteAtTick(spotTickBig.Int64(), precision, baseLess)
	twap := getQuoteAtTick(meanTickBig.Int64(), precision, baseLess)

	return ichiSingleSidedShares(depositZip, totalSupply, pool0, pool1, price, twap, zipIsToken0), zipIsToken0, nil
}

// meanTick ports IchiAlgebraFairReserves._meanTick
// (contracts/src/supply/lib/IchiAlgebraFairReserves.sol:75-87): read plugin off
// the pool, getTimepoints([window, 0]) → tickCumulatives, then
// mean = (cum[1]-cum[0]) / window, rounded toward negative infinity on a
// negative remainder (the UniV3/OracleLibrary convention).
func (q *ProdQuoter) meanTick(ctx context.Context, pool common.Address) (*big.Int, error) {
	plugin, err := chain.CallAddress(ctx, q.r, pool, "plugin()")
	if err != nil {
		return nil, fmt.Errorf("quote: plugin() on pool %s: %w", pool.Hex(), err)
	}
	if plugin == (common.Address{}) {
		return nil, fmt.Errorf("quote: pool %s has no plugin (no TWAP source)", pool.Hex())
	}
	cum0, cum1, err := callGetTimepoints(ctx, q.r, plugin, q.twapWindow)
	if err != nil {
		return nil, fmt.Errorf("quote: getTimepoints on plugin %s: %w", plugin.Hex(), err)
	}
	w := new(big.Int).SetUint64(uint64(q.twapWindow))
	delta := new(big.Int).Sub(cum1, cum0) // tickCumulative(now) - tickCumulative(window ago)
	mean := new(big.Int).Quo(delta, w)    // Quo truncates toward zero
	// round toward negative infinity on a negative numerator with nonzero remainder.
	rem := new(big.Int).Rem(delta, w)
	if delta.Sign() < 0 && rem.Sign() != 0 {
		mean.Sub(mean, big.NewInt(1))
	}
	return mean, nil
}

// callGetTimepoints calls the Algebra plugin getTimepoints(uint32[]) with
// [window, 0] (older, now) and returns tickCumulatives[0], tickCumulatives[1].
// Signature confirmed against
// contracts/src/interfaces/algebra/IAlgebraOraclePlugin.sol:13-16:
//
//	getTimepoints(uint32[] secondsAgos) returns(int56[] tickCumulatives, uint88[] volatilityCumulatives)
func callGetTimepoints(ctx context.Context, r chain.Reader, plugin common.Address, window uint32) (*big.Int, *big.Int, error) {
	u32Arr, err := abi.NewType("uint32[]", "", nil)
	if err != nil {
		return nil, nil, err
	}
	packed, err := abi.Arguments{{Type: u32Arr}}.Pack([]uint32{window, 0})
	if err != nil {
		return nil, nil, err
	}
	sel := selectorBytes("getTimepoints(uint32[])")
	data, err := r.CallContract(ctx, ethereum.CallMsg{To: &plugin, Data: append(sel, packed...)}, nil)
	if err != nil {
		return nil, nil, err
	}
	i56Arr, err := abi.NewType("int56[]", "", nil)
	if err != nil {
		return nil, nil, err
	}
	u88Arr, err := abi.NewType("uint88[]", "", nil)
	if err != nil {
		return nil, nil, err
	}
	out, err := abi.Arguments{{Type: i56Arr}, {Type: u88Arr}}.Unpack(data)
	if err != nil {
		return nil, nil, err
	}
	cum, ok := out[0].([]*big.Int)
	if !ok || len(cum) != 2 {
		return nil, nil, fmt.Errorf("quote: getTimepoints returned %d tickCumulatives, want 2", len(cum))
	}
	return cum[0], cum[1], nil
}

// ichiSingleSidedShares is the pure share-math kernel (no I/O) so it can be
// unit-tested directly. depositZip is the single-sided deposit of the recycled
// zipUSD; zipIsToken0 says which vault side it is (the OTHER side's deposit = 0).
// price/twap are getQuoteAtTick(tick, 1e18) (token1 per 1e18 token0), ALWAYS
// token0->token1 regardless of the deposit side. The numerator is the deposit
// expressed in token1 terms: when zipUSD is token0 it is priced at the WORSE
// (min) price; when zipUSD is token1 it is ALREADY in token1 terms so it is taken
// raw (NOT priced). The denominator (pool valued at the BETTER price) is
// side-independent. Returns 0 if the denominator is 0 (degenerate empty pool —
// the Job then skips restake on minShares==0).
func ichiSingleSidedShares(depositZip, totalSupply, pool0, pool1, price, twap *big.Int, zipIsToken0 bool) *big.Int {
	// ICHI values the deposit at the WORSE price (min) and the pool at the BETTER (max).
	worse := minBig(price, twap)
	better := maxBig(price, twap)

	// numerator (deposit in token1 terms):
	//   zipUSD == token0 (deposit1 = 0): depositZip * min(price,twap) / 1e18
	//   zipUSD == token1 (deposit0 = 0): depositZip raw (already token1 terms)
	var numerator *big.Int
	if zipIsToken0 {
		numerator = mulDiv(depositZip, worse, precision)
	} else {
		numerator = new(big.Int).Set(depositZip)
	}
	// denom = pool0 * max(price,twap) / 1e18 + pool1
	denom := new(big.Int).Add(mulDiv(pool0, better, precision), pool1)
	if denom.Sign() == 0 {
		return big.NewInt(0)
	}
	// shares = numerator * totalSupply / denom  (the other side's deposit = 0, single-sided)
	return mulDiv(numerator, totalSupply, denom)
}

func minBig(a, b *big.Int) *big.Int {
	if a.Cmp(b) <= 0 {
		return a
	}
	return b
}

func maxBig(a, b *big.Int) *big.Int {
	if a.Cmp(b) >= 0 {
		return a
	}
	return b
}
