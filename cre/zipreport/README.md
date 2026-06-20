# cre-zipreport — the shared §8.0 report-encoding library

`cre-zipreport` is the single, SDK-free Go library that encodes the Zipcode §8.0 report envelope and every
per-`(receiver, reportType)` payload, each pinned to the EXACT tuple the **filed contract** decodes. The
CRE `(R)` report-path workflows (CRE-01/03/04) import this package instead of re-implementing the handshake.

It depends ONLY on `github.com/ethereum/go-ethereum` (`accounts/abi` + `common`) — **no cre-sdk
dependency** — so it builds for the host AND for the `wasip1` workflow target, and is trivially
unit-testable.

## The envelope

Every report receiver decodes `abi.encode(uint8 reportType, bytes payload)` first
(`ZipcodeController.sol:193`, `ZipcodeOracleRegistry.sol:129`, `SzipNavOracle.sol:301`,
`SzipFarmUtilityLpOracle.sol:107`, `DefaultCoordinator.sol:182`, `SzAlphaRateOracle.sol:81`,
`WarehouseAdminModule.sol:158` — there the first field is named `opType`, same `(uint8, bytes)` shape).

```go
env, err := zipreport.Envelope(reportType, payload) // abi.encode(uint8, bytes)
```

## The per-`(receiver, reportType)` table (the filed decode sites — source of truth)

| reportType | Receiver constant @ line | inner payload tuple (`abi.decode` site) | builder |
|---|---|---|---|
| `1` Origination | `ZipcodeController.RT_ORIGINATION` (`:47`) | `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint16 borrowLTV, uint16 liqLTV, uint256 drawAmount, uint256 cap, bytes32 siloId)` (`:222`) | `Origination(...)` |
| `2` Draw | `ZipcodeController.RT_DRAW` (`:48`) | `(bytes32 lienId, bytes32 proofRef, uint256 equityMark, uint256 drawAmount)` (`:266`) | `Draw(...)` |
| `4` Close | `ZipcodeController.RT_CLOSE` (`:50`) | `(bytes32 lienId)` (`:287`) | `Close(...)` |
| `5` Default / `6` Liquidation | `RT_DEFAULT`/`RT_LIQUIDATION` (`:51`/`:52`) | `(bytes32 lienId, uint8 status)` (`:203`) | `Status(reportType, lienId, status)` |
| `3` Revaluation | `ZipcodeOracleRegistry.REVALUATION` (`:29`) | `(address[] liens, uint256[] prices, uint32 ts)` (`:132`) | `Revaluation(...)` |
| `7` NavLeg | `SzipNavOracle.NAV_LEG` (`:72`) | `(uint8[] legs, uint256[] prices, uint32 ts)` (`:304`); `legs ∈ {0,1}` (`:66/:68`) | `NavLegReport(...)` |
| `7` LpMark | `SzipFarmUtilityLpOracle.LP_MARK` (`:28`) | `(uint256 mark, uint32 ts)` (`:109`) | `LpMarkReport(...)` |
| `8` Coordinator | `DefaultCoordinator.REPORT_TYPE` (`:49`) | `(uint8 action, bytes data)` (`:185`) | `CoordLock/Release/Default/Recovery/Resolve/WriteOff` |
| `8` RATE | `SzAlphaRateOracle.RATE` (`:26`) | `(uint256 rate, uint48 ts)` (`:83`) | `Rate(...)` |
| `1/2/3/4` Warehouse op | `WarehouseAdminModule.SUPPLY/APPROVE/REDEEM/REPAY` (`:25-31`) | per-op (below); first field is `opType` | `WhSupplyReport/WhApproveReport/WhRedeemReport/WhRepayReport` |

### DefaultCoordinator action `data` tuples (the inner-inner decode)

