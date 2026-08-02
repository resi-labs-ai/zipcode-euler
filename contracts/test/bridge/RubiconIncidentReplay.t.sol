// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SzAlpha} from "../../src/bridge/SzAlpha.sol";
import {MockSubtensorStaking, MockAlphaPrecompile, MockAddressMapping} from "./BridgeMocks.sol";

/// @title Rubicon 2026-06-12 incident replay — the xSN9 timeline, run against OUR wrapper.
/// @notice Every step below mirrors a block in `audit/reviewed/rubicon-incident-2026-06-12.md` (forensics from
///         on-chain logs). Their contract at each step is quoted in the comments; the asserts are what
///         OUR contract does under the identical sequence. Their outcome: 75,353 shares diluted ~89%,
///         permanent, two tokens still frozen 47+ days. Our outcome: zero mints, exit never pausable,
///         recovery = one owner transaction, rate restored EXACTLY.
contract RubiconIncidentReplayTest is Test {
    address internal constant STAKING_V2 = 0x0000000000000000000000000000000000000805;
    address internal constant ALPHA_PRECOMPILE = 0x0000000000000000000000000000000000000808;
    address internal constant ADDRESS_MAPPING = 0x000000000000000000000000000000000000080C;

    uint256 internal constant NETUID = 9; // xSN9, the worst-hit token
    bytes32 internal constant HOTKEY_CONFIGURED = bytes32(uint256(0x5C1b)); // "5Ctb5J..." — the dead pointer
    bytes32 internal constant HOTKEY_ACTUAL = bytes32(uint256(0x5D0D)); // "5DvDyp..." — where the stake really was
    uint256 internal constant MAX_DL = type(uint256).max;

    SzAlpha internal token;
    address internal timelock = makeAddr("timelock");
    address internal holders = makeAddr("preIncidentHolders");
    address internal victim = makeAddr("windowDepositor");

    function setUp() public {
        vm.etch(STAKING_V2, address(new MockSubtensorStaking()).code);
        vm.etch(ALPHA_PRECOMPILE, address(new MockAlphaPrecompile()).code);
        vm.etch(ADDRESS_MAPPING, address(new MockAddressMapping()).code);
        MockSubtensorStaking(payable(STAKING_V2)).setPrice(1e9);
        MockAlphaPrecompile(ALPHA_PRECOMPILE).setPrice(1e9);
        vm.deal(STAKING_V2, 10_000_000 ether);

        SzAlpha impl = new SzAlpha();
        token = SzAlpha(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            SzAlpha.initialize,
                            ("Staked xALPHA", "szALPHA", NETUID, HOTKEY_CONFIGURED, timelock, timelock)
                        )
                    )
                )
            )
        );
    }

    function _staking() internal pure returns (MockSubtensorStaking) {
        return MockSubtensorStaking(payable(STAKING_V2));
    }

    function _coldkey() internal view returns (bytes32) {
        return keccak256(abi.encode(address(token)));
    }

    function test_replay_xSN9_timeline() public {
        // ── Pre-incident (their block 8,382,555): 75,353 shares outstanding, rate 1.2444 ──
        vm.deal(holders, 76_000 ether);
        vm.prank(holders);
        token.deposit{value: 75_353 ether}(1, MAX_DL);
        // validator emissions lift the backing to the recorded 1.2444 rate (alpha 9-dp).
        _staking().addReward(HOTKEY_CONFIGURED, _coldkey(), NETUID, 18_416_275e6);
        uint256 preIncidentRate = token.exchangeRate();
        assertApproxEqRel(preIncidentRate, 1.2444e18, 1e15, "pre-incident rate ~1.2444, as on-chain");
        uint256 preIncidentSupply = token.totalSupply();

        // ── The event (their block ~8,389,505): substrate swap_hotkey. The ENTIRE delegated stake —
        //    every coldkey, including the wrapper's — moves to a key the contract is not reading.
        //    getStake(configured) now returns 0. CORRECTLY. There is nothing at that key. ──
        _staking().driftHotkey(HOTKEY_CONFIGURED, HOTKEY_ACTUAL, _coldkey(), NETUID);
        assertEq(token.totalStaked(), 0, "the configured key reads zero (the read was never wrong)");

        // ── Their block 8,389,505: `if (totalStaked == 0) return 1e18` — the contract reported PAR
        //    against 75k shares. The lie. OURS: the rate REFUSES to exist. ──
        vm.expectRevert(SzAlpha.BackingVanished.selector);
        token.exchangeRate();

        // ── Their block 8,389,519: a depositor stakes 295.57 alpha-worth and mints 13,417.73 shares —
        //    56x the fair mint, at rate 0.02197. Four more follow for 10.6 hours (1,853.40 alpha total,
        //    ~75,000 bad shares). OURS: the first depositor is REFUSED. So is every later one. ──
        vm.deal(victim, 300 ether);
        vm.prank(victim);
        vm.expectRevert(SzAlpha.BackingVanished.selector);
        token.deposit{value: 295.57 ether}(1, MAX_DL);
        assertEq(token.totalSupply(), preIncidentSupply, "zero bad shares minted, ever");

        // ── Their block 8,392,675 (10.6h later): global pause — deposit AND redeem. Holders frozen
        //    (47+ days for xSN9/xSN34). OURS: redeem is not pausable; in the vanished state it reverts
        //    on ARITHMETIC (nothing at the configured key), not on a pause — and works again the
        //    moment recovery lands below. ──
        vm.prank(timelock);
        token.pause(); // even paused...
        vm.prank(holders);
        vm.expectRevert(SzAlpha.ZeroAmount.selector); // ...the exit gate is arithmetic, not an admin switch
        token.redeem(1 ether, 1, MAX_DL);

        // ── Their recovery: 26 DAYS to a UUPS upgrade shipped under fire, then StakeMigrated events,
        //    final rate 0.1410 — holders down ~89% permanently. OURS: one owner transaction, today. ──
        vm.prank(timelock);
        token.retarget(HOTKEY_ACTUAL);

        assertEq(token.exchangeRate(), preIncidentRate, "rate restored EXACTLY - zero dilution, zero loss");
        assertEq(token.totalSupply(), preIncidentSupply, "supply untouched");

        // ── Post-recovery: the exit works even though deposits are still paused (the S3/S11 asymmetry). ──
        vm.prank(holders);
        uint256 out = token.redeem(1000 ether, 1, MAX_DL);
        assertGt(out, 1244 ether, "redeem pays the full 1.2444-rate value, while still paused");

        // Rubicon's holders: -89%, two tokens frozen 47+ days.
        // Ours, same event: 0 bad shares, 0 loss, exit open, recovered in one transaction.
    }
}
