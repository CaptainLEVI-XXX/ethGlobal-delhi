// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AddressLib, Address} from "./libraries/AddressLib.sol";
import {MakerTraits, MakerTraitsLib} from "./libraries/MakerTraitLib.sol";

interface ILimitOrderProtocol {
    struct Order {
        uint256 salt;
        Address maker;
        Address receiver;
        Address makerAsset;
        Address takerAsset;
        uint256 makingAmount;
        uint256 takingAmount;
        MakerTraits makerTraits;
    }

    function fillOrderArgs(
        Order calldata order,
        bytes32 r,
        bytes32 vs,
        uint256 amount,
        uint256 takerTraits,
        bytes calldata fillOrderArgs
    ) external payable returns (uint256, uint256, bytes32);

    function hashOrder(Order calldata order) external view returns (bytes32);
}
