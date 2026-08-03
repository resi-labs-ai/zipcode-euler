// SPDX-License-Identifier: GPL-2.0-or-later
//
// Tests for the pure alarm core (evaluate/evaluateMetagraph) and the revert classifier — no RPC, no
// network. The reader layer is a thin ethclient pass-through exercised live in staging, not here.
package main

import (
	"errors"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

func snap(block uint64, stake, supply int64, hotkey byte, rate int64, reverted bool) *Snapshot {
	s := &Snapshot{
		Block:        block,
		Stake:        big.NewInt(stake),
		Supply:       big.NewInt(supply),
		Hotkey:       common.BytesToHash([]byte{hotkey}),
		RateReverted: reverted,
	}
	if !reverted {
		s.Rate = big.NewInt(rate)
	}
	return s
}

func noRedeem(uint64, uint64) (bool, error)  { return false, nil }
func hasRedeem(uint64, uint64) (bool, error) { return true, nil }

func codes(alerts []Alert) map[string]string {
	m := map[string]string{}
	for _, a := range alerts {
		m[a.Code] = a.Severity
	}
	return m
}

var defaults = Thresholds{StakeDropBps: 200, RateMoveBps: 100, TransportDriftBps: 50}

// Alarm 1: the exact Rubicon state pages; genesis (supply 0) does not.
func TestAlarm1BackingVanished(t *testing.T) {
	got := codes(evaluate(nil, snap(10, 0, 1000, 1, 0, true), defaults, noRedeem))
	if got["backing-vanished"] != "CRITICAL" {
		t.Fatalf("expected CRITICAL backing-vanished, got %v", got)
	}
	if got["rate-reverted"] != "CRITICAL" {
		t.Fatalf("the reverting rate should page alongside alarm 1, got %v", got)
	}

	genesis := codes(evaluate(nil, snap(10, 0, 0, 1, 1e18, false), defaults, noRedeem))
	if len(genesis) != 0 {
		t.Fatalf("genesis (supply 0) must not page, got %v", genesis)
	}
}

// Alarm 2: an unexplained drop beyond threshold pages; an explained one records; a small one is silent.
func TestAlarm2StakeDiscontinuity(t *testing.T) {
	prev := snap(10, 10_000, 10_000, 1, 1e18, false)

	unexplained := codes(evaluate(prev, snap(20, 9_000, 10_000, 1, 1e18, false), defaults, noRedeem))
	if unexplained["stake-discontinuity"] != "CRITICAL" {
		t.Fatalf("10%% unexplained drop must page, got %v", unexplained)
	}

	explained := codes(evaluate(prev, snap(20, 9_000, 10_000, 1, 1e18, false), defaults, hasRedeem))
	if explained["large-redemption"] != "INFO" || explained["stake-discontinuity"] != "" {
		t.Fatalf("an explained drop is INFO, got %v", explained)
	}

	small := codes(evaluate(prev, snap(20, 9_900, 10_000, 1, 1e18, false), defaults, noRedeem))
	if len(small) != 0 {
		t.Fatalf("a 1%% drop under the 2%% threshold must be silent, got %v", small)
	}

	// The check failing must FAIL TOWARD PAGING.
	failing := codes(evaluate(prev, snap(20, 9_000, 10_000, 1, 1e18, false), defaults,
		func(uint64, uint64) (bool, error) { return false, errors.New("rpc down") }))
	if failing["stake-discontinuity"] != "CRITICAL" {
		t.Fatalf("an unverifiable drop must still page, got %v", failing)
	}
}

// Alarm 3: a >1% rate move pages in both directions; a small move is silent; a revert pages.
func TestAlarm3RateJumpAndRevert(t *testing.T) {
	prev := snap(10, 10_000, 10_000, 1, 1_000_000, false)

	up := codes(evaluate(prev, snap(20, 10_000, 10_000, 1, 1_020_000, false), defaults, noRedeem))
	if up["rate-jump"] != "CRITICAL" {
		t.Fatalf("a 2%% up-move must page, got %v", up)
	}
	down := codes(evaluate(prev, snap(20, 10_000, 10_000, 1, 980_000, false), defaults, noRedeem))
	if down["rate-jump"] != "CRITICAL" {
		t.Fatalf("a 2%% down-move must page, got %v", down)
	}
	small := codes(evaluate(prev, snap(20, 10_000, 10_000, 1, 1_005_000, false), defaults, noRedeem))
	if len(small) != 0 {
		t.Fatalf("a 0.5%% move must be silent, got %v", small)
	}
	reverted := codes(evaluate(prev, snap(20, 10_000, 10_000, 1, 0, true), defaults, noRedeem))
	if reverted["rate-reverted"] != "CRITICAL" {
		t.Fatalf("a reverting rate must page, got %v", reverted)
	}
}

// The pointer changing between polls warns (legitimate only via the timelock).
func TestHotkeyRepointWarns(t *testing.T) {
	prev := snap(10, 10_000, 10_000, 1, 1e18, false)
	got := codes(evaluate(prev, snap(20, 10_000, 10_000, 2, 1e18, false), defaults, noRedeem))
	if got["hotkey-repointed"] != "WARN" {
		t.Fatalf("a pointer change must WARN, got %v", got)
	}
}

// Alarm 4 core: absent pages, zero dividends warns, healthy is silent.
func TestAlarm4Metagraph(t *testing.T) {
	if got := codes(evaluateMetagraph(false, 0)); got["hotkey-unregistered"] != "CRITICAL" {
		t.Fatalf("absent hotkey must page, got %v", got)
	}
	if got := codes(evaluateMetagraph(true, 0)); got["hotkey-zero-dividends"] != "WARN" {
		t.Fatalf("zero dividends must WARN, got %v", got)
	}
	if got := evaluateMetagraph(true, 123); len(got) != 0 {
		t.Fatalf("a healthy hotkey must be silent, got %v", got)
	}
}

// The revert classifier: an error carrying EVM return data, or the canonical revert string, is a REVERT
// (an alarm input); anything else is transport (a skipped tick).
type fakeDataError struct{}

func (fakeDataError) Error() string          { return "execution reverted" }
func (fakeDataError) ErrorData() interface{} { return "0x00" }

func TestIsRevert(t *testing.T) {
	if !isRevert(fakeDataError{}) {
		t.Fatal("a DataError-shaped error is a revert")
	}
	if !isRevert(errors.New("execution reverted: BackingVanished()")) {
		t.Fatal("the canonical revert string is a revert")
	}
	if isRevert(errors.New("connection refused")) {
		t.Fatal("a transport error is NOT a revert")
	}
}

// ---------------------------------------------------------------------------------------------------
// Alarm 5 — the transport check. The job moves the rate UNCHANGED, so Base and 964 must agree; this is an
// equality check rather than a threshold, which is what lets it catch a scaling error the "is this move
// too big" alarms cannot distinguish from a real slash.

func baseSnap(raw, smoothed int64, fresh bool) *BaseSnapshot {
	return &BaseSnapshot{Raw: big.NewInt(raw), Smoothed: big.NewInt(smoothed), Fresh: fresh}
}

// A matching pair is silent.
func TestAlarm5MatchingTransportIsSilent(t *testing.T) {
	got := codes(evaluateTransport(snap(10, 1000, 1000, 1, 1_000_000, false), baseSnap(1_000_000, 1_000_000, true), defaults))
	if len(got) != 0 {
		t.Fatalf("expected no alerts on a matching pair, got %v", got)
	}
}

// THE ONE THAT MATTERS: a scaling error. The source says 1e6, Base carries 1e15 (a 1e9 slip). No
// threshold alarm could call this wrong without also rejecting a real slash; equality can.
func TestAlarm5ScalingSlipPages(t *testing.T) {
	src := snap(10, 1000, 1000, 1, 1_000_000, false)
	got := codes(evaluateTransport(src, baseSnap(1_000_000_000_000_000, 1_000_000, true), defaults))
	if got["rate-transport-mismatch"] != "CRITICAL" {
		t.Fatalf("a 1e9 transport slip must page CRITICAL, got %v", got)
	}
	// ...and the responder is told the smoothing is still holding it back.
	if got["rate-smoothing-active"] != "INFO" {
		t.Fatalf("expected the smoothing-active notice alongside, got %v", got)
	}
}

// Sub-threshold drift (one poll of emission accrual) must stay silent, or the alarm is noise.
func TestAlarm5EmissionDriftIsSilent(t *testing.T) {
	src := snap(10, 1000, 1000, 1, 1_000_000, false)
	got := codes(evaluateTransport(src, baseSnap(1_000_010, 1_000_010, true), defaults)) // +0.001%
	if _, bad := got["rate-transport-mismatch"]; bad {
		t.Fatalf("sub-threshold drift must not page, got %v", got)
	}
}

// A stale feed pages: every consumer is failing closed and nobody is marking xALPHA.
func TestAlarm5StaleFeedPages(t *testing.T) {
	got := codes(evaluateTransport(snap(10, 1000, 1000, 1, 1_000_000, false), baseSnap(1_000_000, 1_000_000, false), defaults))
	if got["rate-feed-stale"] != "CRITICAL" {
		t.Fatalf("a stale receiver must page, got %v", got)
	}
}

// The vanished state is alarms 1/3a's job; the transport check must not double-page on the revert.
func TestAlarm5SkipsWhenSourceReverted(t *testing.T) {
	got := codes(evaluateTransport(snap(10, 0, 1000, 1, 0, true), baseSnap(1_000_000, 1_000_000, true), defaults))
	if _, bad := got["rate-transport-mismatch"]; bad {
		t.Fatalf("must not page transport while the source is in the vanished state, got %v", got)
	}
}

// Unconfigured Base side (single-chain rehearsal) is a no-op, not an error.
func TestAlarm5UnconfiguredIsNoop(t *testing.T) {
	if got := evaluateTransport(snap(10, 1000, 1000, 1, 1_000_000, false), nil, defaults); len(got) != 0 {
		t.Fatalf("nil BaseSnapshot must produce no alerts, got %v", got)
	}
}
