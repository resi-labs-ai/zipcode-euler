package job

import (
	"context"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"cre-keeper/internal/chain"
	"cre-keeper/internal/quote"
)

// scaleUp is the ZipDepositModule USDC(6dp)→zipUSD(18dp) mint factor = 1e12.
// Confirmed against contracts/src/supply/ZipDepositModule.sol:58-59,95,118
// (scaleUp = 10**(zipDec-usdcDec) = 1e12; zipMinted = usdcIn*scaleUp, NO deposit
// fee).
var scaleUp = func() *big.Int { v, _ := new(big.Int).SetString("1000000000000", 10); return v }()

// StrikeLoopJob drives the auto-compounder engine's onlyOperator harvest legs
// (8-B5…8-B10) as ONE ordered chain.Plan on the keeper spine (§8.7). It is a
// PURE stateless poll: every Evaluate rebuilds the whole Plan from current reads
// + live quotes, with NO cross-tick state (no EMA, no fill history). Modeled on
// BurnJob (re-pointable address reads, fail-safe, pure-read Evaluate returning a
// chain.Plan; the Runner alone submits).
//
// The six engine modules are read each tick via their public getters (juniorTrancheEngine(),
// the token getters) — addresses are NEVER hard-coded (§17 re-pointable). The
// keeper supplies ONLY scalar amounts (never addresses/calldata) — blast radius
// bounded (§8.7).
//
// The restake leg's deposit side follows the live token0()/token1() slotting: the
// quoter resolves which vault side is the recycled zipUSD each tick and the Job
// builds addLiquidity on that side (deposit0=expectedZip when token0, else
// deposit1=expectedZip).
type StrikeLoopJob struct {
	// the six engine module addresses (re-pointable; from cfg.MustAddr).
	harvest   common.Address // HarvestVoteModule — claimReward / pendingReward / oHYDX
	reservoir common.Address // ReservoirLoopModule — borrow / repay / usdc
	exercise  common.Address // ExerciseModule — exercise / quoteStrike / oHYDX
	sell      common.Address // SellModule — sellHydx / maxSellHydx / hydx / usdc
	recycle   common.Address // RecycleModule — creditFreeValue / recycle / usdc
	lp        common.Address // LpStrategyModule — addLiquidity / stake / ichiVault

	quoter quote.Quoter // injectable price/share seam (production binds to Algebra/ICHI)

	// scalar knobs (cfg).
	cushionBps         uint64
	amberFractionBps   uint64
	recycleFractionBps uint64
	haltPriceUsdc      *big.Int
	amberPriceUsdc     *big.Int
	deadlineBuffer     time.Duration
	maxBorrowPerCycle  *big.Int

	// clock is injectable so tests get a deterministic deadline (defaults to time.Now).
	clock func() time.Time
}

// StrikeLoopConfig groups the StrikeLoopJob construction inputs (modules +
// knobs) so the wiring in cmd/keeper is explicit.
type StrikeLoopConfig struct {
	Harvest, Reservoir, Exercise, Sell, Recycle, Lp  common.Address
	Quoter                                           quote.Quoter
	CushionBps, AmberFractionBps, RecycleFractionBps uint64
	HaltPriceUsdc, AmberPriceUsdc                    uint64
	DeadlineBuffer                                   time.Duration
	MaxBorrowPerCycle                                *big.Int
}

// NewStrikeLoopJob builds the job. clock is nil-safe (defaults to time.Now).
func NewStrikeLoopJob(c StrikeLoopConfig) *StrikeLoopJob {
	return &StrikeLoopJob{
		harvest:            c.Harvest,
		reservoir:          c.Reservoir,
		exercise:           c.Exercise,
		sell:               c.Sell,
		recycle:            c.Recycle,
		lp:                 c.Lp,
		quoter:             c.Quoter,
		cushionBps:         c.CushionBps,
		amberFractionBps:   c.AmberFractionBps,
		recycleFractionBps: c.RecycleFractionBps,
		haltPriceUsdc:      new(big.Int).SetUint64(c.HaltPriceUsdc),
		amberPriceUsdc:     new(big.Int).SetUint64(c.AmberPriceUsdc),
		deadlineBuffer:     c.DeadlineBuffer,
		maxBorrowPerCycle:  new(big.Int).Set(c.MaxBorrowPerCycle),
		clock:              time.Now,
	}
}

// Name implements Job.
func (j *StrikeLoopJob) Name() string { return "strike-loop" }

// applyCushionFloor returns v − v·cushionBps/10000 (a conservative LOWER bound).
func (j *StrikeLoopJob) applyCushionFloor(v *big.Int) *big.Int {
	cut := new(big.Int).Mul(v, new(big.Int).SetUint64(j.cushionBps))
	cut.Div(cut, big.NewInt(10000))
	return new(big.Int).Sub(v, cut)
}

