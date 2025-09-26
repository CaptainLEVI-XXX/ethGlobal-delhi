// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOrderMixin, IAmountGetter} from "./interfaces/IAmountGetter.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {AddressLib, Address} from "./libraries/AddressLib.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {PythVolatilityLib} from "./PythVolatility.sol";

abstract contract OneInchDynamicOrder is IAmountGetter {}
