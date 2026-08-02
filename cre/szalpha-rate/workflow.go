// SPDX-License-Identifier: GPL-2.0-or-later
//
// SzAlphaRateWorkflow — the cross-chain RATE PULL (8x-02).
//
// Job (deliberately tiny): on a cron, read `SzAlpha.exchangeRate()` on Subtensor (964) and push the RAW value
// to `SzAlphaRateOracle` on Base. It transports the ONE primitive that lives only on Bittensor — the exchange
// rate — and NOTHING else. No APR, no NAV, no off-chain math: the chain derives those from the pushed rate.
//
// ── S14, THE RULE THIS JOB EXISTS TO HONOR ─────────────────────────────────────────────────────────────────
// A REVERTING `exchangeRate()` read means NO PUSH — never "push 0", never a fallback value. The vanished-
// backing breaker depends on it: `SzAlpha.exchangeRate()` reverts `BackingVanished` when supply > 0 and the
// stake read is 0 (hotkey drift, the Rubicon failure). The revert must propagate as SILENCE on Base — no push
// lands, the feed ages past `maxStaleness`, `fresh()` fails every consumer closed. This handler therefore maps
// a read error to a LOUD errored run (the repeating error is the off-chain alarm) and never reaches the encode
// path. Recorded as seam S14 in docs/wires/SYSTEM-SEAM-MAP.md and pinned by TestSimRevertingReadNoPush.
// ───────────────────────────────────────────────────────────────────────────────────────────────────────────
//
// Fail-safe no-ops (a liveness-only feed — a no-op tick is the safe outcome): an unset receiver or source
// skips the tick; a ZERO rate return skips (genesis-unseeded stand-in; the receiver would revert ZeroRate).
// A read ERROR is NOT a no-op — see S14 above: it errors loudly, and still pushes nothing.
//
// Residual (tracked in todo-bridge item 2): the 964 read path is unproven against the live chain —
// `exchangeRate()` staticcalls the 0x805 precompile inside the node's eth_call. Until a staging run proves it,
// both selectors are config-driven, so the job can rehearse single-chain against the 18-dp xALPHA stand-in on
// Base (same IXAlphaRate surface) by pointing both selectors at Base.
package main

import (
	"log/slog"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"

	zipreport "cre-zipreport"
)

// defaultWriteGasLimit is the WriteReport GasConfig.GasLimit fallback (used when cfg.WriteGasLimit == 0).
// The receiver's _processReport is one decode + three guards + three sstores; 250k is generous.
const defaultWriteGasLimit = uint64(250_000)

// defaultSchedule pins the push cadence (used when cfg.Schedule == ""). Hourly: the receiver was deployed
// around this cadence (`maxStaleness` ~6h ⇒ ~6 missed pushes before consumers fail closed; `window` 30d for
// the APR anchors). 6-field cron (sec min hour dom mon dow).
const defaultSchedule = "0 0 * * * *" // hourly

// Config is the static workflow config (parsed once at init via cre.ParseJSON[Config]). Every wiring slot is
// config-driven and re-pointable — no hardcoded address, no hardcoded chain.
type Config struct {
	// 964 — Subtensor EVM: the SzAlpha wrapper exposing IXAlphaRate.exchangeRate(). For a single-chain
	// rehearsal point the selector at Base and SzAlpha at the 18-dp xALPHA stand-in (same surface).
	SubtensorChainSelector uint64 `json:"subtensorChainSelector"`
	SzAlpha                string `json:"szAlpha"`

	// 8453 — Base: the SzAlphaRateOracle receiver to push into.
	BaseChainSelector uint64 `json:"baseChainSelector"`
	SzAlphaRateOracle string `json:"szAlphaRateOracle"`

	Schedule      string `json:"schedule"`      // push cron; "" falls back to defaultSchedule (hourly)
	WriteGasLimit uint64 `json:"writeGasLimit"` // WriteReport gas limit; 0 falls back to 250_000
}

func initFn(c *Config, _ *slog.Logger, _ cre.SecretsProvider) (cre.Workflow[*Config], error) {
	schedule := c.Schedule
	if schedule == "" {
		schedule = defaultSchedule // pin the cadence; never hand cron.Trigger an empty schedule
	}
	return cre.Workflow[*Config]{
		cre.Handler(cron.Trigger(&cron.Config{Schedule: schedule}), onCron),
	}, nil
}

