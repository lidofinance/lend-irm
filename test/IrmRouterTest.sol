// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IrmRouter} from "../src/irm-router/IrmRouter.sol";
import {ErrorsLib as RouterErrorsLib} from "../src/irm-router/libraries/ErrorsLib.sol";
import {LinearKinkIrm} from "../src/linear-kink-irm/LinearKinkIrm.sol";
import {LinearKinkConfig} from "../src/linear-kink-irm/LinearKinkConfig.sol";
import {LinearKinkParams} from "../src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";
import {ErrorsLib as KinkErrorsLib} from "../src/linear-kink-irm/libraries/ErrorsLib.sol";
import {AdaptiveCurveIrm} from "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {AdaptiveCurveConfig} from "../src/adaptive-curve-irm/AdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {ErrorsLib as AdaptiveErrorsLib} from "../src/adaptive-curve-irm/libraries/ErrorsLib.sol";
import {OwnerManagerErrors} from "../src/common/OwnerManagerErrors.sol";
import {ConstantsLib} from "./ConstantsLib.sol";
import {TestERC1967Proxy} from "./IrmRouterProxyTest.sol";

import {IIrm} from "../lib/lido-lend/src/interfaces/IIrm.sol";
import {MarketParamsLib} from "../lib/lido-lend/src/libraries/MarketParamsLib.sol";
import {MathLib} from "../lib/lido-lend/src/libraries/MathLib.sol";
import {Id, MarketParams, Market} from "../lib/lido-lend/src/interfaces/IMorpho.sol";

import "../lib/forge-std/src/Test.sol";

/// A minimal stand-in for the LidoLend core, keeping this suite a unit test with direct market-state control: it
/// stores markets, pings the market's IRM as the core does, and stamps `lastUpdate` -- the exact surface IrmRouter
/// interacts with.
contract MorphoMock {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;

    mapping(Id => Market) internal markets;

    /// @dev Lets tests assert that the router triggered an accrual (e.g. before an IRM switch).
    uint256 public accrueInterestCalls;

    function market(Id id) external view returns (Market memory) {
        return markets[id];
    }

    /// @dev Test helper: writes the market state directly.
    function setMarket(Id id, Market memory m) external {
        markets[id] = m;
    }

    /// @dev Mimics Morpho's `_accrueInterest` shape: asks the IRM for the rate (calling as Morpho), compounds the
    /// interest onto both totals, and stamps `lastUpdate`.
    function accrueInterest(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        Market memory m = markets[id];

        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0) return; // mirrors Morpho: a same-block accrual never reaches the IRM

        uint256 avgRate = IIrm(marketParams.irm).borrowRate(marketParams, m);
        uint256 interest = uint256(m.totalBorrowAssets).wMulDown(avgRate.wTaylorCompounded(elapsed));

        markets[id].totalSupplyAssets += uint128(interest);
        markets[id].totalBorrowAssets += uint128(interest);
        markets[id].lastUpdate = uint128(block.timestamp);
        accrueInterestCalls++;
    }

    /// @dev Mimics Morpho's `createMarket` shape: one-shot per id, stamps `lastUpdate`, and pings the IRM (so
    /// creation reverts until the router can price the market).
    function createMarket(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        require(markets[id].lastUpdate == 0, "market already created");

        markets[id].lastUpdate = uint128(block.timestamp);
        IIrm(marketParams.irm).borrowRate(marketParams, markets[id]);
    }
}

