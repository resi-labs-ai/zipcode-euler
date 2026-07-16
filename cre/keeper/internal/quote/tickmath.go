// Package quote is the off-chain price/share seam: the read-only Algebra/ICHI
// eth_calls the StrikeLoopJob needs to size its slippage floors (sellHydx minOut
// and addLiquidity minShares). It is split from internal/job so the Job can take
// a Quoter interface and tests can inject a scripted fake — no live Algebra/ICHI
// contracts needed.
//
// tickmath.go ports the Uniswap-V3 tick math the keeper replicates exactly:
//   - getSqrtRatioAtTick — byte-for-byte port of the canonical UniV3 TickMath
//     (the same source vendored in contracts at
//     contracts/src/libraries/ConcentratedLiquidity.sol:85-118).
//   - getQuoteAtTick — the OracleLibrary getQuoteAtTick (token0/token1-ordered),
//     ported from ConcentratedLiquidity.sol:170-189 (TickQuote).
//   - mulDiv — full-precision a*b/denominator (math/big makes this trivial; the
//     Solidity assembly version is only needed to avoid 256-bit overflow on-EVM).
package quote

import (
	"math/big"

	"github.com/ethereum/go-ethereum/crypto"
)

// selectorBytes returns the 4-byte function selector for a canonical signature
// (mirrors chain.selector, which is unexported to package chain).
func selectorBytes(sig string) []byte {
	return crypto.Keccak256([]byte(sig))[:4]
}

// tick math constants (UniV3 TickMath). MIN/MAX tick from
// ConcentratedLiquidity.sol:78-79.
const (
	minTick = -887272
	maxTick = 887272
)

var (
	two96  = new(big.Int).Lsh(big.NewInt(1), 96)  // 2^96
	two192 = new(big.Int).Lsh(big.NewInt(1), 192) // 2^192
	// uint256 max (for the tick>0 reciprocal step).
	uint256Max = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))
)

// hex helper for the magic constants (panics only on a programmer typo, at init).
func hb(s string) *big.Int {
	v, ok := new(big.Int).SetString(s, 16)
	if !ok {
		panic("quote: bad hex constant " + s)
	}
	return v
}

// The 19 magic multipliers from UniV3 TickMath.getSqrtRatioAtTick, in bit order
// (0x1, 0x2, 0x4, …, 0x80000). ConcentratedLiquidity.sol:90-111.
var tickMagic = []*big.Int{
	hb("fff97272373d413259a46990580e213a"), // 0x2
	hb("fff2e50f5f656932ef12357cf3c7fdcc"), // 0x4
	hb("ffe5caca7e10e4e61c3624eaa0941cd0"), // 0x8
	hb("ffcb9843d60f6159c9db58835c926644"), // 0x10
	hb("ff973b41fa98c081472e6896dfb254c0"), // 0x20
	hb("ff2ea16466c96a3843ec78b326b52861"), // 0x40
	hb("fe5dee046a99a2a811c461f1969c3053"), // 0x80
	hb("fcbe86c7900a88aedcffc83b479aa3a4"), // 0x100
	hb("f987a7253ac413176f2b074cf7815e54"), // 0x200
	hb("f3392b0822b70005940c7a398e4b70f3"), // 0x400
	hb("e7159475a2c29b7443b29c7fa6e889d9"), // 0x800
	hb("d097f3bdfd2022b8845ad8f792aa5825"), // 0x1000
	hb("a9f746462d870fdf8a65dc1f90e061e5"), // 0x2000
	hb("70d869a156d2a1b890bb3df62baf32f7"), // 0x4000
	hb("31be135f97d08fd981231505542fcfa6"), // 0x8000
	hb("9aa508b5b7a84e1c677de54f3e99bc9"),  // 0x10000
	hb("5d6af8dedb81196699c329225ee604"),   // 0x20000
	hb("2216e584f5fa1ea926041bedfe98"),     // 0x40000
	hb("48a170391f7dc42444e8fa2"),          // 0x80000
}

var (
	ratioBit0    = hb("fffcb933bd6fad37aa2d162d1a594001") // absTick&0x1 set
	ratioBit0Not = new(big.Int).Lsh(big.NewInt(1), 128)   // 0x1<<128, absTick&0x1 unset
)

// getSqrtRatioAtTick is a faithful Go port of the canonical UniV3
// TickMath.getSqrtRatioAtTick (ConcentratedLiquidity.sol:85-118). It returns the
// Q64.96 sqrtPriceX96 for the given tick. Panics on out-of-range tick (the EVM
// version reverts T()); callers pass ticks read from a live pool so this is a
// programmer-error guard, not a runtime path.
func getSqrtRatioAtTick(tick int64) *big.Int {
	absTick := tick
	if absTick < 0 {
		absTick = -absTick
	}
	if absTick > maxTick {
		panic("quote: tick out of range")
	}

	var ratio *big.Int
	if absTick&0x1 != 0 {
		ratio = new(big.Int).Set(ratioBit0)
	} else {
		ratio = new(big.Int).Set(ratioBit0Not)
	}

	// For each subsequent bit (0x2 .. 0x80000): ratio = (ratio * magic) >> 128.
	bit := int64(0x2)
	for i := 0; i < len(tickMagic); i++ {
		if absTick&bit != 0 {
			ratio.Mul(ratio, tickMagic[i])
			ratio.Rsh(ratio, 128)
		}
		bit <<= 1
	}

	if tick > 0 {
		ratio = new(big.Int).Div(uint256Max, ratio)
	}

	// Q128.128 -> Q128.96, rounding up: (ratio >> 32) + (ratio % (1<<32) == 0 ? 0 : 1).
	out := new(big.Int).Rsh(ratio, 32)
	rem := new(big.Int).And(ratio, big.NewInt(0xffffffff))
	if rem.Sign() != 0 {
		out.Add(out, big.NewInt(1))
	}
	return out
}

// getQuoteAtTick is a faithful Go port of OracleLibrary.getQuoteAtTick
// (ConcentratedLiquidity.sol:170-189, TickQuote). It returns the quoteToken
// amount equivalent to baseAmount of baseToken at the given tick. Direction
// follows the token address order: baseToken < quoteToken ⇒
// mulDiv(ratioX192, baseAmount, 2^192), else mulDiv(2^192, baseAmount,
// ratioX192). With math/big there is no 256-bit overflow concern, so the >uint128
// sqrtRatio split branch is unnecessary (the math is identical) — we always use
// the ratioX192 = sqrtRatio^2 form.
func getQuoteAtTick(tick int64, baseAmount *big.Int, baseTokenLess bool) *big.Int {
	sqrtRatio := getSqrtRatioAtTick(tick)
	ratioX192 := new(big.Int).Mul(sqrtRatio, sqrtRatio)
	if baseTokenLess {
		return mulDiv(ratioX192, baseAmount, two192)
	}
	return mulDiv(two192, baseAmount, ratioX192)
}

// mulDiv returns a*b/denominator at full precision (floor division). The
// Solidity FullMath.mulDiv assembly exists only to avoid 256-bit intermediate
// overflow on-chain; math/big has arbitrary precision so a plain mul+div is the
// faithful (and exact) equivalent.
func mulDiv(a, b, denominator *big.Int) *big.Int {
	prod := new(big.Int).Mul(a, b)
	return prod.Div(prod, denominator)
}