// onCron is the single handler: read the rate on 964, stamp DON time, push to Base.
func onCron(c *Config, runtime cre.Runtime, _ *cron.Payload) (struct{}, error) {
	logger := runtime.Logger()

	// Unset wiring ⇒ no-op tick (liveness-only feed; nothing to read or nowhere to push is a config state,
	// not a fault).
	if c.SzAlpha == "" || c.SzAlphaRateOracle == "" {
		logger.Info("szalpha-rate: no-op (szAlpha or szAlphaRateOracle unset)")
		return struct{}{}, nil
	}

	// 1. Pull the rate from 964 (the irreducible cross-chain fact).
	//
	// S14: an error here — which includes the contract REVERTING BackingVanished — must produce NO PUSH.
	// Return the error: the run fails loudly (a repeating errored run every tick is the off-chain signal that
	// the breaker is open), the encode path below is never reached, and Base goes stale on schedule.
	rate, err := readExchangeRate(&evm.Client{ChainSelector: c.SubtensorChainSelector}, runtime, c.SzAlpha)
	if err != nil {
		logger.Error("szalpha-rate: exchangeRate() read failed — NO PUSH (S14; if this repeats, suspect the "+
			"BackingVanished breaker: check totalStaked()/totalSupply() on 964)", "err", err)
		return struct{}{}, err
	}

	// A zero RETURN is distinct from a revert: the production SzAlpha never returns 0 (it reverts instead),
	// but the genesis-unseeded stand-in does, and the receiver would revert ZeroRate on it. Skip quietly.
	if rate.Sign() == 0 {
		logger.Info("szalpha-rate: no-op (exchangeRate() == 0, unseeded source)")
		return struct{}{}, nil
	}

	// 2. Stamp with DON time (`runtime.Now()`, the sharefeeds pattern) — NEVER the 964 read-block timestamp.
	// The receiver compares `ts` against BASE time (not-future + strictly-newer + maxStaleness), so a
	// remote-chain stamp imports 964's clock skew: ahead ⇒ FutureTimestamp reverts; behind ⇒ old-on-arrival
	// freshness. DON time ≈ Base time (seconds), so neither arises, and the receiver's not-future check stays
	// a pure producer-bug tripwire (a ms-vs-s stamp fails LOUDLY on the first push instead of poisoning the
	// strictly-newer cursor forever — the receiver has no admin reset by design).
	ts := new(big.Int).SetInt64(runtime.Now().Unix())

	// 3. Encode via the shared §8.0 library (CRE-00) — this slice does NOT re-implement the handshake.
	// zipreport.Rate = envelope abi.encode(uint8 RATE=8, bytes payload), payload abi.encode(uint256, uint48),
	// byte-matching SzAlphaRateOracle._processReport.
	envelope, err := zipreport.Rate(rate, ts)
	if err != nil {
		return struct{}{}, err
	}

	// 4. Sign + push to Base. The receiver enforces non-zero / not-future / strictly-newer; no deviation band
	// by design (a validator slash legitimately lowers the rate).
	if err := writeReport(c, runtime, c.SzAlphaRateOracle, envelope); err != nil {
		return struct{}{}, err
	}
	logger.Info("szalpha-rate: RATE pushed", "rate", rate.String(), "ts", ts.String())
	return struct{}{}, nil
}

// ──────────────────────────────────────────────────────────────────────── DON-mode read (copy sharefeeds)

// selector returns the 4-byte function selector for the canonical signature.
func selector(sig string) []byte {
	return crypto.Keccak256([]byte(sig))[:4]
}

// readExchangeRate reads IXAlphaRate.exchangeRate() on SzAlpha (964). The RATE is the only thing read across
// the chain boundary — the push timestamp is stamped DON-side in `onCron` (never the 964 block time).
func readExchangeRate(client *evm.Client, runtime cre.Runtime, szAlpha string) (*big.Int, error) {
	reply, err := client.CallContract(runtime, &evm.CallContractRequest{
		Call: &evm.CallMsg{To: common.HexToAddress(szAlpha).Bytes(), Data: selector("exchangeRate()")},
	}).Await()
	if err != nil {
		return nil, err // a revert surfaces here — S14: the caller must NOT push (see onCron)
	}
	u256, _ := abi.NewType("uint256", "", nil)
	out, err := abi.Arguments{{Type: u256}}.Unpack(reply.Data)
	if err != nil {
		return nil, err
	}
	return out[0].(*big.Int), nil
}

// ──────────────────────────────────────────────────────────────────────── WriteReport (copy sharefeeds)

// writeReport generates a §8.0 report from the pre-encoded envelope and writes it to the receiver on Base.
func writeReport(c *Config, runtime cre.Runtime, receiver string, envelope []byte) error {
	report, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: envelope,
		EncoderName:    "evm",
		SigningAlgo:    "ecdsa",
		HashingAlgo:    "keccak256",
	}).Await()
	if err != nil {
		return err
	}
	gasLimit := c.WriteGasLimit
	if gasLimit == 0 {
		gasLimit = defaultWriteGasLimit
	}
	client := &evm.Client{ChainSelector: c.BaseChainSelector}
	_, err = client.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  common.HexToAddress(receiver).Bytes(),
		Report:    report,
		GasConfig: &evm.GasConfig{GasLimit: gasLimit},
	}).Await()
	return err
}
