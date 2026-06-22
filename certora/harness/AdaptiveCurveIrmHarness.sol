// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {AdaptiveCurveIrm} from "../../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {Id, MarketParams} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";

// Verifies AdaptiveCurveIrm through a subclass so the Prover runs the (forwarded) constructor: that runs
// `_validateConfig` and sets the curve immutables from a symbolic Config, instead of pinning them to 0.
contract AdaptiveCurveIrmHarness is AdaptiveCurveIrm {
    using MarketParamsLib for MarketParams;

    constructor(address morpho, Config memory cfg) AdaptiveCurveIrm(morpho, cfg) {}

    /// @dev The stored rateAtTarget for `marketParams`, so a spec can read it before/after a call.
    function rateAtTargetOf(MarketParams memory marketParams) external view returns (int256) {
        return rateAtTarget[marketParams.id()];
    }
}
