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
import {console} from "forge-std/console.sol";

// Taxe incoming assets on first swap per flashblock, donates all to LPs
// Tax currency and fee units are configurable per pool during initialization
// intended to be used with L2 Blockchain (OP stacks chain)
contract MEVTaxingHookL2 is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;

    error DynamicFeeNotEnabled();
    error Unauthorized();

    struct PoolConfig {
        Currency taxCurrency; // Which currency to collect taxes in
        uint256 swapFeeUnit; // Fee unit for MEV tax calculation
        uint256 jitFeeUnit; // Fee unit for JIT tax calculation
        uint256 priorityThreshold; // Minimum priority fee to trigger tax
    }

    // Default configuration values
    /// @notice these params need to be battled tested
    uint256 public constant DEFAULT_SWAP_FEE_UNIT = 1 wei;
    uint256 public constant DEFAULT_JIT_FEE_UNIT = 4 wei; // 4x higher for JIT
    uint256 public constant DEFAULT_PRIORITY_THRESHOLD = 10 wei;

    IFlashBlockNumber public immutable flashBlockProvider;
    address public admin;
    // mapping(PoolId => uint256) private lastTaxedBlock;
    // Track only when SWAPS are taxed (indicates "top of block" activity)
    mapping(PoolId => uint256) private lastSwapTaxedBlock;
    mapping(PoolId => PoolConfig) public poolConfig;

    constructor(IPoolManager _manager, IFlashBlockNumber _flashBlockProvider, address _admin) BaseHook(_manager) {
        flashBlockProvider = _flashBlockProvider;
        admin = _admin;
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

    function setPoolConfig(PoolId poolId, PoolConfig memory config) external {
        if (msg.sender != admin) Unauthorized.selector.revertWith();
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

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolConfig memory config = poolConfig[poolId];
        uint256 currentBlock = _getCurrentBlock();
        uint256 priorityFee = _getPriorityFee();

        // Only tax first swap per flashblock
        if (currentBlock == lastSwapTaxedBlock[poolId] || priorityFee < config.priorityThreshold) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Calculate and apply swap tax
        uint256 swapTax = (priorityFee - config.priorityThreshold) * config.swapFeeUnit;

        if (swapTax > 0) {
            // Donate and collect tax
            if (config.taxCurrency == key.currency0) {
                poolManager.donate(key, swapTax, 0, "");
                lastSwapTaxedBlock[poolId] = currentBlock; // Only update for swaps!
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(swapTax)), 0), 0);
            } else {
                poolManager.donate(key, 0, swapTax, "");
                lastSwapTaxedBlock[poolId] = currentBlock; // Only update for swaps!
                return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, int128(int256(swapTax))), 0);
            }
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        PoolConfig memory config = poolConfig[poolId];
        uint256 currentBlock = _getCurrentBlock();

        // Tax JIT liquidity ONLY if no swap has been taxed yet in this block
        // (meaning this liquidity is being added at the "top" of the block)
        if (currentBlock == lastSwapTaxedBlock[poolId]) {
            // A swap already happened in this block - this is normal liquidity, not JIT
            return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        uint256 priorityFee = _getPriorityFee();
        if (priorityFee < config.priorityThreshold) {
            return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        // Calculate JIT tax (4x higher than swap tax)
        uint256 jitTax = (priorityFee - config.priorityThreshold) * config.jitFeeUnit;

        if (jitTax > 0) {
            // return the delta - PoolManager handles collection

            // Send tax to admin
            poolManager.take(config.taxCurrency, admin, jitTax);

            // Return positive delta = LP must pay extra
            if (config.taxCurrency == key.currency0) {
                return (this.afterAddLiquidity.selector, toBalanceDelta(int128(uint128(jitTax)), 0));
            } else {
                return (this.afterAddLiquidity.selector, toBalanceDelta(0, int128(uint128(jitTax))));
            }
        }

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _getCurrentBlock() private view returns (uint256) {
        return address(flashBlockProvider) != address(0) ? flashBlockProvider.getFlashblockNumber() : block.number;
    }

    function _getPriorityFee() private view returns (uint256) {
        unchecked {
            return tx.gasprice - block.basefee;
        }
    }
}