| action | enum | `data` tuple | builder |
|---|---|---|---|
| `Lock` | `0` (`:52`) | `(bytes32 lienId, address originator, uint256 amount)` (`:207`) | `CoordLock` |
| `Release` | `1` (`:53`) | `(bytes32 lienId)` (`:220`) | `CoordRelease` |
| `Default_` | `2` (`:54`) | `(bytes32 lienId, uint256 atRisk)` (`:235`) | `CoordDefault` |
| `Recovery` | `3` (`:55`) | `(bytes32 lienId, uint256 recoveryProceeds)` (`:254`) | `CoordRecovery` |
| `Resolve` | `4` (`:56`) | `(bytes32 lienId, uint256 capitalSlashAmount)` (`:277`) | `CoordResolve` |
| `WriteOff` | `5` (`:57-58`) | `(bytes32 lienId, uint256 capitalSlashAmount)` (`:296`) | `CoordWriteOff` |

### WarehouseAdminModule op payloads (envelope `(uint8 opType, bytes payload)`)

| op | opType | payload | builder |
|---|---|---|---|
| `SUPPLY` | `1` | `(uint256 amount)` (`:164`) | `WhSupplyReport` |
| `APPROVE` | `2` | `(uint256 amount)` (`:168`) | `WhApproveReport` |
| `REDEEM` | `3` | `(uint256 shares)` (`:172`) | `WhRedeemReport` |
| `REPAY` | `4` | `(address dest, uint256 amount)` (`:176`) | `WhRepayReport` |

> The `1 POST_BID` / `2 CANCEL_BID` → `SzipBuyBurnModule` socket (§8.0) is **owned by CRE-05a**
> (`cre/buyburn-bid/`) and is intentionally NOT re-exported here.

## Constants

Receiver-grouped (one `const` block per receiver, so the cross-receiver numeral collisions are explicit —
`NavLeg==7` and `LpMark==7`; `CoordinatorReportType==8` and `RateReportType==8`; the warehouse
`WhSupply==1`..`WhRepay==4` are `opType`s on their own receiver):

`ControllerOrigination/Draw/Close/Default/Liquidation`, `RegistryRevaluation`, `NavLeg` +
`LegAlphaUsd=0`/`LegHydxUsd=1`, `LpMark`, `CoordinatorReportType` + `ActionLock..ActionWriteOff`,
`RateReportType`, `WhSupply/WhApprove/WhRedeem/WhRepay`.

> Naming note: where a reportType constant and a builder would collide (`NavLeg`, `LpMark`), the builder
> takes the `…Report` suffix (`NavLegReport`, `LpMarkReport`) — a Go identifier cannot be both a const and
> a func. The warehouse builders likewise take the `…Report` suffix.

## Validation

`Revaluation` and `NavLegReport` return an error if `len(liens) != len(prices)` / `len(legs) !=
len(prices)` (the contracts revert `LengthMismatch` — fail early off-chain). `Status` errors unless
`reportType ∈ {5, 6}`. `NavLegReport` does NOT range-check legs (the contract's `InvalidLeg` guard owns
that).

## ABI native-type mapping (go-ethereum v1.17.2)

`uint8→uint8`, `uint16→uint16`, `uint32→uint32`, `uint48`/`uint256→*big.Int`, `bytes32→[32]byte`,
`address→common.Address`, `address[]→[]common.Address`, `uint256[]→[]*big.Int`, `uint8[]→[]uint8`,
`bytes→[]byte`. A `*big.Int` for a `uint32` is **rejected** by v1.17.2 — pass native; the ABI bytes are
identical.

## Usage

```go
import (
    "math/big"
    zipreport "cre-zipreport"
)

// Push an LP mark: abi.encode(7, abi.encode(uint256 mark, uint32 ts)).
env, err := zipreport.LpMarkReport(new(big.Int).SetUint64(mark), uint32(now))
if err != nil { /* ... */ }

report, _ := runtime.GenerateReport(&cre.ReportRequest{
    EncodedPayload: env, EncoderName: "evm", SigningAlgo: "ecdsa", HashingAlgo: "keccak256",
}).Await()
client.WriteReport(runtime, &evm.WriteCreReportRequest{Receiver: recv, Report: report, GasConfig: gc})
```

## Test

```sh
go build ./... && go vet ./... && go test ./...
GOOS=wasip1 GOARCH=wasm go build ./...
```

`report_test.go` is NON-VACUOUS: for every builder it decodes the bytes as `(uint8, bytes)`, asserts the
reportType, decodes the inner payload as the exact filed tuple, and asserts every field — plus the
Coordinator inner-inner `(action, data)` decode and the length-mismatch error cases.
