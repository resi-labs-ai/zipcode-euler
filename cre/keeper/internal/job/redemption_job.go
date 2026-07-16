package job

import (
	"context"
	"math/big"

	"github.com/ethereum/go-ethereum/common"

	"cre-keeper/internal/chain"
)

// RedemptionJob drives the senior par-redemption OPERATOR path (CRE-02, the (K)
// half per CRE-OPS-ROUTING.md / §6.1 / §8.3): it settles the redemption queue as
// the queue's controller and claims/escrows through the OffRampModule as the
// off-ramp operator. It is REACTIVE: it settles + claims whatever USDC the (R)
// warehouse REPAY already delivered into the queue's own balance, and optionally
// escrows idle basket zipUSD. It does NOT emit the (R) warehouse REDEEM→REPAY
// funding (that is cre/warehouse, a different transport — see the ticket's "Scope
// boundary").
//
// Like BurnJob: a PURE-read Evaluate returns an ordered chain.Plan; the Runner
// alone submits. Idempotent + stateless (no cross-tick state) — each tick reads
// live queue/off-ramp state and emits whatever legs are currently due. The
// synchronous single-threaded spine guarantees a leg fully mines before the next
// Evaluate re-reads (the BurnJob no-double-act argument, burn_job.go:92-101).
type RedemptionJob struct {
	offramp       common.Address
	targetPending *big.Int
}

// NewRedemptionJob builds the redemption job. offramp is the OffRampModule
// address (re-pointable, from cfg.MustAddr("OffRampModule")); the queue + rq Safe
// + tokens are read LIVE off the off-ramp each tick (§17). targetPending is the
// escrow target (config; default 0 = escrow disabled — the BurnJob minBurn idiom,
// burn_job.go:30). Both stored by reference; targetPending is config-guaranteed
// non-nil (defaults() seeds big.NewInt(0)) and read-only, so no defensive copy.
func NewRedemptionJob(offramp common.Address, targetPending *big.Int) *RedemptionJob {
	return &RedemptionJob{offramp: offramp, targetPending: targetPending}
}

// Name implements Job.
func (j *RedemptionJob) Name() string { return "redemption" }

// floorToUnit returns (x / u) * u — x floored to a whole multiple of u (big.Int).
// u is always scaleUp > 0 at every call site. Unexported package-level so the
// _test.go files in package job can call it.
func floorToUnit(x, u *big.Int) *big.Int {
	return new(big.Int).Mul(new(big.Int).Div(x, u), u)
}

