// SPDX-License-Identifier: GPL-2.0-or-later
//
// SzAlphaRateWorkflow — the cross-chain RATE PULL for 8x-02.
//
// Job (deliberately tiny): on a cron, read `SzAlpha.exchangeRate()` on Subtensor (964) and push the RAW value to
// `SzAlphaRateOracle` on Base. It transports the ONE primitive that lives only on Bittensor — the exchange rate —
// and NOTHING else. No APR, no NAV, no off-chain math: the chain derives those from the pushed rate.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// BUILD BOUNDARY. This is the CRE-03 integration artifact (the `contracts/` Foundry repo has no Go toolchain).
// What is pinned EXACT here (the contract handshake): the payload `abi.encode(uint256 rate, uint48 ts)` and the
// §8.0 envelope `abi.encode(uint8 RATE=8, bytes payload)` — byte-matching `SzAlphaRateOracle._processReport`.
//
// EVERY open item below is TRACKED in the ticket's "OPEN / BLOCKING RISKS" table (tickets/bridge/8x-02-...md) —
// they are NOT buried here. The two that matter:
//   R-1 (BLOCKING): can CRE even READ 964? `SzAlpha.exchangeRate()` staticcalls the 0x805 precompile, which the
//                   "8x exception" says a typed call may never reach. PROVE THIS before relying on the read path.
//   R-4 (wiring):   go.mod, 964/8453 selectors + RPC, config unmarshal, the exact exchangeRate() read.
// Until 8x-01's lane is live, point at the 18-dp xALPHA stand-in (same `IXAlphaRate` surface).
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
package main

import (
	"log/slog"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
	"github.com/smartcontractkit/cre-sdk-go/cre/wasm"
)

const rateReportType uint8 = 8 // SzAlphaRateOracle.RATE — (receiver, reportType)-scoped
const writeGasLimit = uint64(250_000)

type Config struct {
	Schedule string `json:"schedule"` // hourly: "0 0 * * * *" (cadence → maxStaleness ~6h, window 30d)

	// 964 — Subtensor EVM: the SzAlpha wrapper exposing IXAlphaRate.exchangeRate().
	SubtensorChainSelector uint64 `json:"subtensorChainSelector"`
	SzAlpha                string `json:"szAlpha"`

	// 8453 — Base: the rate oracle to push into.
	BaseChainSelector uint64 `json:"baseChainSelector"`
	SzAlphaRateOracle string `json:"szAlphaRateOracle"`
}

func main() {
	runner := wasm.NewRunner(func(b []byte) (Config, error) { return Config{}, nil }) // R-4: unmarshal `b`
	runner.Run(initFn)
}

func initFn(_ []byte, _ *slog.Logger, _ cre.SecretsProvider) (cre.Workflow[Config], error) {
	return cre.Workflow[Config]{
		cre.Handler(cron.Trigger(&cron.Config{Schedule: "0 0 * * * *"}), onCron), // hourly
	}, nil
}

func onCron(cfg Config, runtime cre.Runtime, _ *cron.Payload) (struct{}, error) {
	// 1. Pull the rate from 964 (the irreducible cross-chain fact).
	rate, ts, err := readExchangeRate(&evm.Client{ChainSelector: cfg.SubtensorChainSelector}, runtime, cfg.SzAlpha)
	if err != nil {
		return struct{}{}, err
	}
	if rate.Sign() == 0 {
		return struct{}{}, nil // never push a zero rate (the receiver would revert ZeroRate anyway)
	}

	// 2. Encode the payload EXACT to SzAlphaRateOracle._processReport: (uint256 rate, uint48 ts).
	payload, err := encodeRatePayload(rate, ts)
	if err != nil {
		return struct{}{}, err
	}

	// 3. Sign + 4. push to Base. The receiver enforces non-zero / not-future / strictly-newer.
	report, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: encodeEnvelope(rateReportType, payload),
		EncoderName:    "evm",
		SigningAlgo:    "ecdsa",
		HashingAlgo:    "keccak256",
	}).Await()
	if err != nil {
		return struct{}{}, err
	}
	_, err = (&evm.Client{ChainSelector: cfg.BaseChainSelector}).WriteReport(runtime, &evm.WriteReportRequest{
		Receiver:  common.HexToAddress(cfg.SzAlphaRateOracle).Bytes(),
		Report:    report,
		GasConfig: &evm.GasConfig{GasLimit: writeGasLimit},
	}).Await()
	return struct{}{}, err
}

// encodeRatePayload packs (uint256 rate, uint48 ts) — the EXACT tuple SzAlphaRateOracle decodes.
func encodeRatePayload(rate *big.Int, ts uint64) ([]byte, error) {
	u256, _ := abi.NewType("uint256", "", nil)
	u48, _ := abi.NewType("uint48", "", nil)
	return abi.Arguments{{Type: u256}, {Type: u48}}.Pack(rate, new(big.Int).SetUint64(ts))
}

// encodeEnvelope packs the §8.0 envelope abi.encode(uint8 reportType, bytes payload).
func encodeEnvelope(reportType uint8, payload []byte) []byte {
	u8, _ := abi.NewType("uint8", "", nil)
	bts, _ := abi.NewType("bytes", "", nil)
	out, _ := abi.Arguments{{Type: u8}, {Type: bts}}.Pack(reportType, payload)
	return out
}

// readExchangeRate reads IXAlphaRate.exchangeRate() on SzAlpha (964) + the read block's timestamp.
func readExchangeRate(c *evm.Client, runtime cre.Runtime, szAlpha string) (*big.Int, uint64, error) {
	// R-1 (BLOCKING, see ticket) + R-4: c.CallContract(runtime, &evm.CallContractRequest{Call:{To: szAlpha,
	// Data: selector("exchangeRate()")}}).Await() → decode uint256; ts = read block timestamp. R-1 GATES THIS:
	// exchangeRate() staticcalls the 0x805 precompile — prove CRE can reach it on 964 before relying on this.
	_ = c
	_ = runtime
	_ = common.HexToAddress(szAlpha)
	return big.NewInt(0), 0, nil
}
