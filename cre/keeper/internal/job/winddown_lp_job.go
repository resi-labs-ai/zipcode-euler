package job

import (
	"context"
	"math/big"

	"github.com/ethereum/go-ethereum/common"

	"cre-keeper/internal/chain"
	"cre-keeper/internal/quote"
)

// WindDownLpJob drives the exception-only LP-dissolution hop on
// LpStrategyModule: unstake(shares) → removeLiquidity(shares, min0, min1)
// (KEEPER-02). It is NOT part of the auto-compounder StrikeLoop; it is armed by
// KEEPER_WINDDOWN_ENABLED and runs the global-wind-down LP→legs feeder.
//
// Per Evaluate it dissolves a COVERAGE-EXCESS-bounded slice: the burn `shares`
// is sized to the largest amount the coverage gate still blesses
// (coverageGate.lpBurnKeepsCovered(shares)), clamped to the live stakedBalance()
// and an optional maxSlice cap. The withdraw floor (min0/min1) is sized off the
// CURRENT pro-rata reserves with the StrikeLoop cushion, and a separate
// spot↔TWAP deviation gate fences a manipulated/volatile pool (the SUPPLY-ADV-09
// rule, withdraw variant). Both Actions are marked Private so chain.Submit
// routes the SendTransaction through the MEV-protected backend when configured.
//
// Like StrikeLoopJob it is a PURE stateless poll: every Evaluate rebuilds the
// Plan from current reads + live quotes; addresses are read each tick off the
// module getters (§17 re-pointable), never cached. No-op gates return an EMPTY
// Plan (nil error); read errors propagate (the Runner logs + continues).
type WindDownLpJob struct {
	lp              common.Address // LpStrategyModule — juniorTrancheEngine / ichiVault / coverageGate / stakedBalance / unstake / removeLiquidity
	quoter          quote.Quoter   // injectable price/share seam (production binds to Algebra/ICHI)
	cushionBps      uint64         // withdraw min-floor cushion (200 = 2%)
	maxDeviationBps uint64         // spot↔TWAP deviation ceiling (100 = 1%); above it the Job no-ops
	maxSlice        *big.Int       // optional per-invocation share cap (0 = no cap)
}

// NewWindDownLpJob builds the job. maxSlice is copied (nil ⇒ big.NewInt(0) = no cap).
func NewWindDownLpJob(lp common.Address, q quote.Quoter, cushionBps, maxDeviationBps uint64, maxSlice *big.Int) *WindDownLpJob {
	ms := big.NewInt(0)
	if maxSlice != nil {
		ms = new(big.Int).Set(maxSlice)
	}
	return &WindDownLpJob{
		lp:              lp,
		quoter:          q,
		cushionBps:      cushionBps,
		maxDeviationBps: maxDeviationBps,
		maxSlice:        ms,
	}
}

// Name implements Job.
func (j *WindDownLpJob) Name() string { return "winddown-lp" }

// applyCushionFloor returns v − v·cushionBps/10000 (a conservative LOWER bound),
// same formula as StrikeLoopJob.
func (j *WindDownLpJob) applyCushionFloor(v *big.Int) *big.Int {
	cut := new(big.Int).Mul(v, new(big.Int).SetUint64(j.cushionBps))
	cut.Div(cut, big.NewInt(10000))
	return new(big.Int).Sub(v, cut)
}

