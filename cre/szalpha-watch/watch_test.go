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

var defaults = Thresholds{StakeDropBps: 200, RateMoveBps: 100}

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
