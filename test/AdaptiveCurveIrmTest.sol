// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {ConstantsLib} from "./ConstantsLib.sol";

import "../lib/forge-std/src/Test.sol";

contract AdaptiveCurveIrmTest is Test {
    using MathLib for int256;
    using MathLib for uint256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MorphoMathLib for uint256;
    using MarketParamsLib for MarketParams;

    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    IAdaptiveCurveIrm internal irm;
    MarketParams internal marketParams = MarketParams({
        loanToken: address(0), collateralToken: address(0), oracle: address(0), irm: address(0), lltv: 0
    });

    function setUp() public {
        irm = new AdaptiveCurveIrm(address(this), _defaultConfig());
        vm.warp(90 days);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = AdaptiveCurveIrmTest.handleBorrowRate.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    /* TESTS */

    function testDeployment() public {
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        new AdaptiveCurveIrm(address(0), _defaultConfig());
    }

    function testDeploymentExposesImmutableParams() public {
        AdaptiveCurveIrm.Config memory cfg = _defaultConfig();
        AdaptiveCurveIrm deployed = new AdaptiveCurveIrm(address(this), cfg);

        assertEq(deployed.CURVE_STEEPNESS(), cfg.curveSteepness, "curveSteepness");
        assertEq(deployed.ADJUSTMENT_SPEED(), cfg.adjustmentSpeed, "adjustmentSpeed");
        assertEq(deployed.TARGET_UTILIZATION(), cfg.targetUtilization, "targetUtilization");
        assertEq(deployed.INITIAL_RATE_AT_TARGET(), cfg.initialRateAtTarget, "initialRateAtTarget");
        assertEq(deployed.MIN_RATE_AT_TARGET(), cfg.minRateAtTarget, "minRateAtTarget");
        assertEq(deployed.MAX_RATE_AT_TARGET(), cfg.maxRateAtTarget, "maxRateAtTarget");
        assertEq(deployed.MAX_BORROW_RATE(), cfg.maxBorrowRate, "maxBorrowRate");

        AdaptiveCurveIrm.Config memory got = deployed.getConfig();
        assertEq(got.curveSteepness, cfg.curveSteepness, "getConfig.curveSteepness");
        assertEq(got.maxRateAtTarget, cfg.maxRateAtTarget, "getConfig.maxRateAtTarget");
        assertEq(got.maxBorrowRate, cfg.maxBorrowRate, "getConfig.maxBorrowRate");
    }

    function testDeploymentRevertsOnInvalidParams() public {
        AdaptiveCurveIrm.Config memory cfg;

        cfg = _defaultConfig();
        cfg.curveSteepness = WAD - 1; // < 1e18
        _expectRevert(cfg, ErrorsLib.INVALID_CURVE_STEEPNESS);

        cfg = _defaultConfig();
        cfg.adjustmentSpeed = -1; // < 0
        _expectRevert(cfg, ErrorsLib.INVALID_ADJUSTMENT_SPEED);

        cfg = _defaultConfig();
        cfg.targetUtilization = 0; // <= 0
        _expectRevert(cfg, ErrorsLib.INVALID_TARGET_UTILIZATION);

        cfg = _defaultConfig();
        cfg.targetUtilization = WAD; // >= 1e18
        _expectRevert(cfg, ErrorsLib.INVALID_TARGET_UTILIZATION);

        cfg = _defaultConfig();
        cfg.minRateAtTarget = 0; // <= 0
        _expectRevert(cfg, ErrorsLib.INVALID_RATE_BOUNDS);

        cfg = _defaultConfig();
        cfg.maxRateAtTarget = cfg.minRateAtTarget - 1; // < min
        _expectRevert(cfg, ErrorsLib.INVALID_RATE_BOUNDS);

        cfg = _defaultConfig();
        cfg.initialRateAtTarget = cfg.minRateAtTarget - 1; // < min
        _expectRevert(cfg, ErrorsLib.INVALID_INITIAL_RATE);

        cfg = _defaultConfig();
        cfg.initialRateAtTarget = cfg.maxRateAtTarget + 1; // > max
        _expectRevert(cfg, ErrorsLib.INVALID_INITIAL_RATE);

        cfg = _defaultConfig();
        cfg.maxBorrowRate = -1; // < 0
        _expectRevert(cfg, ErrorsLib.INVALID_MAX_BORROW_RATE);
    }

    function testMaxBorrowRateClampsChargedRate() public {
        AdaptiveCurveIrm.Config memory cfg = _defaultConfig();
        uint256 tip = uint256(ConstantsLib.INITIAL_RATE_AT_TARGET.wMulToZero(ConstantsLib.CURVE_STEEPNESS));
        cfg.maxBorrowRate = int256(tip) / 2; // cap below the tip
        AdaptiveCurveIrm capped = new AdaptiveCurveIrm(address(this), cfg);

        Market memory market;
        market.totalBorrowAssets = 1 ether;
        market.totalSupplyAssets = 1 ether;

        assertEq(irm.borrowRateView(marketParams, market), tip, "uncapped charges the full tip");
        assertEq(capped.borrowRateView(marketParams, market), uint256(cfg.maxBorrowRate), "charged rate clamped");
    }

    function testMaxBorrowRateDoesNotAffectRateAtTarget() public {
        AdaptiveCurveIrm.Config memory cfg = _defaultConfig();
        cfg.maxBorrowRate = int256(ConstantsLib.INITIAL_RATE_AT_TARGET); // well below the high-util tip
        AdaptiveCurveIrm capped = new AdaptiveCurveIrm(address(this), cfg);

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = 0.98 ether;
        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + 5 days);

        irm.borrowRate(marketParams, market);
        capped.borrowRate(marketParams, market);
        assertEq(
            capped.rateAtTarget(marketParams.id()),
            irm.rateAtTarget(marketParams.id()),
            "rateAtTarget adapts identically; the cap bounds only the charged rate"
        );
    }

    function testFuzz_validConfigInvariants(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        int256 maxBorrowRate,
        bool capEnabled,
        uint128 supply,
        uint128 borrowed,
        uint256 elapsed
    ) public {
        AdaptiveCurveIrm.Config memory cfg = _boundedConfig(
            curveSteepness, adjustmentSpeed, targetUtilization, minRate, maxRate, initialRate, maxBorrowRate, capEnabled
        );
        AdaptiveCurveIrm fuzzed = new AdaptiveCurveIrm(address(this), cfg);

        MarketParams memory mp;
        mp.irm = address(fuzzed);

        Market memory market;
        market.totalSupplyAssets = supply;
        market.totalBorrowAssets = uint128(bound(borrowed, 0, supply));

        // First interaction (rateAtTarget == 0 -> INITIAL_RATE_AT_TARGET).
        _assertConfigInvariants(fuzzed, mp, market, cfg);

        // Advance time so the next call exercises the adapting branch.
        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
        _assertConfigInvariants(fuzzed, mp, market, cfg);
    }

    function _boundedConfig(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        int256 maxBorrowRate,
        bool capEnabled
    ) internal view returns (AdaptiveCurveIrm.Config memory cfg) {
        int256 rateCeil = int256(10 ether) / int256(365 days); // 1000%/yr: generous but overflow-safe
        cfg.curveSteepness = bound(curveSteepness, WAD, int256(100 ether));
        cfg.adjustmentSpeed = bound(adjustmentSpeed, 0, int256(1000 ether) / int256(365 days));
        cfg.targetUtilization = bound(targetUtilization, 1, WAD - 1);
        cfg.minRateAtTarget = bound(minRate, 1, rateCeil);
        cfg.maxRateAtTarget = bound(maxRate, cfg.minRateAtTarget, rateCeil);
        cfg.initialRateAtTarget = bound(initialRate, cfg.minRateAtTarget, cfg.maxRateAtTarget);
        cfg.maxBorrowRate = capEnabled ? bound(maxBorrowRate, 1, int256(50 ether) / int256(365 days)) : int256(0);
    }

    function _assertConfigInvariants(
        AdaptiveCurveIrm fuzzed,
        MarketParams memory mp,
        Market memory market,
        AdaptiveCurveIrm.Config memory cfg
    ) internal {
        uint256 rateView = fuzzed.borrowRateView(mp, market);
        uint256 rate = fuzzed.borrowRate(mp, market);
        assertEq(rateView, rate, "borrowRateView == borrowRate");
        if (cfg.maxBorrowRate != 0) assertLe(rate, uint256(cfg.maxBorrowRate), "rate <= MAX_BORROW_RATE");
        int256 rat = fuzzed.rateAtTarget(mp.id());
        assertGe(rat, cfg.minRateAtTarget, "rateAtTarget >= MIN_RATE_AT_TARGET");
        assertLe(rat, cfg.maxRateAtTarget, "rateAtTarget <= MAX_RATE_AT_TARGET");
    }

    function testFuzz_curveMatchesConfigParametrizedOracle(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        int256 maxBorrowRate,
        bool capEnabled,
        uint128 supply0,
        uint128 borrowed0,
        uint128 supply1,
        uint128 borrowed1,
        uint256 elapsed
    ) public {
        AdaptiveCurveIrm.Config memory cfg = _boundedConfig(
            curveSteepness, adjustmentSpeed, targetUtilization, minRate, maxRate, initialRate, maxBorrowRate, capEnabled
        );
        AdaptiveCurveIrm fuzzed = new AdaptiveCurveIrm(address(this), cfg);
        MarketParams memory mp;
        mp.irm = address(fuzzed);
        Id id = mp.id();

        // First interaction sets rateAtTarget = INITIAL_RATE_AT_TARGET so the next call exercises the adapting path.
        Market memory m0;
        m0.totalSupplyAssets = supply0;
        m0.totalBorrowAssets = uint128(bound(borrowed0, 0, supply0));
        fuzzed.borrowRate(mp, m0);
        assertEq(fuzzed.rateAtTarget(id), cfg.initialRateAtTarget, "rateAtTarget = INITIAL after first interaction");

        // Adapting interaction against the config-parametrized oracle.
        Market memory m1;
        m1.totalSupplyAssets = supply1;
        m1.totalBorrowAssets = uint128(bound(borrowed1, 0, supply1));
        m1.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + bound(elapsed, 0, 365 days));

        (uint256 expRate, int256 expEnd) = _oracle(cfg, fuzzed.rateAtTarget(id), m1);

        uint256 gotView = fuzzed.borrowRateView(mp, m1);
        uint256 gotRate = fuzzed.borrowRate(mp, m1);

        assertEq(gotView, gotRate, "borrowRateView == borrowRate");
        assertEq(gotRate, expRate, "charged rate matches config-parametrized oracle");
        assertEq(fuzzed.rateAtTarget(id), expEnd, "rateAtTarget matches config-parametrized oracle");
    }

    function _oracle(AdaptiveCurveIrm.Config memory cfg, int256 start, Market memory market)
        internal
        view
        returns (uint256, int256)
    {
        int256 err = _oracleErr(market, cfg.targetUtilization);

        int256 avg;
        int256 end;
        if (start == 0) {
            avg = cfg.initialRateAtTarget;
            end = cfg.initialRateAtTarget;
        } else {
            int256 linearAdaptation = cfg.adjustmentSpeed.wMulToZero(err) * int256(block.timestamp - market.lastUpdate);
            if (linearAdaptation == 0) {
                avg = start;
                end = start;
            } else {
                end = _oracleNewRat(start, linearAdaptation, cfg.minRateAtTarget, cfg.maxRateAtTarget);
                int256 mid = _oracleNewRat(start, linearAdaptation / 2, cfg.minRateAtTarget, cfg.maxRateAtTarget);
                avg = (start + end + 2 * mid) / 4;
            }
        }

        uint256 rate = uint256(_oracleCurve(avg, err, cfg.curveSteepness));
        if (cfg.maxBorrowRate != 0 && rate > uint256(cfg.maxBorrowRate)) rate = uint256(cfg.maxBorrowRate);
        return (rate, end);
    }

    function _oracleErr(Market memory market, int256 targetUtilization) internal pure returns (int256) {
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);
        int256 errNormFactor = utilization > targetUtilization ? WAD - targetUtilization : targetUtilization;
        return (utilization - targetUtilization).wDivToZero(errNormFactor);
    }

    function _oracleCurve(int256 rateAtTarget, int256 err, int256 curveSteepness) internal pure returns (int256) {
        int256 coeff = err < 0 ? WAD - WAD.wDivToZero(curveSteepness) : curveSteepness - WAD;
        return (coeff.wMulToZero(err) + WAD).wMulToZero(rateAtTarget);
    }

    function _oracleNewRat(int256 start, int256 linearAdaptation, int256 minRate, int256 maxRate)
        internal
        pure
        returns (int256)
    {
        return start.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(minRate, maxRate);
    }

    /* CURVE EDGE CASES */

    function test_edge_steepnessOne_flatCurve() public {
        AdaptiveCurveIrm.Config memory cfg = _defaultConfig();
        cfg.curveSteepness = WAD;
        AdaptiveCurveIrm flat = new AdaptiveCurveIrm(address(this), cfg);
        MarketParams memory mp;
        mp.irm = address(flat);

        uint256 initial = uint256(ConstantsLib.INITIAL_RATE_AT_TARGET);
        assertEq(flat.borrowRateView(mp, _mkt(1 ether, 0)), initial, "util=0 is flat");
        assertEq(flat.borrowRateView(mp, _mkt(1 ether, 0.9 ether)), initial, "util=target is flat");
        assertEq(flat.borrowRateView(mp, _mkt(1 ether, 1 ether)), initial, "util=1 is flat");
    }

    function test_edge_zeroAdjustmentSpeed_neverAdapts() public {
        AdaptiveCurveIrm.Config memory cfg = _defaultConfig();
        cfg.adjustmentSpeed = 0;
        AdaptiveCurveIrm fixedIrm = new AdaptiveCurveIrm(address(this), cfg);
        MarketParams memory mp;
        mp.irm = address(fixedIrm);

        fixedIrm.borrowRate(mp, _mkt(1 ether, 0.9 ether)); // rateAtTarget := INITIAL
        for (uint256 i; i < 5; ++i) {
            Market memory m = _mkt(1 ether, i % 2 == 0 ? 0.3 ether : 0.98 ether);
            m.lastUpdate = uint128(block.timestamp);
            vm.warp(block.timestamp + 10 days);
            fixedIrm.borrowRate(mp, m);
        }
        assertEq(fixedIrm.rateAtTarget(mp.id()), ConstantsLib.INITIAL_RATE_AT_TARGET, "rateAtTarget never moved");
    }

    function test_edge_pinnedRateAtTarget_minEqualsMax() public {
        int256 pin = ConstantsLib.INITIAL_RATE_AT_TARGET;
        AdaptiveCurveIrm.Config memory cfg = _defaultConfig();
        cfg.minRateAtTarget = pin;
        cfg.maxRateAtTarget = pin;
        cfg.initialRateAtTarget = pin;
        AdaptiveCurveIrm pinned = new AdaptiveCurveIrm(address(this), cfg);
        MarketParams memory mp;
        mp.irm = address(pinned);

        pinned.borrowRate(mp, _mkt(1 ether, 0.9 ether));
        Market memory m = _mkt(1 ether, 0.99 ether);
        m.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + 100 days);
        pinned.borrowRate(mp, m);
        assertEq(pinned.rateAtTarget(mp.id()), pin, "rateAtTarget stays pinned when min == max");
    }

    function test_edge_utilizationAboveOne_doesNotRevert() public {
        uint256 atOne = irm.borrowRateView(marketParams, _mkt(1 ether, 1 ether));
        uint256 aboveOne = irm.borrowRateView(marketParams, _mkt(1 ether, 2 ether));
        assertGt(aboveOne, atOne, "rate keeps rising above 100% utilization");
    }

    function test_edge_zeroSupplyPositiveBorrow_actsAsZeroUtilization() public {
        uint256 zeroSupply = irm.borrowRateView(marketParams, _mkt(0, 5 ether));
        uint256 zeroUtil = irm.borrowRateView(marketParams, _mkt(1 ether, 0));
        assertEq(zeroSupply, zeroUtil, "supply=0 behaves as utilization=0");
    }

    function test_edge_extremeRateAtTargetDeploysButBricksAccrual() public {
        int256 extreme = type(int256).max / 3; // passes validation, but the curve math cannot hold it
        AdaptiveCurveIrm.Config memory cfg = _defaultConfig();
        cfg.minRateAtTarget = extreme;
        cfg.maxRateAtTarget = extreme;
        cfg.initialRateAtTarget = extreme;

        // Deployment succeeds despite the absurd rate (no upper-bound validation).
        AdaptiveCurveIrm bricked = new AdaptiveCurveIrm(address(this), cfg);
        assertEq(bricked.INITIAL_RATE_AT_TARGET(), extreme, "deployed with the extreme rate");

        MarketParams memory mp;
        mp.irm = address(bricked);
        Market memory m = _mkt(1 ether, 0.9 ether); // at target: multiplier == WAD, still overflows

        vm.expectRevert(stdError.arithmeticError);
        bricked.borrowRateView(mp, m);

        vm.expectRevert(stdError.arithmeticError);
        bricked.borrowRate(mp, m);
    }

    function _mkt(uint256 supply, uint256 borrow) internal pure returns (Market memory m) {
        m.totalSupplyAssets = uint128(supply);
        m.totalBorrowAssets = uint128(borrow);
    }

    function _expectRevert(AdaptiveCurveIrm.Config memory cfg, string memory err) internal {
        vm.expectRevert(bytes(err));
        new AdaptiveCurveIrm(address(this), cfg);
    }

    function testFirstBorrowRateUtilizationZero() public {
        Market memory market;

        assertApproxEqRel(
            irm.borrowRate(marketParams, market),
            uint256(ConstantsLib.INITIAL_RATE_AT_TARGET / 4),
            0.0001 ether,
            "avgBorrowRate"
        );
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET, "rateAtTarget");
    }

    function testFirstBorrowRateUtilizationOne() public {
        Market memory market;
        market.totalBorrowAssets = 1 ether;
        market.totalSupplyAssets = 1 ether;

        assertEq(
            irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET * 4), "avgBorrowRate"
        );
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET, "rateAtTarget");
    }

    function testRateAfterUtilizationOne() public {
        vm.warp(365 days * 2);
        Market memory market;
        assertApproxEqRel(
            irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET / 4), 0.001 ether
        );

        market.totalBorrowAssets = 1 ether;
        market.totalSupplyAssets = 1 ether;
        market.lastUpdate = uint128(block.timestamp - 5 days);

        // (exp((50/365)*5) ~= 1.9836.
        assertApproxEqRel(
            irm.borrowRateView(marketParams, market),
            uint256(
                (ConstantsLib.INITIAL_RATE_AT_TARGET * 4)
                .wMulToZero((1.9836 ether - 1 ether) * WAD / (ConstantsLib.ADJUSTMENT_SPEED * 5 days))
            ),
            0.1 ether
        );
        // The average value of exp((50/365)*x) between 0 and 5 is approx. 1.4361.
        assertApproxEqRel(
            irm.borrowRateView(marketParams, market),
            uint256((ConstantsLib.INITIAL_RATE_AT_TARGET * 4).wMulToZero(1.4361 ether)),
            0.1 ether
        );
        // Expected rate: 22.976%.
        assertApproxEqRel(irm.borrowRateView(marketParams, market), uint256(0.22976 ether) / 365 days, 0.1 ether);
    }

    function testRateAfterUtilizationZero() public {
        vm.warp(365 days * 2);
        Market memory market;
        assertApproxEqRel(
            irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET / 4), 0.001 ether
        );

        market.totalBorrowAssets = 0 ether;
        market.totalSupplyAssets = 1 ether;
        market.lastUpdate = uint128(block.timestamp - 5 days);

        // (exp((-50/365)*5) ~= 0.5041.
        assertApproxEqRel(
            irm.borrowRateView(marketParams, market),
            uint256(
                (ConstantsLib.INITIAL_RATE_AT_TARGET / 4)
                .wMulToZero((0.5041 ether - 1 ether) * WAD / (-ConstantsLib.ADJUSTMENT_SPEED * 5 days))
            ),
            0.1 ether
        );
        // The average value of exp((-50/365*x)) between 0 and 5 is approx. 0.7240.
        assertApproxEqRel(
            irm.borrowRateView(marketParams, market),
            uint256((ConstantsLib.INITIAL_RATE_AT_TARGET / 4).wMulToZero(0.724 ether)),
            0.1 ether
        );
        // Expected rate: 0.7240%.
        assertApproxEqRel(irm.borrowRateView(marketParams, market), uint256(0.00724 ether) / 365 days, 0.1 ether);
    }

    function testRateAfter45DaysUtilizationAboveTargetNoPing() public {
        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION));
        assertEq(irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET));
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET);

        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + 45 days);

        market.totalBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION + 1 ether) / 2); // Error = 50%
        irm.borrowRate(marketParams, market);

        // Expected rate: 4% * exp(50 * 45 / 365 * 50%) = 87.22%.
        assertApproxEqRel(irm.rateAtTarget(marketParams.id()), int256(0.8722 ether) / 365 days, 0.005 ether);
    }

    function testRateAfter45DaysUtilizationAboveTargetPingEveryMinute() public {
        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION));
        assertEq(irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET));
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET);

        uint128 initialBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION + 1 ether) / 2); // Error = 50%

        market.totalBorrowAssets = initialBorrowAssets;

        for (uint256 i; i < 45 days / 1 minutes; ++i) {
            market.lastUpdate = uint128(block.timestamp);
            vm.warp(block.timestamp + 1 minutes);

            uint256 avgBorrowRate = irm.borrowRate(marketParams, market);
            uint256 interest = market.totalBorrowAssets.wMulDown(avgBorrowRate.wTaylorCompounded(1 minutes));
            market.totalSupplyAssets += uint128(interest);
            market.totalBorrowAssets += uint128(interest);
        }

        assertApproxEqRel(
            market.totalBorrowAssets.wDivDown(market.totalSupplyAssets), 0.95 ether, 0.01 ether, "utilization"
        );

        int256 rateAtTarget = irm.rateAtTarget(marketParams.id());
        // Expected rate: 4% * exp(50 * 45 / 365 * 50%) = 87.22%.
        int256 expectedRateAtTarget = int256(0.8722 ether) / 365 days;
        assertGe(rateAtTarget, expectedRateAtTarget);
        // The rate is tolerated to be +8% (relatively) because of the pings every minute.
        assertApproxEqRel(rateAtTarget, expectedRateAtTarget, 0.08 ether, "expectedRateAtTarget");

        // Expected growth: exp(87.22% * 3.5 * 45 / 365) = +45.70%.
        // The growth is tolerated to be +30% (relatively) because of the pings every minute.
        assertApproxEqRel(
            market.totalBorrowAssets, initialBorrowAssets.wMulDown(1.457 ether), 0.3 ether, "totalBorrowAssets"
        );
    }

    function testRateAfterUtilizationTargetNoPing(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, type(uint48).max);

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION));
        assertEq(irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET));
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET);

        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + elapsed);

        irm.borrowRate(marketParams, market);

        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET);
    }

    function testRateAfter3WeeksUtilizationTargetPingEveryMinute() public {
        irm = new AdaptiveCurveIrm(address(this), _defaultConfig());

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION));
        assertEq(irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET));
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET);

        for (uint256 i; i < 3 weeks / 1 minutes; ++i) {
            market.lastUpdate = uint128(block.timestamp);
            vm.warp(block.timestamp + 1 minutes);

            uint256 avgBorrowRate = irm.borrowRate(marketParams, market);
            uint256 interest = market.totalBorrowAssets.wMulDown(avgBorrowRate.wTaylorCompounded(1 minutes));
            market.totalSupplyAssets += uint128(interest);
            market.totalBorrowAssets += uint128(interest);
        }

        assertApproxEqRel(
            market.totalBorrowAssets.wDivDown(market.totalSupplyAssets),
            uint256(ConstantsLib.TARGET_UTILIZATION),
            0.01 ether
        );

        int256 rateAtTarget = irm.rateAtTarget(marketParams.id());
        assertGe(rateAtTarget, ConstantsLib.INITIAL_RATE_AT_TARGET);
        // The rate is tolerated to be +10% (relatively) because of the pings every minute.
        assertApproxEqRel(rateAtTarget, ConstantsLib.INITIAL_RATE_AT_TARGET, 0.1 ether);
    }

    function testFirstBorrowRate(Market memory market) public {
        vm.assume(market.totalBorrowAssets > 0);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);

        uint256 avgBorrowRate = irm.borrowRate(marketParams, market);
        int256 rateAtTarget = irm.rateAtTarget(marketParams.id());

        assertEq(avgBorrowRate, _curve(int256(ConstantsLib.INITIAL_RATE_AT_TARGET), _err(market)), "avgBorrowRate");
        assertEq(rateAtTarget, ConstantsLib.INITIAL_RATE_AT_TARGET, "rateAtTarget");
    }

    function testBorrowRateEventEmission(Market memory market) public {
        vm.assume(market.totalBorrowAssets > 0);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);

        vm.expectEmit(true, true, true, true, address(irm));
        emit BorrowRateUpdate(
            marketParams.id(),
            _curve(int256(ConstantsLib.INITIAL_RATE_AT_TARGET), _err(market)),
            uint256(_expectedRateAtTarget(marketParams.id(), market))
        );
        irm.borrowRate(marketParams, market);
    }

    function testFirstBorrowRateView(Market memory market) public {
        vm.assume(market.totalBorrowAssets > 0);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);

        uint256 avgBorrowRate = irm.borrowRateView(marketParams, market);
        int256 rateAtTarget = irm.rateAtTarget(marketParams.id());

        assertEq(avgBorrowRate, _curve(int256(ConstantsLib.INITIAL_RATE_AT_TARGET), _err(market)), "avgBorrowRate");
        assertEq(rateAtTarget, 0, "prevBorrowRate");
    }

    function testBorrowRate(Market memory market0, Market memory market1) public {
        vm.assume(market0.totalBorrowAssets > 0);
        vm.assume(market0.totalSupplyAssets >= market0.totalBorrowAssets);
        irm.borrowRate(marketParams, market0);

        vm.assume(market1.totalBorrowAssets > 0);
        vm.assume(market1.totalSupplyAssets >= market1.totalBorrowAssets);
        market1.lastUpdate = uint128(bound(market1.lastUpdate, block.timestamp - 5 days, block.timestamp - 1));

        int256 expectedRateAtTarget = _expectedRateAtTarget(marketParams.id(), market1);
        uint256 expectedAvgRate = _expectedAvgRate(marketParams.id(), market1);

        uint256 borrowRateView = irm.borrowRateView(marketParams, market1);
        uint256 borrowRate = irm.borrowRate(marketParams, market1);

        assertEq(borrowRateView, borrowRate, "borrowRateView");
        assertApproxEqRel(borrowRate, expectedAvgRate, 0.11 ether, "avgBorrowRate");
        assertApproxEqRel(irm.rateAtTarget(marketParams.id()), expectedRateAtTarget, 0.001 ether, "rateAtTarget");
    }

    function testBorrowRateNoTimeElapsed(Market memory market0, Market memory market1) public {
        vm.assume(market0.totalBorrowAssets > 0);
        vm.assume(market0.totalSupplyAssets >= market0.totalBorrowAssets);
        irm.borrowRate(marketParams, market0);

        vm.assume(market1.totalBorrowAssets > 0);
        vm.assume(market1.totalSupplyAssets >= market1.totalBorrowAssets);
        market1.lastUpdate = uint128(block.timestamp);

        int256 expectedRateAtTarget = _expectedRateAtTarget(marketParams.id(), market1);
        uint256 expectedAvgRate = _expectedAvgRate(marketParams.id(), market1);

        uint256 borrowRateView = irm.borrowRateView(marketParams, market1);
        uint256 borrowRate = irm.borrowRate(marketParams, market1);

        assertEq(borrowRateView, borrowRate, "borrowRateView");
        assertApproxEqRel(borrowRate, expectedAvgRate, 0.01 ether, "avgBorrowRate");
        assertApproxEqRel(irm.rateAtTarget(marketParams.id()), expectedRateAtTarget, 0.001 ether, "rateAtTarget");
    }

    function testBorrowRateNoUtilizationChange(Market memory market0, Market memory market1) public {
        vm.assume(market0.totalBorrowAssets > 0);
        vm.assume(market0.totalSupplyAssets >= market0.totalBorrowAssets);
        irm.borrowRate(marketParams, market0);

        market1.totalBorrowAssets = market0.totalBorrowAssets;
        market1.totalSupplyAssets = market0.totalSupplyAssets;
        market1.lastUpdate = uint128(bound(market1.lastUpdate, block.timestamp - 5 days, block.timestamp - 1));

        int256 expectedRateAtTarget = _expectedRateAtTarget(marketParams.id(), market1);
        uint256 expectedAvgRate = _expectedAvgRate(marketParams.id(), market1);

        uint256 borrowRateView = irm.borrowRateView(marketParams, market1);
        uint256 borrowRate = irm.borrowRate(marketParams, market1);

        assertEq(borrowRateView, borrowRate, "borrowRateView");
        assertApproxEqRel(borrowRate, expectedAvgRate, 0.1 ether, "avgBorrowRate");
        assertApproxEqRel(irm.rateAtTarget(marketParams.id()), expectedRateAtTarget, 0.001 ether, "rateAtTarget");
    }

    /* HANDLERS */

    function handleBorrowRate(uint256 totalSupplyAssets, uint256 totalBorrowAssets, uint256 elapsed) external {
        elapsed = bound(elapsed, 0, type(uint48).max);
        totalSupplyAssets = bound(totalSupplyAssets, 0, type(uint128).max);
        totalBorrowAssets = bound(totalBorrowAssets, 0, totalSupplyAssets);

        Market memory market;
        market.lastUpdate = uint128(block.timestamp);
        market.totalBorrowAssets = uint128(totalSupplyAssets);
        market.totalSupplyAssets = uint128(totalBorrowAssets);

        vm.warp(block.timestamp + elapsed);
        irm.borrowRate(marketParams, market);
    }

    /* INVARIANTS */

    function invariantGeMinRateAtTarget() public {
        Market memory market;
        market.totalBorrowAssets = 9 ether;
        market.totalSupplyAssets = 10 ether;

        assertGe(
            irm.borrowRateView(marketParams, market),
            uint256(ConstantsLib.MIN_RATE_AT_TARGET.wDivToZero(ConstantsLib.CURVE_STEEPNESS))
        );
        assertGe(
            irm.borrowRate(marketParams, market),
            uint256(ConstantsLib.MIN_RATE_AT_TARGET.wDivToZero(ConstantsLib.CURVE_STEEPNESS))
        );
    }

    function invariantLeMaxRateAtTarget() public {
        Market memory market;
        market.totalBorrowAssets = 9 ether;
        market.totalSupplyAssets = 10 ether;

        assertLe(
            irm.borrowRateView(marketParams, market),
            uint256(ConstantsLib.MAX_RATE_AT_TARGET.wMulToZero(ConstantsLib.CURVE_STEEPNESS))
        );
        assertLe(
            irm.borrowRate(marketParams, market),
            uint256(ConstantsLib.MAX_RATE_AT_TARGET.wMulToZero(ConstantsLib.CURVE_STEEPNESS))
        );
    }

    function testDefaultConfigIsValid() public {
        AdaptiveCurveIrm deployed = new AdaptiveCurveIrm(address(this), _defaultConfig());
        assertEq(deployed.CURVE_STEEPNESS(), ConstantsLib.CURVE_STEEPNESS, "default config deployed");
    }

    /* HELPERS */

    function _defaultConfig() internal pure returns (AdaptiveCurveIrm.Config memory) {
        return AdaptiveCurveIrm.Config({
            curveSteepness: ConstantsLib.CURVE_STEEPNESS,
            adjustmentSpeed: ConstantsLib.ADJUSTMENT_SPEED,
            targetUtilization: ConstantsLib.TARGET_UTILIZATION,
            initialRateAtTarget: ConstantsLib.INITIAL_RATE_AT_TARGET,
            minRateAtTarget: ConstantsLib.MIN_RATE_AT_TARGET,
            maxRateAtTarget: ConstantsLib.MAX_RATE_AT_TARGET,
            maxBorrowRate: 0
        });
    }

    function _expectedRateAtTarget(Id id, Market memory market) internal view returns (int256) {
        int256 rateAtTarget = irm.rateAtTarget(id);
        int256 speed = ConstantsLib.ADJUSTMENT_SPEED.wMulToZero(_err(market));
        uint256 elapsed = (rateAtTarget > 0) ? block.timestamp - market.lastUpdate : 0;
        int256 linearAdaptation = speed * int256(elapsed);
        int256 adaptationMultiplier = ExpLib.wExp(linearAdaptation);
        return (rateAtTarget > 0)
            ? rateAtTarget.wMulToZero(adaptationMultiplier)
                .bound(ConstantsLib.MIN_RATE_AT_TARGET, ConstantsLib.MAX_RATE_AT_TARGET)
            : ConstantsLib.INITIAL_RATE_AT_TARGET;
    }

    function _expectedAvgRate(Id id, Market memory market) internal view returns (uint256) {
        int256 rateAtTarget = irm.rateAtTarget(id);
        int256 err = _err(market);
        int256 speed = ConstantsLib.ADJUSTMENT_SPEED.wMulToZero(err);
        uint256 elapsed = (rateAtTarget > 0) ? block.timestamp - market.lastUpdate : 0;
        int256 linearAdaptation = speed * int256(elapsed);
        int256 endRateAtTarget = int256(_expectedRateAtTarget(id, market));
        uint256 newBorrowRate = _curve(endRateAtTarget, err);

        uint256 avgBorrowRate;
        if (linearAdaptation == 0 || rateAtTarget == 0) {
            avgBorrowRate = newBorrowRate;
        } else {
            // Safe "unchecked" cast to uint256 because linearAdaptation < 0 <=> newBorrowRate <= borrowRateAfterJump.
            avgBorrowRate =
                uint256((int256(newBorrowRate) - int256(_curve(rateAtTarget, err))).wDivToZero(linearAdaptation));
        }
        return avgBorrowRate;
    }

    function _curve(int256 rateAtTarget, int256 err) internal pure returns (uint256) {
        // Safe "unchecked" cast because err >= -1 (in WAD).
        if (err < 0) {
            return uint256(
                ((WAD - WAD.wDivToZero(ConstantsLib.CURVE_STEEPNESS)).wMulToZero(err) + WAD).wMulToZero(rateAtTarget)
            );
        } else {
            return uint256(((ConstantsLib.CURVE_STEEPNESS - WAD).wMulToZero(err) + WAD).wMulToZero(rateAtTarget));
        }
    }

    function _err(Market memory market) internal pure returns (int256 err) {
        if (market.totalSupplyAssets == 0) return -1 ether;

        int256 utilization = int256(market.totalBorrowAssets.wDivDown(market.totalSupplyAssets));

        if (utilization > ConstantsLib.TARGET_UTILIZATION) {
            err = (utilization - ConstantsLib.TARGET_UTILIZATION).wDivToZero(WAD - ConstantsLib.TARGET_UTILIZATION);
        } else {
            err = (utilization - ConstantsLib.TARGET_UTILIZATION).wDivToZero(ConstantsLib.TARGET_UTILIZATION);
        }
    }
}
