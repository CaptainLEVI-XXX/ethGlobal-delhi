// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ILimitOrderProtocol} from "./interfaces/ILimitOrderProtocol.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract Router {
    using SafeERC20 for IERC20;

    struct LimitOrderData {
        ILimitOrderProtocol.Order order;
        bytes32 r;
        bytes32 vs;
        uint256 fillAmount;
        uint256 takerTraits;
        bytes fillOrderArgs;
    }

    IPoolManager public immutable poolManager;
    ILimitOrderProtocol public immutable limitOrderProtocol;

    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 limitOrderAmount,
        uint256 v4Amount,
        uint256 totalOut
    );

    constructor(IPoolManager _poolManager, ILimitOrderProtocol _limitOrderProtocol) {
        poolManager = _poolManager;
        limitOrderProtocol = _limitOrderProtocol;
    }

    /**
     * @notice Execute hybrid swap: 1inch limit order fill + v4 swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param totalAmountIn Total input amount
     * @param minAmountOut Minimum output amount
     * @param limitOrderData 1inch limit order details (empty if no limit order)
     * @param poolKey v4 pool for remaining swap
     * @return totalAmountOut Total output received
     */
    function hybridSwap(
        address tokenIn,
        address tokenOut,
        uint256 totalAmountIn,
        uint256 minAmountOut,
        LimitOrderData calldata limitOrderData,
        PoolKey calldata poolKey
    ) external returns (uint256 totalAmountOut) {
        // Transfer total amount from user
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), totalAmountIn);

        uint256 limitOrderOutput = 0;
        uint256 remainingAmountIn = totalAmountIn;

        // Execute 1inch limit order if data provided
        if (limitOrderData.fillAmount > 0 && limitOrderData.fillAmount <= totalAmountIn) {
            limitOrderOutput = _executeLimitOrder(limitOrderData, tokenIn, tokenOut, totalAmountIn);
            remainingAmountIn = totalAmountIn - limitOrderData.fillAmount;
        }

        uint256 v4Output = 0;
        // Execute v4 swap for remaining amount (with MEV hook)
        if (remainingAmountIn > 0) {
            v4Output = _executeV4Swap(tokenIn, tokenOut, remainingAmountIn, poolKey);
        }

        totalAmountOut = limitOrderOutput + v4Output;
        require(totalAmountOut >= minAmountOut, "Insufficient output");

        // Transfer final output to user
        IERC20(tokenOut).safeTransfer(msg.sender, totalAmountOut);

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, limitOrderData.fillAmount, remainingAmountIn, totalAmountOut);

        return totalAmountOut;
    }

    /**
     * @notice Execute 1inch limit order fill
     */
    function _executeLimitOrder(LimitOrderData calldata data, address tokenIn, address tokenOut, uint256 totalAmount)
        private
        returns (uint256 outputAmount)
    {
        // Approve 1inch protocol
        IERC20(tokenIn).approve(address(limitOrderProtocol), totalAmount);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // Fill the 1inch limit order
        limitOrderProtocol.fillOrderArgs(
            data.order, data.r, data.vs, data.fillAmount, data.takerTraits, data.fillOrderArgs
        );

        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        outputAmount = balanceAfter - balanceBefore;

        // Reset approval
        IERC20(tokenIn).approve(address(limitOrderProtocol), 0);
    }

    /**
     * @notice Execute v4 swap (triggers MEV taxing hook)
     */
    function _executeV4Swap(address tokenIn, address tokenOut, uint256 amountIn, PoolKey calldata poolKey)
        private
        returns (uint256 outputAmount)
    {
        // Prepare swap parameters
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: tokenIn < tokenOut,
            amountSpecified: -int256(amountIn), // Exact input
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Approve pool manager
        IERC20(tokenIn).approve(address(poolManager), amountIn);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // Execute swap (MEV hook will be triggered automatically)
        poolManager.swap(
            poolKey,
            params,
            "" // No hookData needed since this is just v4 portion
        );

        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        outputAmount = balanceAfter - balanceBefore;

        // Reset approval
        IERC20(tokenIn).approve(address(poolManager), 0);
    }

    /**
     * @notice Preview hybrid swap without execution
     */
    function previewHybridSwap(
        address tokenIn,
        address tokenOut,
        uint256 totalAmountIn,
        LimitOrderData calldata limitOrderData,
        PoolKey calldata poolKey
    )
        external
        view
        returns (uint256 estimatedLimitOrderOutput, uint256 estimatedV4Output, uint256 estimatedTotalOutput)
    {
        // This would require view functions from both protocols
        // Simplified implementation - in practice you'd call quoter functions

        if (limitOrderData.fillAmount > 0) {
            // Estimate 1inch output (you'd call their quoter)
            estimatedLimitOrderOutput = limitOrderData.fillAmount * 3000; // Example: ETH->USDC
        }

        uint256 remainingAmount = totalAmountIn - limitOrderData.fillAmount;
        if (remainingAmount > 0) {
            // Estimate v4 output (you'd call v4 quoter)
            estimatedV4Output = remainingAmount * 2995; // Example with slippage + MEV tax
        }

        estimatedTotalOutput = estimatedLimitOrderOutput + estimatedV4Output;
    }
}