// applyCushionUp returns v + v·cushionBps/10000 (a conservative UPPER bound, for maxPayment).
func (j *StrikeLoopJob) applyCushionUp(v *big.Int) *big.Int {
	add := new(big.Int).Mul(v, new(big.Int).SetUint64(j.cushionBps))
	add.Div(add, big.NewInt(10000))
	return new(big.Int).Add(v, add)
}

// Evaluate reads current state + live quotes and returns ONE ordered Plan; the
// Runner submits it (no Evaluate-time submission, K4). Pre-computes every leg's
// scalar from current reads — later legs use the DETERMINISTIC effect of earlier
// legs (claim adds pendingReward oHYDX; exercise mints `amount` HYDX 1:1).
//
// No-op gates return an EMPTY Plan (nil error), never an error (liveness-only,
// fail-safe). Read errors (RPC) propagate (the Runner logs+continues).
//
// Re-read all module getters + token addresses each tick (§17 re-pointable; do
// NOT cache across ticks — a Timelock re-point must take effect).
func (j *StrikeLoopJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	// --- 1. re-pointable address reads (§17): the engine Safe + the tokens, off the module getters. ---
	safe, err := chain.CallAddress(ctx, r, j.harvest, "juniorTrancheEngine()")
	if err != nil {
		return chain.Plan{}, err
	}
	if safe == (common.Address{}) {
		return chain.Plan{}, nil // unwired — no-op (not an error)
	}
	oHYDX, err := chain.CallAddress(ctx, r, j.harvest, "oHYDX()")
	if err != nil {
		return chain.Plan{}, err
	}
	hydx, err := chain.CallAddress(ctx, r, j.sell, "hydx()")
	if err != nil {
		return chain.Plan{}, err
	}
	vault, err := chain.CallAddress(ctx, r, j.lp, "ichiVault()")
	if err != nil {
		return chain.Plan{}, err
	}

	// --- 2. totalOHydx = oHYDX.balanceOf(safe) + pendingReward() (claim adds pendingReward). ---
	oHydxBal, err := chain.CallUintWithAddr(ctx, r, oHYDX, "balanceOf(address)", safe)
	if err != nil {
		return chain.Plan{}, err
	}
	pending, err := chain.CallUint(ctx, r, j.harvest, "pendingReward()")
	if err != nil {
		return chain.Plan{}, err
	}
	totalOHydx := new(big.Int).Add(oHydxBal, pending)
	if totalOHydx.Sign() == 0 {
		return chain.Plan{}, nil // nothing to harvest — no-op
	}

	// --- 3. taper/halt level check on the live HYDX price P (USDC-per-1-HYDX, 6dp). ---
	// Comparisons are STRICT < (boundary P == threshold → the higher tier).
	P, err := j.quoter.HydxPriceUsdc(ctx)
	if err != nil {
		return chain.Plan{}, err
	}
	if P.Cmp(j.haltPriceUsdc) < 0 {
		return chain.Plan{}, nil // dead market — accrue oHYDX, do not borrow into it
	}
	var tapered *big.Int
	if P.Cmp(j.amberPriceUsdc) < 0 {
		// amber: tapered = totalOHydx · amberFractionBps / 10000
		tapered = new(big.Int).Mul(totalOHydx, new(big.Int).SetUint64(j.amberFractionBps))
		tapered.Div(tapered, big.NewInt(10000))
	} else {
		tapered = new(big.Int).Set(totalOHydx) // full
	}

	// --- 4. exerciseAmount = min(tapered, max(0, maxSellHydx − hydx.balanceOf(safe))). ---
	maxSell, err := chain.CallUint(ctx, r, j.sell, "maxSellHydx()")
	if err != nil {
		return chain.Plan{}, err
	}
	hydxBal, err := chain.CallUintWithAddr(ctx, r, hydx, "balanceOf(address)", safe)
	if err != nil {
		return chain.Plan{}, err
	}
	sellRoom := new(big.Int).Sub(maxSell, hydxBal) // max(0, maxSellHydx − hydxBal)
	if sellRoom.Sign() < 0 {
		sellRoom = big.NewInt(0)
	}
	exerciseAmount := minBig(tapered, sellRoom)
	if exerciseAmount.Sign() == 0 {
		return chain.Plan{}, nil // no room / nothing tapered — no-op
	}

	// --- 5. strike + maxPayment + borrowAmount. ---
	strike, err := chain.CallUintWithUint(ctx, r, j.exercise, "quoteStrike(uint256)", exerciseAmount)
	if err != nil {
		return chain.Plan{}, err
	}
	maxPayment := j.applyCushionUp(strike) // strike + strike·cushionBps/10000
	borrowAmount := new(big.Int).Set(maxPayment)
	if maxPayment.Cmp(j.maxBorrowPerCycle) > 0 {
		return chain.Plan{}, nil // can't fund the cycle responsibly — no-op (borrowCap is the on-chain backstop)
	}

	// --- 6. sellAmount = hydx.balanceOf(safe) + exerciseAmount (exercise mints `amount` HYDX 1:1). ---
	sellAmount := new(big.Int).Add(hydxBal, exerciseAmount)

	// --- 7. quotedOut + minOut + profit gate. ---
	quotedOut, err := j.quoter.HydxToUsdc(ctx, sellAmount)
	if err != nil {
		return chain.Plan{}, err
	}
	minOut := j.applyCushionFloor(quotedOut) // quotedOut − quotedOut·cushionBps/10000
	if minOut.Cmp(maxPayment) <= 0 {
		return chain.Plan{}, nil // unprofitable at the conservative floor — never borrow to lose
	}

	// --- 8. conservativeNet, recycle split, credit. ---
	conservativeNet := new(big.Int).Sub(minOut, maxPayment) // guaranteed-floor surplus (USDC 6dp)
	recycleAmount := new(big.Int).Mul(conservativeNet, new(big.Int).SetUint64(j.recycleFractionBps))
	recycleAmount.Div(recycleAmount, big.NewInt(10000))
	creditAmount := new(big.Int).Set(conservativeNet) // credit the FULL guaranteed surplus

	// --- 9. deadline = clock.Now().Unix() + deadlineBuffer (same for exercise + sell). ---
	now := j.clock
	if now == nil {
		now = time.Now
	}
	deadline := big.NewInt(now().Unix() + int64(j.deadlineBuffer/time.Second))

	// --- the ordered Plan (leg order is load-bearing, K2). ---
	actions := []chain.Action{
		{Label: "claimReward", To: j.harvest, Data: chain.PackCall("claimReward()")},
		{Label: "borrow", To: j.reservoir, Data: chain.PackUintCall("borrow(uint256)", borrowAmount)},
		{Label: "exercise", To: j.exercise, Data: chain.PackUintsCall("exercise(uint256,uint256,uint256)", exerciseAmount, maxPayment, deadline)},
		{Label: "sellHydx", To: j.sell, Data: chain.PackUintsCall("sellHydx(uint256,uint256,uint256)", sellAmount, minOut, deadline)},
		{Label: "repay", To: j.reservoir, Data: chain.PackUintCall("repay(uint256)", borrowAmount)},
		{Label: "creditFreeValue", To: j.recycle, Data: chain.PackUintCall("creditFreeValue(uint256)", creditAmount)},
	}

	// --- recycle + restake legs, skipped together when recycleAmount == 0. ---
	if recycleAmount.Sign() != 0 {
		// expectedZip = recycleAmount · scaleUp (6dp→18dp; scaleUp = 1e12, no deposit fee).
		expectedZip := new(big.Int).Mul(recycleAmount, scaleUp)
		expectedShares, zipIsToken0, err := j.quoter.ZipToShares(ctx, j.recycle, vault, expectedZip)
		if err != nil {
			return chain.Plan{}, err
		}
		minShares := j.applyCushionFloor(expectedShares)
		// minShares == 0 → skip restake (addLiquidity reverts on zero shares /
		// ZeroMinShares); still do recycle. But addLiquidity needs a non-zero
		// minShares, so if it floors to 0 we skip BOTH the restake legs and keep the
		// recycle (the minted zipUSD is picked up next cycle).
		if minShares.Sign() == 0 {
			actions = append(actions,
				chain.Action{Label: "recycle", To: j.recycle, Data: chain.PackUintCall("recycle(uint256)", recycleAmount)},
			)
		} else {
			// stakeAmount = minShares (conservative: addLiquidity guarantees shares ≥ minShares).
			stakeAmount := new(big.Int).Set(minShares)
			// Deposit the recycled zipUSD on whichever side the live token0()/token1()
			// slotting puts it: (expectedZip, 0) when zipUSD is token0, else (0, expectedZip).
			var deposit0, deposit1 *big.Int
			if zipIsToken0 {
				deposit0, deposit1 = expectedZip, big.NewInt(0)
			} else {
				deposit0, deposit1 = big.NewInt(0), expectedZip
			}
			actions = append(actions,
				chain.Action{Label: "recycle", To: j.recycle, Data: chain.PackUintCall("recycle(uint256)", recycleAmount)},
				chain.Action{Label: "addLiquidity", To: j.lp, Data: chain.PackUintsCall("addLiquidity(uint256,uint256,uint256)", deposit0, deposit1, minShares)},
				chain.Action{Label: "stake", To: j.lp, Data: chain.PackUintCall("stake(uint256)", stakeAmount)},
			)
		}
	}

	return chain.Plan{Actions: actions}, nil
}

func minBig(a, b *big.Int) *big.Int {
	if a.Cmp(b) <= 0 {
		return new(big.Int).Set(a)
	}
	return new(big.Int).Set(b)
}
