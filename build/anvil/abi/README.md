# ABIs for the live anvil deployment — frontend prerequisite

Every contract on the live anvil board, with its ABI. Pairs with `../contract-map.md` (addresses) and the
`smoke-path-*.md` specs (call flows).

## Layout
- `*.json` — **our protocol contracts** (full ABIs, straight from `forge inspect`). One file per contract.
- `external/*.json` — **external/live contracts** the protocol sits on (full verified ABIs from Basescan, plus the
  full EVK `IEVault` interface for our EVault proxies, and a canonical `ERC20.json` for tokens).
- `index.json` — **the resolver**: maps each deployed **address → `{name, abi, kind}`**, where `abi` is the path to
  the ABI file (relative to `build/anvil/`) and `kind` is `protocol` / `external` / `standin` / `demo`. 56 addresses.

## How a frontend uses it (viem)
```ts
import index from "build/anvil/abi/index.json";
import controllerAbi from "build/anvil/abi/ZipcodeController.json";

const entry = index["0x36025de2F0753789058eAE99003BbE2131b63810"]; // -> {name, abi, kind}
// or import the ABI directly and instantiate:
const controller = getContract({ address, abi: controllerAbi, client });
```
RPC: `http://127.0.0.1:8545` (chainId 8453). Keys/principals are in `../contract-map.md`.

## Notes
- **Engine-module addresses are zodiac proxies** — their ABI is the mastercopy's (e.g. the BuyBurn proxy uses
  `SzipBuyBurnModule.json`). The index already points each proxy address at the right file.
- **EVault proxies** (farm utility borrow/escrow + base USDC market) all use `external/IEVault.json` — the full EVK
  interface aggregating every vault module. The per-line borrow/escrow vaults minted at origination use the same ABI.
- **Tokens** (USDC, Loot, Shares) point at `external/ERC20.json` (canonical ERC-20). zipUSD is an EVK `ESynth`
  (`ESynth.json` — full surface incl. minter capacity); szipUSD/xALPHA have their own files.
- **Safes** (main/sidecar/warehouse) use `external/GnosisSafe.json` (the 1.4.1 L2 singleton ABI the proxies delegate to).
- **Runtime-minted contracts** have no fixed address yet (resolve at call time): per-line lien tokens use
  `LienCollateralToken.json`; the per-line EVC sub-account (`new LineAccount{salt: lienId}` in the adapter at
  origination) uses `LineAccount.json`; per-market borrow guards use `FarmUtilityBorrowGuard.json`. These have ABI
  files but no `index.json` address entry (they don't exist until a line/market is opened).
- Regenerate after a redeploy: `forge inspect <Name> abi --json` for protocol files; the index addresses change with
  the deploy (the catalog is fixed). External ABIs are stable (live Base contracts).
