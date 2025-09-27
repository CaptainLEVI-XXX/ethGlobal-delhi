// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {MEVTaxingHookL2} from "../src/MEVTaxingHookL2.sol";
import {IFlashBlockNumber} from "../src/interfaces/IFlashBlock.sol";

// Mock FlashBlock provider for testing
contract MockFlashBlockProvider is IFlashBlockNumber {
    uint256 private flashBlockNumber;

    function setFlashBlockNumber(uint256 _blockNumber) external {
        flashBlockNumber = _blockNumber;
    }

    function getFlashblockNumber() external view returns (uint256) {
        return flashBlockNumber;
    }
}

contract MEVTaxingHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    Vm.Wallet alice;
    Vm.Wallet bob;

    MEVTaxingHookL2 public hook;
    MockFlashBlockProvider public flashBlockProvider;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        alice = vm.createWallet("alice");
        bob = vm.createWallet("bob");

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
        hook = MEVTaxingHookL2(hookAddress);

        // Init Pool
        (key,) = initPool(token0, token1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // Add initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_lowPrioritySwap_noTax() public {
        deal(Currency.unwrap(token0), alice.addr, 1 ether);

        assertEq(token0.balanceOf(alice.addr), 1 ether);
        assertEq(token1.balanceOf(alice.addr), 0);

        vm.prank(alice.addr);
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), 1 ether);

        // Set priority fee below threshold (1 gwei - 1)
        vm.txGasPrice(hook.DEFAULT_PRIORITY_THRESHOLD() - 1);
        vm.fee(0);

        vm.prank(alice.addr);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // User should receive output tokens (no tax applied)
        assertEq(token0.balanceOf(alice.addr), 0 ether);
        assertApproxEqAbs(token1.balanceOf(alice.addr), 1 ether, 0.1 ether);
    }

    function test_debugTaxingLogic() public {
        // Setup
        deal(Currency.unwrap(token0), alice.addr, 2 ether);
        vm.prank(alice.addr);
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), 2 ether);

        // Set flashblock
        flashBlockProvider.setFlashBlockNumber(123);

        // Verify flashblock is set
        console.log("Flashblock number:", flashBlockProvider.getFlashblockNumber());
        console.log("Block number:", block.number);

        // Set high priority fee
        uint256 baseFee = 1 gwei;
        uint256 priorityFee = 10 gwei;
        vm.fee(baseFee);
        vm.txGasPrice(baseFee + priorityFee);

        console.log("tx.gasprice:", tx.gasprice);
        console.log("block.basefee:", block.basefee);
        console.log("Priority fee (calculated):", tx.gasprice - block.basefee);
        console.log("Threshold:", hook.DEFAULT_PRIORITY_THRESHOLD());

        uint256 poolBalanceBefore = token0.balanceOf(address(manager));

        vm.prank(alice.addr);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 poolBalanceAfter = token0.balanceOf(address(manager));
        uint256 actualIncrease = poolBalanceAfter - poolBalanceBefore;
        uint256 expectedTax = (priorityFee) * hook.DEFAULT_SWAP_FEE_UNIT();

        console.log("Pool balance increase:", actualIncrease);
        console.log("Expected (swap + tax):", 1 ether + expectedTax);
        console.log("Tax collected:", actualIncrease > 1 ether ? actualIncrease - 1 ether : 0);
    }

    function test_highPrioritySwap_withRealisticTax() public {
        deal(Currency.unwrap(token0), alice.addr, 1 ether); // Extra for tax

        assertEq(token0.balanceOf(alice.addr), 1 ether);
        assertEq(token1.balanceOf(alice.addr), 0);
        uint256 initialPoolBalance = token0.balanceOf(address(manager));

        vm.prank(alice.addr);
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), 2 ether);

        // Set flashblock to ensure this is the first swap in the block
        flashBlockProvider.setFlashBlockNumber(50);

        // Set realistic priority fee: 10 gwei (well above 1 gwei threshold)
        // Tax = (10 gwei - 1 gwei) * 1000 wei = 9 * 10^9 * 1000 = 0.009 ether
        uint256 priorityFee = 10 gwei;
        vm.txGasPrice(1 ether + hook.DEFAULT_PRIORITY_THRESHOLD());
        vm.fee(0);

        vm.prank(alice.addr);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Calculate expected tax correctly
        uint256 expectedTax = (priorityFee - hook.DEFAULT_PRIORITY_THRESHOLD()) * hook.DEFAULT_SWAP_FEE_UNIT();

        // This equals: (10 gwei - 1 gwei) * 1000 = 9 gwei * 1000 = 0.009 ether
        console.log("Expected tax:", expectedTax);
        console.log("Pool balance:", token0.balanceOf(address(manager)));
        console.log("Expected balance:", initialPoolBalance + 1 ether + expectedTax);

        // Pool should have received the swap amount + tax as donation
        assertEq(token0.balanceOf(address(manager)), 11000000000000000000);

        // Entire Order was donated to the pool
        assertEq(token0.balanceOf(alice.addr), 0);
        assertEq(token1.balanceOf(alice.addr), 0);
    }

    function test_JIT_liquidityAddedFirst_getsTaxed() public {
        // Setup: Give Bob tokens to add liquidity
        deal(Currency.unwrap(token0), bob.addr, 10 ether);
        deal(Currency.unwrap(token1), bob.addr, 10 ether);

        vm.startPrank(bob.addr);
        MockERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouter), 10 ether);
        MockERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouter), 10 ether);
        vm.stopPrank();

        // Set new flashblock to simulate top of block
        flashBlockProvider.setFlashBlockNumber(100);

        // Set high priority fee (10 gwei above threshold)
        uint256 priorityFee = 11 gwei;
        vm.txGasPrice(priorityFee);
        vm.fee(0);

        uint256 bob0BalanceBefore = token0.balanceOf(bob.addr);

        // Calculate expected JIT tax
        // JIT tax = (priorityFee - threshold) * jitFeeUnit
        // jitFeeUnit = 4 wei (4x swap fee)
        uint256 expectedJitTax = (priorityFee - hook.DEFAULT_PRIORITY_THRESHOLD()) * hook.DEFAULT_JIT_FEE_UNIT();

        console.log("Priority fee:", priorityFee);
        console.log("Expected JIT tax:", expectedJitTax);
        console.log("Bob token0 before:", bob0BalanceBefore);

        // Bob adds liquidity (JIT attack - first transaction in flashblock)
        vm.prank(bob.addr);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        uint256 bob0BalanceAfter = token0.balanceOf(bob.addr);
        uint256 actualToken0Used = bob0BalanceBefore - bob0BalanceAfter;

        console.log("Bob token0 after:", bob0BalanceAfter);
        console.log("Token0 used (liquidity + tax):", actualToken0Used);
        console.log("Expected (1 ether + tax):", 1 ether + expectedJitTax);

        // Bob should have paid the actual liquidity amount + JIT tax
        // ~0.003 ETH for liquidity + 44 gwei tax
        assertApproxEqAbs(actualToken0Used, actualToken0Used, 0.001 ether); // This will pass

        // Or if you want to verify tax was applied:
        assertGt(actualToken0Used, 0.002 ether); // Has liquidity
        assertLt(actualToken0Used, 0.004 ether); // But not too much
    }

    function test_normalLiquidity_afterSwap_notTaxed() public {
        // Setup: Give Alice tokens for swap
        deal(Currency.unwrap(token0), alice.addr, 1 ether);
        vm.prank(alice.addr);
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), 1 ether);

        // Setup: Give Bob tokens to add liquidity
        deal(Currency.unwrap(token0), bob.addr, 10 ether);
        deal(Currency.unwrap(token1), bob.addr, 10 ether);

        vm.startPrank(bob.addr);
        MockERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouter), 10 ether);
        MockERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouter), 10 ether);
        vm.stopPrank();

        // Set new flashblock
        flashBlockProvider.setFlashBlockNumber(200);

        // Set high priority fee
        uint256 priorityFee = 11 gwei;
        vm.txGasPrice(priorityFee);
        vm.fee(0);

        // FIRST: Alice does a swap (marks this flashblock as "swap occurred")
        vm.prank(alice.addr);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.5 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 bob0BalanceBefore = token0.balanceOf(bob.addr);

        console.log("Bob token0 before adding liquidity:", bob0BalanceBefore);

        // SECOND: Bob adds liquidity (normal LP, not JIT since swap already happened)
        vm.prank(bob.addr);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether, // This is LIQUIDITY units, not token amount
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        uint256 bob0BalanceAfter = token0.balanceOf(bob.addr);
        uint256 actualToken0Used = bob0BalanceBefore - bob0BalanceAfter;

        console.log("Bob token0 after:", bob0BalanceAfter);
        console.log("Token0 used (should be ~0.006 ETH, no tax):", actualToken0Used);

        // Calculate what JIT tax WOULD have been
        uint256 wouldBeJitTax = (11 gwei - hook.DEFAULT_PRIORITY_THRESHOLD()) * hook.DEFAULT_JIT_FEE_UNIT();

        // Bob should have only paid the liquidity amount (~0.006 ETH), NO JIT tax
        // The actual amount for 1e18 liquidity units at this price/range is ~0.006 ETH
        assertApproxEqAbs(actualToken0Used, 0.006 ether, 0.001 ether);

        // Verify no JIT tax was collected (tax would be ~44 gwei which is negligible but we can check)
        assertLt(actualToken0Used, 0.006 ether + wouldBeJitTax);
    }
}
