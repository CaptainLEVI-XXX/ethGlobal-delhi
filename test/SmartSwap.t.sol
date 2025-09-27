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

contract HybridRouterTest is OneInchHelper, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Router public router;
    MEVTaxingHookL2 public mevHook;
    MockFlashBlockProvider public flashBlockProvider;

    PoolKey public wethUsdcPoolKey;

    // V4 helper contracts
    // PoolModifyLiquidityTest public modifyLiquidityRouter;
    // PoolSwapTest public swapRouter;

    uint160 constant SQRT_PRICE_1_3000 = 4309467807335529498290617876; // 1 WETH = 3000 USDC

    function setUp() public override {
        // Initialize 1inch setup from parent
        super.setUp();

        // Deploy V4 infrastructure
        _deployV4Infrastructure();

        // Initialize WETH/USDC pool with MEV hook
        _initializeV4Pool();

        // Deploy Router with both protocols
        router = new Router(manager, LIMIT_ORDER_PROTOCOL);

        // Setup approvals for Router
        _setupRouterApprovals();
    }

    function _deployV4Infrastructure() internal {
        // Deploy PoolManager
        manager = new PoolManager(address(this));

        // Deploy flash block provider
        flashBlockProvider = new MockFlashBlockProvider();
        flashBlockProvider.setFlashBlockNumber(1);

        // Deploy MEV Hook with proper flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Deploy hook to deterministic address
        bytes memory hookBytecode =
            abi.encodePacked(type(MEVTaxingHookL2).creationCode, abi.encode(manager, flashBlockProvider, address(this)));

        address hookAddress = address(flags);
        vm.etch(hookAddress, hookBytecode);
        mevHook = MEVTaxingHookL2(hookAddress);

        // Deploy helper routers for V4
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
    }

    function _initializeV4Pool() internal {
        // Create pool key for WETH/USDC - USDC must be currency0 (smaller address)
        wethUsdcPoolKey = PoolKey({
            currency0: Currency.wrap(USDC), // USDC has smaller address
            currency1: Currency.wrap(WETH), // WETH has larger address
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(mevHook))
        });

        // Initialize pool with inverted price (1 USDC = 1/3000 WETH)
        // sqrt(1/3000) = sqrt(0.000333...) ≈ 0.01825...
        // In X96 format: 0.01825 * 2^96 ≈ 1449103404082823763968843322
        uint160 SQRT_PRICE_3000_1 = 1449103404082823763968843322;
        manager.initialize(wethUsdcPoolKey, SQRT_PRICE_3000_1);

        // Add initial liquidity for the pool
        _addV4Liquidity();
    }

    function _addV4Liquidity() internal {
        // Fund the liquidity router
        deal(WETH, address(this), 100 ether);
        deal(USDC, address(this), 300_000 * 1e6);

        // Approve tokens
        IERC20(WETH).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(USDC).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            wethUsdcPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
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
        // Alice creates a 1inch limit order for 1 WETH @ 3100 USDC
        OneInchDynamicOrder.SpreadParams memory params = OneInchDynamicOrder.SpreadParams({
            baseSpreadBps: 0, // No spread for simplicity
            multiplier: 0,
            maxSpreadBps: 0,
            useMakerAsset: true
        });

        (ILimitOrderProtocol.Order memory aliceOrder, bytes memory extension, uint256 takerTraits) =
        _buildOrderWithVolatilitySpread(
            alice,
            WETH,
            USDC,
            1 ether, // 1 WETH
            3100 * 1e6, // 3100 USDC (better than pool price)
            params
        );

        (bytes32 r, bytes32 vs) = _signOrder(aliceOrder, _alicePrivateKey);

        // Bob wants to swap 2 WETH for USDC using hybrid approach
        // 1 WETH via 1inch (Alice's order), 1 WETH via V4
        uint256 bobWethBefore = IERC20(WETH).balanceOf(bob);
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);

        console.log("Bob WETH before:", bobWethBefore);
        console.log("Bob USDC before:", bobUsdcBefore);

        // Prepare limit order data for Router
        Router.LimitOrderData memory limitOrderData = Router.LimitOrderData({
            order: aliceOrder,
            r: r,
            vs: vs,
            fillAmount: 1 ether, // Fill 1 WETH from Alice's order
            takerTraits: takerTraits,
            fillOrderArgs: extension
        });

        // Set normal priority fee (no MEV tax)
        vm.txGasPrice(1 gwei);
        vm.fee(0);

        // Execute hybrid swap
        vm.prank(bob);
        uint256 totalOutput = router.smartSwap(
            WETH,
            USDC,
            2 ether, // Total: 2 WETH input
            5900 * 1e6, // Min output: 5900 USDC
            limitOrderData, // 1 WETH via 1inch
            wethUsdcPoolKey // 1 WETH via V4
        );

        uint256 bobWethAfter = IERC20(WETH).balanceOf(bob);
        uint256 bobUsdcAfter = IERC20(USDC).balanceOf(bob);

        console.log("\n=== Hybrid Swap Results ===");
        console.log("Bob WETH after:", bobWethAfter);
        console.log("Bob USDC after:", bobUsdcAfter);
        console.log("Total WETH swapped:", bobWethBefore - bobWethAfter);
        console.log("Total USDC received:", bobUsdcAfter - bobUsdcBefore);
        console.log("Total output from router:", totalOutput);

        // Verify results
        assertEq(bobWethBefore - bobWethAfter, 2 ether, "Should swap exactly 2 WETH");
        assertEq(totalOutput, bobUsdcAfter - bobUsdcBefore, "Router output should match balance change");

        // Should receive ~3100 USDC from 1inch + ~2995 USDC from V4 = ~6095 USDC
        assertGt(totalOutput, 5900 * 1e6, "Should exceed minimum output");
        assertLt(totalOutput, 6200 * 1e6, "Should be reasonable output");

        console.log("\n=== Breakdown ===");
        uint256 expectedFrom1Inch = 3100 * 1e6;
        uint256 expectedFromV4 = 2995 * 1e6;
        console.log("Expected from 1inch (1 WETH @ 3100):", expectedFrom1Inch);
        console.log("Expected from V4 (1 WETH @ ~2995):", expectedFromV4);
        console.log("Actual total received:", totalOutput);

        // Verify Alice received her USDC from the limit order
        assertEq(IERC20(WETH).balanceOf(alice), 99 ether, "Alice should have 1 WETH less");
        assertGt(IERC20(USDC).balanceOf(alice), 1_000_000 * 1e6, "Alice should have received USDC");
    }
}
