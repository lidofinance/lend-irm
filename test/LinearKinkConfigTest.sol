// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LinearKinkConfig} from "../src/linear-kink-irm/LinearKinkConfig.sol";
import {LinearKinkParams} from "../src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";
import {ErrorsLib} from "../src/linear-kink-irm/libraries/ErrorsLib.sol";

import "../lib/forge-std/src/Test.sol";

contract LinearKinkConfigTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_BORROW_RATE = 8.0 ether / uint256(365 days);

    function _defaultParams() internal pure returns (LinearKinkParams memory) {
        return LinearKinkParams({optimalUtilization: 0.9 ether, baseRate: 1e9, slope1: 4e9, slope2: 60e9});
    }

    function test_constructorStoresFourImmutablesAndGetterRoundTrips() public {
        LinearKinkParams memory p = _defaultParams();
        LinearKinkConfig config = new LinearKinkConfig(p);

        assertEq(config.OPTIMAL_UTILIZATION(), p.optimalUtilization);
        assertEq(config.BASE_RATE(), p.baseRate);
        assertEq(config.SLOPE1(), p.slope1);
        assertEq(config.SLOPE2(), p.slope2);

        LinearKinkParams memory returned = config.getKinkParams();
        assertEq(returned.optimalUtilization, p.optimalUtilization);
        assertEq(returned.baseRate, p.baseRate);
        assertEq(returned.slope1, p.slope1);
        assertEq(returned.slope2, p.slope2);
    }

    function test_constructorRevertsOnZeroOptimalUtilization() public {
        LinearKinkParams memory p = _defaultParams();
        p.optimalUtilization = 0;

        vm.expectRevert(bytes(ErrorsLib.INVALID_OPTIMAL_UTILIZATION));
        new LinearKinkConfig(p);
    }

    function test_constructorRevertsOnFullOptimalUtilization() public {
        LinearKinkParams memory p = _defaultParams();
        p.optimalUtilization = uint64(WAD);

        vm.expectRevert(bytes(ErrorsLib.INVALID_OPTIMAL_UTILIZATION));
        new LinearKinkConfig(p);
    }

    function test_constructorRevertsWhenPeakRateExceedsMax() public {
        LinearKinkParams memory p = _defaultParams();
        p.slope2 = uint64(MAX_BORROW_RATE);

        vm.expectRevert(bytes(ErrorsLib.MAX_RATE_EXCEEDED));
        new LinearKinkConfig(p);
    }

    function test_constructorAcceptsPeakRateAtMax() public {
        LinearKinkParams memory p = _defaultParams();
        p.baseRate = 0;
        p.slope1 = 0;
        p.slope2 = uint64(MAX_BORROW_RATE);

        LinearKinkConfig config = new LinearKinkConfig(p);
        assertEq(config.SLOPE2(), MAX_BORROW_RATE);
    }
}
