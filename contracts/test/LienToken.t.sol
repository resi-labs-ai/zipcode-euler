// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {LienCollateralToken} from "../src/LienCollateralToken.sol";
import {LienTokenFactory} from "../src/LienTokenFactory.sol";

contract LienTokenTest is Test {
    LienTokenFactory factory;

    address controller = makeAddr("controller");
    address attacker = makeAddr("attacker");
    address recipient = makeAddr("recipient");

    bytes32 constant LIEN_ID = keccak256("LIEN_ID_1");
    bytes32 constant LIEN_ID_2 = keccak256("LIEN_ID_2");

    event LienCreated(bytes32 indexed lienId, address indexed lien);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        factory = new LienTokenFactory();
    }

    // ---- Token shape ----
    function test_TokenShape() public {
        vm.prank(controller);
        LienCollateralToken lien = LienCollateralToken(factory.create(LIEN_ID));

        assertEq(lien.totalSupply(), 1e18, "totalSupply");
        assertEq(lien.balanceOf(controller), 1e18, "balanceOf controller");
        assertEq(lien.decimals(), 18, "decimals");
        assertEq(lien.name(), "Zipcode Lien Collateral", "name");
        assertEq(lien.symbol(), "zLIEN", "symbol");
        assertEq(lien.controller(), controller, "controller");
    }

    // ---- Token-constructor zero-guard ----
    function test_ConstructorRevertsOnZeroController() public {
        vm.expectRevert(bytes("LienCollateralToken: zero controller"));
        new LienCollateralToken(address(0));
    }

    // ---- Precompute correctness (L4 step 3) ----
    function test_PrecomputeMatchesDeploy() public {
        address predicted = factory.computeAddress(LIEN_ID, controller);
        assertEq(predicted.code.length, 0, "predicted slot empty before deploy");

        vm.prank(controller);
        address deployed = factory.create(LIEN_ID);

        assertEq(predicted, deployed, "predicted == deployed");
        assertGt(deployed.code.length, 0, "deployed has code");
    }

    // ---- Precompute keyed on (lienId, controller) ----
    function test_PrecomputeKeyedOnLienIdAndController() public {
        // distinct lienIds -> distinct addresses
        assertTrue(
            factory.computeAddress(LIEN_ID, controller) != factory.computeAddress(LIEN_ID_2, controller),
            "distinct lienId -> distinct address"
        );
        // distinct controllers -> distinct addresses
        assertTrue(
            factory.computeAddress(LIEN_ID, controller) != factory.computeAddress(LIEN_ID, attacker),
            "distinct controller -> distinct address"
        );
    }

    // ---- Create is caller-bound + squat-proof ----
    function test_CreateCallerBoundSquatProof() public {
        vm.prank(attacker);
        address attackerLien = factory.create(LIEN_ID);

        // attacker's token binds to attacker, at the attacker-keyed slot
        assertEq(attackerLien, factory.computeAddress(LIEN_ID, attacker), "attacker token at attacker slot");
        assertEq(LienCollateralToken(attackerLien).controller(), attacker, "attacker token authority");

        // the canonical (controller) slot is still empty -> real controller can still create LIEN_i
        address canonical = factory.computeAddress(LIEN_ID, controller);
        assertEq(canonical.code.length, 0, "canonical slot untouched");

        vm.prank(controller);
        address controllerLien = factory.create(LIEN_ID);
        assertEq(controllerLien, canonical, "controller still gets canonical slot");
        assertEq(LienCollateralToken(controllerLien).controller(), controller, "controller token authority");
    }

    // ---- Dedup / single-use lienId ----
    function test_DedupSameCallerReverts() public {
        vm.prank(controller);
        factory.create(LIEN_ID);

        vm.prank(controller);
        vm.expectRevert(Errors.FailedDeployment.selector);
        factory.create(LIEN_ID);
    }

    function test_BurnThenRecreateStillReverts() public {
        vm.prank(controller);
        LienCollateralToken lien = LienCollateralToken(factory.create(LIEN_ID));

        vm.prank(controller);
        lien.burn(1e18);
        assertEq(lien.totalSupply(), 0, "supply burned to 0");

        // address permanently retired even at 0 supply
        vm.prank(controller);
        vm.expectRevert(Errors.FailedDeployment.selector);
        factory.create(LIEN_ID);
    }

    // ---- Burn authority + bounds ----
    function test_BurnByControllerDropsSupplyAndEmits() public {
        vm.prank(controller);
        LienCollateralToken lien = LienCollateralToken(factory.create(LIEN_ID));

        vm.expectEmit(true, true, false, true, address(lien));
        emit Transfer(controller, address(0), 1e18);

        vm.prank(controller);
        lien.burn(1e18);

        assertEq(lien.totalSupply(), 0, "supply 0");
        assertEq(lien.balanceOf(controller), 0, "controller balance 0");
    }

    function test_BurnByNonControllerReverts() public {
        vm.prank(controller);
        LienCollateralToken lien = LienCollateralToken(factory.create(LIEN_ID));

        vm.prank(attacker);
        vm.expectRevert(LienCollateralToken.NotController.selector);
        lien.burn(1e18);
    }

    function test_BurnZeroNoOp() public {
        vm.prank(controller);
        LienCollateralToken lien = LienCollateralToken(factory.create(LIEN_ID));

        vm.prank(controller);
        lien.burn(0);

        assertEq(lien.totalSupply(), 1e18, "supply unchanged after burn(0)");
    }

    function test_BurnOverBalanceReverts() public {
        vm.prank(controller);
        LienCollateralToken lien = LienCollateralToken(factory.create(LIEN_ID));

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, controller, 1e18, 1e18 + 1)
        );
        lien.burn(1e18 + 1);
    }

    // ---- Transferability ----
    function test_Transferable() public {
        vm.prank(controller);
        LienCollateralToken lien = LienCollateralToken(factory.create(LIEN_ID));

        vm.prank(controller);
        lien.transfer(recipient, 1e18);

        assertEq(lien.balanceOf(controller), 0, "controller balance moved out");
        assertEq(lien.balanceOf(recipient), 1e18, "recipient received");
    }

    // ---- Event ----
    function test_LienCreatedEvent() public {
        address predicted = factory.computeAddress(LIEN_ID, controller);

        vm.expectEmit(true, true, false, false, address(factory));
        emit LienCreated(LIEN_ID, predicted);

        vm.prank(controller);
        address lien = factory.create(LIEN_ID);
        assertEq(lien, predicted, "emitted lien == returned address");
    }

    // ---- Decimals pin ----
    function test_DecimalsPin() public view {
        assertEq(factory.LIEN_DECIMALS(), 18, "LIEN_DECIMALS");
    }
}
