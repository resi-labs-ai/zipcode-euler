package config

import (
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// setBaseEnv sets the minimum required env for a valid Load (scalar knobs use
// defaults). It uses t.Setenv so each test gets a clean env.
func setBaseEnv(t *testing.T) {
	t.Helper()
	t.Setenv("KEEPER_RPC_URL", "http://127.0.0.1:8545")
	t.Setenv("KEEPER_CHAIN_ID", "8453")
}

func TestLoad_HappyPath(t *testing.T) {
	setBaseEnv(t)
	t.Setenv("KEEPER_POLL_INTERVAL", "15s")
	t.Setenv("KEEPER_CONFIRM_TIMEOUT", "45s")
	t.Setenv("KEEPER_GAS_BUFFER_BPS", "2500")
	t.Setenv("KEEPER_FEE_CAP_MULTIPLIER", "3")
	t.Setenv("KEEPER_ADDR_FarmUtilityLoopModule", "0x61cdc9c8839753f520cc9dc4f2a733e132fe10e4")
	t.Setenv("KEEPER_ADDR_ExitGate", "0xd9b8393fD5057bcb4Fb2d86a1FD594fD8Ebae89e")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.RPCURL != "http://127.0.0.1:8545" {
		t.Errorf("RPCURL = %q", cfg.RPCURL)
	}
	if cfg.ChainID != 8453 {
		t.Errorf("ChainID = %d", cfg.ChainID)
	}
	if cfg.PollInterval != 15*time.Second {
		t.Errorf("PollInterval = %v", cfg.PollInterval)
	}
	if cfg.ConfirmTimeout != 45*time.Second {
		t.Errorf("ConfirmTimeout = %v", cfg.ConfirmTimeout)
	}
	if cfg.GasBufferBps != 2500 {
		t.Errorf("GasBufferBps = %d", cfg.GasBufferBps)
	}
	if cfg.FeeCapMultiplier != 3 {
		t.Errorf("FeeCapMultiplier = %d", cfg.FeeCapMultiplier)
	}
	want := common.HexToAddress("0x61cdc9c8839753f520cc9dc4f2a733e132fe10e4")
	if got, err := cfg.MustAddr("FarmUtilityLoopModule"); err != nil || got != want {
		t.Errorf("MustAddr(FarmUtilityLoopModule) = %s, %v", got.Hex(), err)
	}
}

func TestLoad_DefaultsAppliedBeforeValidate(t *testing.T) {
	// Bare env (only the two non-defaulted required fields) must produce defaults
	// that are valid — GasBufferBps==3000, etc.
	setBaseEnv(t)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load with bare env: %v", err)
	}
	if cfg.GasBufferBps != 3000 {
		t.Errorf("default GasBufferBps = %d, want 3000", cfg.GasBufferBps)
	}
	if cfg.FeeCapMultiplier != 2 {
		t.Errorf("default FeeCapMultiplier = %d, want 2", cfg.FeeCapMultiplier)
	}
	if cfg.PollInterval != 30*time.Second {
		t.Errorf("default PollInterval = %v, want 30s", cfg.PollInterval)
	}
	if cfg.ConfirmTimeout != 60*time.Second {
		t.Errorf("default ConfirmTimeout = %v, want 60s", cfg.ConfirmTimeout)
	}
}

func TestLoad_ExplicitZeroGasBufferRejected(t *testing.T) {
	// An EXPLICIT KEEPER_GAS_BUFFER_BPS=0 is rejected (vs unset ⇒ default 3000).
	setBaseEnv(t)
	t.Setenv("KEEPER_GAS_BUFFER_BPS", "0")
	if _, err := Load(); err == nil {
		t.Fatal("expected explicit GasBufferBps=0 to be rejected")
	}
}

func TestValidate_Rejections(t *testing.T) {
	valid := func() Config {
		c := defaults()
		c.RPCURL = "http://127.0.0.1:8545"
		c.ChainID = 8453
		return c
	}
	cases := map[string]func(c *Config){
		"empty RPCURL":          func(c *Config) { c.RPCURL = "" },
		"zero ChainID":          func(c *Config) { c.ChainID = 0 },
		"zero GasBufferBps":     func(c *Config) { c.GasBufferBps = 0 },
		"zero FeeCapMult":       func(c *Config) { c.FeeCapMultiplier = 0 },
		"nonpos PollInterval":   func(c *Config) { c.PollInterval = 0 },
		"nonpos ConfirmTimeout": func(c *Config) { c.ConfirmTimeout = 0 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			c := valid()
			mutate(&c)
			if err := c.Validate(); err == nil {
				t.Errorf("%s: expected Validate to reject", name)
			}
		})
	}

	// Sanity: the valid baseline passes.
	c := valid()
	if err := c.Validate(); err != nil {
		t.Errorf("valid baseline rejected: %v", err)
	}
}

func TestMustAddr_MissingOrZero(t *testing.T) {
	c := defaults()
	if _, err := c.MustAddr("ZipRedemptionQueue"); err == nil {
		t.Error("expected MustAddr on absent name to error")
	}
}
