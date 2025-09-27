// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {OneInchDynamicOrder} from "../src/1inchDynamicOrder.sol";
import {IOrderMixin} from "../src/interfaces/IAmountGetter.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {AddressLib, Address} from "../src/libraries/AddressLib.sol";
import {MakerTraits, MakerTraitsLib} from "../src/libraries/MakerTraitLib.sol";
import {ILimitOrderProtocol} from "../src/interfaces/ILimitOrderProtocol.sol";
// interface ILimitOrderProtocol {
//     struct Order {
//         uint256 salt;
//         Address maker;
//         Address receiver;
//         Address makerAsset;
//         Address takerAsset;
//         uint256 makingAmount;
//         uint256 takingAmount;
//         MakerTraits makerTraits;
//     }

//     function fillOrderArgs(
//         Order calldata order,
//         bytes32 r,
//         bytes32 vs,
//         uint256 amount,
//         uint256 takerTraits,
//         bytes calldata fillOrderArgs
//     ) external payable returns (uint256, uint256, bytes32);

//     function hashOrder(Order calldata order) external view returns (bytes32);
// }

contract OneInchHelper is Test {
    using SafeTransferLib for address;
    using MakerTraitsLib for MakerTraits;

    // ============ CONSTANTS ============
    uint256 public constant MAINNET_FORK_BLOCK = 23020785;

    // Mainnet tokens
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // 1inch Limit Order Protocol V4 Mainnet address
    ILimitOrderProtocol public constant LIMIT_ORDER_PROTOCOL =
        ILimitOrderProtocol(0x111111125421cA6dc452d289314280a0f8842A65);

    address public constant PYTH_ORACLE = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    // 1inch Protocol Flags
    uint256 public constant HAS_EXTENSION_FLAG = 1 << 249;
    uint256 public constant ALLOW_MULTIPLE_FILLS_FLAG = 1 << 254;

    // Volatility spread extension instance
    OneInchDynamicOrder public oneInchDynamicOrder;

    // Test accounts private keys (doesn't exist on mainent)
    uint256 _alicePrivateKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 _bobPrivateKey = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    address public alice;
    address public bob;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), MAINNET_FORK_BLOCK);

        alice = vm.addr(_alicePrivateKey);
        bob = vm.addr(_bobPrivateKey);

        oneInchDynamicOrder = new OneInchDynamicOrder(address(this), PYTH_ORACLE);

        // Fund alice and bob
        _deal(alice);
        _deal(bob);

        // Approvals for the Limit Order Protocol
        _approve(alice);
        _approve(bob);

        // Setup volatility feeds (dummy setup for test)
        _setUpInitializationData();
    }

    function _buildOrderWithVolatilitySpread(
        address maker,
        address makerAsset,
        address takerAsset,
        uint256 makingAmount,
        uint256 takingAmount,
        OneInchDynamicOrder.SpreadParams memory spreadParams
    ) internal view returns (ILimitOrderProtocol.Order memory order, bytes memory extension, uint256 takerTraits) {
        // Encode parameters using ABI encoding
        bytes memory encodedParams = abi.encode(spreadParams);

        // Build getter data: just address, the protocol will append selector + params
        bytes memory makingAmountData = abi.encodePacked(address(oneInchDynamicOrder), encodedParams);
        bytes memory takingAmountData = abi.encodePacked(address(oneInchDynamicOrder), encodedParams);

        // Calculate cumulative offsets for each extension
        uint256 offset1 = makingAmountData.length;
        uint256 offset2 = offset1 + takingAmountData.length;

        // Pack offsets as one uint256 (8 x uint32)
        uint256 packedOffsets = (uint256(0) << (32 * 0)) // makerAssetSuffix offset
            | (uint256(0) << (32 * 1)) // takerAssetSuffix offset
            | (uint256(offset1) << (32 * 2)) // makingAmountGetter offset
            | (uint256(offset2) << (32 * 3)) // takingAmountGetter offset
            | (uint256(offset2) << (32 * 4)) // predicate offset
            | (uint256(offset2) << (32 * 5)) // permit offset
            | (uint256(offset2) << (32 * 6)) // preInteraction offset
            | (uint256(offset2) << (32 * 7)); // postInteraction offset

        // Build extension: offsets (32 bytes) + data
        extension = abi.encodePacked(bytes32(packedOffsets), makingAmountData, takingAmountData);

        // Calculate salt
        uint256 extensionHash = uint256(keccak256(extension)) & ((1 << 160) - 1);
        uint256 randomSalt = uint256(keccak256(abi.encodePacked(block.timestamp, maker, makingAmount))) >> 160;
        uint256 salt = (randomSalt << 160) | extensionHash;

        // Build maker traits
        uint256 makerTraitsValue = HAS_EXTENSION_FLAG | ALLOW_MULTIPLE_FILLS_FLAG;

        order = ILimitOrderProtocol.Order({
            salt: salt,
            maker: Address.wrap(uint160(maker)),
            receiver: Address.wrap(uint160(maker)),
            makerAsset: Address.wrap(uint160(makerAsset)),
            takerAsset: Address.wrap(uint160(takerAsset)),
            makingAmount: makingAmount,
            takingAmount: takingAmount,
            makerTraits: MakerTraits.wrap(makerTraitsValue)
        });

        // Build taker traits
        uint256 makerAmountFlag = 1 << 255;
        uint256 extensionLengthBits = uint256(extension.length) << 224;
        takerTraits = makerAmountFlag | extensionLengthBits;
    }

    function _signOrder(ILimitOrderProtocol.Order memory order, uint256 privateKey)
        internal
        view
        returns (bytes32 r, bytes32 vs)
    {
        bytes32 orderHash = LIMIT_ORDER_PROTOCOL.hashOrder(order);
        (uint8 v, bytes32 r_, bytes32 s) = vm.sign(privateKey, orderHash);

        // Pack v and s into vs according to 1inch format
        vs = bytes32((uint256(v - 27) << 255) | uint256(s));
        r = r_;
    }

    function test_fullorderflow_with_volatility_spread() public {
        OneInchDynamicOrder.SpreadParams memory params = OneInchDynamicOrder.SpreadParams({
            baseSpreadBps: 50,
            multiplier: 200,
            maxSpreadBps: 200,
            useMakerAsset: true
        });

        (ILimitOrderProtocol.Order memory order, bytes memory extension, uint256 takerTraits) =
            _buildOrderWithVolatilitySpread(alice, WETH, USDC, 1 ether, 3000 * 1e6, params);

        (bytes32 r, bytes32 vs) = _signOrder(order, _alicePrivateKey);

        // Verify extension hash
        uint256 expectedHash = uint256(keccak256(extension)) & ((1 << 160) - 1);
        uint256 saltHash = order.salt & ((1 << 160) - 1);
        assertEq(expectedHash, saltHash, "Extension hash mismatch");

        // Record balances before fill
        uint256 aliceWethBefore = WETH.balanceOf(alice);
        uint256 aliceUsdcBefore = USDC.balanceOf(alice);
        uint256 bobWethBefore = WETH.balanceOf(bob);
        uint256 bobUsdcBefore = USDC.balanceOf(bob);

        // Perform order fill as Bob (taker)
        vm.prank(bob);
        (uint256 makingAmount, uint256 takingAmount,) = LIMIT_ORDER_PROTOCOL.fillOrderArgs(
            order,
            r,
            vs,
            1 ether, // Fill exact making amount
            takerTraits,
            extension // Pass the extension as args
        );

        // Verify balances updated correctly
        assertEq(WETH.balanceOf(alice), aliceWethBefore - makingAmount, "Alice WETH balance incorrect");
        assertEq(USDC.balanceOf(alice), aliceUsdcBefore + takingAmount, "Alice USDC balance incorrect");
        assertEq(WETH.balanceOf(bob), bobWethBefore + makingAmount, "Bob WETH balance incorrect");
        assertEq(USDC.balanceOf(bob), bobUsdcBefore - takingAmount, "Bob USDC balance incorrect");

        // Verify spread was applied
        uint256 baseAmount = 3000 * 1e6;
        require(takingAmount >= baseAmount, "Taking amount should be >= base");

        uint256 actualSpreadBps = ((takingAmount - baseAmount) * 10000) / baseAmount;
        console.log("Actual spread applied (bps):", actualSpreadBps);

        console.log("\nOrder filled successfully with volatility spread!");
    }

    function _deal(address user) internal {
        deal(WETH, user, 100 ether);
        deal(USDC, user, 1_000_000 * 1e6);
    }

    function _approve(address user) internal {
        vm.startPrank(user);
        WETH.safeApprove(address(LIMIT_ORDER_PROTOCOL), type(uint256).max);
        USDC.safeApprove(address(LIMIT_ORDER_PROTOCOL), type(uint256).max);
        vm.stopPrank();
    }

    function _setUpInitializationData() internal {
        // Setup volatility feeds (dummy setup for test)
        address[] memory tokens = new address[](3);
        bytes32[] memory priceFeeds = new bytes32[](3);
        bool[] memory isStablecoin = new bool[](3);
        uint256[] memory volatilityOverrides = new uint256[](3);

        tokens[0] = WETH;
        priceFeeds[0] = 0x9d4294bbcd1174d6f2003ec365831e64cc31d9f6f15a2b85399db8d5000960f6;
        isStablecoin[0] = false;
        volatilityOverrides[0] = 2000; // 20% for testing

        tokens[1] = USDC;
        priceFeeds[1] = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
        isStablecoin[1] = true;
        volatilityOverrides[1] = 0; // use default

        tokens[2] = DAI;
        priceFeeds[2] = 0x0;
        isStablecoin[2] = true;
        volatilityOverrides[2] = 0;

        oneInchDynamicOrder.addTokenFeeds(tokens, priceFeeds, isStablecoin, volatilityOverrides);
    }
}
