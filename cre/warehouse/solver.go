// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-02c — the cross-silo redemption solver (§6.1 / §6.3 / §8.2 / §8.3 / §8.5; federation §4.7).
//
// A THIRD default-OFF cron handler (onSolverTick) in cre/warehouse, alongside CRE-04's onWarehouseOp (http) and
// CRE-02b's onFundingTick (cron). It is the multi-warehouse generalization of CRE-02b's single-pool funding leg:
// on each tick it reads the ONE shared ZipRedemptionQueue shortfall, enumerates the live silos off the
// SiloRegistry, sizes a per-pool REDEEM/REPAY split that respects each pool's gated free-liquidity + per-silo
// coverage gate, and fires per-silo REDEEM→REPAY reports into the one shared queue by writing to EACH silo's own
// WarehouseAdminModule (Fork B — option (i), one binary, per-silo loop). Default-OFF (SolverEnabled=false):
// returns before any read. No contract changes — off-chain Go only.
//
// THE SPLIT (Fork A — pro-rata by gated free-liquidity). The REDEEM shortfall is split across pools proportional
// to each pool's availP — the coverage-gated, reserve-netted, per-tick-clamped redeemable amount (NOT the raw
// maxWithdraw). An undercovered or reserve-starved pool has availP == 0 ⇒ weight 0 ⇒ it is skipped automatically;
// "starved/undercovered pool is skipped" falls out of the weight, not a special case.
//
// THE JOIN (the registry gap — a config seam, not back-pressure). SiloRegistry.Silo has NO warehouseAdminModule
// field, so the silo→WAM binding is config (cfg.Warehouses) joined by warehouseSafe: for each WAM read its
// warehouseSafe() once and pair it to the active registry silo with the matching warehouseSafe (1:1 — one Safe
// per silo). A WAM with no matching active silo, or an active silo with no mapped WAM, is skipped + logged.
//
// REUSE: every read helper (readAddr/readUint/readUintWithAddr/readUintWithArg/readBool/callF/selectorF/
// decodeUintF) and sizing helper (clampF/bigMin/mustBigF) lives in funding.go; the encoders buildRedeem/buildRepay
// live in workflow.go; the write path generalizes to writeReportTo (workflow.go). This file adds only the
// registry decode (readSiloIds / getSilo / decodeSilo) and the solver tick.
package main

import (
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
)

// solverPool is a joined, per-tick view of one (active silo, WAM) pair after the warehouseSafe join. Sized
// scalars (repayP/redeemSharesP) are filled by the two legs.
type solverPool struct {
	wam    common.Address // the silo's WarehouseAdminModule (the report receiver for this pool)
	safe   common.Address // warehouseSafe — the EE-share + USDC custodian
	eePool common.Address // the silo's senior EE pool
	freeze common.Address // the silo's DurationFreezeModule (per-silo coverage gate)

	safeUsdc *big.Int // usdc.balanceOf(safe) — already-held REDEEM proceeds (the REPAY leg source)
	availP   *big.Int // the coverage-gated, reserve-netted, per-tick-clamped redeemable USDC (REDEEM weight)

	repayP        *big.Int // sized REPAY amount (6-dp USDC) toward the queue
	redeemSharesP *big.Int // sized REDEEM shares (EE shares)
	redeemAssetsP *big.Int // the USDC target the shares were sized from (telemetry / invariant)
}

