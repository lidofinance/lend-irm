// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {MarketConfigFactory} from "../src/adaptive-curve-irm/MarketConfigFactory.sol";
import {IMarketConfig} from "../src/adaptive-curve-irm/interfaces/IMarketConfig.sol";
import {ConstantsLib} from "./ConstantsLib.sol";
import "../src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol";
import "../lib/lido-lend/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../lib/lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";

import "../lib/forge-std/src/Test.sol";

contract AdaptiveCurveIrmLibTest is Test {
    using MarketParamsLib for MarketParams;
    using stdStorage for StdStorage;
    using MathLib for uint256;

    address public adaptiveCurveIrm;
    MarketConfigFactory internal factory;

    function setUp() public {
        factory = new MarketConfigFactory();
        adaptiveCurveIrm = _deploy();
    }

    /// @dev A bare IRM bound to the shared factory, with the test as morpho and owner (so it can set configs).
    function _deploy() internal returns (address) {
        return address(new AdaptiveCurveIrm(address(this), address(this)));
    }

    /// @dev The periphery's target curve: default constants with a configurable cap, so tests can vary just the cap.
    function _config(uint256 maxBorrowRate) internal pure returns (IMarketConfig.Config memory) {
        return IMarketConfig.Config({
            curveSteepness: ConstantsLib.CURVE_STEEPNESS,
            adjustmentSpeed: ConstantsLib.ADJUSTMENT_SPEED,
            targetUtilization: ConstantsLib.TARGET_UTILIZATION,
            initialRateAtTarget: ConstantsLib.INITIAL_RATE_AT_TARGET,
            minRateAtTarget: ConstantsLib.MIN_RATE_AT_TARGET,
            maxRateAtTarget: ConstantsLib.MAX_RATE_AT_TARGET,
            maxBorrowRate: maxBorrowRate
        });
    }

    /// @dev Deploys a MarketConfig via the factory and points `irmAddress` at it for `id`.
    function _register(address irmAddress, bytes32 id, IMarketConfig.Config memory config) internal {
        AdaptiveCurveIrm(irmAddress).setConfig(Id.wrap(id), factory.createConfig(config));
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
        adaptiveCurveIrm = _deploy();
        rateAtTarget = bound(rateAtTarget, 0, uint256(ConstantsLib.MAX_RATE_AT_TARGET));
        // Full uint128 amount range (no artificial cap): borrow <= supply (Morpho's util <= 1 invariant), everything
        // else unconstrained — large markets where the compounded-interest accrual can overflow uint128 are in scope.
        initTotalBorrowAssets = uint128(bound(initTotalBorrowAssets, 0, initTotalSupplyAssets));
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
        _register(adaptiveCurveIrm, id, _config(bound(maxBorrowRate, 0, uint256(ConstantsLib.MAX_RATE_AT_TARGET))));

        address morpho = makeAddr("morpho");
        _setRateAtTarget(adaptiveCurveIrm, id, rateAtTarget);
        assertEq(IAdaptiveCurveIrm(adaptiveCurveIrm).rateAtTarget(Id.wrap(id)), int256(rateAtTarget), "rateAtTarget");
        vm.mockCall(morpho, abi.encodeWithSelector(IMorpho.market.selector), abi.encode(market));

        // Revert symmetry across the whole range: the lib and MorphoBalancesLib must either both succeed with equal
        // results, or both revert (e.g. when accrual overflows uint128 at extreme amounts). No magic cap is needed —
        // the overflow boundary is exercised and proven identical on both sides.
        (bool libOk, bytes memory libResult) =
            address(this).staticcall(abi.encodeCall(this.libExpectedMarketBalances, (morpho, id, adaptiveCurveIrm)));
        (bool morphoOk, bytes memory morphoResult) =
            address(this).staticcall(abi.encodeCall(this.morphoExpectedMarketBalances, (morpho, marketParams)));

        assertEq(libOk, morphoOk, "lib and MorphoBalancesLib succeed/revert together");
        if (libOk) assertEq(keccak256(libResult), keccak256(morphoResult), "identical balances when both succeed");
    }

    /// @dev External wrappers so the test can `staticcall` each path and compare success/revert symmetrically.
    function libExpectedMarketBalances(address morpho, bytes32 id, address irm)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        return AdaptiveCurveIrmLib.expectedMarketBalances(morpho, id, irm);
    }

    function morphoExpectedMarketBalances(address morpho, MarketParams memory marketParams)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        return MorphoBalancesLib.expectedMarketBalances(IMorpho(morpho), marketParams);
    }

    function testBorrowRateView(uint256 rateAtTarget, Market memory market, uint256 maxBorrowRate) public {
        vm.warp(1000 days);
        adaptiveCurveIrm = _deploy();

        rateAtTarget = bound(rateAtTarget, 0, uint256(ConstantsLib.MAX_RATE_AT_TARGET));
        // borrow rate doesn't revert on utilization > 1, and the test passes. Still, we require that.
        market.totalBorrowAssets = uint128(bound(market.totalBorrowAssets, 0, market.totalSupplyAssets));
        market.lastUpdate = uint128(bound(market.lastUpdate, 0, 1000 days));
        market.fee = uint128(bound(market.fee, 0, 0.25e18));

        MarketParams memory marketParams;
        marketParams.irm = adaptiveCurveIrm;
        bytes32 id = Id.unwrap(marketParams.id());
        _register(adaptiveCurveIrm, id, _config(bound(maxBorrowRate, 0, uint256(ConstantsLib.MAX_RATE_AT_TARGET))));

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
        IMarketConfig.Config memory config = _boundedConfig(
            curveSteepness, adjustmentSpeed, targetUtilization, minRate, maxRate, initialRate, maxBorrowRate, capEnabled
        );
        address irmAddress = _deploy();

        MarketParams memory marketParams;
        marketParams.irm = irmAddress;
        bytes32 id = Id.unwrap(marketParams.id());
        _register(irmAddress, id, config);

        rateAtTarget = bound(rateAtTarget, 0, uint256(config.maxRateAtTarget));
        market.totalBorrowAssets = uint128(bound(market.totalBorrowAssets, 0, market.totalSupplyAssets));
        market.lastUpdate = uint128(bound(market.lastUpdate, 0, 1000 days));
        market.fee = uint128(bound(market.fee, 0, 0.25e18));

        _setRateAtTarget(irmAddress, id, rateAtTarget);

        // The periphery reads the IRM's live params per-instance; assert it matches the contract across the
        // whole config space (not just the default ConstantsLib config).
        uint256 fromLib = AdaptiveCurveIrmLib.borrowRateView(id, market, irmAddress);
        uint256 fromContract = IAdaptiveCurveIrm(irmAddress).borrowRateView(marketParams, market);
        assertEq(fromLib, fromContract, "periphery matches the contract across the config space");
    }

    /// @dev Squeezes raw fuzz inputs into an always-valid `Config`, so the periphery-equivalence fuzzer can vary the
    /// whole curve.
    function _boundedConfig(
        int256 curveSteepness,
        int256 adjustmentSpeed,
        int256 targetUtilization,
        int256 minRate,
        int256 maxRate,
        int256 initialRate,
        uint256 maxBorrowRate,
        bool capEnabled
    ) internal view returns (IMarketConfig.Config memory config) {
        int256 rateCeil = int256(10_000 ether) / int256(365 days); // MAX_RATE_AT_TARGET_LIMIT
        int256 speedCeil = int256(10_000 ether) / int256(365 days); // MAX_ADJUSTMENT_SPEED
        config.curveSteepness = bound(curveSteepness, WAD, int256(100 ether));
        config.adjustmentSpeed = bound(adjustmentSpeed, 0, speedCeil);
        config.targetUtilization = bound(targetUtilization, 1, WAD - 1);
        config.minRateAtTarget = bound(minRate, 1, rateCeil);
        config.maxRateAtTarget = bound(maxRate, config.minRateAtTarget, rateCeil);
        config.initialRateAtTarget = bound(initialRate, config.minRateAtTarget, config.maxRateAtTarget);
        config.maxBorrowRate = capEnabled ? bound(maxBorrowRate, 1, 10_000 ether / uint256(365 days)) : 0;
    }

    /// @dev Forces the IRM's stored `rateAtTarget[id]` to `rate` via vm.store, so equivalence checks start from a known
    /// state.
    function _setRateAtTarget(address irmAddress, bytes32 marketId, uint256 rate) internal {
        vm.store(irmAddress, keccak256(abi.encode(marketId, uint256(0))), bytes32(rate));
    }
}
