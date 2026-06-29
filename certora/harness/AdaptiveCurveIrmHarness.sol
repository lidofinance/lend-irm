// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {AdaptiveCurveIrm} from "../../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {Id, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";

// Verifies AdaptiveCurveIrm through a subclass. The curve parameters live in a per-market MarketConfig that the IRM
// reads through an external `getConfig()` static call; a spec links a MarketConfig, requires it is the one registered
// for the market (`configOf`), and constrains its `getConfig()` to satisfy the validation bounds.
contract AdaptiveCurveIrmHarness is AdaptiveCurveIrm {
    using MarketParamsLib for MarketParams;

    constructor(address morpho, address owner) AdaptiveCurveIrm(morpho, owner) {}

    /// @dev The stored rateAtTarget for `marketParams`, so a spec can read it before/after a call.
    function rateAtTargetOf(MarketParams memory marketParams) external view returns (int256) {
        return rateAtTarget[marketParams.id()];
    }

    /// @dev The MarketConfig set for `marketParams`, so a spec can pin it to the linked config.
    function configOf(MarketParams memory marketParams) external view returns (address) {
        return address(marketConfig[marketParams.id()]);
    }
}
