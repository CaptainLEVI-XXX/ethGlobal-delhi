// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {IFlashBlockNumber} from "./interfaces/IFlashBlock.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";

// Taxe incoming assets on first swap per flashblock, donates all to LPs
// Tax currency and fee units are configurable per pool during initialization
contract MEVTaxHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;

    error DynamicFeeNotEnabled();

    struct PoolConfig {
        Currency taxCurrency; // Which currency to collect taxes in
        uint256 swapFeeUnit; // Fee unit for MEV tax calculation
        uint256 jitFeeUnit; // Fee unit for JIT tax calculation
        uint256 priorityThreshold; // Minimum priority fee to trigger tax
    }

    // Default configuration values
    uint256 public constant DEFAULT_SWAP_FEE_UNIT = 1000 wei;
    uint256 public constant DEFAULT_JIT_FEE_UNIT = 4000 wei; // 4x higher for JIT
    uint256 public constant DEFAULT_PRIORITY_THRESHOLD = 1 gwei;

    IFlashBlockNumber public immutable flashBlockProvider;
    mapping(PoolId => uint256) private lastTaxedBlock;
    mapping(PoolId => PoolConfig) public poolConfig;

    constructor(IPoolManager _manager, IFlashBlockNumber _flashBlockProvider) BaseHook(_manager) {
        flashBlockProvider = _flashBlockProvider;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function customizePoolConfig(PoolKey calldata key, bytes calldata hookData) external {
        PoolId poolId = key.toId();

        // Default configuration
        PoolConfig memory config = PoolConfig({
            taxCurrency: key.currency0,
            swapFeeUnit: DEFAULT_SWAP_FEE_UNIT,
            jitFeeUnit: DEFAULT_JIT_FEE_UNIT,
            priorityThreshold: DEFAULT_PRIORITY_THRESHOLD
        });

        // Parse custom configuration from hookData if provided
        if (hookData.length > 0) {
            _parseHookData(key, hookData, config);
        }

        poolConfig[poolId] = config;
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) DynamicFeeNotEnabled.selector.revertWith();

        poolConfig[key.toId()] = PoolConfig({
            taxCurrency: key.currency0,
            swapFeeUnit: DEFAULT_SWAP_FEE_UNIT,
            jitFeeUnit: DEFAULT_JIT_FEE_UNIT,
            priorityThreshold: DEFAULT_PRIORITY_THRESHOLD
        });

        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolConfig memory config = poolConfig[poolId];
        uint256 currentBlock = _getCurrentBlock();

        // Only tax first swap per flashblock
        if (currentBlock == lastTaxedBlock[poolId]) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 priorityFee = _getPriorityFee();
        if (priorityFee < config.priorityThreshold) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Calculate MEV tax: (priorityFee - threshold) * feeUnit
        uint256 swapTax;
        unchecked {
            swapTax = (priorityFee - config.priorityThreshold) * config.swapFeeUnit;
        }

        if (swapTax == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Donate first (creates debt), then return delta to collect from user
        if (config.taxCurrency == key.currency0) {
            poolManager.donate(key, swapTax, 0, "");
        } else {
            poolManager.donate(key, 0, swapTax, "");
        }

        lastTaxedBlock[poolId] = currentBlock;

        // Return delta based on tax currency and swap direction
        return _getSwapTaxDelta(params, config.taxCurrency, key, swapTax);
    }

    function _parseHookData(PoolKey calldata key, bytes calldata hookData, PoolConfig memory config) private pure {
        if (hookData.length >= 32) {
            // First 32 bytes: tax currency address
            Currency specified = Currency.wrap(abi.decode(hookData[:32], (address)));
            if (specified == key.currency0 || specified == key.currency1) {
                config.taxCurrency = specified;
            }
        }

        if (hookData.length >= 64) {
            // Next 32 bytes: swap fee unit
            uint256 swapFeeUnit = abi.decode(hookData[32:64], (uint256));
            if (swapFeeUnit > 0) {
                config.swapFeeUnit = swapFeeUnit;
            }
        }

        if (hookData.length >= 96) {
            // Next 32 bytes: jit fee unit
            uint256 jitFeeUnit = abi.decode(hookData[64:96], (uint256));
            if (jitFeeUnit > 0) {
                config.jitFeeUnit = jitFeeUnit;
            }
        }

        if (hookData.length >= 128) {
            // Next 32 bytes: priority threshold
            uint256 priorityThreshold = abi.decode(hookData[96:128], (uint256));
            config.priorityThreshold = priorityThreshold;
        }
    }

    function _getCurrentBlock() private view returns (uint256) {
        return address(flashBlockProvider) != address(0) ? flashBlockProvider.getFlashblockNumber() : block.number;
    }

    function _getSwapTaxDelta(
        IPoolManager.SwapParams calldata params,
        Currency taxCurrency,
        PoolKey calldata key,
        uint256 swapTax
    ) private pure returns (bytes4, BeforeSwapDelta, uint24) {
        if (params.zeroForOne) {
            // User selling currency0
            if (taxCurrency == key.currency0) {
                // Tax same currency user is selling
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(swapTax)), 0), 0);
            } else {
                // Tax different currency (user buying)
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, int128(uint128(swapTax))), 0);
            }
        } else {
            // User selling currency1
            if (taxCurrency == key.currency1) {
                // Tax same currency user is selling
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, int128(uint128(swapTax))), 0);
            } else {
                // Tax different currency (user buying)
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(swapTax)), 0), 0);
            }
        }
    }

    function _getPriorityFee() private view returns (uint256) {
        unchecked {
            return tx.gasprice - block.basefee;
        }
    }
}
