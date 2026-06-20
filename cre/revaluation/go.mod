module cre-revaluation

go 1.25.3

require (
	cre-zipreport v0.0.0
	github.com/ethereum/go-ethereum v1.17.2
	github.com/smartcontractkit/cre-sdk-go v1.0.1-0.20251111122439-00032d582c18
	github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm v1.0.0-beta.0
	github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http v0.0.0
)

require (
	github.com/ProjectZKM/Ziren/crates/go-runtime/zkvm_runtime v0.0.0-20251001021608-1fe7b43fc4d6 // indirect
	github.com/davecgh/go-spew v1.1.2-0.20180830191138-d8f796af33cc // indirect
	github.com/decred/dcrd/dcrec/secp256k1/v4 v4.0.1 // indirect
	github.com/go-viper/mapstructure/v2 v2.4.0 // indirect
	github.com/holiman/uint256 v1.3.2 // indirect
	github.com/pmezard/go-difflib v1.0.1-0.20181226105442-5d4384ee4fb2 // indirect
	github.com/shopspring/decimal v1.4.0 // indirect
	github.com/smartcontractkit/chainlink-protos/cre/go v0.0.0-20260521152427-d3f6dc93de42 // indirect
	github.com/stretchr/testify v1.11.1 // indirect
	golang.org/x/sys v0.41.0 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)

// Pin to the in-tree SDK snapshot the ticket cites as truth (DEP SEAM: every cre/* module replaces the
// in-tree SDK snapshot). The published releases predate the WriteCreReportRequest split and
// testutils.SetTimeProvider this module + its tests use.
replace github.com/smartcontractkit/cre-sdk-go => ../../reference/cre-sdk-go

replace github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm => ../../reference/cre-sdk-go/capabilities/blockchain/evm

// This slice is http/event-driven (§8.1: no cron heartbeat). The networking/http capability replaces the
// in-tree snapshot via the same relative-replace idiom (swapped in for the scaffold's scheduler/cron).
replace github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http => ../../reference/cre-sdk-go/capabilities/networking/http

// The shared §8.0 report-encoding library (CRE-00), via the same relative-replace idiom the SDK pins use.
replace cre-zipreport => ../zipreport