// Evaluate reads current state + live quotes and returns ONE ordered Plan
// (unstake then removeLiquidity), both Private. The Runner submits it.
func (j *WindDownLpJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	// a. re-pointable address reads (§17): the engine Safe, the LP vault, the gate.
	safe, err := chain.CallAddress(ctx, r, j.lp, "juniorTrancheEngine()")
	if err != nil {
		return chain.Plan{}, err
	}
	if safe == (common.Address{}) {
		return chain.Plan{}, nil // unwired — no-op (not an error)
	}
	vault, err := chain.CallAddress(ctx, r, j.lp, "ichiVault()")
	if err != nil {
		return chain.Plan{}, err
	}
	gate, err := chain.CallAddress(ctx, r, j.lp, "coverageGate()")
	if err != nil {
		return chain.Plan{}, err // may be zero (ungated); a read failure still propagates
	}

	// d. the live staked LP (removeLiquidity burns LP held in the Safe; unstake pulls it back).
	staked, err := chain.CallUint(ctx, r, j.lp, "stakedBalance()")
	if err != nil {
		return chain.Plan{}, err
	}
	if staked.Sign() == 0 {
		return chain.Plan{}, nil // nothing staked — no-op
	}

	// e. clamp to the optional per-invocation slice cap.
	slice := staked
	if j.maxSlice.Sign() > 0 && slice.Cmp(j.maxSlice) > 0 {
		slice = j.maxSlice
	}

	// f. size shares to the coverage excess: the largest s in [1, slice] the gate
	//    still blesses. lpBurnKeepsCovered is monotonic (true for small s, false as
	//    s grows), so binary-search the boundary.
	shares := slice
	if gate != (common.Address{}) {
		s, ok, err := j.largestCoveredSlice(ctx, r, gate, slice)
		if err != nil {
			return chain.Plan{}, err
		}
		if !ok {
			return chain.Plan{}, nil // even s=1 is undercovered — no excess to dissolve, no-op
		}
		shares = s
	}

	// g. manipulation guard: skip if the pool's spot price deviates from its TWAP
	//    beyond the ceiling (the withdraw floor is sized off CURRENT reserves).
	dev, err := j.quoter.LpSpotTwapDeviationBps(ctx, vault)
	if err != nil {
		return chain.Plan{}, err // NoPlugin / unready TWAP aborts (never falls back to spot)
	}
	if dev.Cmp(new(big.Int).SetUint64(j.maxDeviationBps)) > 0 {
		return chain.Plan{}, nil // pool manipulated/volatile — try later
	}

	// h. TWAP-fenced withdraw floor: pro-rata expected, cushioned down.
	e0, e1, err := j.quoter.LpWithdrawExpected(ctx, vault, shares)
	if err != nil {
		return chain.Plan{}, err
	}
	min0 := j.applyCushionFloor(e0)
	min1 := j.applyCushionFloor(e1)

	// i. both floors zero ⇒ removeLiquidity reverts ZeroMinAmount on-chain; skip.
	if min0.Sign() == 0 && min1.Sign() == 0 {
		return chain.Plan{}, nil
	}

	// j. the ordered Plan (leg order is load-bearing): unstake then removeLiquidity,
	//    both Private (MEV-protected send when a private backend is configured).
	return chain.Plan{Actions: []chain.Action{
		{Label: "unstake", To: j.lp, Data: chain.PackUintCall("unstake(uint256)", shares), Private: true},
		{Label: "removeLiquidity", To: j.lp, Data: chain.PackUintsCall("removeLiquidity(uint256,uint256,uint256)", shares, min0, min1), Private: true},
	}}, nil
}

// largestCoveredSlice returns the largest s in [1, slice] with
// coverageGate.lpBurnKeepsCovered(s) == true, via binary search on the monotonic
// predicate (true for small s, false as s grows). ok=false means no s≥1 is
// covered. A read error propagates.
func (j *WindDownLpJob) largestCoveredSlice(ctx context.Context, r chain.Reader, gate common.Address, slice *big.Int) (*big.Int, bool, error) {
	// Fast path: if the full slice is covered, take it.
	full, err := chain.CallBoolWithUint(ctx, r, gate, "lpBurnKeepsCovered(uint256)", slice)
	if err != nil {
		return nil, false, err
	}
	if full {
		return new(big.Int).Set(slice), true, nil
	}
	// Reject if even the smallest burn (s=1) is undercovered.
	one := big.NewInt(1)
	covered1, err := chain.CallBoolWithUint(ctx, r, gate, "lpBurnKeepsCovered(uint256)", one)
	if err != nil {
		return nil, false, err
	}
	if !covered1 {
		return nil, false, nil
	}
	// Binary search the largest covered s in [1, slice): invariant lo=covered (≥1),
	// hi=uncovered (≤slice). Converge until hi-lo == 1; lo is the answer.
	lo := big.NewInt(1)        // known covered
	hi := new(big.Int).Set(slice) // known uncovered
	gap := new(big.Int).Sub(hi, lo)
	for gap.Cmp(big.NewInt(1)) > 0 {
		mid := new(big.Int).Add(lo, hi)
		mid.Rsh(mid, 1) // (lo+hi)/2
		covered, err := chain.CallBoolWithUint(ctx, r, gate, "lpBurnKeepsCovered(uint256)", mid)
		if err != nil {
			return nil, false, err
		}
		if covered {
			lo.Set(mid)
		} else {
			hi.Set(mid)
		}
		gap.Sub(hi, lo)
	}
	return new(big.Int).Set(lo), true, nil
}
