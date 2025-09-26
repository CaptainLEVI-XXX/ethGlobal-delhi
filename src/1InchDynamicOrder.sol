// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOrderMixin, IAmountGetter} from "./interfaces/IAmountGetter.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {AddressLib, Address} from "./libraries/AddressLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {PythVolatilityLib} from "./PythVolatility.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

contract OneInchDynamicOrder is IAmountGetter, Owned {
    using CustomRevert for bytes4;
    using AddressLib for Address;
    using FixedPointMathLib for uint256;
    using PythVolatilityLib for PythVolatilityLib.VolatilityStorage;

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_SPREAD = 1000;

    error RestrictedOperation();

    struct SpreadParams {
        uint256 baseSpreadBps;
        uint256 multiplier;
        uint256 maxSpreadBps;
        bool useMakerAsset; // true = maker asset for volatility, false = taker asset for volatility
    }

    address public admin;
    PythVolatilityLib.VolatilityStorage internal _pythStorage;

    constructor(address _admin, address _pythOracle) Owned(_admin) {
        _pythStorage.setPythOracle(_pythOracle);
    }

    function getTakingAmount(
        IOrderMixin.Order calldata order,
        bytes calldata, /* extension */
        bytes32, /* orderHash */
        address, /* taker */
        uint256 makingAmount,
        uint256, /* remainingMakingAmount */
        bytes calldata extraData
    ) external view returns (uint256 takingAmount) {
        SpreadParams memory params = abi.decode(extraData, (SpreadParams));

        if (validateSpreadParams(params.baseSpreadBps, params.multiplier, params.maxSpreadBps)) {
            // determine which token to use for volatility
            Address targetToken = params.useMakerAsset ? order.makerAsset : order.takerAsset;

            // Get Valatility for the target token
            uint256 currentVolatility = _getTokenVolatility(targetToken.get());

            // calculate Dynamic Spread
            uint256 dynamicSpread =
                _calculateDynamicSpread(params.baseSpreadBps, params.multiplier, params.maxSpreadBps, currentVolatility);

            // Apply spread to taking Amount
            uint256 originalTakingAmount = makingAmount.mulDiv(order.takingAmount, order.makingAmount);
            takingAmount = originalTakingAmount.rawAdd(originalTakingAmount.mulDiv(dynamicSpread, BASIS_POINTS));
        }
    }

    function getMakingAmount(
        IOrderMixin.Order calldata order,
        bytes calldata, /* extension */
        bytes32, /* orderHash */
        address, /* taker */
        uint256 takingAmount,
        uint256, /* remainingMakingAmount */
        bytes calldata extraData
    ) external view returns (uint256 makingAmount) {
        SpreadParams memory params = abi.decode(extraData, (SpreadParams));

        if (validateSpreadParams(params.baseSpreadBps, params.multiplier, params.maxSpreadBps)) {
            // Determine ehich Token to use for volatality calculation
            Address targetToken = params.useMakerAsset ? order.makerAsset : order.takerAsset;

            // Get volatility for the target token
            uint256 currentVolatility = _getTokenVolatility(targetToken.get());

            // Calculate dynamic spread
            uint256 dynamicSpread =
                _calculateDynamicSpread(params.baseSpreadBps, params.multiplier, params.maxSpreadBps, currentVolatility);

            // Apply spread to making amount
            uint256 originalMakingAmount = takingAmount.mulDiv(order.makingAmount, order.takingAmount);
            makingAmount = originalMakingAmount.rawSub(originalMakingAmount.mulDiv(dynamicSpread, BASIS_POINTS));
        }
    }

    function _calculateDynamicSpread(
        uint256 baseSpreadBps,
        uint256 volatilityMultiplier,
        uint256 maxSpreadBps,
        uint256 currentVolatility
    ) internal pure returns (uint256) {
        // Convert volatility from basis points to percentage
        uint256 volatilityPct = currentVolatility / 100;

        // Calculate volatility impact
        uint256 volatilityImpact = volatilityPct.mulDiv(volatilityMultiplier, 100);
        // Add to base spread
        uint256 dynamicSpread = baseSpreadBps.rawAdd(volatilityImpact);

        // Cap at maximum spread
        return dynamicSpread.min(maxSpreadBps);
    }

    function previewSpread(
        address tokenA, // From order.makerAsset or order.takerAsset
        uint256 baseSpreadBps,
        uint256 volatilityMultiplier,
        uint256 maxSpreadBps
    ) external view returns (uint256 currentVolatility, uint256 dynamicSpread) {
        currentVolatility = _getTokenVolatility(tokenA);
        dynamicSpread = _calculateDynamicSpread(baseSpreadBps, volatilityMultiplier, maxSpreadBps, currentVolatility);
    }

    function validateSpreadParams(uint256 baseSpreadBps, uint256 _volatilityMultiplier, uint256 maxSpreadBps)
        public
        pure
        returns (bool)
    {
        if (baseSpreadBps > MAX_SPREAD) return false;
        if (maxSpreadBps > MAX_SPREAD) return false;
        if (_volatilityMultiplier > 1000) return false;
        return true;
    }

    function _getTokenVolatility(address token) internal view returns (uint256) {
        return _pythStorage.getTokenVolatility(token);
    }

    function updatePriceHistory(address[] calldata token) external {
        _pythStorage.updatePriceHistory(token);
    }

    function addTokenFeeds(
        address[] calldata tokens,
        bytes32[] calldata priceFeeds,
        bool[] calldata isStablecoin,
        uint256[] calldata volatilityOverrides
    ) external {
        if (msg.sender != admin) RestrictedOperation.selector.revertWith();
        _pythStorage.setUpTokenFeeds(tokens, priceFeeds, isStablecoin, volatilityOverrides);
    }
}
