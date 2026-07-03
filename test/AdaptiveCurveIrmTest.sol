// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {AdaptiveCurveConfig} from "../src/adaptive-curve-irm/AdaptiveCurveConfig.sol";
import {IAdaptiveCurveConfig} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
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
        // morpho == owner == address(this): the test is both the Morpho caller and the owner (sets configs).
        irm = _newIrm();
        _setConfig(address(irm), marketParams, _defaultConfig());
        vm.warp(90 days);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = AdaptiveCurveIrmTest.handleBorrowRate.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    /* ============================== MORPHO UPSTREAM TESTS ============================== */
    /* Inherited from morpho-org/morpho-blue-irm @ 2bce6da, adapted to the AdaptiveCurveConfig constructor. */

    function testDeployment() public {
        // The constructor rejects a zero morpho.
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        new AdaptiveCurveIrm(address(0));

        // `initialize` rejects a zero owner, sets it once, and rejects a second call.
        AdaptiveCurveIrm fresh = new AdaptiveCurveIrm(address(this));
        // The constructor locks the implementation (isInitialized == true, packed with `manager` in slot 4); clear the
        // slot so `initialize` runs.
        vm.store(address(fresh), bytes32(uint256(4)), bytes32(0));
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        fresh.initialize(address(0), address(this));

        fresh.initialize(address(this), address(this));
        assertEq(fresh.owner(), address(this), "owner set by initialize");

        vm.expectRevert(bytes(ErrorsLib.ALREADY_INITIALIZED));
        fresh.initialize(address(this), address(this));
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

    /* ================================ LIDO FORK TESTS ================================ */

    /* ---- Config registration ---- */
    /* Curve-param validation and getCurveParams round-trip moved to AdaptiveCurveConfigTest (validation now lives in
    the
       AdaptiveCurveConfig constructor). */

    /// A market with no registered config cannot be priced: both the state-changing call and the view revert.
    function testBorrowRateRevertsWhenConfigNotSet() public {
        MarketParams memory unregistered = marketParams;
        unregistered.loanToken = address(0xDEAD); // a fresh id never registered on `irm`
        Market memory market = _market(1 ether, 0.9 ether);

        vm.expectRevert(bytes(ErrorsLib.CONFIG_NOT_SET));
        irm.borrowRate(unregistered, market);

        vm.expectRevert(bytes(ErrorsLib.CONFIG_NOT_SET));
        irm.borrowRateView(unregistered, market);
    }

    /* ---- Access control ---- */

    /// Only Morpho may call state-changing borrowRate; borrowRateView stays open to anyone.
    function testBorrowRateOnlyMorpho(address caller) public {
        vm.assume(caller != address(this)); // address(this) is MORPHO (set in setUp)
        Market memory market = _market(1 ether, 0.9 ether);

        // State-changing borrowRate is Morpho-only.
        vm.prank(caller);
        vm.expectRevert(bytes(ErrorsLib.NOT_MORPHO));
        irm.borrowRate(marketParams, market);

        // The view is permissionless; a non-Morpho caller can still read it.
        vm.prank(caller);
        irm.borrowRateView(marketParams, market);
    }

    /// setMarketCurveParams is owner-or-manager only; an outsider is rejected with NOT_AUTHORIZED.
    function testSetConfigOnlyOwner(address caller) public {
        vm.assume(caller != address(this)); // address(this) is owner and manager (set in setUp)
        vm.prank(caller);
        vm.expectRevert(bytes(ErrorsLib.NOT_AUTHORIZED));
        AdaptiveCurveIrm(address(irm)).setMarketCurveParams(marketParams, _defaultConfig());
    }

    /// transferOwnership immediately moves ownership: the old owner loses the owner-only powers, the new owner gains
    /// them. (setMarketCurveParams is not owner-exclusive — the old owner keeps it while still the manager — so the
    /// owner-only power checked here is setManager.)
    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");
        AdaptiveCurveIrm irm_ = AdaptiveCurveIrm(address(irm));

        irm_.transferOwnership(newOwner);
        assertEq(irm_.owner(), newOwner, "owner changed");

        // The old owner (this) can no longer exercise owner-only powers; the new owner can.
        vm.expectRevert(bytes(ErrorsLib.NOT_OWNER));
        irm_.setManager(address(this));
        vm.prank(newOwner);
        irm_.setManager(address(this));
        assertEq(irm_.manager(), address(this), "new owner set the manager");
    }

    /// transferOwnership is owner-only.
    function testTransferOwnershipOnlyOwner(address caller) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        vm.expectRevert(bytes(ErrorsLib.NOT_OWNER));
        AdaptiveCurveIrm(address(irm)).transferOwnership(caller);
    }

    /// transferOwnership rejects the zero address.
    function testTransferOwnershipRejectsZero() public {
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        AdaptiveCurveIrm(address(irm)).transferOwnership(address(0));
    }

    /// setMarketCurveParams deploys a config from params, sets it, and the market prices.
    function testSetConfigDeploysAndPrices() public {
        AdaptiveCurveIrm(address(irm)).setMarketCurveParams(marketParams, _defaultConfig());

        assertTrue(address(irm.marketCurveConfig(marketParams.id())) != address(0), "config set");
        Market memory market = _market(1 ether, uint256(ConstantsLib.TARGET_UTILIZATION));
        assertEq(irm.borrowRateView(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET), "it prices");
    }

    /* ---- Borrow-rate cap ---- */

    /// A cap below the curve's tip clamps the charged rate to MAX_BORROW_RATE.
    function testMaxBorrowRateClampsChargedRate() public {
        // Deploy a capped IRM whose cap sits below the curve's tip at full utilization.
        AdaptiveCurveParams memory config = _defaultConfig();
        uint256 curveTip = uint256(ConstantsLib.INITIAL_RATE_AT_TARGET.wMulToZero(ConstantsLib.CURVE_STEEPNESS));
        config.maxBorrowRate = curveTip / 2; // cap below the tip
        AdaptiveCurveIrm capped = _newIrm();
        _setConfig(address(capped), marketParams, config);

        Market memory market;
        market.totalBorrowAssets = 1 ether;
        market.totalSupplyAssets = 1 ether;

        // Uncapped charges the full tip; capped is clamped to MAX_BORROW_RATE.
        assertEq(irm.borrowRateView(marketParams, market), curveTip, "uncapped charges the full tip");
        assertEq(capped.borrowRateView(marketParams, market), config.maxBorrowRate, "charged rate clamped");
    }

    /// The cap bounds only the charged rate; rateAtTarget adapts the same as uncapped.
    function testMaxBorrowRateDoesNotAffectRateAtTarget() public {
        AdaptiveCurveParams memory config = _defaultConfig();
        config.maxBorrowRate = uint256(ConstantsLib.INITIAL_RATE_AT_TARGET); // well below the high-util tip
        AdaptiveCurveIrm capped = _newIrm();
        _setConfig(address(capped), marketParams, config);

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = 0.98 ether;
        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + 5 days);

        // Drive an adapting call on both the uncapped and capped IRMs from the same state.
        irm.borrowRate(marketParams, market);
        capped.borrowRate(marketParams, market);

        // rateAtTarget moves identically; the cap touches only the charged rate.
        assertEq(
            capped.rateAtTarget(marketParams.id()),
            irm.rateAtTarget(marketParams.id()),
            "rateAtTarget adapts identically; the cap bounds only the charged rate"
        );
    }

    /* ---- Curve & adaptation edge cases ---- */

    /// Two markets (distinct ids) on one IRM adapt independently — one up, one down.
    function test_marketsAdaptIndependently() public {
        MarketParams memory paramsUp = marketParams;
        paramsUp.loanToken = address(0xA);
        MarketParams memory paramsDown = marketParams;
        paramsDown.loanToken = address(0xB);
        Id idUp = paramsUp.id();
        Id idDown = paramsDown.id();
        assertTrue(Id.unwrap(idUp) != Id.unwrap(idDown), "distinct ids");

        // Both markets share the default curve, registered independently per id.
        _setConfig(address(irm), paramsUp, _defaultConfig());
        _setConfig(address(irm), paramsDown, _defaultConfig());

        // Seed both at target -> both at INITIAL_RATE_AT_TARGET.
        irm.borrowRate(paramsUp, _market(1 ether, 0.9 ether));
        irm.borrowRate(paramsDown, _market(1 ether, 0.9 ether));

        // Drive one market above target and the other below target over the same span.
        Market memory marketUp = _market(1 ether, 0.99 ether);
        marketUp.lastUpdate = uint128(block.timestamp);
        Market memory marketDown = _market(1 ether, 0.1 ether);
        marketDown.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + 30 days);
        irm.borrowRate(paramsUp, marketUp);
        irm.borrowRate(paramsDown, marketDown);

        assertGt(irm.rateAtTarget(idUp), ConstantsLib.INITIAL_RATE_AT_TARGET, "up-driven market adapted up");
        assertLt(irm.rateAtTarget(idDown), ConstantsLib.INITIAL_RATE_AT_TARGET, "down-driven market adapted down");
    }

    /// curveSteepness == WAD makes the curve flat: one rate at every utilization.
    function test_edge_steepnessOne_flatCurve() public {
        AdaptiveCurveParams memory config = _defaultConfig();
        config.curveSteepness = WAD;
        (AdaptiveCurveIrm flat, MarketParams memory deployedParams) = _deploy(config);

        // Steepness 1 -> the curve is flat: the same rate at every utilization.
        uint256 initial = uint256(ConstantsLib.INITIAL_RATE_AT_TARGET);
        assertEq(flat.borrowRateView(deployedParams, _market(1 ether, 0)), initial, "util=0 is flat");
        assertEq(flat.borrowRateView(deployedParams, _market(1 ether, 0.9 ether)), initial, "util=target is flat");
        assertEq(flat.borrowRateView(deployedParams, _market(1 ether, 1 ether)), initial, "util=1 is flat");
    }

    /// adjustmentSpeed == 0 freezes rateAtTarget across any number of off-target calls.
    function test_edge_zeroAdjustmentSpeed_neverAdapts() public {
        AdaptiveCurveParams memory config = _defaultConfig();
        config.adjustmentSpeed = 0;
        (AdaptiveCurveIrm fixedIrm, MarketParams memory deployedParams) = _deploy(config);

        fixedIrm.borrowRate(deployedParams, _market(1 ether, 0.9 ether)); // rateAtTarget := INITIAL
        // Repeated off-target calls must never move rateAtTarget when the speed is zero.
        for (uint256 i; i < 5; ++i) {
            Market memory market = _market(1 ether, i % 2 == 0 ? 0.3 ether : 0.98 ether);
            market.lastUpdate = uint128(block.timestamp);
            vm.warp(block.timestamp + 10 days);
            fixedIrm.borrowRate(deployedParams, market);
        }
        assertEq(
            fixedIrm.rateAtTarget(deployedParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET, "rateAtTarget never moved"
        );
    }

    /// min == max pins rateAtTarget even over a long adapting call.
    function test_edge_pinnedRateAtTarget_minEqualsMax() public {
        int256 pinnedRate = ConstantsLib.INITIAL_RATE_AT_TARGET;
        AdaptiveCurveParams memory config = _defaultConfig();
        config.minRateAtTarget = pinnedRate;
        config.maxRateAtTarget = pinnedRate;
        config.initialRateAtTarget = pinnedRate;
        (AdaptiveCurveIrm pinned, MarketParams memory deployedParams) = _deploy(config);

        // With min == max, rateAtTarget is pinned even across a long adapting call.
        pinned.borrowRate(deployedParams, _market(1 ether, 0.9 ether));
        Market memory market = _market(1 ether, 0.99 ether);
        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + 100 days);
        pinned.borrowRate(deployedParams, market);
        assertEq(pinned.rateAtTarget(deployedParams.id()), pinnedRate, "rateAtTarget stays pinned when min == max");
    }

    /// Utilization above 100% does not revert and keeps raising the rate.
    function test_edge_utilizationAboveOne_doesNotRevert() public {
        uint256 atOne = irm.borrowRateView(marketParams, _market(1 ether, 1 ether));
        uint256 aboveOne = irm.borrowRateView(marketParams, _market(1 ether, 2 ether));
        assertGt(aboveOne, atOne, "rate keeps rising above 100% utilization");
    }

    /// Zero supply with a positive borrow is treated as zero utilization.
    function test_edge_zeroSupplyPositiveBorrow_actsAsZeroUtilization() public {
        uint256 zeroSupply = irm.borrowRateView(marketParams, _market(0, 5 ether));
        uint256 zeroUtil = irm.borrowRateView(marketParams, _market(1 ether, 0));
        assertEq(zeroSupply, zeroUtil, "supply=0 behaves as utilization=0");
    }

    /// A config at the validation ceilings still computes without int256 overflow.
    function test_edge_configAtLimitsDeploysAndComputes() public {
        int256 rateLimit = int256(10_000 ether) / int256(365 days);
        AdaptiveCurveParams memory config = _defaultConfig();
        config.curveSteepness = int256(100 ether); // max steepness
        config.adjustmentSpeed = int256(10_000 ether) / int256(365 days); // max speed
        config.minRateAtTarget = rateLimit;
        config.maxRateAtTarget = rateLimit; // rateAtTarget pinned at the ceiling
        config.initialRateAtTarget = rateLimit;
        (AdaptiveCurveIrm atLimit, MarketParams memory deployedParams) = _deploy(config);

        // Seed rateAtTarget, then a large above-target jump — the worst case for the curve and adaptation math.
        atLimit.borrowRate(deployedParams, _market(1 ether, 0.9 ether));
        Market memory market = _market(1 ether, 0.99 ether);
        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + 365 days);

        // The chosen limits stay clear of int256 overflow, so the rate computation does not revert.
        atLimit.borrowRateView(deployedParams, market);
        atLimit.borrowRate(deployedParams, market);
    }

    /* ---- Fuzz & differential ---- */

    /// Across the operating-band config space, the IRM's output invariants always hold.
    function testFuzz_validConfigInvariants(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        uint256 maxBorrowRate,
        bool capEnabled,
        uint128 supply,
        uint128 borrowed,
        uint256 elapsed
    ) public {
        AdaptiveCurveParams memory config = _boundedConfig(
            curveSteepness, adjustmentSpeed, targetUtilization, minRate, maxRate, initialRate, maxBorrowRate, capEnabled
        );
        (AdaptiveCurveIrm fuzzed, MarketParams memory deployedParams) = _deploy(config);

        Market memory market;
        market.totalSupplyAssets = supply;
        market.totalBorrowAssets = uint128(bound(borrowed, 0, supply));

        // First interaction (rateAtTarget == 0 -> INITIAL_RATE_AT_TARGET).
        _assertConfigInvariants(fuzzed, deployedParams, market, config);

        // Advance time so the next call exercises the adapting branch.
        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
        _assertConfigInvariants(fuzzed, deployedParams, market, config);
    }

    /// Across the full accepted config space (up to the ceilings), the invariants hold without reverting.
    function testFuzz_fullRangeConfigUpholdsInvariants(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        uint256 maxBorrowRate,
        bool capEnabled,
        uint128 supply,
        uint128 borrowed,
        uint256 elapsed
    ) public {
        // Covers the whole accepted config space, up to the validation ceilings the operating-band fuzzer does not
        // reach. Asserts only non-revert and the structural invariants, not a reference match.
        AdaptiveCurveParams memory config = _fullRangeConfig(
            curveSteepness, adjustmentSpeed, targetUtilization, minRate, maxRate, initialRate, maxBorrowRate, capEnabled
        );
        (AdaptiveCurveIrm fuzzed, MarketParams memory deployedParams) = _deploy(config);

        Market memory market;
        market.totalSupplyAssets = supply;
        market.totalBorrowAssets = uint128(bound(borrowed, 0, supply));

        _assertConfigInvariants(fuzzed, deployedParams, market, config);

        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
        _assertConfigInvariants(fuzzed, deployedParams, market, config);
    }

    /// The charged rate and rateAtTarget match an independent config-parametrized reference, across the FULL accepted
    /// config space (up to the validation ceilings), not just the operating band.
    function testFuzz_curveMatchesConfigParametrizedReference(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        uint256 maxBorrowRate,
        bool capEnabled,
        uint128 supply0,
        uint128 borrowed0,
        uint128 supply1,
        uint128 borrowed1,
        uint256 elapsed
    ) public {
        AdaptiveCurveParams memory config = _fullRangeConfig(
            curveSteepness, adjustmentSpeed, targetUtilization, minRate, maxRate, initialRate, maxBorrowRate, capEnabled
        );
        (AdaptiveCurveIrm fuzzed, MarketParams memory deployedParams) = _deploy(config);
        Id id = deployedParams.id();

        // First interaction sets rateAtTarget = INITIAL_RATE_AT_TARGET so the next call exercises the adapting path.
        Market memory seedMarket;
        seedMarket.totalSupplyAssets = supply0;
        seedMarket.totalBorrowAssets = uint128(bound(borrowed0, 0, supply0));
        fuzzed.borrowRate(deployedParams, seedMarket);
        assertEq(fuzzed.rateAtTarget(id), config.initialRateAtTarget, "rateAtTarget = INITIAL after first interaction");

        // Adapting interaction against the config-parametrized reference.
        Market memory adaptingMarket;
        adaptingMarket.totalSupplyAssets = supply1;
        adaptingMarket.totalBorrowAssets = uint128(bound(borrowed1, 0, supply1));
        adaptingMarket.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + bound(elapsed, 0, 365 days));

        (uint256 expectedRate, int256 expectedEndRate) = _refBorrowRate(config, fuzzed.rateAtTarget(id), adaptingMarket);

        uint256 gotView = fuzzed.borrowRateView(deployedParams, adaptingMarket);
        uint256 gotRate = fuzzed.borrowRate(deployedParams, adaptingMarket);

        assertEq(gotView, gotRate, "borrowRateView == borrowRate");
        assertEq(gotRate, expectedRate, "charged rate matches config-parametrized reference");
        assertEq(fuzzed.rateAtTarget(id), expectedEndRate, "rateAtTarget matches config-parametrized reference");
    }

    /* ==================================== HELPERS ==================================== */

    /// @dev The baseline config (upstream curve constants, cap off). Used by setUp and any test needing a "normal" IRM.
    function _defaultConfig() internal pure returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: ConstantsLib.CURVE_STEEPNESS,
            adjustmentSpeed: ConstantsLib.ADJUSTMENT_SPEED,
            targetUtilization: ConstantsLib.TARGET_UTILIZATION,
            initialRateAtTarget: ConstantsLib.INITIAL_RATE_AT_TARGET,
            minRateAtTarget: ConstantsLib.MIN_RATE_AT_TARGET,
            maxRateAtTarget: ConstantsLib.MAX_RATE_AT_TARGET,
            maxBorrowRate: 0
        });
    }

    /// @dev Deploys an IRM with the test as morpho, owner, and manager.
    function _newIrm() internal returns (AdaptiveCurveIrm irm_) {
        irm_ = new AdaptiveCurveIrm(address(this));
        // The constructor locks the implementation (isInitialized == true, packed with `manager` in slot 4); clear the
        // slot so a direct-deployed IRM can be initialized in tests. `manager` is still zero here, so wiping the whole
        // slot only unsets the lock.
        vm.store(address(irm_), bytes32(uint256(4)), bytes32(0));
        irm_.initialize(address(this), address(this));
    }

    /// @dev Points `irm_` at a config deployed from `config` for `params` (the test is owner/manager). Takes full
    /// MarketParams because setMarketCurveParams derives the id from them.
    function _setConfig(address irm_, MarketParams memory params, AdaptiveCurveParams memory config)
        internal
        returns (address configAddress)
    {
        AdaptiveCurveIrm(irm_).setMarketCurveParams(params, config);
        configAddress = address(AdaptiveCurveIrm(irm_).marketCurveConfig(params.id()));
    }

    /// @dev Spins up an IRM for `config` and the `MarketParams` that addresses it (the id is derived from it),
    /// setting the config so the market can be priced — tests skip the new-contract + wire boilerplate.
    function _deploy(AdaptiveCurveParams memory config)
        internal
        returns (AdaptiveCurveIrm irm_, MarketParams memory deployedParams)
    {
        irm_ = _newIrm();
        deployedParams.irm = address(irm_);
        _setConfig(address(irm_), deployedParams, config);
    }

    /// @dev A bare `Market` carrying only supply/borrow (i.e. a utilization) — for rate calls where nothing else
    /// matters.
    function _market(uint256 supply, uint256 borrow) internal pure returns (Market memory market) {
        market.totalSupplyAssets = uint128(supply);
        market.totalBorrowAssets = uint128(borrow);
    }

    /// @dev Squeezes raw fuzz inputs into an always-valid `Params` in the realistic operating band, so the
    /// differential and invariant fuzzers explore normal markets.
    function _boundedConfig(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        uint256 maxBorrowRate,
        bool capEnabled
    ) internal view returns (AdaptiveCurveParams memory config) {
        // Operating band: realistic, overflow-safe ranges where production markets live. The full validation range
        // (up to MAX_ADJUSTMENT_SPEED and MAX_RATE_AT_TARGET_LIMIT) is covered by
        // testFuzz_fullRangeConfigUpholdsInvariants.
        int256 rateCeil = int256(10 ether) / int256(365 days); // 1000%/yr
        config.curveSteepness = bound(curveSteepness, WAD, int256(100 ether));
        config.adjustmentSpeed = bound(adjustmentSpeed, 0, int256(1000 ether) / int256(365 days));
        config.targetUtilization = bound(targetUtilization, 1, WAD - 1);
        config.minRateAtTarget = bound(minRate, 1, rateCeil);
        config.maxRateAtTarget = bound(maxRate, config.minRateAtTarget, rateCeil);
        config.initialRateAtTarget = bound(initialRate, config.minRateAtTarget, config.maxRateAtTarget);
        config.maxBorrowRate = capEnabled ? bound(maxBorrowRate, 1, 50 ether / uint256(365 days)) : 0;
    }

    /// @dev Like `_boundedConfig` but stretched to the true validation ceilings, so the invariant fuzzer also
    /// covers the extreme end of the accepted config space.
    function _fullRangeConfig(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        uint256 maxBorrowRate,
        bool capEnabled
    ) internal view returns (AdaptiveCurveParams memory config) {
        // The true validation ceilings: adjustmentSpeed up to MAX_ADJUSTMENT_SPEED, rates up to
        // MAX_RATE_AT_TARGET_LIMIT.
        int256 rateCeil = int256(10_000 ether) / int256(365 days); // = MAX_RATE_AT_TARGET_LIMIT (~1e6%/yr)
        int256 speedCeil = int256(10_000 ether) / int256(365 days); // = MAX_ADJUSTMENT_SPEED (~10000/yr)
        config.curveSteepness = bound(curveSteepness, WAD, int256(100 ether));
        config.adjustmentSpeed = bound(adjustmentSpeed, 0, speedCeil);
        config.targetUtilization = bound(targetUtilization, 1, WAD - 1);
        config.minRateAtTarget = bound(minRate, 1, rateCeil);
        config.maxRateAtTarget = bound(maxRate, config.minRateAtTarget, rateCeil);
        config.initialRateAtTarget = bound(initialRate, config.minRateAtTarget, config.maxRateAtTarget);
        config.maxBorrowRate = capEnabled ? bound(maxBorrowRate, 1, 10_000 ether / uint256(365 days)) : 0;
    }

    /// @dev The shared check for the invariant fuzzers: after one borrowRate call, view == state, the cap holds,
    /// the rate stays under a sane upper bound, and rateAtTarget is within [min, max].
    function _assertConfigInvariants(
        AdaptiveCurveIrm fuzzed,
        MarketParams memory deployedParams,
        Market memory market,
        AdaptiveCurveParams memory config
    ) internal {
        uint256 rateView = fuzzed.borrowRateView(deployedParams, market);
        uint256 rate = fuzzed.borrowRate(deployedParams, market);
        assertEq(rateView, rate, "borrowRateView == borrowRate");
        if (config.maxBorrowRate != 0) assertLe(rate, config.maxBorrowRate, "rate <= MAX_BORROW_RATE");
        // For utilization <= 1 the uncapped rate is exactly `curveSteepness * avgRateAtTarget` at its worst case
        // (err == WAD), and avgRateAtTarget <= maxRateAtTarget, so the rate never exceeds this tight upper bound (no
        // rounding slack needed, since `wMulToZero` is monotonic). A sign flip in the curve math would wrap the
        // int->uint cast far above the bound, so the assert doubles as a non-negativity guard.
        assertLe(
            rate, uint256(config.curveSteepness.wMulToZero(config.maxRateAtTarget)), "rate within tight upper bound"
        );
        int256 storedRate = fuzzed.rateAtTarget(deployedParams.id());
        assertGe(storedRate, config.minRateAtTarget, "rateAtTarget >= MIN_RATE_AT_TARGET");
        assertLe(storedRate, config.maxRateAtTarget, "rateAtTarget <= MAX_RATE_AT_TARGET");
    }

    /// @dev The differential test's oracle: recomputes the borrow rate from scratch (curve + adaptation + cap)
    /// so the contract's output can be checked against an independent implementation.
    function _refBorrowRate(AdaptiveCurveParams memory config, int256 startRate, Market memory market)
        internal
        view
        returns (uint256, int256)
    {
        int256 err = _refErr(market, config.targetUtilization);

        int256 avgRateAtTarget;
        int256 endRateAtTarget;
        if (startRate == 0) {
            avgRateAtTarget = config.initialRateAtTarget;
            endRateAtTarget = config.initialRateAtTarget;
        } else {
            int256 linearAdaptation =
                config.adjustmentSpeed.wMulToZero(err) * int256(block.timestamp - market.lastUpdate);
            if (linearAdaptation == 0) {
                avgRateAtTarget = startRate;
                endRateAtTarget = startRate;
            } else {
                endRateAtTarget =
                    _refNewRateAtTarget(startRate, linearAdaptation, config.minRateAtTarget, config.maxRateAtTarget);
                int256 midRateAtTarget = _refNewRateAtTarget(
                    startRate, linearAdaptation / 2, config.minRateAtTarget, config.maxRateAtTarget
                );
                avgRateAtTarget = (startRate + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        uint256 rate = uint256(_refCurve(avgRateAtTarget, err, config.curveSteepness));
        if (config.maxBorrowRate != 0 && rate > config.maxBorrowRate) rate = config.maxBorrowRate;
        return (rate, endRateAtTarget);
    }

    /// @dev Reference `err`: utilization's signed deviation from target, scaled to [-1, +1] (-1 empty, 0 at
    /// target, +1 full). Mirrors the contract.
    function _refErr(Market memory market, int256 targetUtilization) internal pure returns (int256) {
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);
        int256 errNormFactor = utilization > targetUtilization ? WAD - targetUtilization : targetUtilization;
        return (utilization - targetUtilization).wDivToZero(errNormFactor);
    }

    /// @dev Reference curve: maps (`rateAtTarget`, `err`) to a rate for `curveSteepness`. Mirrors the contract's
    /// `_curve`.
    function _refCurve(int256 _rateAtTarget, int256 err, int256 curveSteepness) internal pure returns (int256) {
        int256 coeff = err < 0 ? WAD - WAD.wDivToZero(curveSteepness) : curveSteepness - WAD;
        return (coeff.wMulToZero(err) + WAD).wMulToZero(_rateAtTarget);
    }

    /// @dev Reference adaptation step: start * exp(linearAdaptation), clamped to [min, max]. Mirrors
    /// `_newRateAtTarget`.
    function _refNewRateAtTarget(int256 start, int256 linearAdaptation, int256 minRate, int256 maxRate)
        internal
        pure
        returns (int256)
    {
        return start.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(minRate, maxRate);
    }

    /* Upstream helpers (used by the Morpho upstream tests above). */

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
