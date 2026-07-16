// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-02c — table-driven sizing/routing test for the cross-silo redemption solver (onSolverTick). Against a
// simulated backend with mocked eth_call replies (the funding_test.go evmmock idiom, P5), it decodes the CAPTURED
// report bytes per silo (the §8.0 envelope abi.encode(uint8 opType, bytes payload), then the per-op tuple — NOT
// trusting zipreport) and proves the K5 invariants:
//
//	(a) a starved pool (freeReservoir ≤ reserves ⇒ availP=0) AND an undercovered pool (covered=false ⇒ availP=0)
//	    each get ZERO redeem and are skipped;
//	(b) the REDEEM split matches pro-rata: two healthy pools with availP 3:1 split the redeem 3:1 (modulo floor);
//	(c) Σ repaidP + Σ redeemAssetsP ≤ shortfall;
//	(d) redeemAssetsP ≤ availP for every pool;
//	(e) SolverEnabled=false ⇒ ZERO reads, ZERO writes; empty Warehouses / no active silos / no shortfall ⇒ no writes;
//	(f) each REDEEM/REPAY is written to the CORRECT per-silo WAM (the warehouseSafe join routes correctly).
//
// The getSilo mock ENCODES its return via the canonical 11-field abi tuple Pack (9 addresses, uint16, bool) so the
// word-offset decodeSilo is proven against the canonical ABI layout (P1). The existing funding/op tests are
// unchanged and still pass; this handler is purely additive.
package main

import (
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	evmmock "github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm/mock"
	"github.com/smartcontractkit/cre-sdk-go/cre/testutils"

	zipreport "cre-zipreport"
)

// The shared single-chain wiring slots. queue == redemptionBox (seam #6); usdc0 is the one token across silos.
var (
	sRegistry = common.HexToAddress("0x0000000000000000000000000000000000005E00")
	sQueue    = common.HexToAddress("0x0000000000000000000000000000000000005A11")
	sUsdc     = common.HexToAddress("0x0000000000000000000000000000000000005F11")
)

// siloMock is one (silo, WAM) pair's scripted state for a tick.
type siloMock struct {
	id   [32]byte
	wam  common.Address // the WarehouseAdminModule (report receiver) — distinct per pool
	safe common.Address // warehouseSafe (the registry join key)
	pool common.Address // eePool
	frz  common.Address // freeze

	active   bool
	covered  bool
	safeUsdc *big.Int // usdc.balanceOf(safe)
	maxWith  *big.Int // eePool.maxWithdraw(safe) — the free reservoir
	shares   *big.Int // eePool.balanceOf(safe) — total shares held
	nav      *big.Int // eePool.convertToAssets(shares)
}

// solverQueueState scripts the shared queue + global shortfall.
type solverQueueState struct {
	totalPending *big.Int // 18-dp zipUSD
	scaleUp      *big.Int
	reserved     *big.Int // 6-dp USDC
	usdcBalQueue *big.Int // 6-dp USDC balanceOf(queue)
}

// silo32 builds a deterministic non-zero bytes32 silo id.
func silo32(low byte) [32]byte {
	var id [32]byte
	id[0] = 0x51
	id[31] = low
	return id
}

func solverConfig(warehouses []common.Address) *Config {
	cfg := testConfig() // ChainSelector + Warehouse(unused here) + WriteGasLimit
	cfg.SolverEnabled = true
	cfg.SolverSchedule = "0 */5 * * * *"
	cfg.SiloRegistry = sRegistry.Hex()
	cfg.HarvestReserve = "100000000" // 100 USDC (6-dp)
	cfg.SafetyBuffer = "50000000"    // 50 USDC
	cfg.MaxRedeemPerTick = "0"       // uncapped by this knob
	whs := make([]string, len(warehouses))
	for i, w := range warehouses {
		whs[i] = w.Hex()
	}
	cfg.Warehouses = whs
	return cfg
}

