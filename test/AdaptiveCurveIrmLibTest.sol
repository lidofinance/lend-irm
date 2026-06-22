// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {ConstantsLib} from "./ConstantsLib.sol";
import "../src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol";
import "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

import "../lib/forge-std/src/Test.sol";

contract AdaptiveCurveIrmLibTest is Test {
    using MarketParamsLib for MarketParams;
    using stdStorage for StdStorage;
    using MathLib for uint256;

    address public adaptiveCurveIrm;

    function setUp() public {
        adaptiveCurveIrm = _deploy(0);
    }

    /// @dev The periphery's target IRM: default curve with a configurable cap, so tests can vary just the cap.
    function _deploy(uint256 maxBorrowRate) internal returns (address) {
        return address(
            new AdaptiveCurveIrm(
                address(this),
                IAdaptiveCurveIrm.Config({
                    curveSteepness: ConstantsLib.CURVE_STEEPNESS,
                    adjustmentSpeed: ConstantsLib.ADJUSTMENT_SPEED,
                    targetUtilization: ConstantsLib.TARGET_UTILIZATION,
                    initialRateAtTarget: ConstantsLib.INITIAL_RATE_AT_TARGET,
                    minRateAtTarget: ConstantsLib.MIN_RATE_AT_TARGET,
                    maxRateAtTarget: ConstantsLib.MAX_RATE_AT_TARGET,
                    maxBorrowRate: maxBorrowRate
                })
            )
        );
    }

    function testExpectedMarketBalances(
        uint256 rateAtTarget,
        uint128 initTotalSupplyAssets,
        uint128 initTotalBorrowAssets,
        uint128 initTotalSupplyShares,
        uint128 initTotalBorrowShares,
        uint128 lastUpdate,
        uint128 fee,
        uint256 maxBorrowRate
    ) public {
        vm.warp(1000 days);
        adaptiveCurveIrm = _deploy(bound(maxBorrowRate, 0, uint256(ConstantsLib.MAX_RATE_AT_TARGET)));
        rateAtTarget = bound(rateAtTarget, 0, uint256(ConstantsLib.MAX_RATE_AT_TARGET));
        initTotalSupplyAssets = uint128(bound(initTotalSupplyAssets, 0, 1e35));
        initTotalBorrowAssets = uint128(bound(initTotalBorrowAssets, 0, initTotalSupplyAssets));
        initTotalSupplyShares = uint128(bound(initTotalSupplyShares, 0, 1e35));
        initTotalBorrowShares = uint128(bound(initTotalBorrowShares, 0, 1e35));
        lastUpdate = uint128(bound(lastUpdate, 0, 1000 days));
        fee = uint128(bound(fee, 0, 0.25e18));

        Market memory market = Market({
            totalSupplyAssets: initTotalSupplyAssets,
            totalSupplyShares: initTotalSupplyShares,
            totalBorrowAssets: initTotalBorrowAssets,
            totalBorrowShares: initTotalBorrowShares,
            lastUpdate: lastUpdate,
            fee: fee
        });

        MarketParams memory marketParams = MarketParams({
            loanToken: address(0), collateralToken: address(0), oracle: address(0), irm: adaptiveCurveIrm, lltv: 0
        });
        bytes32 id = Id.unwrap(marketParams.id());

        address morpho = makeAddr("morpho");
        // set rate at target.
        _setRateAtTarget(adaptiveCurveIrm, id, rateAtTarget);
        assertEq(IAdaptiveCurveIrm(adaptiveCurveIrm).rateAtTarget(Id.wrap(id)), int256(rateAtTarget), "rateAtTarget");
        // set market state.
        vm.mockCall(morpho, abi.encodeWithSelector(IMorpho.market.selector), abi.encode(market));

        this.adaptiveCurveIrm();
        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            AdaptiveCurveIrmLib.expectedMarketBalances(morpho, id, adaptiveCurveIrm);
        this.adaptiveCurveIrm();
        (
            uint256 expectedTotalSupplyAssets,
            uint256 expectedTotalSupplyShares,
            uint256 expectedTotalBorrowAssets,
            uint256 expectedTotalBorrowShares
        ) = MorphoBalancesLib.expectedMarketBalances(IMorpho(morpho), marketParams);

        assertEq(totalSupplyAssets, expectedTotalSupplyAssets, "total supply assets");
        assertEq(totalSupplyShares, expectedTotalSupplyShares, "total supply shares");
        assertEq(totalBorrowAssets, expectedTotalBorrowAssets, "total borrow assets");
        assertEq(totalBorrowShares, expectedTotalBorrowShares, "total borrow shares");
    }

    function testBorrowRateView(uint256 rateAtTarget, Market memory market, uint256 maxBorrowRate) public {
        vm.warp(1000 days);
        adaptiveCurveIrm = _deploy(bound(maxBorrowRate, 0, uint256(ConstantsLib.MAX_RATE_AT_TARGET)));

        rateAtTarget = bound(rateAtTarget, 0, uint256(ConstantsLib.MAX_RATE_AT_TARGET));
        // borrow rate doesn't revert on utilization > 1, and the test passes. Still, we require that.
        market.totalBorrowAssets = uint128(bound(market.totalBorrowAssets, 0, market.totalSupplyAssets));
        market.lastUpdate = uint128(bound(market.lastUpdate, 0, 1000 days));
        market.fee = uint128(bound(market.fee, 0, 0.25e18));

        MarketParams memory marketParams;
        marketParams.irm = adaptiveCurveIrm;
        bytes32 id = Id.unwrap(marketParams.id());

        // set rate at target.
        _setRateAtTarget(adaptiveCurveIrm, id, rateAtTarget);
        assertEq(IAdaptiveCurveIrm(adaptiveCurveIrm).rateAtTarget(Id.wrap(id)), int256(rateAtTarget), "rateAtTarget");

        uint256 computedBorrowRate = AdaptiveCurveIrmLib.borrowRateView(id, market, adaptiveCurveIrm);
        uint256 expectedBorrowRate = IAdaptiveCurveIrm(adaptiveCurveIrm).borrowRateView(marketParams, market);
        assertEq(computedBorrowRate, expectedBorrowRate, "computedBorrowRate");
    }

    /// The periphery borrowRateView matches the contract's own view across the full config space.
    function testFuzz_borrowRateView_matchesContract_acrossConfigs(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        uint256 maxBorrowRate,
        bool capEnabled,
        uint256 rateAtTarget,
        Market memory market
    ) public {
        vm.warp(1000 days);
        IAdaptiveCurveIrm.Config memory cfg = _boundedCfg(
            curveSteepness, adjustmentSpeed, targetUtilization, minRate, maxRate, initialRate, maxBorrowRate, capEnabled
        );
        address irmAddr = address(new AdaptiveCurveIrm(address(this), cfg));

        MarketParams memory mp;
        mp.irm = irmAddr;
        bytes32 id = Id.unwrap(mp.id());

        rateAtTarget = bound(rateAtTarget, 0, uint256(cfg.maxRateAtTarget));
        market.totalBorrowAssets = uint128(bound(market.totalBorrowAssets, 0, market.totalSupplyAssets));
        market.lastUpdate = uint128(bound(market.lastUpdate, 0, 1000 days));
        market.fee = uint128(bound(market.fee, 0, 0.25e18));

        _setRateAtTarget(irmAddr, id, rateAtTarget);

        // The periphery reads the IRM's live params per-instance; assert it matches the contract across the
        // whole config space (not just the default ConstantsLib config).
        uint256 fromLib = AdaptiveCurveIrmLib.borrowRateView(id, market, irmAddr);
        uint256 fromContract = IAdaptiveCurveIrm(irmAddr).borrowRateView(mp, market);
        assertEq(fromLib, fromContract, "periphery matches the contract across the config space");
    }

    /// @dev Squeezes raw fuzz inputs into an always-valid `Config`, so the periphery-equivalence fuzzer can vary the
    /// whole curve.
    function _boundedCfg(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        uint256 maxBorrowRate,
        bool capEnabled
    ) internal view returns (IAdaptiveCurveIrm.Config memory cfg) {
        int256 rateCeil = int256(10_000 ether) / int256(365 days); // MAX_RATE_AT_TARGET_LIMIT
        int256 speedCeil = int256(10_000 ether) / int256(365 days); // MAX_ADJUSTMENT_SPEED
        cfg.curveSteepness = bound(curveSteepness, WAD, int256(100 ether));
        cfg.adjustmentSpeed = bound(adjustmentSpeed, 0, speedCeil);
        cfg.targetUtilization = bound(targetUtilization, 1, WAD - 1);
        cfg.minRateAtTarget = bound(minRate, 1, rateCeil);
        cfg.maxRateAtTarget = bound(maxRate, cfg.minRateAtTarget, rateCeil);
        cfg.initialRateAtTarget = bound(initialRate, cfg.minRateAtTarget, cfg.maxRateAtTarget);
        cfg.maxBorrowRate = capEnabled ? bound(maxBorrowRate, 1, 10_000 ether / uint256(365 days)) : 0;
    }

    /// @dev Forces the IRM's stored `rateAtTarget[id]` to `rate` via vm.store, so equivalence checks start from a known
    /// state.
    function _setRateAtTarget(address irmAddr, bytes32 marketId, uint256 rate) internal {
        vm.store(irmAddr, keccak256(abi.encode(marketId, uint256(0))), bytes32(rate));
    }
}
