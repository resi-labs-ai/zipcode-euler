// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "./ForkConfig.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {SummonSubstrate} from "../script/SummonSubstrate.s.sol";
import {ISafe} from "../src/interfaces/safe/ISafe.sol";
import {IBaal} from "../src/interfaces/baal/IBaal.sol";

import {ReservoirLoopModule} from "../src/supply/szipUSD/ReservoirLoopModule.sol";
import {SzipReservoirLpOracle} from "../src/supply/SzipReservoirLpOracle.sol";
import {ReservoirBorrowGuard} from "../src/supply/szipUSD/ReservoirBorrowGuard.sol";
import {ReservoirMarketDeployer} from "../script/ReservoirMarketDeployer.sol";

import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";
import {IEVault, IBorrowing} from "evk/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors as PriceErrors} from "euler-price-oracle/lib/Errors.sol";
import {Errors as EvkErrors} from "evk/EVault/shared/Errors.sol";

// =========================================================================== mocks

/// @notice A recording mock Safe: implements the Zodiac avatar surface (`execTransactionFromModule`), records every
///         `(to, value, data, operation)`, and (when `live`) actually performs the call. Can be forced to fail a
///         specific exec index (atomicity test). Modeled verbatim on `SzipBuyBurnModule.t.sol`.
contract RecordingSafe {
    struct Recorded {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
    }

    Recorded[] public calls;
    bool public live;
    uint256 public failOnCallIndex = type(uint256).max;

    function setLive(bool v) external {
        live = v;
    }

    function setFailOnCallIndex(uint256 i) external {
        failOnCallIndex = i;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function getCall(uint256 i) external view returns (address to, uint256 value, bytes memory data, uint8 operation) {
        Recorded storage r = calls[i];
        return (r.to, r.value, r.data, r.operation);
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool)
    {
        (bool ok,) = _record(to, value, data, operation);
        return ok;
    }

    /// @notice The module drives the Safe via `execTransactionFromModuleReturnData` (so a failed inner call surfaces
    ///         as `(false, revertData)` — modeling the real Gnosis Safe, which catches inner reverts and returns false
    ///         rather than bubbling).
    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool, bytes memory)
    {
        return _record(to, value, data, operation);
    }

    function _record(address to, uint256 value, bytes calldata data, uint8 operation)
        internal
        returns (bool ok, bytes memory ret)
    {
        if (calls.length == failOnCallIndex) revert("forced-fail");
        calls.push(Recorded({to: to, value: value, data: data, operation: operation}));
        if (live) {
            (ok, ret) = to.call{value: value}(data);
            // Model the real Safe: catch the inner revert and RETURN (false, revertData), do NOT bubble.
            return (ok, ret);
        }
        return (true, "");
    }

    receive() external payable {}
}