/// Unit tests for IrmRouter wired exactly like production: the router logic behind an ERC-1967 proxy,
/// initialized through it, fronting immutable LinearKinkIrm/AdaptiveCurveIrm implementations constructed with
/// `ROUTER = router proxy`, against a MorphoMock playing Morpho.
contract IrmRouterTest is Test {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;

    address internal owner = address(0xA11CE);
    address internal manager = address(0xB0B);
    address internal outsider = address(0xDEAD);

    MorphoMock internal mock;
    IrmRouter internal router;
    LinearKinkIrm internal kink;
    AdaptiveCurveIrm internal adaptive;

    MarketParams internal marketParams;
    Id internal id;

    function setUp() public {
        mock = new MorphoMock();
        router = IrmRouter(address(new TestERC1967Proxy(address(new IrmRouter(address(mock))))));
        router.initialize(owner, manager);

        kink = new LinearKinkIrm(owner, manager);
        adaptive = new AdaptiveCurveIrm(address(router), owner, manager);

        marketParams = MarketParams({
            loanToken: address(0x1),
            collateralToken: address(0x2),
            oracle: address(0x3),
            irm: address(router),
            lltv: 0.8 ether
        });
        id = marketParams.id();

        vm.warp(90 days);
    }

    /* FORWARDING */

    /// The routed kink market prices exactly as the implementation does, for both entry points, across utilizations.
    function test_forwarding_routedKinkMatchesDirect() public {
        _configureKink();
        _route(kink);

        uint256[5] memory borrows = [uint256(0), 0.45 ether, 0.9 ether, 0.95 ether, 1 ether];
        for (uint256 i; i < borrows.length; ++i) {
            Market memory m = _market(1 ether, borrows[i]);
            uint256 expected = kink.borrowRateView(marketParams, m);

            assertEq(router.borrowRateView(marketParams, m), expected, "view forwards to the kink impl");
            vm.prank(address(mock));
            assertEq(router.borrowRate(marketParams, m), expected, "borrowRate forwards to the kink impl");
        }
    }

    /// The full Morpho accrual path (mock -> router -> kink) compounds interest at the kink implementation's rate.
    function test_forwarding_accrueInterestPathUsesKinkRate() public {
        _configureKink();
        _route(kink);

        Market memory m = _market(1 ether, 0.9 ether);
        m.lastUpdate = uint128(block.timestamp);
        mock.setMarket(id, m);

        vm.warp(block.timestamp + 1 days);
        uint256 expectedRate = kink.borrowRateView(marketParams, m);
        uint256 expectedInterest = uint256(m.totalBorrowAssets).wMulDown(expectedRate.wTaylorCompounded(1 days));

        mock.accrueInterest(marketParams);

        Market memory accrued = mock.market(id);
        assertEq(accrued.totalBorrowAssets, m.totalBorrowAssets + expectedInterest, "interest at the kink rate");
        assertEq(accrued.totalSupplyAssets, m.totalSupplyAssets + expectedInterest, "supply grew by the interest");
        assertEq(accrued.lastUpdate, block.timestamp, "lastUpdate stamped");
    }

    /* GATES */

    /// State-changing borrowRate is Morpho-only, even for a routed market.
    function test_borrowRate_nonMorphoCallerReverts() public {
        _configureKink();
        _route(kink);
        Market memory m = _market(1 ether, 0.5 ether);

        vm.prank(outsider);
        vm.expectRevert(bytes(RouterErrorsLib.NOT_MORPHO));
        router.borrowRate(marketParams, m);
    }

    /// An unrouted market cannot be priced: both entry points revert IRM_NOT_SET.
    function test_unroutedMarketReverts() public {
        Market memory m = _market(1 ether, 0.5 ether);

        vm.expectRevert(bytes(RouterErrorsLib.IRM_NOT_SET));
        router.borrowRateView(marketParams, m);

        vm.prank(address(mock));
        vm.expectRevert(bytes(RouterErrorsLib.IRM_NOT_SET));
        router.borrowRate(marketParams, m);
    }

    /* SET MARKET IRM: AUTH */

    /// The manager routes markets alongside the owner: routing is the router's operational duty.
    function test_setMarketIrm_managerCanRoute() public {
        _configureKink();

        vm.prank(manager);
        router.setMarketIrm(marketParams, kink);

        assertEq(address(router.marketIrm(id)), address(kink), "manager routed the market");
    }

    /// setMarketIrm rejects anyone who is neither owner nor manager.
    function test_setMarketIrm_outsiderReverts() public {
        _configureKink();

        vm.prank(outsider);
        vm.expectRevert(bytes(OwnerManagerErrors.NOT_AUTHORIZED));
        router.setMarketIrm(marketParams, kink);
    }

    /// setMarketIrm rejects the zero implementation.
    function test_setMarketIrm_zeroIrmReverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes(OwnerManagerErrors.ZERO_ADDRESS));
        router.setMarketIrm(marketParams, IIrm(address(0)));
    }

    /// setMarketIrm rejects marketParams that do not commit to this router: the id would belong to a different
    /// market and the real router-fronted market would stay unrouted.
    function test_setMarketIrm_wrongIrmFieldReverts() public {
        _configureKink();
        MarketParams memory wrong = marketParams;
        wrong.irm = address(kink);

        vm.prank(owner);
        vm.expectRevert(bytes(RouterErrorsLib.NOT_ROUTER_MARKET));
        router.setMarketIrm(wrong, kink);
    }

    /* SET MARKET IRM: PROBE */

    /// Routing a not-yet-created market does not touch the implementation: an unconfigured one routes fine, and
    /// the failure surfaces at createMarket, which reverts and creates nothing.
    function test_setMarketIrm_unconfiguredRoutesButCreateMarketReverts() public {
        _route(kink);
        assertEq(address(router.marketIrm(id)), address(kink), "routing succeeded without a probe");

        vm.expectRevert(bytes(KinkErrorsLib.CONFIG_NOT_SET));
        mock.createMarket(marketParams);

        assertEq(mock.market(id).lastUpdate, 0, "nothing was created");

        _configureKink();
        mock.createMarket(marketParams);
        assertEq(mock.market(id).lastUpdate, block.timestamp, "created once configured");
    }

    /// A mis-constructed ROUTER gate (an AdaptiveCurveIrm built with `ROUTER = mock` instead of the router) is
    /// caught by the live-market probe, and pre-creation by createMarket's own ping.
    function test_setMarketIrm_probeCatchesWrongRouterGate() public {
        AdaptiveCurveIrm wrongGate = new AdaptiveCurveIrm(address(mock), owner, manager);
        AdaptiveCurveConfig config = new AdaptiveCurveConfig(_adaptiveConfig());
        vm.prank(manager);
        wrongGate.applyIrmConfig(marketParams, address(config));

        // Pre-creation: routing succeeds (no probe), the createMarket ping catches the wrong gate and creates nothing.
        _route(wrongGate);
        vm.expectRevert(bytes(AdaptiveErrorsLib.NOT_ROUTER));
        mock.createMarket(marketParams);
        assertEq(mock.market(id).lastUpdate, 0, "nothing was created");

        // Live market: the probe catches the wrong gate at setMarketIrm and the switch rolls back.
        _configureKink();
        _route(kink);
        mock.createMarket(marketParams);
        vm.prank(owner);
        vm.expectRevert(bytes(AdaptiveErrorsLib.NOT_ROUTER));
        router.setMarketIrm(marketParams, wrongGate);
        assertEq(address(router.marketIrm(id)), address(kink), "switch rolled back");
    }

    /// An implementation with no config for the market is caught by the live-market probe, and the switch rolls
    /// back.
    function test_setMarketIrm_probeCatchesUnconfiguredImpl() public {
        _configureKink();
        _route(kink);
        mock.createMarket(marketParams);

        // `adaptive` has no config for this market: the probe reverts and the route stays on the kink model.
        vm.prank(owner);
        vm.expectRevert(bytes(AdaptiveErrorsLib.CONFIG_NOT_SET));
        router.setMarketIrm(marketParams, adaptive);
        assertEq(address(router.marketIrm(id)), address(kink), "switch rolled back");
    }

    /// Routing pre-creation writes no implementation state, and the launch seed comes from createMarket's ping.
    /// Attaching a fresh adaptive implementation to a LIVE market seeds it through the probe.
    function test_setMarketIrm_seedSemantics() public {
        _configureAdaptive(adaptive);
        _route(adaptive);
        assertEq(adaptive.rateAtTarget(id), 0, "pre-creation routing writes no state");

        mock.createMarket(marketParams);
        assertEq(adaptive.rateAtTarget(id), ConstantsLib.INITIAL_RATE_AT_TARGET, "createMarket's ping seeds the rate");

        AdaptiveCurveIrm fresh = new AdaptiveCurveIrm(address(router), owner, manager);
        _configureAdaptive(fresh);
        _route(fresh);
        assertEq(fresh.rateAtTarget(id), ConstantsLib.INITIAL_RATE_AT_TARGET, "live-market probe seeds a fresh impl");
    }

    /// Re-routing before createMarket is idempotent: an uncreated market is never probed, so no implementation
    /// state exists to decay. Regression: the old pre-creation probe saw the whole epoch as elapsed at zero
    /// utilization on its second run and crushed rateAtTarget from initialRateAtTarget to minRateAtTarget before
    /// the market ever launched.
    function test_setMarketIrm_repeatBeforeCreateMarketKeepsSeededRate() public {
        _configureAdaptive(adaptive);
        _configureKink();

        // A duplicate route (script retry) and a kink detour with a route back, all before createMarket.
        _route(adaptive);
        _route(adaptive);
        _route(kink);
        _route(adaptive);

        assertEq(adaptive.rateAtTarget(id), 0, "pre-creation routing never touches the implementation");

        mock.createMarket(marketParams);
        assertEq(
            adaptive.rateAtTarget(id),
            ConstantsLib.INITIAL_RATE_AT_TARGET,
            "the market launches at initialRateAtTarget, not the floor"
        );
    }

    /// Switching a live market first accrues interest, settling the elapsed period at the OLD model's rate.
    function test_setMarketIrm_accruesBeforeSwitch() public {
        _configureKink();
        _route(kink);
        mock.createMarket(marketParams);
        _fundMarket(1 ether, 0.9 ether);
        assertEq(mock.accrueInterestCalls(), 0, "no accrual yet");

        vm.warp(block.timestamp + 30 days);
        _configureAdaptive(adaptive);
        _route(adaptive);

        assertEq(mock.accrueInterestCalls(), 1, "the switch triggered exactly one accrual");
        Market memory m = mock.market(id);
        assertEq(m.lastUpdate, block.timestamp, "accrual stamped lastUpdate at the switch");
        assertGt(m.totalBorrowAssets, 0.9 ether, "the elapsed period was settled (interest accrued)");
        assertEq(address(router.marketIrm(id)), address(adaptive), "market routed to the new impl");
    }

    /* CREATE MARKET ORDERING */

    /// createMarket pings borrowRate through the router, so it reverts until the market is routed.
    function test_createMarket_revertsUntilRouted() public {
        vm.expectRevert(bytes(RouterErrorsLib.IRM_NOT_SET));
        mock.createMarket(marketParams);

        _configureKink();
        _route(kink);
        mock.createMarket(marketParams);

        assertEq(mock.market(id).lastUpdate, block.timestamp, "market created once config + routing are in place");
    }

    /* MIGRATION */

    /// A live market migrates kink -> adaptive -> back to kink and is priced by the correct model after each switch.
    function test_migration_kinkToAdaptiveAndBack() public {
        _configureKink();
        _configureAdaptive(adaptive);
        _route(kink);
        mock.createMarket(marketParams);
        _fundMarket(1 ether, 0.9 ether);

        // Leg 1: the kink model prices. U = 0.9 == optimalUtilization -> baseRate + slope1.
        Market memory m = mock.market(id);
        assertEq(router.borrowRateView(marketParams, m), 1e9 + 4e9, "kink prices at base + slope1");

        // Leg 2: switch to adaptive -- the router now prices with the adaptive model.
        vm.warp(block.timestamp + 10 days);
        _route(adaptive);
        m = mock.market(id);
        uint256 adaptiveRate = adaptive.borrowRateView(marketParams, m);
        assertEq(router.borrowRateView(marketParams, m), adaptiveRate, "router forwards to the adaptive impl");
        assertTrue(adaptiveRate != kink.borrowRateView(marketParams, m), "the models genuinely price differently");

        // Leg 3: switch back to kink -- the market keeps its independent kink params and prices with them again.
        vm.warp(block.timestamp + 10 days);
        _route(kink);
        m = mock.market(id);
        assertEq(
            router.borrowRateView(marketParams, m),
            kink.borrowRateView(marketParams, m),
            "router forwards to the kink impl again"
        );
    }

    /// Routing back to a previously used adaptive implementation resumes from the rateAtTarget frozen at the
    /// switch-away -- it is never reset and does not adapt while the market is routed elsewhere.
    function test_migration_backToUsedAdaptiveResumesStaleRate() public {
        _configureKink();
        _configureAdaptive(adaptive);
        _route(adaptive);
        mock.createMarket(marketParams);
        _fundMarket(1 ether, 1 ether); // 100% utilization: the adaptive rate climbs on every accrual

        int256 adapted = _adaptRateUp();
        assertGt(adapted, ConstantsLib.INITIAL_RATE_AT_TARGET, "the rate adapted away from initial");

        // Switch away in the same block as the last accrual, freezing the adaptive state as-is.
        _route(kink);
        int256 frozen = adaptive.rateAtTarget(id);
        assertEq(frozen, adapted, "switch-away froze the adaptive state");

        // The market lives on the kink model. The abandoned implementation's state does not move.
        vm.warp(block.timestamp + 30 days);
        mock.accrueInterest(marketParams);
        assertEq(adaptive.rateAtTarget(id), frozen, "no adaptation while routed away");

        // Route back: the probe runs at elapsed zero and keeps the stale value verbatim (no re-seed).
        _route(adaptive);
        assertEq(adaptive.rateAtTarget(id), frozen, "re-attachment resumes from the stale rateAtTarget");
    }

    /// The migration runbook for carrying the adapted rate onto a fresh implementation: snapshot rateAtTarget,
    /// configure the fresh implementation with initialRateAtTarget equal to the snapshot, switch -- the probe seeds
    /// the fresh state with exactly the old rate.
    function test_migration_snapshotSeedsFreshAdaptive() public {
        _configureAdaptive(adaptive);
        _route(adaptive);
        mock.createMarket(marketParams);
        _fundMarket(1 ether, 1 ether);

        int256 snapshot = _adaptRateUp();
        assertGt(snapshot, ConstantsLib.INITIAL_RATE_AT_TARGET, "the rate adapted away from initial");

        AdaptiveCurveIrm fresh = new AdaptiveCurveIrm(address(router), owner, manager);
        AdaptiveCurveParams memory cfg = _adaptiveConfig();
        cfg.initialRateAtTarget = snapshot;
        AdaptiveCurveConfig config = new AdaptiveCurveConfig(cfg);
        vm.prank(manager);
        fresh.applyIrmConfig(marketParams, address(config));

        _route(fresh);

        assertEq(fresh.rateAtTarget(id), snapshot, "the fresh implementation carries the snapshotted rate");
    }

    /* HELPERS */

    /// @dev The LinearKinkIrmTest default curve: kink at 90%, base 1e9, slopes 4e9/60e9 (per second, WAD-scaled).
    function _configureKink() internal {
        LinearKinkConfig config = new LinearKinkConfig(
            LinearKinkParams({optimalUtilization: 0.9 ether, baseRate: 1e9, slope1: 4e9, slope2: 60e9})
        );
        vm.prank(manager);
        kink.applyIrmConfig(marketParams, address(config));
    }

    /// @dev Registers the default adaptive curve for the wired market on `irm_`.
    function _configureAdaptive(AdaptiveCurveIrm irm_) internal {
        AdaptiveCurveConfig config = new AdaptiveCurveConfig(_adaptiveConfig());
        vm.prank(manager);
        irm_.applyIrmConfig(marketParams, address(config));
    }

    /// @dev The upstream default adaptive config, cap off.
    function _adaptiveConfig() internal pure returns (AdaptiveCurveParams memory) {
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

    /// @dev Routes the wired market to `irm_` as the owner.
    function _route(IIrm irm_) internal {
        vm.prank(owner);
        router.setMarketIrm(marketParams, irm_);
    }

    /// @dev Adapts the routed adaptive market's rate upward with three accruals at 100% utilization and returns the
    /// resulting rateAtTarget.
    function _adaptRateUp() internal returns (int256) {
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 5 days);
            mock.accrueInterest(marketParams);
        }
        return adaptive.rateAtTarget(id);
    }

    /// @dev Writes supply/borrow into the mock's stored market, preserving its `lastUpdate`.
    function _fundMarket(uint256 supply, uint256 borrow) internal {
        Market memory m = mock.market(id);
        m.totalSupplyAssets = uint128(supply);
        m.totalBorrowAssets = uint128(borrow);
        mock.setMarket(id, m);
    }

    /// @dev A bare `Market` carrying only supply/borrow (i.e. a utilization).
    function _market(uint256 supply, uint256 borrow) internal pure returns (Market memory m) {
        m.totalSupplyAssets = uint128(supply);
        m.totalBorrowAssets = uint128(borrow);
    }
}
