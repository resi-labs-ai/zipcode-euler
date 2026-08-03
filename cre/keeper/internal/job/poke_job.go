package job

import (
	"context"
	"fmt"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"cre-keeper/internal/chain"
)

// PokeJob keeps the NAV oracle's TWAP accumulator alive.
//
// WHAT BREAKS WITHOUT IT. `SzipNavOracle.twapNavPerShare()` walks back for an observation at or before
// `now - W`. If the accumulator has been idle for a full `W` (3600s) there is no such observation, the lookup
// misses, and the function returns raw `spot`. At that point `navEntry == navExit == spot` and the entry/exit
// spread — the thing that stops someone minting cheap and exiting rich off one spot move — is simply absent.
// Legs stay `fresh` throughout, because `maxAge` is 86400 against a `W` of 3600, so nothing fails closed and
// nothing reverts. The vault just quietly stops defending itself.
//
// WHY A BACKSTOP AND NOT A HEARTBEAT. The accumulator is already advanced by every NAV leg push:
// `_processReport` calls `_accumulate()` before writing, and `cre/sharefeeds` pushes every 5 minutes. While
// that feed is healthy this job has nothing to do. The exposure is the window where sharefeeds is DOWN but the
// legs have not yet aged past `maxAge` — between one hour and twenty-four hours of outage, the bracket is
// disarmed while every consumer still reads the oracle as fresh. This job covers exactly that window, and
// poking is still worth something during a leg outage because the xALPHA rate leg and the LP reserves are read
// live, so spot can move even while the pushed legs are frozen.
//
// WHY NOT AN ON-CHAIN FIX. It was tried and reverted. Making `twapNavPerShare` revert on an idle accumulator
// is bypassed by `poke()` being permissionless — whoever benefits calls it themselves and gets the identical
// read — and the revert also fired on the exit path, narrowing the "staleness pauses issuance, never exit"
// asymmetry. Liveness is the only lever, which makes it an operational dependency rather than a code one.
//
// COST OF A FALSE POSITIVE: one `poke()` transaction, which is idempotent and permissionless. Poking too often
// is harmless; poking too late is the failure. The threshold is therefore set well inside `W`.
type PokeJob struct {
	navOracle common.Address
	// pokeAfter is the accumulator age (seconds) at which this job acts. Must be comfortably below the
	// oracle's `W`, since a tick can be missed and the transaction still has to land.
	pokeAfter uint64
}

// NewPokeJob builds the job. `pokeAfter` should be a fraction of the oracle's `W` — at the default `W` of
// 3600 and a keeper interval of minutes, 1200 (20 minutes) leaves two further ticks of margin before the
// bracket would actually degrade.
func NewPokeJob(navOracle common.Address, pokeAfter uint64) *PokeJob {
	return &PokeJob{navOracle: navOracle, pokeAfter: pokeAfter}
}

// Name implements Job.
func (j *PokeJob) Name() string { return "nav-poke" }

// Evaluate reads `lastUpdate()` and returns a `poke()` action only once the accumulator has aged past
// `pokeAfter`. A healthy sharefeeds keeps the age near zero, so the steady state is an empty plan.
func (j *PokeJob) Evaluate(ctx context.Context, r chain.Reader) (chain.Plan, error) { //nolint:revive // ctx used by CallUint
	lastUpdate, err := chain.CallUint(ctx, r, j.navOracle, "lastUpdate()")
	if err != nil {
		return chain.Plan{}, fmt.Errorf("nav-poke: reading lastUpdate() on %s: %w", j.navOracle.Hex(), err)
	}
	if lastUpdate.Sign() == 0 {
		// Never accumulated: pre-genesis wiring, not a staleness condition. Poking here would be noise.
		return chain.Plan{}, nil
	}

	// Wall clock, not block time. `Reader` exposes only `CallContract`, and at a threshold measured in tens of
	// minutes the few seconds of skew between a Base block and this host are irrelevant. The cost of being
	// wrong in either direction is one idempotent, permissionless `poke()`.
	head := uint64(time.Now().Unix())
	last := lastUpdate.Uint64()
	if head <= last {
		return chain.Plan{}, nil // clock skew or same-block read; nothing to do
	}
	age := head - last
	if age < j.pokeAfter {
		return chain.Plan{}, nil // sharefeeds is keeping it current — the steady state
	}

	return chain.Plan{Actions: []chain.Action{{
		Label: fmt.Sprintf("nav-poke: accumulator idle %ds (>= %ds) — poke() before the TWAP degrades to spot", age, j.pokeAfter),
		To:    j.navOracle,
		Data:  chain.Selector("poke()"),
	}}}, nil
}
