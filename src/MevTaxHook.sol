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
}
