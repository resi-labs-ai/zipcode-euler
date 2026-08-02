// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SzAlpha} from "../src/bridge/SzAlpha.sol";

/// @title DeploySzAlphaTestnet — the Phase-A staking-leg deploy (Bittensor testnet 945, NO CCIP).
/// @notice Deploys ONLY the UUPS wrapper + the genesis seed: no pools, no lockbox, no CCT registration.
///         CCIP does not exist on testnet 945 (`SN46-BRIDGE-MVP-V2.md` §2), so `deploy964`'s CCT asserts
///         and registry wiring would revert there — Phase A proves the staking leg alone (deposit mints
///         against a REAL measured stake delta; redeem pays a REAL balance delta; the A8 retarget drill).
/// @dev Env:
///        NETUID            required — the testnet subnet id (46 exists on 945; verify first)
///        VALIDATOR_HOTKEY  required — bytes32 hex of the target hotkey (MVP-V2 §A3)
///        OWNER             optional — upgrade/pause/retarget authority; defaults to the BROADCASTER so
///                          the A8 drill can call `retarget` directly (mainnet uses the timelock; A6)
///        CCIP_ADMIN        optional — unused on testnet (no CCT); defaults to OWNER (init needs non-zero)
///        GENESIS_SEED_WEI  optional — default 0.1 TAO (1e17); the broadcaster's substrate mirror must
///                          hold it (§A4 — the precompile debits the mirror, not the EVM balance)
///      Run:
///        forge script script/DeploySzAlphaTestnet.s.sol --rpc-url $TESTNET_RPC --private-key $PK \
///          --broadcast --slow
/// @dev The seed runs IN-BROADCAST at supply 0 (the one legitimate `minSharesOut == 0` caller) and the
///      shares burn to 0xdead — same no-permissionless-genesis-window posture as `deploy964`. If the
///      seed reverts `AddStakeEffectMissing`, the substrate mirror is unfunded (§A4, the step that bites).
contract DeploySzAlphaTestnet is Script {
    function run() external returns (SzAlpha token) {
        uint256 netuid_ = vm.envUint("NETUID");
        bytes32 hotkey = vm.envBytes32("VALIDATOR_HOTKEY");
        address ownerEnv = vm.envOr("OWNER", address(0));
        uint256 seedWei = vm.envOr("GENESIS_SEED_WEI", uint256(1e17));

        vm.startBroadcast();
        address owner_ = ownerEnv == address(0) ? msg.sender : ownerEnv;
        address ccipAdmin_ = vm.envOr("CCIP_ADMIN", owner_);

        SzAlpha impl = new SzAlpha();
        token = SzAlpha(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            SzAlpha.initialize,
                            ("Staked xALPHA (testnet)", "szALPHA-t", netuid_, hotkey, owner_, ccipAdmin_)
                        )
                    )
                )
            )
        );

        uint256 seedShares = token.deposit{value: seedWei}(0, type(uint256).max);
        token.transfer(address(0xdead), seedShares);
        vm.stopBroadcast();

        console2.log("SzAlpha (proxy):", address(token));
        console2.log("implementation:", address(impl));
        console2.log("owner (retarget/pause/upgrade):", owner_);
        console2.log("netuid:", netuid_);
        console2.logBytes32(token.validatorHotkey());
        console2.logBytes32(token.wrapperColdkey());
        console2.log("seed shares burnt to 0xdead:", seedShares);
        console2.log("totalStaked (18-dp):", token.totalStaked());
        console2.log("exchangeRate (1e18 = 1:1):", token.exchangeRate());
    }
}
