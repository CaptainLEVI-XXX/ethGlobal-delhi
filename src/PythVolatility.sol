// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPyth} from "lib/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";

library PythVolatilityLib {
    using FixedPointMathLib for uint256;
    using CustomRevert for bytes4;

    struct VolatilityStorage {
        IPyth pythOracle;
        mapping(address => TokenConfig) tokenConfigs;
        mapping(address => PriceHistory) priceHistories;
    }

    struct TokenConfig {
        bytes32 pythPriceId;
        uint256 volatilityOverride; // Manual override (0 = calculate)
        bool isStablecoin;
        bool isSupported;
    }

    struct PriceHistory {
        uint256[24] hourlyPrices; // 24 hours of price data
        uint256 lastUpdate;
        uint8 currentIndex;
        uint8 dataPoints; // Track valid data points
    }

    uint256 public constant STABLECOIN_VOLATILITY = 100; // 1%
    uint256 public constant DEFAULT_VOLATILITY = 100; // 1%
    uint256 public constant VOLATILITY_SCALE = 10000; // Basis points

    error TokenNotSupported();
    error InvalidPrice();

    function setPythOracle(VolatilityStorage storage self, address _pythOracle) internal {
        self.pythOracle = IPyth(_pythOracle);
    }

    function setUpTokenFeeds(
        VolatilityStorage storage self,
        address[] calldata tokens,
        bytes32[] calldata pythPriceIds,
        bool[] calldata isStableCoin,
        uint256[] calldata volatilityOverrides
    ) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            self.tokenConfigs[tokens[i]] = TokenConfig({
                pythPriceId: pythPriceIds[i],
                volatilityOverride: volatilityOverrides[i],
                isStablecoin: isStableCoin[i],
                isSupported: true
            });
        }
    }

    function getTokenVolatility(VolatilityStorage storage self, address token) internal view returns (uint256) {
        TokenConfig memory config = self.tokenConfigs[token];
        if (!config.isSupported) TokenNotSupported.selector.revertWith();

        // Check override
        if (config.volatilityOverride > 0) {
            return config.volatilityOverride;
        }

        // Stablecoins have fixed low volatility
        if (config.isStablecoin) {
            return STABLECOIN_VOLATILITY;
        }

        // Calculate from price history
        PriceHistory storage history = self.priceHistories[token];

        // Need at least 12 data points
        if (history.dataPoints < 12) {
            return DEFAULT_VOLATILITY;
        }

        return _calculateVolatility(history);
    }

    function _calculateVolatility(PriceHistory storage history) private view returns (uint256) {
        uint256 sumReturns = 0;
        uint256 sumSquaredReturns = 0;
        uint256 validSamples = 0;

        // Calculate returns between consecutive prices
        for (uint256 i = 1; i < history.dataPoints; i++) {
            uint256 prevIdx = (history.currentIndex + 24 - history.dataPoints + i - 1) % 24;
            uint256 currIdx = (history.currentIndex + 24 - history.dataPoints + i) % 24;

            uint256 prevPrice = history.hourlyPrices[prevIdx];
            uint256 currPrice = history.hourlyPrices[currIdx];

            if (prevPrice == 0 || currPrice == 0) continue;

            // Calculate return in basis points
            uint256 return_ = currPrice.mulDiv(VOLATILITY_SCALE, prevPrice);
            if (return_ > VOLATILITY_SCALE) {
                return_ = return_ - VOLATILITY_SCALE;
            } else {
                return_ = VOLATILITY_SCALE - return_;
            }

            sumReturns += return_;
            sumSquaredReturns += return_ * return_;
            validSamples++;
        }

        if (validSamples < 2) return DEFAULT_VOLATILITY;

        // Calculate standard deviation
        uint256 meanReturn = sumReturns / validSamples;
        uint256 variance = sumSquaredReturns / validSamples - (meanReturn * meanReturn);

        return variance.sqrt();
    }

    function updatePriceHistory(VolatilityStorage storage self, address[] calldata tokens) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            TokenConfig memory config = self.tokenConfigs[token];
            if (!config.isSupported) continue;

            PriceHistory storage history = self.priceHistories[token];

            // Update hourly (skip if less than 1 hour since last update)
            if (block.timestamp < history.lastUpdate + 1 hours) continue;

            // Get price from Pyth
            PythStructs.Price memory pythPrice = self.pythOracle.getPriceUnsafe(config.pythPriceId);
            if (pythPrice.price <= 0) InvalidPrice.selector.revertWith();

            // Convert to uint256 (handle negative exponent for decimals)
            uint256 price = uint256(uint64(pythPrice.price));
            if (pythPrice.expo < 0) {
                price = price / (10 ** uint256(uint32(-pythPrice.expo)));
            }

            // Store in circular buffer
            history.hourlyPrices[history.currentIndex] = price;
            history.currentIndex = uint8((history.currentIndex + 1) % 24);

            if (history.dataPoints < 24) {
                history.dataPoints++;
            }

            history.lastUpdate = block.timestamp;
        }
    }
}
