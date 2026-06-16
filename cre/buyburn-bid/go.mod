module cre-buyburn-bid

go 1.25.3

require (
	github.com/ethereum/go-ethereum v1.17.2
	github.com/smartcontractkit/cre-sdk-go v1.0.1-0.20251111122439-00032d582c18
	github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm v1.0.0-beta.0
	github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron v0.9.0
)

require (
	github.com/decred/dcrd/dcrec/secp256k1/v4 v4.0.1 // indirect
	github.com/go-viper/mapstructure/v2 v2.4.0 // indirect
	github.com/holiman/uint256 v1.3.2 // indirect
	github.com/shopspring/decimal v1.4.0 // indirect
	github.com/smartcontractkit/chainlink-protos/cre/go v0.0.0-20260521152427-d3f6dc93de42 // indirect
	golang.org/x/sys v0.41.0 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)

// Pin to the in-tree SDK snapshot the ticket cites as truth (C7: local replace is permitted). The published
// releases predate the WriteCreReportRequest split (C1), testutils.SetTimeProvider, and the EthereumMainnetBase1
// selector this workflow + its tests use.
replace github.com/smartcontractkit/cre-sdk-go => ../../reference/cre-sdk-go

replace github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm => ../../reference/cre-sdk-go/capabilities/blockchain/evm

replace github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron => ../../reference/cre-sdk-go/capabilities/scheduler/cron
