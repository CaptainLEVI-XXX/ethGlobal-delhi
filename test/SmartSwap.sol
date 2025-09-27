// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OneInchHelper} from "./1inchHelper.sol";
import {Router} from "../src/Router.sol";
import {MEVTaxingHookL2} from "../src/MEVTaxingHookL2.sol";
import {MockFlashBlockProvider} from "./MevTaxing.t.sol";
import {OneInchDynamicOrder} from "../src/1inchDynamicOrder.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILimitOrderProtocol} from "../src/interfaces/ILimitOrderProtocol.sol";
import {IFlashBlockNumber} from "../src/interfaces/IFlashBlock.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract HybridRouterTest is OneInchHelper, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager; // Add this for accessing pool state

    Router public router;
    MEVTaxingHookL2 public mevHook;
    MockFlashBlockProvider public flashBlockProvider;

    Currency token0;
    Currency token1;

    function setUp() public override {
        // Initialize 1inch setup from parent
        super.setUp();

        if (WETH < USDC) {
            token0 = Currency.wrap(WETH);
            token1 = Currency.wrap(USDC);
        } else {
            token0 = Currency.wrap(USDC);
            token1 = Currency.wrap(WETH);
        }

        // Deploy V4 infrastructure
        _deployV4Infrastructure();
        _addV4Liquidity();

        // Deploy Router with both protocols
        router = new Router(manager, LIMIT_ORDER_PROTOCOL);

        // Setup approvals for Router
        _setupRouterApprovals();
    }

    function _deployV4Infrastructure() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy flash block provider
        flashBlockProvider = new MockFlashBlockProvider();

        // Deploy our hook
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        address hookAddress = address(flags);

        deployCodeTo(
            "MEVTaxingHookL2.sol",
            abi.encode(manager, IFlashBlockNumber(address(flashBlockProvider)), address(this)),
            hookAddress
        );
        mevHook = MEVTaxingHookL2(hookAddress);

        // Initialize pool with correct price
        uint160 initSqrtPrice;
        if (Currency.unwrap(token0) == USDC) {
            // USDC is token0, WETH is token1
            // Price = token0/token1 = USDC/WETH = 1/3000
            initSqrtPrice = 1448442638333492138;
        } else {
            // WETH is token0, USDC is token1
            // Price = token0/token1 = WETH/USDC = 3000/1
            initSqrtPrice = 4337962309165438028470343003;
        }

        (key,) = initPool(token0, token1, mevHook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    }

    function _addV4Liquidity() internal {
        // Now these balanced amounts will work
        uint256 wethAmount = 100 ether;
        uint256 usdcAmount = 100_000 * 1e6;

        deal(WETH, address(this), wethAmount);
        deal(USDC, address(this), usdcAmount);

        //... approvals code ...
        // Approve all routers
        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            IERC20(WETH).approve(toApprove[i], type(uint256).max);
            IERC20(USDC).approve(toApprove[i], type(uint256).max);
        }

        // Add wide-range liquidity at 1:1 price
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 * 10 ^ 6,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function _setupRouterApprovals() internal {
        // Bob approves Router for WETH and USDC
        vm.startPrank(bob);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_hybridSwap_1inchAndV4() public {
        // Access pool state using StateLibrary
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        console.log("Pool initialized with sqrtPriceX96:", sqrtPriceX96);
        console.log("Pool initialized with tick:", tick);

        uint128 liquidity = manager.getLiquidity(key.toId());
        console.log("Pool total liquidity:", liquidity);

        // Alice creates a limit order: selling 1 WETH for 3000 USDC
        OneInchDynamicOrder.SpreadParams memory params = OneInchDynamicOrder.SpreadParams({
            baseSpreadBps: 50,
            multiplier: 100,
            maxSpreadBps: 200,
            useMakerAsset: true
        });

        (ILimitOrderProtocol.Order memory aliceOrder, bytes memory extension, uint256 takerTraits) =
            _buildOrderWithVolatilitySpread(alice, WETH, USDC, 1 ether, 3000 * 1e6, params);

        (bytes32 r, bytes32 vs) = _signOrder(aliceOrder, _alicePrivateKey);

        // Bob's balances before swap
        uint256 bobWethBefore = IERC20(WETH).balanceOf(bob);
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);

        console.log("\n=== Initial State ===");
        console.log("Bob WETH before:", bobWethBefore);
        console.log("Bob USDC before:", bobUsdcBefore);

        // Prepare limit order data
        Router.LimitOrderData memory limitOrderData = Router.LimitOrderData({
            order: aliceOrder,
            r: r,
            vs: vs,
            fillAmount: 1 ether,
            takerTraits: takerTraits,
            fillOrderArgs: extension,
            expectedInput: 3021 * 1e6 // Account for spread
        });

        Router.V4SwapParams memory v4params = calculateV4Params(key, USDC);

        // Execute hybrid swap
        vm.prank(bob);
        uint256 totalOutput = router.smartSwap(
            6000 * 1e6,
            0,
            limitOrderData,
            key,
            v4params
        );

        // Check results
        uint256 bobWethAfter = IERC20(WETH).balanceOf(bob);
        uint256 bobUsdcAfter = IERC20(USDC).balanceOf(bob);

        console.log("\n=== Swap Results ===");
        console.log("Bob WETH after:", bobWethAfter);
        console.log("Bob USDC after:", bobUsdcAfter);
        console.log("Total USDC spent:", bobUsdcBefore - bobUsdcAfter);
        console.log("Total WETH received:", bobWethAfter - bobWethBefore);
        console.log("Router output:", totalOutput);

        // Verify results
        assertEq(bobUsdcBefore - bobUsdcAfter, 6000 * 1e6, "Should spend exactly 6000 USDC");
        assertEq(totalOutput, bobWethAfter - bobWethBefore, "Router output should match balance change");

        // Should get close to 2 WETH
        // assertGt(totalOutput, 1.9 ether, "Should exceed minimum output");
        // assertLt(totalOutput, 2.1 ether, "Should be reasonable output");
    }
    function calculateV4Params(PoolKey memory poolKey, address tokenIn)
        internal
        pure
        returns (Router.V4SwapParams memory params)
    {
        params.zeroForOne = tokenIn == Currency.unwrap(poolKey.currency0);
        params.sqrtPriceLimitX96 = params.zeroForOne
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;
    }
}
