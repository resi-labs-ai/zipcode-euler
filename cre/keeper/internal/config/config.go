// Package config loads and validates the keeper service configuration.
//
// The operator private key is deliberately NOT part of Config (it lives only in
// keymgr's input via KEEPER_OPERATOR_KEY) so a Config dump can never leak it.
package config

import (
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// Config is the keeper service configuration. Addresses are re-pointable (§17),
// supplied via env (KEEPER_ADDR_<NAME>) — never hard-coded in Go.
type Config struct {
	RPCURL           string                    `json:"rpc_url"`
	ChainID          uint64                    `json:"chain_id"`
	PollInterval     time.Duration             `json:"poll_interval"`
	GasBufferBps     uint64                    `json:"gas_buffer_bps"`     // gas-limit buffer in bps; 3000 => x1.30 (limit only)
	FeeCapMultiplier uint64                    `json:"fee_cap_multiplier"` // base-fee headroom knob (K3)
	ConfirmTimeout   time.Duration             `json:"confirm_timeout"`
	Modules          map[string]common.Address `json:"modules"` // address book keyed by name

	// MinBurnAmount is the BurnJob floor (KEEPER_MIN_BURN_AMOUNT, base-10). It is
	// env-only — `json:"-"` keeps it OUT of the JSON-file overlay (a *big.Int does
	// not round-trip cleanly through it). Default 0 = burn any non-zero fill;
	// unlike the scalar knobs, an explicit 0 is VALID here (no Validate rule).
	MinBurnAmount *big.Int `json:"-"`
}

// defaults returns a Config seeded with the documented default values. Defaults
// are applied BEFORE env + Validate, so an unset KEEPER_GAS_BUFFER_BPS becomes
// 3000 (valid) while an explicit KEEPER_GAS_BUFFER_BPS=0 is rejected.
func defaults() Config {
	return Config{
		PollInterval:     30 * time.Second,
		GasBufferBps:     3000, // x1.30 on the gas LIMIT only
		FeeCapMultiplier: 2,    // base-fee headroom
		ConfirmTimeout:   60 * time.Second,
		Modules:          map[string]common.Address{},
		MinBurnAmount:    big.NewInt(0), // 0 = burn any non-zero fill (explicit 0 is valid)
	}
}

// Load builds a Config: defaults first, then an optional JSON file overlay
// (KEEPER_CONFIG_FILE), then env (env wins), then Validate.
func Load() (*Config, error) {
	cfg := defaults()

	if path := os.Getenv("KEEPER_CONFIG_FILE"); path != "" {
		if err := overlayJSONFile(&cfg, path); err != nil {
			return nil, err
		}
	}

	if err := overlayEnv(&cfg); err != nil {
		return nil, err
	}

	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func overlayJSONFile(cfg *Config, path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("config: reading KEEPER_CONFIG_FILE %q: %w", path, err)
	}
	if err := json.Unmarshal(raw, cfg); err != nil {
		return fmt.Errorf("config: parsing KEEPER_CONFIG_FILE %q: %w", path, err)
	}
	if cfg.Modules == nil {
		cfg.Modules = map[string]common.Address{}
	}
	return nil
}

func overlayEnv(cfg *Config) error {
	if v := os.Getenv("KEEPER_RPC_URL"); v != "" {
		cfg.RPCURL = v
	}
	if v := os.Getenv("KEEPER_CHAIN_ID"); v != "" {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			return fmt.Errorf("config: KEEPER_CHAIN_ID %q: %w", v, err)
		}
		cfg.ChainID = n
	}
	if v := os.Getenv("KEEPER_GAS_BUFFER_BPS"); v != "" {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			return fmt.Errorf("config: KEEPER_GAS_BUFFER_BPS %q: %w", v, err)
		}
		cfg.GasBufferBps = n
	}
	if v := os.Getenv("KEEPER_FEE_CAP_MULTIPLIER"); v != "" {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			return fmt.Errorf("config: KEEPER_FEE_CAP_MULTIPLIER %q: %w", v, err)
		}
		cfg.FeeCapMultiplier = n
	}
	if v := os.Getenv("KEEPER_POLL_INTERVAL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return fmt.Errorf("config: KEEPER_POLL_INTERVAL %q: %w", v, err)
		}
		cfg.PollInterval = d
	}
	if v := os.Getenv("KEEPER_CONFIRM_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return fmt.Errorf("config: KEEPER_CONFIRM_TIMEOUT %q: %w", v, err)
		}
		cfg.ConfirmTimeout = d
	}
	// MinBurnAmount: env-only, base-10 *big.Int. Replace the default ONLY if the
	// var is non-empty (so the seeded 0 survives, per the defaults→json→env order).
	// Reject only an unparseable non-empty value (a Load error, not a Validate
	// rule — any parsed value ≥0 is valid; 0 = burn any non-zero fill).
	if v := os.Getenv("KEEPER_MIN_BURN_AMOUNT"); v != "" {
		n, ok := new(big.Int).SetString(v, 10)
		if !ok {
			return fmt.Errorf("config: KEEPER_MIN_BURN_AMOUNT %q is not a base-10 integer", v)
		}
		cfg.MinBurnAmount = n
	}

	if cfg.Modules == nil {
		cfg.Modules = map[string]common.Address{}
	}
	const prefix = "KEEPER_ADDR_"
	for _, kv := range os.Environ() {
		key, val, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		if !strings.HasPrefix(key, prefix) || len(key) == len(prefix) {
			continue
		}
		name := strings.TrimPrefix(key, prefix)
		if val == "" {
			continue
		}
		if !common.IsHexAddress(val) {
			return fmt.Errorf("config: %s=%q is not a valid hex address", key, val)
		}
		cfg.Modules[name] = common.HexToAddress(val)
	}
	return nil
}

// Validate rejects an invalid configuration. Scalar knobs are always checked.
// Address-book entries are checked lazily via MustAddr (a job declares the names
// it needs); unreferenced book entries may be absent/zero.
func (c *Config) Validate() error {
	if c.RPCURL == "" {
		return fmt.Errorf("config: RPCURL is required (KEEPER_RPC_URL)")
	}
	if c.ChainID == 0 {
		return fmt.Errorf("config: ChainID must be non-zero (KEEPER_CHAIN_ID)")
	}
	if c.GasBufferBps == 0 {
		return fmt.Errorf("config: GasBufferBps must be non-zero (KEEPER_GAS_BUFFER_BPS)")
	}
	if c.FeeCapMultiplier == 0 {
		return fmt.Errorf("config: FeeCapMultiplier must be non-zero (KEEPER_FEE_CAP_MULTIPLIER)")
	}
	if c.PollInterval <= 0 {
		return fmt.Errorf("config: PollInterval must be > 0 (KEEPER_POLL_INTERVAL)")
	}
	if c.ConfirmTimeout <= 0 {
		return fmt.Errorf("config: ConfirmTimeout must be > 0 (KEEPER_CONFIRM_TIMEOUT)")
	}
	return nil
}

// MustAddr returns the address registered under name, erroring loudly if a
// referenced name is missing or the zero address. A job/startup-check calls this
// to declare which names it needs (scoped address validation, K1).
func (c *Config) MustAddr(name string) (common.Address, error) {
	addr, ok := c.Modules[name]
	if !ok || addr == (common.Address{}) {
		return common.Address{}, fmt.Errorf("config: required module address %q is missing or zero (set KEEPER_ADDR_%s)", name, name)
	}
	return addr, nil
}