// onSolverTick is the CRE-02c cross-silo solver (K1 — the THIRD handler). Stateless / idempotent (the CRE-02b
// posture). Default-OFF (K-DEFAULT-OFF / K5(e)): SolverEnabled == false ⇒ zero reads, zero writes.
func onSolverTick(cfg *Config, runtime cre.Runtime, _ *cron.Payload) (struct{}, error) {
	logger := runtime.Logger()

	// (1) Default-OFF (K-DEFAULT-OFF): return BEFORE any CallContract — zero reads, zero writes.
	if !cfg.SolverEnabled {
		logger.Info("warehouse solver: no-op (disabled)")
		return struct{}{}, nil
	}
	// (2) Unconfigured ⇒ no-op.
	if strings.TrimSpace(cfg.SiloRegistry) == "" || len(cfg.Warehouses) == 0 {
		logger.Info("warehouse solver: no-op (registry unset or no warehouses)")
		return struct{}{}, nil
	}

	client := &evm.Client{ChainSelector: cfg.ChainSelector}
	registry := common.HexToAddress(cfg.SiloRegistry)

	// (3) Resolve the shared queue + global shortfall. queue/usdc are read OFF cfg.Warehouses[0] (re-pointable,
	// §17). scaleUp == 0 ⇒ no-op (malformed/unwired queue; mirrors CRE-02b / RedemptionJob).
	wh0 := common.HexToAddress(cfg.Warehouses[0])
	queue, err := readAddr(client, runtime, wh0, "redemptionBox()")
	if err != nil {
		return struct{}{}, err
	}
	usdc0, err := readAddr(client, runtime, wh0, "usdc()")
	if err != nil {
		return struct{}{}, err
	}
	if queue == (common.Address{}) || usdc0 == (common.Address{}) {
		logger.Info("warehouse solver: no-op (queue/usdc unset on warehouse[0])")
		return struct{}{}, nil
	}

	scaleUp, err := readUint(client, runtime, queue, "scaleUp()")
	if err != nil {
		return struct{}{}, err
	}
	if scaleUp.Sign() == 0 {
		logger.Info("warehouse solver: no-op (scaleUp 0)")
		return struct{}{}, nil
	}
	totalPending, err := readUint(client, runtime, queue, "totalPending()")
	if err != nil {
		return struct{}{}, err
	}
	reserved, err := readUint(client, runtime, queue, "reservedAssets()")
	if err != nil {
		return struct{}{}, err
	}
	usdcBalQueue, err := readUintWithAddr(client, runtime, usdc0, "balanceOf(address)", queue)
	if err != nil {
		return struct{}{}, err
	}

	// shortfall = max(0, totalPending/scaleUp − max(0, usdc.balanceOf(queue) − reservedAssets)). 6-dp USDC (P7:
	// scaleUp = 1e12; totalPending 18-dp zipUSD ⇒ /scaleUp is 6-dp). <= 0 ⇒ no-op (settle/claim is CRE-02's job).
	freeUsdc := new(big.Int).Sub(usdcBalQueue, reserved)
	if freeUsdc.Sign() < 0 {
		freeUsdc = big.NewInt(0)
	}
	parCapacity := new(big.Int).Div(totalPending, scaleUp)
	shortfall := new(big.Int).Sub(parCapacity, freeUsdc)
	if shortfall.Sign() <= 0 {
		logger.Info("warehouse solver: no-op (no shortfall)")
		return struct{}{}, nil
	}

	// Build the WAM→address map keyed by warehouseSafe (read each WAM's warehouseSafe() once; P3: assert each
	// WAM's redemptionBox()==queue AND usdc()==usdc0; skip+log any divergent WAM).
	wamBySafe := map[common.Address]common.Address{} // warehouseSafe → WAM
	for _, w := range cfg.Warehouses {
		wam := common.HexToAddress(w)
		wSafe, err := readAddr(client, runtime, wam, "warehouseSafe()")
		if err != nil {
			return struct{}{}, err
		}
		if wSafe == (common.Address{}) {
			logger.Info("warehouse solver: skip WAM (zero warehouseSafe)")
			continue
		}
		wBox, err := readAddr(client, runtime, wam, "redemptionBox()")
		if err != nil {
			return struct{}{}, err
		}
		if wBox != queue {
			logger.Info("warehouse solver: skip WAM (divergent redemptionBox)")
			continue
		}
		wUsdc, err := readAddr(client, runtime, wam, "usdc()")
		if err != nil {
			return struct{}{}, err
		}
		if wUsdc != usdc0 {
			logger.Info("warehouse solver: skip WAM (divergent usdc)")
			continue
		}
		wamBySafe[wSafe] = wam
	}

	// (4) Build the candidate pool set. Enumerate allSiloIds(); for each getSilo(id): skip !active; join to a WAM
	// by warehouseSafe. (5) Per-pool availP (the CRE-02b floor, per pool).
	siloIds, err := readSiloIds(client, runtime, registry)
	if err != nil {
		return struct{}{}, err
	}
	var pools []*solverPool
	for _, id := range siloIds {
		safe, eePool, freeze, active, ok := getSilo(client, runtime, registry, id)
		if !ok {
			logger.Info("warehouse solver: skip silo (short/empty getSilo)")
			continue
		}
		if !active {
			continue
		}
		wam, joined := wamBySafe[safe]
		if !joined {
			logger.Info("warehouse solver: skip silo (no mapped WAM)")
			continue
		}

		// safeUsdc off the shared usdc0 (P3); covered() off the per-silo freeze (zero ⇒ true, the CRE-02b idiom —
		// defensive: the registry never stores a zero freeze). freeReservoir = eePool.maxWithdraw(safe).
		safeUsdc, err := readUintWithAddr(client, runtime, usdc0, "balanceOf(address)", safe)
		if err != nil {
			return struct{}{}, err
		}
		covered := true
		if freeze != (common.Address{}) {
			covered, err = readBool(client, runtime, freeze, "covered()")
			if err != nil {
				return struct{}{}, err
			}
		}
		freeReservoir, err := readUintWithAddr(client, runtime, eePool, "maxWithdraw(address)", safe)
		if err != nil {
			return struct{}{}, err
		}

		// (5) availP = covered ? clamp(freeReservoir − HarvestReserve − SafetyBuffer, 0, MaxRedeemPerTick) : 0.
		// MaxRedeemPerTick == 0 ⇒ no upper clamp. PER-POOL knobs reused from CRE-02b (applied per pool identically).
		availP := big.NewInt(0)
		if covered {
			a := new(big.Int).Sub(new(big.Int).Sub(freeReservoir, mustBigF(cfg.HarvestReserve)), mustBigF(cfg.SafetyBuffer))
			hi := mustBigF(cfg.MaxRedeemPerTick)
			if hi.Sign() <= 0 {
				hi = a
			}
			availP = clampF(a, big.NewInt(0), hi)
		}

		pools = append(pools, &solverPool{
			wam: wam, safe: safe, eePool: eePool, freeze: freeze,
			safeUsdc: safeUsdc, availP: availP,
			repayP: big.NewInt(0), redeemSharesP: big.NewInt(0), redeemAssetsP: big.NewInt(0),
		})
	}
	if len(pools) == 0 {
		logger.Info("warehouse solver: no-op (no joined active pools)")
		return struct{}{}, nil
	}

	// (6) REPAY leg (un-gated; greedy, global-bounded). Iterate pools in allSiloIds() order; repayP =
	// min(safeUsdc_P, remainingShortfall); remainingShortfall -= repayP. REPAY moves cash the Safe already holds,
	// so it is safe even when undercovered; greedy keeps Σ repayP ≤ shortfall.
	remaining := new(big.Int).Set(shortfall)
	for _, p := range pools {
		if remaining.Sign() <= 0 {
			break
		}
		p.repayP = bigMin(p.safeUsdc, remaining)
		remaining = new(big.Int).Sub(remaining, p.repayP)
	}

	// (7) REDEEM split (pro-rata by availP, Fork A). totalAvail = Σ availP; redeemTarget = min(remaining, totalAvail).
	// Per pool: redeemAssetsP = floor(redeemTarget · availP / totalAvail) (integer floor ⇒ Σ ≤ redeemTarget,
	// conservative; redeemAssetsP ≤ availP because availP/totalAvail ≤ 1 and redeemTarget ≤ totalAvail). totalAvail
	// == 0 ⇒ no REDEEM (every pool starved/undercovered).
	totalAvail := big.NewInt(0)
	for _, p := range pools {
		totalAvail = new(big.Int).Add(totalAvail, p.availP)
	}
	if remaining.Sign() > 0 && totalAvail.Sign() > 0 {
		redeemTarget := bigMin(remaining, totalAvail)
		for _, p := range pools {
			if p.availP.Sign() <= 0 {
				continue
			}
			p.redeemAssetsP = new(big.Int).Div(new(big.Int).Mul(redeemTarget, p.availP), totalAvail)
			if p.redeemAssetsP.Sign() <= 0 {
				continue
			}
			// Shares from the ERC-4626 ratio (NO convertToShares dependency): redeemSharesP =
			// floor(redeemAssetsP · balanceOf(safe) / convertToAssets(balanceOf(safe))), guarded > 0.
			totalShares, err := readUintWithAddr(client, runtime, p.eePool, "balanceOf(address)", p.safe)
			if err != nil {
				return struct{}{}, err
			}
			navAssets, err := readUintWithArg(client, runtime, p.eePool, "convertToAssets(uint256)", totalShares)
			if err != nil {
				return struct{}{}, err
			}
			if navAssets.Sign() > 0 && totalShares.Sign() > 0 {
				p.redeemSharesP = new(big.Int).Div(new(big.Int).Mul(p.redeemAssetsP, totalShares), navAssets)
			}
		}
	}

	// (8) Fire per-silo REPAY→REDEEM to EACH pool's OWN WAM (Fork B). REPAY-then-REDEEM per pool (deliver-then-
	// refill; abort-safe — each sized off pre-tick reads). A write error is RETURNED (the §8.5 / CRE-02b posture).
	for _, p := range pools {
		if p.repayP.Sign() > 0 {
			envelope, berr := buildRepay(WarehouseOp{Op: "repay", Dest: queue.Hex(), Amount: p.repayP.String()})
			if berr != nil {
				return struct{}{}, berr
			}
			if werr := writeReportTo(cfg, runtime, p.wam, envelope); werr != nil {
				return struct{}{}, werr
			}
		}
		if p.redeemSharesP.Sign() > 0 {
			envelope, berr := buildRedeem(WarehouseOp{Op: "redeem", Shares: p.redeemSharesP.String()})
			if berr != nil {
				return struct{}{}, berr
			}
			if werr := writeReportTo(cfg, runtime, p.wam, envelope); werr != nil {
				return struct{}{}, werr
			}
		}
	}
	return struct{}{}, nil
}