// encSiloTuple ENCODES a Silo via the canonical 11-field abi tuple (9 addresses, uint16 lineCount, bool active),
// proving the word-offset decodeSilo against the canonical ABI layout (P1).
func encSiloTuple(t *testing.T, m siloMock) []byte {
	t.Helper()
	addrT := mustType(t, "address")
	u16T := mustType(t, "uint16")
	boolT := mustType(t, "bool")
	args := abi.Arguments{
		{Type: addrT}, // adapter (0)
		{Type: addrT}, // warehouseSafe (1)
		{Type: addrT}, // eePool (2)
		{Type: addrT}, // juniorBasket (3)
		{Type: addrT}, // escrow (4)
		{Type: addrT}, // defaultCoordinator (5)
		{Type: addrT}, // navOracle (6)
		{Type: addrT}, // freeze (7)
		{Type: addrT}, // curator (8)
		{Type: u16T},  // lineCount (9)
		{Type: boolT}, // active (10)
	}
	adapter := common.BytesToAddress([]byte{0xAD, m.safe[19]})
	junk := common.BytesToAddress([]byte{0xDE, m.safe[19]})
	out, err := args.Pack(
		adapter, m.safe, m.pool, junk, junk, junk, junk, m.frz, junk, uint16(3), m.active,
	)
	if err != nil {
		t.Fatalf("pack silo tuple: %v", err)
	}
	return out
}

// captured holds one decoded write: the receiver WAM and the raw envelope.
type captWrite struct {
	wam common.Address
	env []byte
}

