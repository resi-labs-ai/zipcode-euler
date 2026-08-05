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
// Per Evaluate it dissolves the live stakedBalance(), clamped to an optional
// maxSlice cap. It used to bound the burn to the coverage excess by binary
// searching coverageGate.lpBurnKeepsCovered(shares); that gate was removed on
// 2026-08-04 because dissolving LP returns zipUSD and xALPHA to the same Safe
// and coverage counts them at the same value, so the burn cannot move the freeze
// floor. The withdraw floor (min0/min1) is sized off the
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
	lp              common.Address // LpStrategyModule — juniorTrancheEngine / ichiVault / stakedBalance / unstake / removeLiquidity
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

	// f. the burn is the whole clamped slice. There is no coverage-excess sizing any more:
	//    LpStrategyModule.removeLiquidity dropped its coverage gate on 2026-08-04, because dissolving LP returns
	//    zipUSD and xALPHA to the same Safe and SzipNavOracle.mainSpotEquity counts them at the value the LP was
	//    counted at, so a dissolution cannot move the freeze floor. The old binary search over
	//    lpBurnKeepsCovered therefore sized every tick against a predicate that under-reported coverage by the
	//    full burn value. The remaining bound on this job is the spot/TWAP deviation gate in step g, which is now
	//    the only thing standing between a manipulated pool and a badly-priced withdraw.
	shares := slice

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

