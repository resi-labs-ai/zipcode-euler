// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {ForkConfig} from "./ForkConfig.sol";
import {AlgebraIchiFairLpOracle} from "../src/supply/AlgebraIchiFairLpOracle.sol";
import {IchiAlgebraFairReserves} from "../src/supply/lib/IchiAlgebraFairReserves.sol";
import {IICHIVault} from "../src/interfaces/ichi/IICHIVault.sol";
import {IAlgebraPool} from "../src/interfaces/algebra/IAlgebraPool.sol";
import {TickMath} from "../src/libraries/ConcentratedLiquidity.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EulerRouter} from "euler-price-oracle/EulerRouter.sol";
import {BaseAddresses} from "../script/BaseAddresses.sol";
import {ReservoirMarketDeployer} from "../script/ReservoirMarketDeployer.sol";
import {GenericFactory} from "evk/GenericFactory/GenericFactory.sol";

/// @notice A zero-rate IRM (EVK `IIRM` face) for the reservoir-market deploy-path test.
contract ZeroIRM {
    function computeInterestRate(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function computeInterestRateView(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Base-fork verification of the trustless fair-value ICHI-on-Algebra LP oracle against the LIVE
///         HYDX/USDC vault. Three properties:
///           1. fair reconstruction ≈ `getTotalAmounts()` while the pool is calm (the TWAP recon is faithful);
///           2. the dollar valuation is sane (TVL hundreds-of-k, majority USDC; the holder cross-check that
///              debank confirms — m4ngos.base.eth);
///           3. MANIPULATION INVARIANCE — a large in-block swap moves `getTotalAmounts()` (the spot split the old
///              `_lpValue` trusted) materially, while the oracle's fair quote barely moves. This is the property
///              the whole exercise exists to prove.
/// Requires BASE_RPC_URL (auto-loaded from contracts/.env); pinned to ForkConfig.BASE_FORK_BLOCK for determinism.
contract AlgebraIchiFairLpOracleForkTest is ForkConfig {
    address internal constant VAULT = 0xfF8B29e9f536F9A43DA7868011b7B667fa8d73f7; // HYDX/USDC ICHI (single-sided USDC)
    address internal constant HOLDER = 0x5F4797488B3542A76813D9dEEd57bC7d33De54D6; // m4ngos.base.eth
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant HYDX = 0x00000e7efa313F4E11Bfff432471eD9423AC6B30;
    uint32 internal constant WINDOW = 3600; // 1h

    AlgebraIchiFairLpOracle internal oracle;
    address internal pool;

    function setUp() public {
        _selectBaseFork();
        oracle = new AlgebraIchiFairLpOracle(VAULT, WINDOW);
        pool = IICHIVault(VAULT).pool();
    }

    // ----------------------------------------------------------------- 1. recon ≈ spot when calm
    function test_fork_fairReserves_match_getTotalAmounts_when_calm() public view {
        (uint256 f0, uint256 f1,) = IchiAlgebraFairReserves.fairReserves(VAULT, WINDOW);
        (uint256 s0, uint256 s1) = IICHIVault(VAULT).getTotalAmounts();
        // TWAP tick ≈ current tick on a calm pool ⇒ reconstruction reproduces the live reserves (within ~1%).
        assertApproxEqRel(f0, s0, 0.01e18, "fair token0 ~ spot");
        assertApproxEqRel(f1, s1, 0.01e18, "fair token1 ~ spot");
    }

    // ----------------------------------------------------------------- 2. dollar sanity + holder cross-check
    function test_fork_tvl_and_holder_value() public {
        (uint256 tvl, uint256 a0, uint256 a1, int24 tick) = oracle.fairTvl();
        emit log_named_decimal_uint("LP TVL (USDC)", tvl, 6);
        emit log_named_int("TWAP tick", tick);
        emit log_named_decimal_uint("USDC share %", a1 * 100e18 / tvl, 18);

        assertGt(tvl, 100_000e6, "TVL is hundreds of thousands USDC");
        assertLt(tvl, 5_000_000e6, "TVL upper sanity");
        assertGt(a1, tvl / 2, "majority USDC (single-sided USDC vault)"); // a1 valued at $1 dominates
        assertGt(a0, 0, "holds some HYDX");

        uint256 bal = IICHIVault(VAULT).balanceOf(HOLDER);
        uint256 holderUsdc = oracle.getQuote(bal, VAULT, USDC);
        emit log_named_decimal_uint("m4ngos holding (USDC)", holderUsdc, 6);
        // pro-rata identity: holder value / TVL == balance / supply.
        assertApproxEqRel(
            holderUsdc, tvl * bal / IICHIVault(VAULT).totalSupply(), 0.0001e18, "holder value is pro-rata of TVL"
        );
        assertGt(holderUsdc, 0, "holder has a positive valuation");
    }

    // ----------------------------------------------------------------- 3. manipulation invariance (the point)
    function test_fork_manipulation_invariance() public {
        uint256 oneShare = 1e18;
        uint256 fairBefore = oracle.getQuote(oneShare, VAULT, USDC);
        (uint256 s0Before, uint256 s1Before) = IICHIVault(VAULT).getTotalAmounts();

        // Push HYDX price UP with a large in-block USDC->HYDX swap (token1 -> token0 ⇒ zeroToOne = false).
        uint256 amountIn = 300_000e6; // 300k USDC — large vs the pool's HYDX side
        deal(USDC, address(this), amountIn);
        IAlgebraPool(pool).swap(
            address(this),
            false, // token1 (USDC) in, token0 (HYDX) out ⇒ price rises
            int256(amountIn),
            TickMath.MAX_SQRT_RATIO - 1, // limit: let price move up freely
            ""
        );

        // The manipulation moved the live (spot) reserve split materially...
        (uint256 s0After, uint256 s1After) = IICHIVault(VAULT).getTotalAmounts();
        assertGt(s1After, s1Before, "spot USDC reserve rose (swap landed)");
        assertLt(s0After, s0Before, "spot HYDX reserve fell");
        assertGt((s0Before - s0After) * 100 / s0Before, 2, "spot split shifted > 2% (manipulation is real)");

        // ...but the fair quote (TWAP-anchored) barely moved: the 1h mean tick has not absorbed the same-block tick.
        uint256 fairAfter = oracle.getQuote(oneShare, VAULT, USDC);
        emit log_named_decimal_uint("fair quote before", fairBefore, 6);
        emit log_named_decimal_uint("fair quote after ", fairAfter, 6);
        assertApproxEqRel(fairAfter, fairBefore, 0.01e18, "fair LP value invariant under in-block manipulation (<1%)");
    }

    // ----------------------------------------------------------------- 4. plugs into Euler as collateral
    /// @notice The LP token resolves as EVK collateral through a real `EulerRouter` configured with this oracle —
    ///         the trustless drop-in for `SzipReservoirLpOracle` on the reservoir borrow market. Proves the
    ///         router→lpToken→oracle resolution the `ReservoirMarketDeployer` wire-check depends on.
    function test_fork_resolves_through_euler_router() public {
        EulerRouter router = new EulerRouter(BaseAddresses.EVC, address(this)); // this = governor
        router.govSetConfig(VAULT, USDC, address(oracle)); // price (lpToken, USDC) via the fair oracle

        uint256 bal = IICHIVault(VAULT).balanceOf(HOLDER);
        uint256 viaRouter = router.getQuote(bal, VAULT, USDC);
        uint256 viaOracle = oracle.getQuote(bal, VAULT, USDC);
        assertEq(viaRouter, viaOracle, "router resolves LP collateral via the fair oracle");
        assertGt(viaRouter, 0, "non-zero collateral valuation");
    }

    // ----------------------------------------------------------------- 5. the deploy P5 fair-oracle path
    /// @notice Build the actual reservoir market (the same `ReservoirMarketDeployer` `DeployZipcode._phaseP5` runs)
    ///         with the fair oracle as the collateral oracle. Proves the `lpTwapWindow != 0` deploy branch: the
    ///         market wires + resolves with NO CRE seed (the fair oracle prices live), unlike the CRE-push oracle
    ///         that reverts until a mark is pushed. The deployer's internal W3 wire-check (`_assertWired`) is the
    ///         in-deploy proof; here we additionally resolve through the returned router.
    function test_fork_reservoir_market_builds_with_fair_oracle() public {
        (address escrowVault, address borrowVault, address router) = new ReservoirMarketDeployer().deploy(
            ReservoirMarketDeployer.Params({
                factory: GenericFactory(BaseAddresses.EVAULT_FACTORY),
                evc: BaseAddresses.EVC,
                governor: address(this),
                lpToken: VAULT,
                usdc: USDC,
                lpOracle: address(oracle), // the fair oracle — the lpTwapWindow != 0 P5 path
                irm: address(new ZeroIRM()),
                engineSafe: makeAddr("engine"),
                borrowLTV: 8000,
                liqLTV: 9000
            })
        );
        assertTrue(escrowVault != address(0) && borrowVault != address(0) && router != address(0), "market built");
        // escrow shares unwrap to the LP token 1:1, then price via the fair oracle → USDC (no seed needed).
        uint256 q = EulerRouter(router).getQuote(1e18, escrowVault, USDC);
        assertGt(q, 0, "router resolves escrow to lpToken to fair oracle to USDC");
    }

    /// @dev Algebra swap callback: pay the token we owe from our dealt balance.
    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == pool, "cb: not pool");
        if (amount0Delta > 0) IERC20(HYDX).transfer(pool, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(USDC).transfer(pool, uint256(amount1Delta));
    }
}