// Evaluate reads live off-ramp + queue state and returns an ordered Plan. Order
// is load-bearing: reactive always-safe legs first (settleEpoch, claim), the
// optional escrow leg last (so its failure under abort-on-first-error never
// strands the always-safe legs). All reads are re-read each tick (§17 — never
// cached across ticks).
func (j *RedemptionJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) {
	// 1. Re-pointable address reads off the off-ramp (NEVER hard-coded).
	rqSafe, err := chain.CallAddress(ctx, r, j.offramp, "juniorTrancheSafe()")
	if err != nil {
		return chain.Plan{}, err
	}
	queue, err := chain.CallAddress(ctx, r, j.offramp, "queue()")
	if err != nil {
		return chain.Plan{}, err
	}
	zipUSD, err := chain.CallAddress(ctx, r, j.offramp, "zipUSD()")
	if err != nil {
		return chain.Plan{}, err
	}
	// Unwired ⇒ no-op (NOT an error; mirrors burn_job.go:60-62).
	if queue == (common.Address{}) || rqSafe == (common.Address{}) {
		return chain.Plan{}, nil
	}

	// 2. Queue state reads.
	usdcAddr, err := chain.CallAddress(ctx, r, queue, "usdc()")
	if err != nil {
		return chain.Plan{}, err
	}
	scaleUp, err := chain.CallUint(ctx, r, queue, "scaleUp()")
	if err != nil {
		return chain.Plan{}, err
	}
	// A 0 scaleUp would divide-by-zero (malformed/unwired queue) ⇒ no-op.
	if scaleUp.Sign() == 0 {
		return chain.Plan{}, nil
	}
	pending, err := chain.CallUint(ctx, r, queue, "totalPending()")
	if err != nil {
		return chain.Plan{}, err
	}
	// The queue's current open requester (single-requester topology). The escrow leg
	// only fires when the queue is FREE FOR US — pendingRequester is zero (no open
	// request) or already our own rqSafe. Today (one junior Safe) this is always true,
	// so it's a no-op; it PREPARES for serialization (CTR-14 option a): when a second
	// junior Safe shares this one queue, each keeper waits its turn here instead of
	// emitting a requestRedeem that the queue hard-reverts MultipleRequesters
	// (ZipRedemptionQueue.sol:181-185). settle/claim are NOT gated on this — they act
	// on whatever is pending/claimable regardless of requester.
	pendingRequester, err := chain.CallAddress(ctx, r, queue, "pendingRequester()")
	if err != nil {
		return chain.Plan{}, err
	}
	reserved, err := chain.CallUint(ctx, r, queue, "reservedAssets()")
	if err != nil {
		return chain.Plan{}, err
	}
	// The two balanceOf reads hit DIFFERENT token addresses with different args:
	// usdcAddr/queue → usdcBalQueue, zipUSD/rqSafe → idleZip.
	usdcBalQueue, err := chain.CallUintWithAddr(ctx, r, usdcAddr, "balanceOf(address)", queue)
	if err != nil {
		return chain.Plan{}, err
	}
	claimable, err := chain.CallUintWithAddr(ctx, r, queue, "maxWithdraw(address)", rqSafe)
	if err != nil {
		return chain.Plan{}, err
	}
	idleZip, err := chain.CallUintWithAddr(ctx, r, zipUSD, "balanceOf(address)", rqSafe)
	if err != nil {
		return chain.Plan{}, err
	}

	// 3. freeUsdc = usdcBalQueue − reserved, floored at 0 (reserved can momentarily
	//    exceed balance only by bug).
	freeUsdc := new(big.Int).Sub(usdcBalQueue, reserved)
	if freeUsdc.Sign() < 0 {
		freeUsdc = big.NewInt(0)
	}

	// 4. Build the ordered Plan; each leg independently gated on the PRE-read state.
	var actions []chain.Action

	// settleEpoch — expectedFill = min(freeUsdc, pending/scaleUp); mirrors the
	// queue's own computation (ZipRedemptionQueue.sol:203-206), so a Go
	// expectedFill==0 correctly predicts an on-chain filledShares==0 no-op. Emit
	// IFF freeUsdc>0 && pending>=scaleUp (both must hold). Gate in Go to avoid a
	// wasted no-op tx.
	if freeUsdc.Sign() > 0 && pending.Cmp(scaleUp) >= 0 {
		actions = append(actions, chain.Action{
			Label: "settleEpoch",
			To:    queue,
			Data:  chain.PackCall("settleEpoch()"),
		})
	}

	// claim — emit IFF claimable>0. Claims the PRE-read banked claimableAssets[rqSafe];
	// this-tick settle's freshly-banked fill is claimed next tick (≤2 ticks to fully
	// cycle delivered USDC — acceptable, low-frequency treasury plumbing).
	if claimable.Sign() > 0 {
		actions = append(actions, chain.Action{
			Label: "claim",
			To:    j.offramp,
			Data:  chain.PackUintCall("claim(uint256)", claimable),
		})
	}

	// requestRedeem (escrow; default-OFF) — emit IFF escrow enabled (targetPending>0)
	// AND gap = targetPending − pending > 0 AND escrow = floorToUnit(min(gap,idleZip),
	// scaleUp) >= scaleUp (a sub-unit escrow would revert NotWholeUnit/ZeroAmount).
	queueFreeForUs := pendingRequester == (common.Address{}) || pendingRequester == rqSafe
	if j.targetPending.Sign() > 0 && queueFreeForUs {
		gap := new(big.Int).Sub(j.targetPending, pending)
		if gap.Sign() > 0 {
			minGapIdle := gap
			if idleZip.Cmp(minGapIdle) < 0 {
				minGapIdle = idleZip
			}
			escrow := floorToUnit(minGapIdle, scaleUp)
			if escrow.Cmp(scaleUp) >= 0 {
				actions = append(actions, chain.Action{
					Label: "requestRedeem",
					To:    j.offramp,
					Data:  chain.PackUintCall("requestRedeem(uint256)", escrow),
				})
			}
		}
	}

	return chain.Plan{Actions: actions}, nil
}