// ──────────────────────────────────────────────────────────────────── SiloRegistry reads (P1 / P2)

// readSiloIds calls allSiloIds() (no arg) and decodes the bytes32[] return (P2). Returns [][32]byte.
func readSiloIds(client *evm.Client, runtime cre.Runtime, registry common.Address) ([][32]byte, error) {
	data, err := callF(client, runtime, registry, selectorF("allSiloIds()"))
	if err != nil {
		return nil, err
	}
	t, _ := abi.NewType("bytes32[]", "", nil)
	out, err := abi.Arguments{{Type: t}}.Unpack(data)
	if err != nil {
		return nil, err
	}
	return out[0].([][32]byte), nil
}

// getSilo packs the bytes32 id, appends to selectorF("getSilo(bytes32)"), calls, and decodeSilos the reply (P2).
// Only the four fields the solver needs are returned; ok=false on a short/empty reply.
func getSilo(client *evm.Client, runtime cre.Runtime, registry common.Address, id [32]byte) (safe, eePool, freeze common.Address, active bool, ok bool) {
	t, _ := abi.NewType("bytes32", "", nil)
	packed, err := abi.Arguments{{Type: t}}.Pack(id)
	if err != nil {
		return common.Address{}, common.Address{}, common.Address{}, false, false
	}
	data, err := callF(client, runtime, registry, append(selectorF("getSilo(bytes32)"), packed...))
	if err != nil {
		return common.Address{}, common.Address{}, common.Address{}, false, false
	}
	return decodeSilo(data)
}

// decodeSilo extracts {warehouseSafe, eePool, freeze, active} from the getSilo(bytes32) reply by WORD OFFSET (P1
// — the load-bearing pin). The Silo tuple is 11 fully-static fields (9 × address, uint16 lineCount, bool active)
// ⇒ a fully-static, inline-encoded 11-word blob: len == 352 (11 × 32), NO leading offset word, field i at word i.
// Field order (SiloRegistry.sol:82-95): adapter(0), warehouseSafe(1), eePool(2), juniorBasket(3), escrow(4),
// defaultCoordinator(5), navOracle(6), freeze(7), curator(8), lineCount(9), active(10).
func decodeSilo(data []byte) (safe, eePool, freeze common.Address, active bool, ok bool) {
	if len(data) < 352 {
		return common.Address{}, common.Address{}, common.Address{}, false, false
	}
	word := func(i int) []byte { return data[i*32 : (i+1)*32] }
	safe = common.BytesToAddress(word(1)[12:32])
	eePool = common.BytesToAddress(word(2)[12:32])
	freeze = common.BytesToAddress(word(7)[12:32])
	active = word(10)[31] != 0
	return safe, eePool, freeze, active, true
}
