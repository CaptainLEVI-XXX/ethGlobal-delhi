// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOrderMixin, IAmountGetter} from "./interfaces/IAmountGetter.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {AddressLib, Address} from "./libraries/AddressLib.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {PythVolatilityLib} from "./PythVolatility.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

abstract contract OneInchDynamicOrder is IAmountGetter,Owned {
    using CustomRevert for bytes4;
    using AddressLib for Address;
    using FixedPointMathLib for uint256;
    // using PythVolatilityLib for PythVolatilityLib.VolatilityStorge;


    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_SPREAD = 1000;

    error SpreadTooHigh();
    error InvalidParam();
    error RestrictedOperation();

     struct SpreadParams{
        uint256 baseSpreadBps;
        uint256 multiplier;
        uint256 maxSpreadBps;
        bool useMakerAsset;  // true = maker asset for volatility, false = taker asset for volatility
    }

    address public admin;
    // PythVolatilityLib.VolatilityStorge internal _pythStorage;

    constructor(address _admin) Owned(_admin) {
    }

     function getTakingAmount(
        IOrderMixin.Order calldata order,
        bytes calldata extension,
        bytes32 orderHash,
        address taker,
        uint256 makingAmount,
        uint256 remainingMakingAmount,
        bytes calldata extraData
    ) external view returns (uint256 takingAmount) {

        SpreadParams memory params = abi.decode(extraData, (SpreadParams));

        // determine which token to use for volatility
        Address targetToken = params.useMakerAsset ? order.makerAsset : order.takerAsset;

        // Get Valatility for the target token
        uint256 currentVolatility = _getTokenVolatility(targetToken.get());

        // calculate Dynamic Spread
        uint256 dynamicSpread = _calculateDynamicSpread(
            params.baseSpreadBps, params.multiplier, params.maxSpreadBps, currentVolatility
        );

        // Apply spread to taking Amount
        uint256 originalTakingAmount = makingAmount.mulDiv(order.takingAmount, order.makingAmount);
        takingAmount = originalTakingAmount.rawAdd(originalTakingAmount.mulDiv(dynamicSpread, BASIS_POINTS));
        
    }

        function getMakingAmount(
        IOrderMixin.Order calldata order,
        bytes calldata extension,
        bytes32 orderHash,
        address taker,
        uint256 takingAmount,
        uint256 remainingTakingAmount,
        bytes calldata extraData
    ) external view returns (uint256 makingAmount) {

        SpreadParams memory params = abi.decode(extraData, (SpreadParams));

        // Determine ehich Token to use for volatality calculation
        Address targetToken = params.useMakerAsset ? order.makerAsset : order.takerAsset;

        // Get volatility for the target token
        uint256 currentVolatility = _getTokenVolatility(targetToken.get());

        // Calculate dynamic spread
        uint256 dynamicSpread = _calculateDynamicSpread(
            params.baseSpreadBps, params.multiplier, params.maxSpreadBps, currentVolatility
        );

        // Apply spread to making amount
        uint256 originalMakingAmount = takingAmount.mulDiv(order.makingAmount, order.takingAmount);
        makingAmount = originalMakingAmount.rawSub(originalMakingAmount.mulDiv(dynamicSpread, BASIS_POINTS));
        
    }



}