// runSolver wires the mocks for the queue + the list of silos, runs onSolverTick, and returns the captured writes
// tagged with the per-WAM receiver (K5(f)).
func runSolver(t *testing.T, cfg *Config, qs solverQueueState, silos []siloMock) []captWrite {
	t.Helper()
	runtime := testutils.NewRuntime(t, testutils.Secrets{})

	evmMock, err := evmmock.NewClientCapability(testChainSelector, t)
	if err != nil {
		t.Fatalf("NewClientCapability: %v", err)
	}
	sel := func(sig string) string { return string(selectorF(sig)) }

	var writes []captWrite

	// Per-WAM writeCap: capture (WAM, payload) so K5(f) per-silo routing is asserted.
	mkWriteCap := func(wam common.Address) func([]byte, *evm.GasConfig) (*evm.WriteReportReply, error) {
		return func(payload []byte, _ *evm.GasConfig) (*evm.WriteReportReply, error) {
			cp := make([]byte, len(payload))
			copy(cp, payload)
			writes = append(writes, captWrite{wam: wam, env: cp})
			return &evm.WriteReportReply{}, nil
		}
	}

	// Registry: allSiloIds() → the id list; getSilo(bytes32) dispatches on the id arg to the matching tuple.
	idList := make([][32]byte, len(silos))
	tuples := map[[32]byte][]byte{}
	for i, m := range silos {
		idList[i] = m.id
		tuples[m.id] = encSiloTuple(t, m)
	}
	bytes32ArrT := mustType(t, "bytes32[]")
	allIds, _ := abi.Arguments{{Type: bytes32ArrT}}.Pack(idList)
	evmmock.AddContractMock(sRegistry, evmMock, map[string]func([]byte) ([]byte, error){
		sel("allSiloIds()"): func([]byte) ([]byte, error) { return allIds, nil },
		sel("getSilo(bytes32)"): func(in []byte) ([]byte, error) {
			var id [32]byte
			copy(id[:], in[len(in)-32:])
			tup, ok := tuples[id]
			if !ok {
				return []byte{}, nil
			}
			return tup, nil
		},
	}, nil)

	// usdc: balanceOf(addr) dispatches on the trailing-20-byte arg — queue vs each pool's safe.
	safeBal := map[common.Address]*big.Int{}
	for _, m := range silos {
		safeBal[m.safe] = m.safeUsdc
	}
	evmmock.AddContractMock(sUsdc, evmMock, map[string]func([]byte) ([]byte, error){
		sel("balanceOf(address)"): func(in []byte) ([]byte, error) {
			arg := common.BytesToAddress(in[len(in)-20:])
			if arg == sQueue {
				return encU(qs.usdcBalQueue), nil
			}
			if v, ok := safeBal[arg]; ok {
				return encU(v), nil
			}
			return encU(big.NewInt(0)), nil
		},
	}, nil)

	// queue: scaleUp / totalPending / reservedAssets.
	evmmock.AddContractMock(sQueue, evmMock, map[string]func([]byte) ([]byte, error){
		sel("scaleUp()"):        func([]byte) ([]byte, error) { return encU(qs.scaleUp), nil },
		sel("totalPending()"):   func([]byte) ([]byte, error) { return encU(qs.totalPending), nil },
		sel("reservedAssets()"): func([]byte) ([]byte, error) { return encU(qs.reserved), nil },
	}, nil)

	// Per-silo: the WAM getters (+ write receiver), the eePool reads, the freeze covered().
	for _, m := range silos {
		mm := m
		evmmock.AddContractMock(mm.wam, evmMock, map[string]func([]byte) ([]byte, error){
			sel("warehouseSafe()"): func([]byte) ([]byte, error) { return encAddr(mm.safe), nil },
			sel("redemptionBox()"): func([]byte) ([]byte, error) { return encAddr(sQueue), nil },
			sel("usdc()"):          func([]byte) ([]byte, error) { return encAddr(sUsdc), nil },
		}, mkWriteCap(mm.wam))

		evmmock.AddContractMock(mm.pool, evmMock, map[string]func([]byte) ([]byte, error){
			sel("maxWithdraw(address)"):     func([]byte) ([]byte, error) { return encU(mm.maxWith), nil },
			sel("balanceOf(address)"):       func([]byte) ([]byte, error) { return encU(mm.shares), nil },
			sel("convertToAssets(uint256)"): func([]byte) ([]byte, error) { return encU(mm.nav), nil },
		}, nil)

		evmmock.AddContractMock(mm.frz, evmMock, map[string]func([]byte) ([]byte, error){
			sel("covered()"): func([]byte) ([]byte, error) { return encB(mm.covered), nil },
		}, nil)
	}

	// warehouses[0] is silos[0].wam — onSolverTick reads queue/usdc off it.
	if _, err := onSolverTick(cfg, runtime, nil); err != nil {
		t.Fatalf("onSolverTick: %v", err)
	}
	return writes
}

