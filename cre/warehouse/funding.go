// SPDX-License-Identifier: GPL-2.0-or-later
//
// CRE-02b — the reserve-gated, self-sizing redemption funding leg (§8.2 / §8.3 / §8.5 / §11).
//
// A cron-driven handler (onFundingTick) that lives ALONGSIDE CRE-04's http handler (onWarehouseOp) in the SAME
// binary, so both write under the warehouse's single pinned expectedWorkflowId (P1; the ReceiverTemplate pins
// exactly one author, so a separate workflow could not WriteReport). It is DEFAULT-OFF: until ops set
// cfg.FundingEnabled, the handler returns immediately before any CallContract (P3) — zero reads, zero writes.
//
// One tick (stateless / idempotent, like the keeper's RedemptionJob — no cross-tick state, no EMA, no stored
// target; the cycle is self-healing so a partial or manual firing is always safe):
//
//	1. FundingEnabled == false        ⇒ no-op (return before any read).
//	2. Resolve safe/eePool/usdc/queue OFF the warehouse adapter (re-pointable, §17). Any zero ⇒ no-op.
//	3. scaleUp == 0                   ⇒ no-op (malformed/unwired queue; mirrors RedemptionJob).
//	4. shortfall = max(0, totalPending/scaleUp − (usdc.balanceOf(queue) − reservedAssets)). 0 ⇒ no funding.
//	5. REPAY leg (NOT coverage-gated — moves cash the Safe already holds): repayAmt = min(safeUsdc, shortfall).
//	6. REDEEM leg (reserve/coverage-gated): avail = clamp(maxWithdraw(safe) − harvestReserve − safetyBuffer, 0,
//	   maxRedeemPerTick); floor = covered ? avail : 0; redeemAssets = min(shortfall − repayAmt, floor);
//	   redeemShares = redeemAssets · totalShares / navAssets (ERC-4626 convertToAssets ratio; integer floor ⇒
//	   conservative, never over-redeems).
//	7. Order: REPAY then REDEEM — each sized off the SAME pre-tick reads; order is for clarity/abort-safety.
//
// Utilization U is NOT read via a bespoke getter (FINDING): there is no separate U getter, and introducing one
// would fight the freeze over the same cash. U is captured by maxWithdraw(safe) through the reserve math — high U
// ⇒ small maxWithdraw ⇒ small floor; !covered ⇒ floor 0. Derive the floor through maxWithdraw + harvestReserve +
// safetyBuffer + covered() ONLY.
//
// REUSE: the sized ops round-trip through CRE-04's existing buildRedeem/buildRepay → zipreport → writeReport — no
// new encoder, no new report transport, no contract change. The §8.5 anticipated reverts (EE cap, Roles
// ParameterNotAllowed, WrongRedemptionBox) are on-chain backstops; a write error is surfaced (the CRE-04 posture).
package main

import (
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
)

