// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ILimitOrderProtocol} from "./interfaces/ILimitOrderProtocol.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";

contract Aggregator {
    using SafeTransferLib for address;
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using CustomRevert for bytes4;

    IPoolManager public immutable poolManager;
    ILimitOrderProtocol public immutable limitOrderProtocol;
    bytes internal constant ZERO_BYTES = "";

    event SwapExecuted(
        address indexed user,
        Currency indexed tokenIn,
        Currency indexed tokenOut,
        uint256 limitOrderAmount,
        uint256 v4Amount,
        uint256 totalOut
    );

    struct LimitOrderData {
        ILimitOrderProtocol.Order order;
        bytes32 r;
        bytes32 vs;
        uint256 fillAmount;
        uint256 takerTraits;
        bytes fillOrderArgs;
        uint256 expectedInput;
    }

    // swap parameters
    struct V4SwapParams {
        bool zeroForOne;
        uint160 sqrtPriceLimitX96;
    }

    // swap data for callback
    struct SwapCallbackData {
        PoolKey poolKey;
        Currency tokenIn;
        Currency tokenOut;
        uint256 amountIn;
        V4SwapParams v4Params;
    }

    constructor(IPoolManager _poolManager, ILimitOrderProtocol _limitOrderProtocol) {
        poolManager = _poolManager;
        limitOrderProtocol = _limitOrderProtocol;
    }

    function smartSwap(
        uint256 totalAmountIn,
        uint256 minAmountOut,
        LimitOrderData calldata limitOrderData,
        PoolKey calldata poolKey,
        V4SwapParams calldata v4Params
    ) external returns (uint256 totalAmountOut) {
        Currency tokenIn = poolKey.currency0;
        Currency tokenOut = poolKey.currency1;

        //token order
        if (!v4Params.zeroForOne) {
            (tokenIn, tokenOut) = (tokenOut, tokenIn);
        }

        // Transfer tokens once
        Currency.unwrap(tokenIn).safeTransferFrom(msg.sender, address(this), totalAmountIn);

        uint256 limitOrderOutput;
        uint256 remainingAmountIn = totalAmountIn;

        // Execute limit order if specified
        if (limitOrderData.fillAmount > 0) {
            require(limitOrderData.expectedInput <= totalAmountIn, "Limit order input exceeds total");
            limitOrderOutput = _executeLimitOrder(limitOrderData, tokenIn, tokenOut);

            unchecked {
                remainingAmountIn = totalAmountIn - limitOrderData.expectedInput;
            }
        }

        uint256 v4Output;
        if (remainingAmountIn > 0) {
            v4Output = _executeV4Swap(poolKey, tokenIn, tokenOut, remainingAmountIn, v4Params);
        }

        unchecked {
            totalAmountOut = limitOrderOutput + v4Output;
        }

        // require(totalAmountOut >= minAmountOut, "Insufficient output");

        // Transfer output to user
        // tokenOut.transfer(msg.sender, totalAmountOut);
        Currency.unwrap(tokenOut).safeTransfer(msg.sender, totalAmountOut);

        emit SwapExecuted(
            msg.sender, tokenIn, tokenOut, limitOrderData.expectedInput, remainingAmountIn, totalAmountOut
        );
    }

    function _executeLimitOrder(LimitOrderData calldata data, Currency tokenIn, Currency tokenOut)
        private
        returns (uint256 outputAmount)
    {
        //  approve amount
        Currency.unwrap(tokenIn).safeApprove(address(limitOrderProtocol), type(uint256).max);

        uint256 balanceBefore = tokenOut.balanceOfSelf();

        limitOrderProtocol.fillOrderArgs(
            data.order, data.r, data.vs, data.fillAmount, data.takerTraits, data.fillOrderArgs
        );

        unchecked {
            outputAmount = tokenOut.balanceOfSelf() - balanceBefore;
        }

        // Reset approval
        Currency.unwrap(tokenIn).safeApprove(address(limitOrderProtocol), 0);
    }

    /// V4 swap execution
    function _executeV4Swap(
        PoolKey calldata poolKey,
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn,
        V4SwapParams calldata params
    ) private returns (uint256 outputAmount) {
        SwapCallbackData memory callbackData = SwapCallbackData({
            poolKey: poolKey,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            v4Params: params
        });

        bytes memory result = poolManager.unlock(abi.encode(callbackData));
        (outputAmount) = abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");

        SwapCallbackData memory swapData = abi.decode(data, (SwapCallbackData));

        // Create swap params with pre-calculated values
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: swapData.v4Params.zeroForOne,
            amountSpecified: -int256(swapData.amountIn),
            sqrtPriceLimitX96: swapData.v4Params.sqrtPriceLimitX96
        });

        BalanceDelta delta = poolManager.swap(swapData.poolKey, swapParams, ZERO_BYTES);

        (int256 deltaIn, int256 deltaOut) =
            swapData.v4Params.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());

        uint256 amountOut;

        // Handle output tokens
        if (deltaOut > 0) {
            amountOut = uint256(deltaOut);
            swapData.tokenOut.take(poolManager, address(this), amountOut, false);
        }

        // Handle input tokens
        if (deltaIn < 0) {
            swapData.tokenIn.settle(poolManager, address(this), uint256(-deltaIn), false);
        }

        return abi.encode(amountOut);
    }
}