// decodeRepayEnv / decodeRedeemEnv decode a captured envelope (NOT trusting zipreport).
func decodeRepayEnv(t *testing.T, env []byte) (common.Address, *big.Int) {
	t.Helper()
	op, payload := decodeEnvelope(t, env)
	if op != zipreport.WhRepay {
		t.Fatalf("expected REPAY opType constant %d, got %d", zipreport.WhRepay, op)
	}
	if op != 4 {
		t.Fatalf("expected REPAY opType literal 4, got %d", op)
	}
	dec, err := abi.Arguments{{Type: mustType(t, "address")}, {Type: mustType(t, "uint256")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode repay payload: %v", err)
	}
	return dec[0].(common.Address), dec[1].(*big.Int)
}

func decodeRedeemEnv(t *testing.T, env []byte) *big.Int {
	t.Helper()
	op, payload := decodeEnvelope(t, env)
	if op != zipreport.WhRedeem {
		t.Fatalf("expected REDEEM opType constant %d, got %d", zipreport.WhRedeem, op)
	}
	if op != 3 {
		t.Fatalf("expected REDEEM opType literal 3, got %d", op)
	}
	dec, err := abi.Arguments{{Type: mustType(t, "uint256")}}.Unpack(payload)
	if err != nil {
		t.Fatalf("decode redeem payload: %v", err)
	}
	return dec[0].(*big.Int)
}

// ─────────────────────────────────────────────────────────── builders

// healthyPool: covered, ample reservoir. availP = maxWith − 100 − 50.
func pool(id, low byte, active, covered bool, safeUsdc, maxWith int64) siloMock {
	shares := new(big.Int).Mul(big.NewInt(2), big.NewInt(1_000_000_000_000_000_000)) // 2e18
	nav := big.NewInt(2_000_000_000)                                                 // 2000 USDC (6-dp)
	return siloMock{
		id:     silo32(id),
		wam:    common.BytesToAddress([]byte{0xC0, low}),
		safe:   common.BytesToAddress([]byte{0xD0, low}),
		pool:   common.BytesToAddress([]byte{0xE0, low}),
		frz:    common.BytesToAddress([]byte{0xF0, low}),
		active: active, covered: covered,
		safeUsdc: big.NewInt(safeUsdc), maxWith: big.NewInt(maxWith),
		shares: shares, nav: nav,
	}
}

func wamsOf(silos []siloMock) []common.Address {
	out := make([]common.Address, len(silos))
	for i, m := range silos {
		out[i] = m.wam
	}
	return out
}

// reservesUSDC = HarvestReserve(100) + SafetyBuffer(50) = 150 USDC.
const reservesUSDC = int64(150_000_000)

func availOf(m siloMock) *big.Int {
	if !m.covered {
		return big.NewInt(0)
	}
	a := m.maxWith.Int64() - reservesUSDC
	if a < 0 {
		a = 0
	}
	return big.NewInt(a)
}

// sharesFor sizes the expected REDEEM shares for a redeemAssets target via the 4626 ratio.
func sharesFor(m siloMock, redeemAssets *big.Int) *big.Int {
	if m.nav.Sign() <= 0 || m.shares.Sign() <= 0 {
		return big.NewInt(0)
	}
	return new(big.Int).Div(new(big.Int).Mul(redeemAssets, m.shares), m.nav)
}

func scaleUp1e12s() *big.Int { v, _ := new(big.Int).SetString("1000000000000", 10); return v }
func pending18s(usdc6 int64) *big.Int {
	return new(big.Int).Mul(big.NewInt(usdc6), scaleUp1e12s())
}

// noShortfallQueue makes shortfall 0. shortfallQueue makes par capacity = par6, free = 0.
func shortfallQueue(par6 int64) solverQueueState {
	return solverQueueState{
		totalPending: pending18s(par6), scaleUp: scaleUp1e12s(),
		reserved: big.NewInt(0), usdcBalQueue: big.NewInt(0),
	}
}

// ─────────────────────────────────────────────────────────── (e) default-OFF ⇒ zero writes (and zero reads)

func TestSolverDisabledNoReports(t *testing.T) {
	silos := []siloMock{pool(0x01, 0x01, true, true, 0, 5_000_000_000)}
	cfg := solverConfig(wamsOf(silos))
	cfg.SolverEnabled = false
	out := runSolver(t, cfg, shortfallQueue(1_000_000_000), silos)
	if len(out) != 0 {
		t.Fatalf("disabled: expected 0 writes, got %d", len(out))
	}
}

func TestSolverEmptyWarehousesNoReports(t *testing.T) {
	cfg := solverConfig(nil) // len(Warehouses)==0 ⇒ no-op
	out := runSolver(t, cfg, shortfallQueue(1_000_000_000), nil)
	if len(out) != 0 {
		t.Fatalf("empty warehouses: expected 0 writes, got %d", len(out))
	}
}

func TestSolverNoShortfallNoReports(t *testing.T) {
	silos := []siloMock{pool(0x01, 0x01, true, true, 500_000_000, 5_000_000_000)}
	cfg := solverConfig(wamsOf(silos))
	// par capacity 300, free = usdcBalQueue 400 − 0 ≥ 300 ⇒ shortfall ≤ 0.
	qs := solverQueueState{
		totalPending: pending18s(300_000_000), scaleUp: scaleUp1e12s(),
		reserved: big.NewInt(0), usdcBalQueue: big.NewInt(400_000_000),
	}
	out := runSolver(t, cfg, qs, silos)
	if len(out) != 0 {
		t.Fatalf("no shortfall: expected 0 writes, got %d", len(out))
	}
}

func TestSolverNoActiveSilosNoReports(t *testing.T) {
	silos := []siloMock{pool(0x01, 0x01, false, true, 500_000_000, 5_000_000_000)} // inactive
	cfg := solverConfig(wamsOf(silos))
	out := runSolver(t, cfg, shortfallQueue(1_000_000_000), silos)
	if len(out) != 0 {
		t.Fatalf("no active silos: expected 0 writes, got %d", len(out))
	}
}

// ─────────────────────────────────────────────────────────── (a)+(b)+(c)+(d)+(f) the main split

// Three pools: P1 healthy availP=3000, P2 healthy availP=1000 (3:1), P3 starved (maxWith ≤ reserves ⇒ availP=0),
// P4 undercovered (covered=false ⇒ availP=0). Shortfall large enough that REPAY exhausts safe USDC and REDEEM
// then splits 3:1.
func TestSolverProRataSplitAndSkips(t *testing.T) {
	p1 := pool(0x01, 0x01, true, true, 100_000_000, 3_150_000_000) // availP = 3150−150 = 3000
	p2 := pool(0x02, 0x02, true, true, 0, 1_150_000_000)           // availP = 1150−150 = 1000
	p3 := pool(0x03, 0x03, true, true, 0, 120_000_000)             // starved: 120 < 150 ⇒ availP=0
	p4 := pool(0x04, 0x04, true, false, 0, 5_000_000_000)          // undercovered ⇒ availP=0
	silos := []siloMock{p1, p2, p3, p4}
	cfg := solverConfig(wamsOf(silos))

	// shortfall = 5000 USDC. REPAY: only p1 holds 100 ⇒ repay 100 (remaining 4900). totalAvail = 4000;
	// redeemTarget = min(4900, 4000) = 4000. p1 gets 4000·3000/4000 = 3000; p2 gets 4000·1000/4000 = 1000.
	out := runSolver(t, cfg, shortfallQueue(5_000_000_000), silos)

	// Tag writes per WAM.
	byWam := map[common.Address][]captWrite{}
	for _, w := range out {
		byWam[w.wam] = append(byWam[w.wam], w)
	}

	// (a) p3 (starved) and p4 (undercovered) get ZERO writes.
	if len(byWam[p3.wam]) != 0 {
		t.Fatalf("starved p3: expected 0 writes, got %d", len(byWam[p3.wam]))
	}
	if len(byWam[p4.wam]) != 0 {
		t.Fatalf("undercovered p4: expected 0 writes, got %d", len(byWam[p4.wam]))
	}

	// (f) p1 routes REPAY(100) + REDEEM; p2 routes REDEEM only (safeUsdc 0).
	if len(byWam[p1.wam]) != 2 {
		t.Fatalf("p1: expected REPAY+REDEEM (2 writes), got %d", len(byWam[p1.wam]))
	}
	if len(byWam[p2.wam]) != 1 {
		t.Fatalf("p2: expected REDEEM only (1 write), got %d", len(byWam[p2.wam]))
	}

	// p1 REPAY first → queue / 100 USDC.
	dest, repay1 := decodeRepayEnv(t, byWam[p1.wam][0].env)
	if dest != sQueue {
		t.Fatalf("p1 REPAY dest: got %s want queue %s", dest.Hex(), sQueue.Hex())
	}
	if repay1.Cmp(big.NewInt(100_000_000)) != 0 {
		t.Fatalf("p1 REPAY amount: got %s want 100000000", repay1)
	}

	// (b) pro-rata 3:1. redeemAssets p1 = 3000, p2 = 1000.
	redeemAssets1 := big.NewInt(3_000_000_000)
	redeemAssets2 := big.NewInt(1_000_000_000)
	wantShares1 := sharesFor(p1, redeemAssets1)
	wantShares2 := sharesFor(p2, redeemAssets2)
	gotShares1 := decodeRedeemEnv(t, byWam[p1.wam][1].env)
	gotShares2 := decodeRedeemEnv(t, byWam[p2.wam][0].env)
	if gotShares1.Cmp(wantShares1) != 0 {
		t.Fatalf("p1 REDEEM shares: got %s want %s", gotShares1, wantShares1)
	}
	if gotShares2.Cmp(wantShares2) != 0 {
		t.Fatalf("p2 REDEEM shares: got %s want %s", gotShares2, wantShares2)
	}
	// 3:1 ratio (modulo floor): shares1 == 3·shares2 (here exact since nav/shares identical per pool).
	if new(big.Int).Mul(gotShares2, big.NewInt(3)).Cmp(gotShares1) != 0 {
		t.Fatalf("pro-rata: shares1 %s != 3·shares2 %s", gotShares1, gotShares2)
	}

	// (c) Σ repaid + Σ redeemAssets ≤ shortfall: 100 + 3000 + 1000 = 4100 ≤ 5000.
	sumFunded := new(big.Int).Add(repay1, new(big.Int).Add(redeemAssets1, redeemAssets2))
	if sumFunded.Cmp(big.NewInt(5_000_000_000)) > 0 {
		t.Fatalf("(c) funded %s > shortfall 5000000000", sumFunded)
	}

	// (d) redeemAssetsP ≤ availP for every pool.
	if redeemAssets1.Cmp(availOf(p1)) > 0 {
		t.Fatalf("(d) p1 redeemAssets %s > availP %s", redeemAssets1, availOf(p1))
	}
	if redeemAssets2.Cmp(availOf(p2)) > 0 {
		t.Fatalf("(d) p2 redeemAssets %s > availP %s", redeemAssets2, availOf(p2))
	}
}

// ─────────────────────────────────────────────────────────── (c) REDEEM target bounded by remaining shortfall

// A small shortfall fully covered by REPAY ⇒ no REDEEM (remaining 0), Σ funded ≤ shortfall exactly.
func TestSolverRepayCoversShortfallNoRedeem(t *testing.T) {
	p1 := pool(0x01, 0x01, true, true, 500_000_000, 5_000_000_000)
	silos := []siloMock{p1}
	cfg := solverConfig(wamsOf(silos))
	// shortfall 300; safe holds 500 ⇒ REPAY 300, remaining 0 ⇒ no REDEEM.
	out := runSolver(t, cfg, shortfallQueue(300_000_000), silos)
	if len(out) != 1 {
		t.Fatalf("expected 1 write (REPAY only), got %d", len(out))
	}
	if out[0].wam != p1.wam {
		t.Fatalf("REPAY routed to wrong WAM")
	}
	_, amt := decodeRepayEnv(t, out[0].env)
	if amt.Cmp(big.NewInt(300_000_000)) != 0 {
		t.Fatalf("REPAY amount: got %s want 300000000", amt)
	}
}

// ─────────────────────────────────────────────────────────── all pools starved/undercovered ⇒ REDEEM skipped

func TestSolverAllStarvedNoRedeem(t *testing.T) {
	p1 := pool(0x01, 0x01, true, true, 0, 100_000_000) // 100 < 150 ⇒ availP 0
	p2 := pool(0x02, 0x02, true, false, 0, 9_000_000_000)
	silos := []siloMock{p1, p2}
	cfg := solverConfig(wamsOf(silos))
	out := runSolver(t, cfg, shortfallQueue(5_000_000_000), silos)
	if len(out) != 0 {
		t.Fatalf("all starved/undercovered + no safe USDC: expected 0 writes, got %d", len(out))
	}
}