// onFundingTick is the CRE-02b funding handler (K1). It reads the reserve-gated availability + the redemption
// shortfall on-chain (DON mode, the buyburn-bid read idiom), sizes a REPAY (USDC the Safe already holds → queue)
// and/or a REDEEM (EE shares → Safe, to refill for next tick), and emits the matching report(s) via CRE-04's
// existing build/write path. Default-OFF (K3): FundingEnabled == false ⇒ zero reads, zero writes.
func onFundingTick(cfg *Config, runtime cre.Runtime, _ *cron.Payload) (struct{}, error) {
	logger := runtime.Logger()

	// (1) Default-OFF (K3 / P3): return BEFORE any CallContract — zero reads, zero writes.
	if !cfg.FundingEnabled {
		logger.Info("warehouse funding: no-op (disabled)")
		return struct{}{}, nil
	}
	if strings.TrimSpace(cfg.Warehouse) == "" {
		logger.Info("warehouse funding: no-op (warehouse unset)")
		return struct{}{}, nil
	}

	client := &evm.Client{ChainSelector: cfg.ChainSelector}
	adapter := common.HexToAddress(cfg.Warehouse)

	// (2) Resolve the wiring slots OFF the warehouse adapter (re-pointable, §17 — NOT fresh Config addresses).
	// redemptionBox == queue (seam #6, pinned at deploy): one address is BOTH the REPAY dest AND the shortfall
	// source. Any zero slot ⇒ malformed/unwired ⇒ no-op.
	safe, err := readAddr(client, runtime, adapter, "warehouseSafe()")
	if err != nil {
		return struct{}{}, err
	}
	eePool, err := readAddr(client, runtime, adapter, "eePool()")
	if err != nil {
		return struct{}{}, err
	}
	usdc, err := readAddr(client, runtime, adapter, "usdc()")
	if err != nil {
		return struct{}{}, err
	}
	queue, err := readAddr(client, runtime, adapter, "redemptionBox()")
	if err != nil {
		return struct{}{}, err
	}
	if safe == (common.Address{}) || eePool == (common.Address{}) || usdc == (common.Address{}) || queue == (common.Address{}) {
		logger.Info("warehouse funding: no-op (adapter slot unset)")
		return struct{}{}, nil
	}

	// (3) Queue state. scaleUp == 0 ⇒ no-op (divide-by-zero guard; mirrors RedemptionJob).
	scaleUp, err := readUint(client, runtime, queue, "scaleUp()")
	if err != nil {
		return struct{}{}, err
	}
	if scaleUp.Sign() == 0 {
		logger.Info("warehouse funding: no-op (scaleUp 0)")
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
	usdcBalQueue, err := readUintWithAddr(client, runtime, usdc, "balanceOf(address)", queue)
	if err != nil {
		return struct{}{}, err
	}

	// (4) shortfall = max(0, totalPending/scaleUp − freeUsdc), freeUsdc = max(0, usdcBalQueue − reserved). Both
	// terms are 6-dp USDC (P7: scaleUp = 1e12; totalPending is 18-dp zipUSD, so totalPending/scaleUp is 6-dp,
	// directly comparable to usdc.balanceOf / reservedAssets — ZipRedemptionQueue.sol:203-204).
	freeUsdc := new(big.Int).Sub(usdcBalQueue, reserved)
	if freeUsdc.Sign() < 0 {
		freeUsdc = big.NewInt(0)
	}
	parCapacity := new(big.Int).Div(totalPending, scaleUp) // 6-dp USDC
	shortfall := new(big.Int).Sub(parCapacity, freeUsdc)
	if shortfall.Sign() <= 0 {
		logger.Info("warehouse funding: no-op (no shortfall)")
		return struct{}{}, nil // nothing to fund; settle/claim is CRE-02's job
	}

	// (5) REPAY leg — drain already-delivered Safe USDC toward the queue (NOT coverage-gated: it moves cash the
	// warehouse already holds and never touches EE shares / the reservoir, so it is safe even when undercovered).
	safeUsdc, err := readUintWithAddr(client, runtime, usdc, "balanceOf(address)", safe)
	if err != nil {
		return struct{}{}, err
	}
	repayAmt := bigMin(safeUsdc, shortfall)

	// (6) REDEEM leg — top the Safe up for the part of the shortfall the Safe can't yet cover, GATED on the
	// reserve/coverage floor. avail = clamp(maxWithdraw(safe) − harvestReserve − safetyBuffer, 0, maxRedeemPerTick)
	// (the buyburn-bid clamp; maxRedeemPerTick == 0 ⇒ no upper clamp). !covered ⇒ floor 0 (K4).
	covered := true
	if gate := common.HexToAddress(cfg.CoverageGate); gate != (common.Address{}) {
		covered, err = readBool(client, runtime, gate, "covered()")
		if err != nil {
			return struct{}{}, err
		}
	}

	freeReservoir, err := readUintWithAddr(client, runtime, eePool, "maxWithdraw(address)", safe)
	if err != nil {
		return struct{}{}, err
	}
	avail := new(big.Int).Sub(new(big.Int).Sub(freeReservoir, mustBigF(cfg.HarvestReserve)), mustBigF(cfg.SafetyBuffer))
	hi := mustBigF(cfg.MaxRedeemPerTick)
	if hi.Sign() <= 0 {
		hi = avail // maxRedeemPerTick == 0 (or unset) ⇒ no upper clamp by this knob
	}
	avail = clampF(avail, big.NewInt(0), hi)

	floor := big.NewInt(0)
	if covered {
		floor = avail
	}
	// redeemAssets = min(shortfall − repayAmt, floor), floored at 0.
	remaining := new(big.Int).Sub(shortfall, repayAmt)
	redeemAssets := bigMin(remaining, floor)
	if redeemAssets.Sign() < 0 {
		redeemAssets = big.NewInt(0)
	}

	// Derive shares from the ERC-4626 convertToAssets ratio (P7 — NO dependency on convertToShares, which the stub
	// omits): redeemShares = redeemAssets · totalShares / navAssets. Guard navAssets>0 && totalShares>0, else skip
	// REDEEM. Integer floor ⇒ redeems marginally LESS than the target (conservative, never over-redeems).
	redeemShares := big.NewInt(0)
	if redeemAssets.Sign() > 0 {
		totalShares, err := readUintWithAddr(client, runtime, eePool, "balanceOf(address)", safe)
		if err != nil {
			return struct{}{}, err
		}
		navAssets, err := readUintWithArg(client, runtime, eePool, "convertToAssets(uint256)", totalShares)
		if err != nil {
			return struct{}{}, err
		}
		if navAssets.Sign() > 0 && totalShares.Sign() > 0 {
			redeemShares = new(big.Int).Div(new(big.Int).Mul(redeemAssets, totalShares), navAssets)
		}
	}

	// (7) Order: REPAY then REDEEM — deliver what we have now, then refill for next tick. Each is sized off the
	// pre-tick reads, so order is for clarity/abort-safety. Two ops ⇒ up to two sequential writeReport Awaits in
	// the one handler. A write error is RETURNED (§8.5 posture; do not swallow). Both skipped when 0 (K5 — no
	// wasted writes).
	if repayAmt.Sign() > 0 {
		envelope, berr := buildRepay(WarehouseOp{Op: "repay", Dest: queue.Hex(), Amount: repayAmt.String()})
		if berr != nil {
			return struct{}{}, berr
		}
		if werr := writeReport(cfg, runtime, envelope); werr != nil {
			return struct{}{}, werr
		}
	}
	if redeemShares.Sign() > 0 {
		envelope, berr := buildRedeem(WarehouseOp{Op: "redeem", Shares: redeemShares.String()})
		if berr != nil {
			return struct{}{}, berr
		}
		if werr := writeReport(cfg, runtime, envelope); werr != nil {
			return struct{}{}, werr
		}
	}
	return struct{}{}, nil
}

// ──────────────────────────────────────────────────────────────────── on-chain reads (DON mode, cloned idiom)
//
// cre/warehouse was a pure encoder with NO on-chain reads. These helpers are cloned from buyburn-bid's read layer
// (workflow.go:286-367) — read SEMANTICS/units only; the keeper's `chain` pkg is a different module that would not
// compile here (P4). readAddr is NEW (buyburn-bid reads no addresses, P5).

// selectorF returns the 4-byte function selector for a canonical signature. (Distinct name to avoid colliding
// with any future selector helper in this package.)
func selectorF(sig string) []byte {
	return crypto.Keccak256([]byte(sig))[:4]
}

// callF performs a view CallContract and returns the raw return bytes (From left nil for views).
func callF(client *evm.Client, runtime cre.Runtime, addr common.Address, data []byte) ([]byte, error) {
	reply, err := client.CallContract(runtime, &evm.CallContractRequest{
		Call: &evm.CallMsg{To: addr.Bytes(), Data: data},
	}).Await()
	if err != nil {
		return nil, err
	}
	return reply.Data, nil
}

// readUint reads a no-arg view returning a single uint (uint256/uint48/… all decode into *big.Int).
func readUint(client *evm.Client, runtime cre.Runtime, addr common.Address, sig string) (*big.Int, error) {
	data, err := callF(client, runtime, addr, selectorF(sig))
	if err != nil {
		return nil, err
	}
	return decodeUintF(data)
}

// readUintWithAddr reads a single-address-arg view returning a uint (e.g. maxWithdraw(address), balanceOf(address)).
func readUintWithAddr(client *evm.Client, runtime cre.Runtime, addr common.Address, sig string, arg common.Address) (*big.Int, error) {
	addrT, _ := abi.NewType("address", "", nil)
	packed, err := abi.Arguments{{Type: addrT}}.Pack(arg)
	if err != nil {
		return nil, err
	}
	data, err := callF(client, runtime, addr, append(selectorF(sig), packed...))
	if err != nil {
		return nil, err
	}
	return decodeUintF(data)
}

// readUintWithArg reads a single-uint256-arg view returning a uint (e.g. convertToAssets(uint256)).
func readUintWithArg(client *evm.Client, runtime cre.Runtime, addr common.Address, sig string, arg *big.Int) (*big.Int, error) {
	u256, _ := abi.NewType("uint256", "", nil)
	packed, err := abi.Arguments{{Type: u256}}.Pack(arg)
	if err != nil {
		return nil, err
	}
	data, err := callF(client, runtime, addr, append(selectorF(sig), packed...))
	if err != nil {
		return nil, err
	}
	return decodeUintF(data)
}

// readBool reads a no-arg view returning a single bool (e.g. covered()).
func readBool(client *evm.Client, runtime cre.Runtime, addr common.Address, sig string) (bool, error) {
	data, err := callF(client, runtime, addr, selectorF(sig))
	if err != nil {
		return false, err
	}
	boolT, _ := abi.NewType("bool", "", nil)
	out, err := abi.Arguments{{Type: boolT}}.Unpack(data)
	if err != nil {
		return false, err
	}
	return out[0].(bool), nil
}

// readAddr reads a no-arg view returning a single address (the four warehouse-adapter getters). NEW (P5):
// buyburn-bid reads no addresses, so this is written, not cloned.
func readAddr(client *evm.Client, runtime cre.Runtime, addr common.Address, sig string) (common.Address, error) {
	data, err := callF(client, runtime, addr, selectorF(sig))
	if err != nil {
		return common.Address{}, err
	}
	addrT, _ := abi.NewType("address", "", nil)
	out, err := abi.Arguments{{Type: addrT}}.Unpack(data)
	if err != nil {
		return common.Address{}, err
	}
	return out[0].(common.Address), nil
}

func decodeUintF(data []byte) (*big.Int, error) {
	u256, _ := abi.NewType("uint256", "", nil)
	out, err := abi.Arguments{{Type: u256}}.Unpack(data)
	if err != nil {
		return nil, err
	}
	return out[0].(*big.Int), nil
}

// ──────────────────────────────────────────────────────────────────── sizing helpers

// clampF(v, lo, hi) = min(max(v, lo), hi). Cloned from buyburn-bid's clamp.
func clampF(v, lo, hi *big.Int) *big.Int {
	out := new(big.Int).Set(v)
	if out.Cmp(lo) < 0 {
		out.Set(lo)
	}
	if out.Cmp(hi) > 0 {
		out.Set(hi)
	}
	return out
}

// bigMin returns the smaller of a, b (a fresh copy).
func bigMin(a, b *big.Int) *big.Int {
	if a.Cmp(b) <= 0 {
		return new(big.Int).Set(a)
	}
	return new(big.Int).Set(b)
}

// mustBigF parses a base-10 config string into a *big.Int (0 if empty/unparseable — the conservative direction).
// Cloned from buyburn-bid's mustBig.
func mustBigF(s string) *big.Int {
	if strings.TrimSpace(s) == "" {
		return big.NewInt(0)
	}
	v, ok := new(big.Int).SetString(strings.TrimSpace(s), 10)
	if !ok {
		return big.NewInt(0)
	}
	return v
}