/// @notice A minimal 18-dp ERC20 stand-in for the ICHI LP share (8-B6 mints the real one; the §4.5.1 stand-in posture).
contract MockLpToken {
    string public constant name = "Mock ICHI LP";
    string public constant symbol = "mLP";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice A zero-rate IRM (IIRM face) — model `EulerVenueAdapter.t.sol`.
contract ZeroIRM {
    function computeInterestRate(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function computeInterestRateView(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice A deployer harness that deliberately mis-wires the wire-check against the WRONG LP token, so the (W3)
///         WireMismatch invariant is reachable — model `MisWiringAdapter`.
contract MisWiringDeployer is ReservoirMarketDeployer {
    address public immutable wrongLpToken;

    constructor(address wrongLpToken_) {
        wrongLpToken = wrongLpToken_;
    }

    function _assertWired(address router, address escrowVault, address, address usdc, address lpOracle)
        internal
        view
        override
    {
        // Feed the WRONG expected lpToken -> the real resolve (correct lpToken) must trip WireMismatch.
        super._assertWired(router, escrowVault, wrongLpToken, usdc, lpOracle);
    }
}

// =========================================================================== tests

/// @notice 8-B5 reservoir strike-financing loop. Unit (recording mock Safe — exec-shape/authority/atomicity) + fork
///         (live Base EVK/EVC/EulerRouter, real summoned substrate Safe — the post→borrow→repay→withdraw loop) +
///         LP-oracle + guard + deployer.
contract ReservoirLoopModuleTest is ForkConfig, SummonSubstrate {
    // -- live Base --
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6-dp
    address internal constant FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    // -- actors --
    address internal owner = makeAddr("timelockOwner");
    address internal operator = makeAddr("creOperator");
    address internal rando = makeAddr("rando");
    address internal team = makeAddr("teamMultisig");
    address internal supplier = makeAddr("usdcSupplier");

    uint256 internal constant BORROW_CAP = 1_000_000e6; // 1,000,000 USDC aggregate cap
    uint256 internal constant VALIDITY = 1 days; // generous engine-cadence window
    uint256 internal constant SALT = uint256(keccak256("zipcode.reservoir.8b5.salt.a"));

    // -- common deploys --
    GenericFactory internal factory;
    IEVC internal evc;
    ZeroIRM internal irm;
    MockLpToken internal lp;

    function setUp() public {
        _selectBaseFork();
        factory = GenericFactory(BaseAddresses.EVAULT_FACTORY);
        evc = IEVC(BaseAddresses.EVC);
        irm = new ZeroIRM();
        lp = new MockLpToken();
    }

    // ----------------------------------------------------------------- helpers
    /// @dev Deploy + setUp a module over an arbitrary engine Safe + market (recording-mock unit context).
    function _deployModule(
        address engineSafe_,
        address borrowVault_,
        address escrowVault_,
        uint256 cap_
    ) internal returns (ReservoirLoopModule m) {
        m = new ReservoirLoopModule();
        m.setUp(
            abi.encode(
                owner, engineSafe_, operator, address(evc), borrowVault_, escrowVault_, address(lp), USDC, cap_
            )
        );
    }

    /// @dev Deploy a fresh LP oracle (renounced, as production) wired to `lpToken_`.
    function _deployOracle(address lpToken_) internal returns (SzipReservoirLpOracle o) {
        o = new SzipReservoirLpOracle(FORWARDER, USDC, VALIDITY, lpToken_);
        o.renounceOwnership();
    }

    /// @dev Push an LP mark via the CRE Forwarder (the only writer).
    function _pushMark(SzipReservoirLpOracle o, uint256 mark) internal {
        bytes memory report = abi.encode(o.LP_MARK(), abi.encode(mark, uint32(block.timestamp)));
        vm.prank(FORWARDER);
        o.onReport("", report);
    }

    /// @dev Stand up the reservoir market through the deployer for `engineSafe_`/`oracle`.
    function _deployMarket(address engineSafe_, address oracle_, uint16 borrowLTV, uint16 liqLTV)
        internal
        returns (address escrowVault, address borrowVault, address router)
    {
        ReservoirMarketDeployer dep = new ReservoirMarketDeployer();
        (escrowVault, borrowVault, router) = dep.deploy(
            ReservoirMarketDeployer.Params({
                factory: factory,
                evc: address(evc),
                governor: owner,
                lpToken: address(lp),
                usdc: USDC,
                lpOracle: oracle_,
                irm: address(irm),
                engineSafe: engineSafe_,
                borrowLTV: borrowLTV,
                liqLTV: liqLTV
            })
        );
    }

    /// @dev Seed the borrow vault with USDC liquidity (a supplier deposit) so borrows have cash.
    function _seedBorrowVault(address borrowVault, uint256 amount) internal {
        deal(USDC, supplier, amount);
        vm.startPrank(supplier);
        IERC20(USDC).approve(borrowVault, amount);
        IEVault(borrowVault).deposit(amount, supplier);
        vm.stopPrank();
    }

    /// @dev Summon a real substrate + enable the module on its main Safe (team-owner drives the enable).
    function _summonAndEnable(ReservoirLoopModule m) internal returns (address mainSafe) {
        vm.startPrank(team);
        Substrate memory s = _summon(team, SALT);
        vm.stopPrank();
        mainSafe = s.mainSafe;
        bytes memory enableMod = abi.encodeWithSelector(ISafe.enableModule.selector, address(m));
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(team))), bytes32(0), uint8(1));
        vm.prank(team);
        ISafe(mainSafe).execTransaction(mainSafe, 0, enableMod, 0, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    // =================================================================== setUp / authority / locks (unit)

    function test_setUp_wires_storage() public {
        ReservoirLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        assertEq(m.owner(), owner);
        assertEq(m.operator(), operator);
        assertEq(m.engineSafe(), address(0xBEEF));
        assertEq(m.avatar(), address(0xBEEF));
        assertEq(m.target(), address(0xBEEF));
        assertEq(m.evc(), address(evc));
        assertEq(m.borrowVault(), address(0xB));
        assertEq(m.escrowVault(), address(0xE));
        assertEq(m.lpToken(), address(lp));
        assertEq(m.usdc(), USDC);
        assertEq(m.borrowCap(), BORROW_CAP);
    }

    function test_setUp_initializer_once() public {
        ReservoirLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        vm.expectRevert();
        m.setUp(
            abi.encode(owner, address(0xBEEF), operator, address(evc), address(0xB), address(0xE), address(lp), USDC, BORROW_CAP)
        );
    }

    function test_setUp_rejects_owner_equals_operator() public {
        ReservoirLoopModule m = new ReservoirLoopModule();
        vm.expectRevert(ReservoirLoopModule.OwnerIsOperator.selector);
        m.setUp(abi.encode(owner, address(0xBEEF), owner, address(evc), address(0xB), address(0xE), address(lp), USDC, BORROW_CAP));
    }

    function test_setUp_rejects_zero_address_evc() public {
        ReservoirLoopModule m = new ReservoirLoopModule();
        vm.expectRevert(ReservoirLoopModule.ZeroAddress.selector);
        m.setUp(abi.encode(owner, address(0xBEEF), operator, address(0), address(0xB), address(0xE), address(lp), USDC, BORROW_CAP));
    }

    function test_setUp_rejects_zero_address_engineSafe() public {
        ReservoirLoopModule m = new ReservoirLoopModule();
        vm.expectRevert(ReservoirLoopModule.ZeroAddress.selector);
        m.setUp(abi.encode(owner, address(0), operator, address(evc), address(0xB), address(0xE), address(lp), USDC, BORROW_CAP));
    }

    function test_operator_cannot_redirect_safe() public {
        ReservoirLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        m.setAvatar(rando);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        m.setTarget(rando);
    }

    function test_mastercopy_inert() public {
        ReservoirLoopModule mc = new ReservoirLoopModule();
        assertEq(mc.operator(), address(0));
        assertEq(mc.engineSafe(), address(0));
        vm.prank(operator);
        vm.expectRevert(ReservoirLoopModule.NotOperator.selector);
        mc.postCollateral(1e18);
        vm.prank(operator);
        vm.expectRevert(ReservoirLoopModule.NotOperator.selector);
        mc.borrow(1e6);
        vm.prank(operator);
        vm.expectRevert(ReservoirLoopModule.NotOperator.selector);
        mc.repay(1e6);
        vm.prank(operator);
        vm.expectRevert(ReservoirLoopModule.NotOperator.selector);
        mc.withdrawCollateral(1e18);
    }

    function test_entrypoints_only_operator() public {
        ReservoirLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        vm.startPrank(rando);
        vm.expectRevert(ReservoirLoopModule.NotOperator.selector);
        m.postCollateral(1e18);
        vm.expectRevert(ReservoirLoopModule.NotOperator.selector);
        m.borrow(1e6);
        vm.expectRevert(ReservoirLoopModule.NotOperator.selector);
        m.repay(1e6);
        vm.expectRevert(ReservoirLoopModule.NotOperator.selector);
        m.withdrawCollateral(1e18);
        vm.stopPrank();
    }

    function test_setBorrowCap_only_owner() public {
        ReservoirLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        vm.prank(rando);
        vm.expectRevert();
        m.setBorrowCap(123);
        vm.prank(operator);
        vm.expectRevert();
        m.setBorrowCap(123);
        vm.prank(owner);
        m.setBorrowCap(456e6);
        assertEq(m.borrowCap(), 456e6);
    }

    function test_zero_amount_reverts() public {
        ReservoirLoopModule m = _deployModule(address(0xBEEF), address(0xB), address(0xE), BORROW_CAP);
        vm.startPrank(operator);
        vm.expectRevert(ReservoirLoopModule.ZeroAmount.selector);
        m.postCollateral(0);
        vm.expectRevert(ReservoirLoopModule.ZeroAmount.selector);
        m.borrow(0);
        vm.expectRevert(ReservoirLoopModule.ZeroAmount.selector);
        m.repay(0);
        vm.expectRevert(ReservoirLoopModule.ZeroAmount.selector);
        m.withdrawCollateral(0);
        vm.stopPrank();
    }

    // =================================================================== exec discipline (recording mock)

    /// @dev THE security-boundary test (exhaustive): exact callCount per entrypoint, every call Operation.Call +
    ///      value==0 targeting only the wired addresses, and the inner IEVC.call calldata decoded to prove the
    ///      onBehalfOfAccount + innermost receiver/owner == engineSafe.
    function test_exec_discipline_full() public {
        RecordingSafe safe = new RecordingSafe();
        address bv = address(0xB0B0);
        address ev = address(0xE5C0);
        ReservoirLoopModule m = _deployModule(address(safe), bv, ev, BORROW_CAP);
        address es = address(safe);

        // ---- postCollateral: exactly 3 ----
        vm.prank(operator);
        m.postCollateral(50e18);
        assertEq(safe.callCount(), 3);
        _assertCall(safe, 0, address(lp), abi.encodeWithSelector(IERC20.approve.selector, ev, uint256(50e18)));
        _assertCall(safe, 1, address(evc), abi.encodeCall(IEVC.enableCollateral, (es, ev)));
        _assertCall(safe, 2, ev, abi.encodeWithSelector(_depositSelector(), uint256(50e18), es));

        // ---- borrow: exactly 2 more (cap not exceeded; debtOf is a view on a non-vault stub -> stub returns 0) ----
        // bv is a bare address with no code -> debtOf staticcall returns empty; use a debt-stub instead.
        // Re-deploy with a DebtStub borrow vault so debtOf() == 0 succeeds in the cap check.
        DebtStub stub = new DebtStub();
        RecordingSafe safe2 = new RecordingSafe();
        ReservoirLoopModule m2 = _deployModule(address(safe2), address(stub), ev, BORROW_CAP);
        address es2 = address(safe2);

        vm.prank(operator);
        m2.borrow(79e6);
        assertEq(safe2.callCount(), 2);
        _assertCall(safe2, 0, address(evc), abi.encodeCall(IEVC.enableController, (es2, address(stub))));
        // call 1: EVC.call(borrowVault, engineSafe, 0, borrow(79e6, engineSafe))
        _assertEvcCall(safe2, 1, address(stub), es2, abi.encodeCall(IBorrowing.borrow, (uint256(79e6), es2)));

        // ---- repay: exactly 3 ----
        RecordingSafe safe3 = new RecordingSafe();
        ReservoirLoopModule m3 = _deployModule(address(safe3), address(stub), ev, BORROW_CAP);
        address es3 = address(safe3);
        vm.prank(operator);
        m3.repay(40e6);
        assertEq(safe3.callCount(), 3);
        _assertCall(safe3, 0, USDC, abi.encodeWithSelector(IERC20.approve.selector, address(stub), uint256(40e6)));
        _assertEvcCall(safe3, 1, address(stub), es3, abi.encodeCall(IBorrowing.repay, (uint256(40e6), es3)));
        _assertCall(safe3, 2, USDC, abi.encodeWithSelector(IERC20.approve.selector, address(stub), uint256(0)));

        // ---- withdrawCollateral: exactly 1 (after debtOf view == 0) ----
        RecordingSafe safe4 = new RecordingSafe();
        ReservoirLoopModule m4 = _deployModule(address(safe4), address(stub), ev, BORROW_CAP);
        address es4 = address(safe4);
        vm.prank(operator);
        m4.withdrawCollateral(30e18);
        assertEq(safe4.callCount(), 1);
        _assertEvcCall(safe4, 0, ev, es4, abi.encodeWithSelector(_withdrawSelector(), uint256(30e18), es4, es4));
    }

    function _assertCall(RecordingSafe safe, uint256 i, address expTo, bytes memory expData) internal view {
        (address to, uint256 value, bytes memory data, uint8 op) = safe.getCall(i);
        assertEq(to, expTo, "wrong target");
        assertEq(value, 0, "value must be 0");
        assertEq(op, 0, "must be Operation.Call");
        assertEq(keccak256(data), keccak256(expData), "wrong calldata");
    }

    /// @dev Decode the outer EVC.call and assert target/onBehalf/value + the innermost calldata.
    function _assertEvcCall(RecordingSafe safe, uint256 i, address expTarget, address expOnBehalf, bytes memory expInner)
        internal
        view
    {
        (address to, uint256 value, bytes memory data, uint8 op) = safe.getCall(i);
        assertEq(to, address(evc), "outer to must be EVC");
        assertEq(value, 0, "outer value 0");
        assertEq(op, 0, "Operation.Call");
        // strip the 4-byte EVC.call selector, decode (address,address,uint256,bytes)
        bytes memory args = _slice(data, 4);
        (address target, address onBehalf, uint256 innerValue, bytes memory inner) =
            abi.decode(args, (address, address, uint256, bytes));
        assertEq(target, expTarget, "EVC.call target");
        assertEq(onBehalf, expOnBehalf, "EVC.call onBehalfOfAccount == engineSafe");
        assertEq(innerValue, 0, "inner value 0");
        assertEq(keccak256(inner), keccak256(expInner), "innermost calldata (receiver/owner == engineSafe)");
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[from + i];
        }
    }

    function _depositSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("deposit(uint256,address)"));
    }

    function _withdrawSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("withdraw(uint256,address,address)"));
    }

    // =================================================================== atomicity (recording mock, live)

    function test_atomicity_postCollateral_deposit_revert_rolls_back() public {
        // live safe so approve really lands on the real LP; force the 3rd exec (deposit, index 2) to fail.
        RecordingSafe safe = new RecordingSafe();
        safe.setLive(true);
        safe.setFailOnCallIndex(2);
        // a real escrow-ish target is not needed; deposit goes to `ev` which has no code -> live call would fail
        // anyway, but the FORCED fail at index 2 happens BEFORE the deposit is recorded, so approve+enableCollateral
        // (indices 0,1) ran live. enableCollateral on the real EVC for a code-less account is a no-op success.
        address ev = address(0xE5C0);
        ReservoirLoopModule m = _deployModule(address(safe), address(new DebtStub()), ev, BORROW_CAP);

        vm.prank(operator);
        vm.expectRevert();
        m.postCollateral(10e18);

        // the whole tx reverted -> no standing LP allowance, no dangling collateral-enable.
        assertEq(lp.allowance(address(safe), ev), 0, "approve rolled back");
        address[] memory cols = evc.getCollaterals(address(safe));
        assertEq(cols.length, 0, "enableCollateral rolled back");
    }

    function test_atomicity_repay_call_revert_rolls_back() public {
        RecordingSafe safe = new RecordingSafe();
        safe.setLive(true);
        safe.setFailOnCallIndex(1); // fail on the EVC.call(repay)
        DebtStub stub = new DebtStub();
        ReservoirLoopModule m = _deployModule(address(safe), address(stub), address(0xE5C0), BORROW_CAP);

        vm.prank(operator);
        vm.expectRevert();
        m.repay(40e6);

        // approve rolled back with the tx.
        assertEq(IERC20(USDC).allowance(address(safe), address(stub)), 0, "approve rolled back");
    }

    // =================================================================== LP oracle (unit)

    function test_oracle_push_and_quote_roundtrip() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        _pushMark(o, 1e6); // $1.00 per 1e18 LP share
        assertEq(o.getQuote(1e18, address(lp), USDC), 1e6, "full share == $1");
        assertEq(o.getQuote(5e17, address(lp), USDC), 5e5, "half share == $0.50");
    }

    function test_oracle_non_divisible_floors_against_borrower() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        // mark = 3 (6-dp); inAmount = 1 wei LP share -> 1 * 1e6 * 3 / 1e24 floors to 0 (against the borrower).
        _pushMark(o, 3);
        assertEq(o.getQuote(1, address(lp), USDC), 0, "floors against borrower");
        // a mark*inAmount not divisible by feedScale -> floor. mark=1e6, inAmount=333333333333333333 (1/3 share).
        _pushMark(o, 1e6);
        uint256 inAmt = 333_333_333_333_333_333;
        assertEq(o.getQuote(inAmt, address(lp), USDC), inAmt / 1e12, "floor of 1/3 share value");
        assertTrue((inAmt * 1e6) % 1e24 != 0, "must be non-divisible");
    }

    function test_oracle_only_forwarder_can_push() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        bytes memory report = abi.encode(o.LP_MARK(), abi.encode(uint256(1e6), uint32(block.timestamp)));
        vm.prank(rando);
        vm.expectRevert();
        o.onReport("", report);
    }

    function test_oracle_wrong_reportType_reverts() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        bytes memory report = abi.encode(uint8(3), abi.encode(uint256(1e6), uint32(block.timestamp)));
        vm.prank(FORWARDER);
        vm.expectRevert(abi.encodeWithSelector(SzipReservoirLpOracle.InvalidReportType.selector, uint8(3)));
        o.onReport("", report);
    }

    function test_oracle_base_or_quote_mismatch_reverts() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        _pushMark(o, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_NotSupported.selector, address(0xAAAA), USDC));
        o.getQuote(1e18, address(0xAAAA), USDC); // base != lpToken
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_NotSupported.selector, address(lp), address(0xBBBB)));
        o.getQuote(1e18, address(lp), address(0xBBBB)); // quote != USDC
    }

    function test_oracle_failclosed_zero_mark_and_future_ts() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        bytes memory zeroMark = abi.encode(o.LP_MARK(), abi.encode(uint256(0), uint32(block.timestamp)));
        vm.prank(FORWARDER);
        vm.expectRevert(PriceErrors.PriceOracle_InvalidAnswer.selector);
        o.onReport("", zeroMark);

        bytes memory futureTs = abi.encode(o.LP_MARK(), abi.encode(uint256(1e6), uint32(block.timestamp + 1)));
        vm.prank(FORWARDER);
        vm.expectRevert(SzipReservoirLpOracle.FutureTimestamp.selector);
        o.onReport("", futureTs);
    }

    function test_oracle_never_pushed_reverts_notsupported() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_NotSupported.selector, address(lp), USDC));
        o.getQuote(1e18, address(lp), USDC);
    }

    function test_oracle_stale_reverts_toostale() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        _pushMark(o, 1e6);
        vm.warp(block.timestamp + VALIDITY + 1);
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_TooStale.selector, VALIDITY + 1, VALIDITY));
        o.getQuote(1e18, address(lp), USDC);
    }

    function test_oracle_lp_mark_is_not_three() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        assertEq(o.LP_MARK(), 7);
        assertTrue(o.LP_MARK() != 3, "LP_MARK must not be the registry REVALUATION=3");
    }

    // =================================================================== guard (unit + fork-ish)

    function test_guard_isHookTarget_only_for_factory_proxy() public {
        ReservoirBorrowGuard g = new ReservoirBorrowGuard(address(factory), address(0xBEEF));
        // a non-proxy caller (this test) -> 0
        assertEq(g.isHookTarget(), bytes4(0));
        // a real factory proxy caller -> the magic selector
        address proxy = factory.createProxy(address(0), false, abi.encodePacked(USDC, address(0), address(0)));
        vm.prank(proxy);
        assertEq(g.isHookTarget(), g.isHookTarget.selector);
    }

    // =================================================================== deployer wiring (fork)

    function test_deployer_governor_RETAINED() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        _pushMark(o, 1e6); // the deployer's setLTV reads getQuote
        (address ev, address bv, address router) = _deployMarket(address(0xBEEF), address(o), 0.7e4, 0.8e4);

        // The §4.5.1 inversion of WOOF-04: the router governor is RETAINED (NOT address(0)).
        assertEq(EulerRouter(router).governor(), owner, "router governor RETAINED at the Timelock");
        assertTrue(EulerRouter(router).governor() != address(0), "router NOT frozen");

        // escrow is a bare 1:1 holding box, governance renounced.
        assertEq(IEVault(ev).convertToAssets(1e18), 1e18, "escrow 1:1 shares<->assets");
        assertEq(IEVault(ev).governorAdmin(), address(0), "escrow governance renounced");

        // borrow vault oracle == the router; guard installed at OP_BORROW.
        assertEq(IEVault(bv).oracle(), router, "borrow vault oracle == router");
        (address hookTarget, uint32 hookedOps) = IEVault(bv).hookConfig();
        assertEq(hookedOps, uint32(1 << 6), "OP_BORROW only");
        assertEq(ReservoirBorrowGuard(hookTarget).engineSafe(), address(0xBEEF), "guard pins the engine Safe");

        // The retained governor can still re-point the router (re-pointable).
        SzipReservoirLpOracle o2 = _deployOracle(address(lp));
        vm.prank(owner);
        EulerRouter(router).govSetConfig(address(lp), USDC, address(o2));
    }

    function test_deployer_wiremismatch_reachable() public {
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        _pushMark(o, 1e6); // the deployer's setLTV reads getQuote (runs before the wire-check)
        MockLpToken wrongLp = new MockLpToken();
        MisWiringDeployer dep = new MisWiringDeployer(address(wrongLp));
        vm.expectRevert(ReservoirMarketDeployer.WireMismatch.selector);
        dep.deploy(
            ReservoirMarketDeployer.Params({
                factory: factory,
                evc: address(evc),
                governor: owner,
                lpToken: address(lp),
                usdc: USDC,
                lpOracle: address(o),
                irm: address(irm),
                engineSafe: address(0xBEEF),
                borrowLTV: 0.7e4,
                liqLTV: 0.8e4
            })
        );
    }

    // =================================================================== the full loop (fork, headline)

    function test_full_loop_revolves_twice() public {
        ReservoirLoopModule m = new ReservoirLoopModule();
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        address engineSafe = _summonAndEnable(m);

        // push a fresh LP mark ($1/share) before the deployer's setLTV (which reads getQuote).
        _pushMark(o, 1e6);
        (address ev, address bv, address router) = _deployMarket(engineSafe, address(o), 0.7e4, 0.8e4);
        m.setUp(abi.encode(owner, engineSafe, operator, address(evc), bv, ev, address(lp), USDC, BORROW_CAP));
        router; // silence

        // seed the borrow vault with USDC; deal LP to the Safe.
        _seedBorrowVault(bv, 500_000e6);
        lp.mint(engineSafe, 1000e18);

        uint256 slice = 100e18; // $100 collateral
        uint256 strike = 50e6; // $50 borrow, well inside 0.7 * $100

        for (uint256 round = 0; round < 2; round++) {
            // post
            vm.prank(operator);
            m.postCollateral(slice);
            assertEq(m.postedCollateral(), slice, "posted == slice");
            assertEq(evc.getCollaterals(engineSafe).length, 1, "collateral enabled (no dup)");

            // borrow
            uint256 usdcBefore = IERC20(USDC).balanceOf(engineSafe);
            vm.prank(operator);
            m.borrow(strike);
            assertEq(IERC20(USDC).balanceOf(engineSafe) - usdcBefore, strike, "Safe received strike");
            assertEq(m.outstandingDebt(), strike, "outstandingDebt == strike");
            assertEq(m.outstandingDebt(), IBorrowing(bv).debtOf(engineSafe), "view reads the vault live");
            assertEq(evc.getControllers(engineSafe).length, 1, "controller enabled (no dup)");

            // repay (give the Safe the USDC to repay — in production from 8-B9 sale proceeds)
            deal(USDC, engineSafe, strike);
            vm.prank(operator);
            m.repay(strike);
            assertEq(m.outstandingDebt(), 0, "debt cleared");
            assertEq(IERC20(USDC).allowance(engineSafe, bv), 0, "no standing approval");

            // withdraw
            vm.prank(operator);
            m.withdrawCollateral(slice);
            assertEq(m.postedCollateral(), 0, "collateral withdrawn");
            assertEq(lp.balanceOf(engineSafe), 1000e18, "LP back to the Safe");
        }

        // after 2 loops: no duplicate enables.
        assertEq(evc.getCollaterals(engineSafe).length, 1, "no dup collateral after revolve");
        assertEq(evc.getControllers(engineSafe).length, 1, "controller stays enabled, no dup");
    }

    // =================================================================== over-LTV / cap / stale / guard (fork)

    function test_over_LTV_reverts_AccountLiquidity() public {
        (ReservoirLoopModule m, address engineSafe, address ev, address bv) = _liveLoopSetup(0.7e4, 0.8e4, 1e6);

        // post $100 collateral.
        vm.prank(operator);
        m.postCollateral(100e18);

        // EVK gates NEW borrows against the BORROW LTV (0.7), not the liq LTV (0.8): max healthy borrow = $70.
        // A healthy borrow just under the boundary succeeds (proves enableController + the boundary): 69 < 70.
        vm.prank(operator);
        m.borrow(69e6);
        assertEq(m.outstandingDebt(), 69e6);

        // a further borrow taking the total over $70 (the borrow LTV) reverts E_AccountLiquidity.
        vm.prank(operator);
        vm.expectRevert(EvkErrors.E_AccountLiquidity.selector);
        m.borrow(5e6);
        ev;
        bv;
    }

    function test_no_collateral_borrow_reverts_AccountLiquidity() public {
        (ReservoirLoopModule m,,,) = _liveLoopSetup(0.7e4, 0.8e4, 1e6);
        vm.prank(operator);
        vm.expectRevert(EvkErrors.E_AccountLiquidity.selector);
        m.borrow(1e6);
    }

    function test_aggregate_cap_boundary_and_killswitch() public {
        // cap == strike exactly: borrow(cap) succeeds, +1 reverts CapExceeded.
        (ReservoirLoopModule m, address engineSafe,,) = _liveLoopSetup(0.7e4, 0.8e4, 1e6);
        engineSafe;
        // need cap small; redeploy module with cap = 60e6 against the same market.
        // (the _liveLoopSetup module has cap BORROW_CAP; just test boundary on a fresh small-cap module.)
        vm.prank(operator);
        m.postCollateral(100e18);

        // set a small cap via owner so debt(0)+cap succeeds and +1 fails. cap = 50e6.
        vm.prank(owner);
        m.setBorrowCap(50e6);
        vm.prank(operator);
        m.borrow(50e6); // exactly the cap, debt 0 -> 50 <= 50 OK and < liqLTV*$100
        assertEq(m.outstandingDebt(), 50e6);
        vm.prank(operator);
        vm.expectRevert(ReservoirLoopModule.CapExceeded.selector);
        m.borrow(1); // 50 + 1 > 50 cap

        // kill-switch: cap 0 -> every borrow reverts.
        vm.prank(owner);
        m.setBorrowCap(0);
        vm.prank(operator);
        vm.expectRevert(ReservoirLoopModule.CapExceeded.selector);
        m.borrow(1);
    }

    function test_stale_and_never_pushed_mark_fail_borrow_closed() public {
        // Stand up with a live mark (the deployer's setLTV needs one); then test the two fail-closed borrow paths.
        ReservoirLoopModule m = new ReservoirLoopModule();
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        address engineSafe = _summonAndEnable(m);
        _pushMark(o, 1e6);
        (address ev, address bv, address router) = _deployMarket(engineSafe, address(o), 0.7e4, 0.8e4);
        m.setUp(abi.encode(owner, engineSafe, operator, address(evc), bv, ev, address(lp), USDC, BORROW_CAP));
        _seedBorrowVault(bv, 500_000e6);
        lp.mint(engineSafe, 1000e18);

        vm.prank(operator);
        m.postCollateral(100e18);

        // (1) PATH A — STALE: warp past the validity window -> borrow reverts TooStale (bubbled from the router).
        vm.warp(block.timestamp + VALIDITY + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_TooStale.selector, VALIDITY + 1, VALIDITY));
        m.borrow(10e6);

        // (2) PATH B — NEVER-PUSHED: the (retained) governor re-points the router to a fresh, never-pushed oracle ->
        //     borrow reverts NotSupported (bubbled from the router; the cache timestamp == 0).
        SzipReservoirLpOracle bare = _deployOracle(address(lp));
        vm.prank(owner);
        EulerRouter(router).govSetConfig(address(lp), USDC, address(bare));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PriceErrors.PriceOracle_NotSupported.selector, address(lp), USDC));
        m.borrow(10e6);
    }

    function test_withdraw_with_debt_reverts() public {
        (ReservoirLoopModule m,,,) = _liveLoopSetup(0.7e4, 0.8e4, 1e6);
        vm.prank(operator);
        m.postCollateral(100e18);
        vm.prank(operator);
        m.borrow(10e6);
        vm.prank(operator);
        vm.expectRevert(ReservoirLoopModule.DebtOutstanding.selector);
        m.withdrawCollateral(50e18);
    }

    function test_exact_repay_clears_debt_and_resets_allowance_overrepay_reverts() public {
        // NOTE (ticket factual correction): EVK `repay(amount, receiver)` does NOT cap a literal `amount` at the
        // outstanding debt — a literal over-amount reverts `E_RepayTooMuch` (only `type(uint256).max` means "all").
        // So the loop repays the EXACT debt: an exact repay clears it + resets the residual approval; an over-repay
        // reverts (the operator never over-pays — it repays the strike it borrowed). See the build report.
        (ReservoirLoopModule m, address engineSafe, , address bv) = _liveLoopSetup(0.7e4, 0.8e4, 1e6);
        vm.prank(operator);
        m.postCollateral(100e18);
        vm.prank(operator);
        m.borrow(40e6);

        // an over-repay (> outstanding debt) reverts E_RepayTooMuch (EVK does not cap a literal amount).
        deal(USDC, engineSafe, 100e6);
        vm.prank(operator);
        vm.expectRevert(EvkErrors.E_RepayTooMuch.selector);
        m.repay(60e6);
        assertEq(m.outstandingDebt(), 40e6, "over-repay reverted, debt unchanged");

        // an EXACT repay clears the debt and resets the residual approval to 0 (security F13).
        uint256 before = IERC20(USDC).balanceOf(engineSafe);
        vm.prank(operator);
        m.repay(40e6);
        assertEq(m.outstandingDebt(), 0, "debt cleared");
        assertEq(before - IERC20(USDC).balanceOf(engineSafe), 40e6, "exactly the debt debited");
        assertEq(IERC20(USDC).allowance(engineSafe, bv), 0, "allowance reset to 0");
    }

    function test_third_party_borrow_blocked_by_guard() public {
        // The engine Safe's loop passes the guard; a third party that posts the escrow on its OWN account is blocked.
        ReservoirLoopModule m = new ReservoirLoopModule();
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        address engineSafe = _summonAndEnable(m);
        _pushMark(o, 1e6);
        (address ev, address bv,) = _deployMarket(engineSafe, address(o), 0.7e4, 0.8e4);
        m.setUp(abi.encode(owner, engineSafe, operator, address(evc), bv, ev, address(lp), USDC, BORROW_CAP));
        _seedBorrowVault(bv, 500_000e6);
        lp.mint(engineSafe, 1000e18);

        // engine Safe loop borrows fine (passes the guard).
        vm.prank(operator);
        m.postCollateral(100e18);
        vm.prank(operator);
        m.borrow(10e6);
        assertEq(m.outstandingDebt(), 10e6, "engine borrow passes the guard");

        // third party: holds LP, deposits into the SAME escrow on its OWN account, enables, attempts a direct borrow.
        address thirdParty = makeAddr("thirdPartyLeverager");
        lp.mint(thirdParty, 200e18);
        vm.startPrank(thirdParty);
        lp.approve(ev, 200e18);
        IEVault(ev).deposit(200e18, thirdParty);
        evc.enableCollateral(thirdParty, ev);
        evc.enableController(thirdParty, bv);
        // direct borrow via EVC.call on its own account -> the guard rejects (NotEngineSafe).
        vm.expectRevert();
        evc.call(bv, thirdParty, 0, abi.encodeCall(IBorrowing.borrow, (1e6, thirdParty)));
        vm.stopPrank();
    }

    /// @dev Shared live-loop setup: summon Safe, enable module, stand up market, seed USDC, push mark, mint LP.
    function _liveLoopSetup(uint16 borrowLTV, uint16 liqLTV, uint256 mark)
        internal
        returns (ReservoirLoopModule m, address engineSafe, address ev, address bv)
    {
        m = new ReservoirLoopModule();
        SzipReservoirLpOracle o = _deployOracle(address(lp));
        engineSafe = _summonAndEnable(m);
        // The mark must exist before the deployer's `setLTV` (which reads `getQuote` to validate the collateral
        // price at config time) — in production CRE pushes the mark at/before deploy.
        _pushMark(o, mark);
        address router;
        (ev, bv, router) = _deployMarket(engineSafe, address(o), borrowLTV, liqLTV);
        router;
        m.setUp(abi.encode(owner, engineSafe, operator, address(evc), bv, ev, address(lp), USDC, BORROW_CAP));
        _seedBorrowVault(bv, 500_000e6);
        lp.mint(engineSafe, 1000e18);
    }
}

/// @notice A minimal borrow-vault stub for the unit exec-discipline + atomicity tests: `debtOf` returns 0 so the cap
///         check passes; everything else is irrelevant (the recording Safe records, it does not execute on it).
contract DebtStub {
    function debtOf(address) external pure returns (uint256) {
        return 0;
    }
}
