// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {MarketConfigFactory} from "../src/adaptive-curve-irm/MarketConfigFactory.sol";
import {IMarketConfig} from "../src/adaptive-curve-irm/interfaces/IMarketConfig.sol";
import "../src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol";

import "../lib/forge-std/src/Test.sol";

/// Reparametrization in the per-market-config model: re-registering a new MarketConfig under the SAME id swaps the
/// market's curve. The dynamics (snap on the next adapting call, lazy re-clamp, whole-interval repricing) are emergent
/// from reading whichever config is currently registered + the unchanged curve math + the persisted rateAtTarget — no
/// proxy involved. Variant A allows the re-registration these tests exercise.
contract AdaptiveCurveIrmReparamTest is Test {
    using MarketParamsLib for MarketParams;

    int256 internal constant Y = 365 days;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TARGET = 0.9 ether;

    AdaptiveCurveIrm internal irm;
    MarketConfigFactory internal factory;
    MarketParams internal params;
    Id internal id;

    /// Re-registering bounds that still contain the rate preserves rateAtTarget with no spike.
    function test_reparam_statePersists_noSpike_whenBoundsContainRate() public {
        _wired(_config(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y));
        _adaptDown();

        int256 rateBefore = _rateAtTarget();
        uint256 borrowBefore = _borrowAtTarget();

        _reparam(_config(rateBefore, rateBefore / 2, rateBefore * 2));

        assertEq(_rateAtTarget(), rateBefore, "rateAtTarget persisted through reparametrization (storage intact)");
        assertEq(_borrowAtTarget(), borrowBefore, "no spike: borrow continues from the persisted rate");
    }

    /// A new MIN above the stored rate snaps rateAtTarget up on the next adapting call.
    function test_reparam_rateRises_whenNewMinAboveStoredRate() public {
        _wired(_config(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y));
        _adaptDown();

        int256 rateBefore = _rateAtTarget();
        int256 newMinRate = rateBefore * 3 / 2;
        _reparam(_config(newMinRate, newMinRate, newMinRate * 4));

        assertEq(_rateAtTarget(), rateBefore, "stored rate unchanged until the next adapting call");

        _poke(0.95 ether);
        int256 rateAfter = _rateAtTarget();
        assertGe(rateAfter, newMinRate, "rate clamped up to the new MIN");
        assertGt(rateAfter, rateBefore, "rate jumped up after the reparametrization (the spike)");
    }

    /// A new MAX below the stored rate snaps rateAtTarget down on the next adapting call.
    function test_reparam_rateDrops_whenNewMaxBelowStoredRate() public {
        _wired(_config(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y));
        _adaptDown();

        int256 rateBefore = _rateAtTarget();
        int256 newMaxRate = rateBefore * 2 / 3;
        _reparam(_config(newMaxRate, rateBefore / 4, newMaxRate));

        assertEq(_rateAtTarget(), rateBefore, "stored rate unchanged until the next adapting call");

        _poke(0.95 ether);
        int256 rateAfter = _rateAtTarget();
        assertLe(rateAfter, newMaxRate, "rate clamped down to the new MAX");
        assertLt(rateAfter, rateBefore, "rate jumped down after the reparametrization");
    }

    /// The cap applies after registration and a tighter cap takes effect on the next call.
    function test_reparam_capAppliesAndTightens() public {
        int256 initialRate = int256(0.04 ether) / Y;
        int256 minRate = int256(0.005 ether) / Y;
        int256 maxRate = int256(0.08 ether) / Y;

        // Uncapped tip at 100% util (first interaction) = initial * curveSteepness = 0.06/yr.
        IMarketConfig.Config memory config = _config(initialRate, minRate, maxRate);
        config.maxBorrowRate = 0.05 ether / uint256(Y); // below the 0.06/yr tip
        _wired(config);

        assertEq(
            irm.borrowRateView(params, _market(1 ether)),
            config.maxBorrowRate,
            "charged rate clamped to MAX_BORROW_RATE"
        );

        // Reparametrize to a tighter cap (same curve); the new ceiling takes effect on the next call.
        IMarketConfig.Config memory tighterCapConfig = _config(initialRate, minRate, maxRate);
        tighterCapConfig.maxBorrowRate = 0.03 ether / uint256(Y);
        _reparam(tighterCapConfig);

        assertEq(
            irm.borrowRateView(params, _market(1 ether)),
            tighterCapConfig.maxBorrowRate,
            "tighter cap bites on the next call"
        );
    }

    /// A cap below the adapted rate clamps the charged rate immediately, leaving rateAtTarget intact.
    function test_reparam_capBelowAdaptedRate_clampsImmediately_keepsState() public {
        _wired(_config(int256(0.02 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y));
        _adaptUp();

        int256 rateBefore = _rateAtTarget();
        uint256 chargedBefore = irm.borrowRateView(params, _market(TARGET));

        int256 capRate = rateBefore / 2;
        IMarketConfig.Config memory cappedConfig = _config(rateBefore, rateBefore / 2, rateBefore * 2);
        cappedConfig.maxBorrowRate = uint256(capRate);
        _reparam(cappedConfig);

        assertEq(_rateAtTarget(), rateBefore, "rateAtTarget preserved across reparametrization");

        uint256 chargedAfter = irm.borrowRateView(params, _market(TARGET));
        assertEq(chargedAfter, uint256(capRate), "charged rate clamped to the new cap on the next call");
        assertLt(chargedAfter, chargedBefore, "charged rate dropped after the reparametrization");
        assertEq(_rateAtTarget(), rateBefore, "the cap did not touch rateAtTarget");
    }

    /// After tightening MAX, an at-target poke leaves rateAtTarget out of range until a later off-target call.
    function test_reparam_tighterMax_atTargetPokeDefersRebound() public {
        _wired(_config(int256(0.02 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y));
        _adaptUp();

        int256 rateBefore = _rateAtTarget();
        int256 newMaxRate = rateBefore / 2;
        _reparam(_config(newMaxRate, int256(0.005 ether) / Y, newMaxRate));

        _poke(TARGET);
        assertEq(_rateAtTarget(), rateBefore, "at-target poke leaves the stored rate unbounded");
        assertGt(_rateAtTarget(), newMaxRate, "rateAtTarget still above the new MAX (rebound deferred)");
        assertEq(
            irm.borrowRateView(params, _market(TARGET)),
            uint256(rateBefore),
            "uncapped: the stale above-MAX rate is charged as-is"
        );

        _poke(0.3 ether);
        assertLe(_rateAtTarget(), newMaxRate, "off-target poke re-bounds rateAtTarget down to the new MAX");
    }

    /// Widening lets rateAtTarget creep up; a later narrowing snaps it onto the new ceiling in one step.
    function test_reparam_widenLetsRateCreep_thenNarrowShocks() public {
        int256 initialMinRate = int256(0.005 ether) / Y;
        int256 initialMaxRate = int256(0.05 ether) / Y;

        _wired(_config(initialMaxRate, initialMinRate, initialMaxRate));
        _poke(TARGET);
        assertEq(_rateAtTarget(), initialMaxRate, "seed: at-target pinned at the initial ceiling");

        int256 wideMaxRate = int256(0.2 ether) / Y;
        _reparam(_config(initialMaxRate, initialMinRate, wideMaxRate));
        assertEq(_rateAtTarget(), initialMaxRate, "widen alone does not move the stored rate");

        // Off-target above target makes rateAtTarget creep up, step by step, but stay under the widened ceiling.
        int256 beforeCrawl = _rateAtTarget();
        _crawl(0.98 ether, 1 hours, 1);
        int256 afterFirstHour = _rateAtTarget();
        _crawl(0.98 ether, 1 hours, 11); // 12h total
        int256 crept = _rateAtTarget();

        assertGt(afterFirstHour, beforeCrawl, "rate creeps up after the first off-target step");
        assertGt(crept, afterFirstHour, "rate keeps creeping up over more steps");
        assertLt(crept, wideMaxRate, "creep stays below the widened ceiling (creep, not snap)");

        // Narrow the ceiling below the crept rate: unchanged until the next adapting call, then snapped in one step.
        int256 tightMaxRate = int256(0.03 ether) / Y;
        _reparam(_config(tightMaxRate, initialMinRate, tightMaxRate));
        assertEq(_rateAtTarget(), crept, "narrow alone leaves the crept rate unchanged");
        assertGt(crept, tightMaxRate, "the crept rate is above the new tight ceiling");

        _crawl(0.98 ether, 1 hours, 1);
        assertEq(_rateAtTarget(), tightMaxRate, "shock: snapped exactly onto the new tight ceiling in one step");
    }

    /// Changing targetUtilization shifts the charged rate at the same utilization, without moving rateAtTarget.
    function test_reparam_targetShift_changesChargedRate_keepsState() public {
        _wired(_defaultConfig());
        _poke(TARGET);

        int256 storedRate = _rateAtTarget();
        uint256 chargedBefore = irm.borrowRateView(params, _market(0.8 ether));

        IMarketConfig.Config memory newConfig = _config(storedRate, storedRate / 2, storedRate * 2);
        newConfig.targetUtilization = int256(0.5 ether);
        _reparam(newConfig);

        assertEq(_rateAtTarget(), storedRate, "target change does not move the stored rate");
        uint256 chargedAfter = irm.borrowRateView(params, _market(0.8 ether));
        assertGt(chargedAfter, chargedBefore, "same utilization charges more after the target moves below it");
    }

    /// Changing curveSteepness shifts the charged rate above target, without moving rateAtTarget.
    function test_reparam_steepnessShift_changesChargedRate_keepsState() public {
        _wired(_defaultConfig());
        _poke(TARGET);

        int256 storedRate = _rateAtTarget();
        uint256 chargedBefore = irm.borrowRateView(params, _market(0.98 ether));

        IMarketConfig.Config memory newConfig = _config(storedRate, storedRate / 2, storedRate * 2);
        newConfig.curveSteepness = int256(4 ether);
        _reparam(newConfig);

        assertEq(_rateAtTarget(), storedRate, "steepness change does not move the stored rate");
        uint256 chargedAfter = irm.borrowRateView(params, _market(0.98 ether));
        assertGt(chargedAfter, chargedBefore, "steeper curve charges more above target at the same utilization");
    }

    /// The first call after reparametrization prices the whole interval since lastUpdate at the new params.
    function test_reparam_newParamsPriceWholeIntervalSinceLastUpdate() public {
        _wired(_defaultConfig());
        _adaptUp();
        int256 startRate = _rateAtTarget();

        // Market stamped "now"; a long span elapses before the next call touches it.
        Market memory market = _market(0.98 ether); // market.lastUpdate = block.timestamp
        vm.warp(block.timestamp + 60 days);

        // Reparametrize mid-span to a faster adjustmentSpeed; the curve is otherwise the same and the bounds keep
        // startRate.
        IMarketConfig.Config memory fasterConfig = _config(startRate, startRate / 4, startRate * 4);
        fasterConfig.adjustmentSpeed = int256(80 ether) / Y; // 4x the original 20/yr
        _reparam(fasterConfig);

        // The first borrowRate after reparametrization prices the whole [lastUpdate, now] span at the NEW params,
        // even though lastUpdate predates it.
        irm.borrowRate(params, market);
        int256 newRate = _rateAtTarget();

        // Reference: a standalone impl seeded to the same start, applied to the same span from scratch.
        (AdaptiveCurveIrm control, MarketParams memory controlParams) = _seededControl(fasterConfig, startRate);
        control.borrowRate(controlParams, market);

        assertEq(control.rateAtTarget(controlParams.id()), newRate, "whole pre-reparam span priced at the new params");
        assertTrue(newRate != startRate, "the span moved the stored rate");
    }

    /// Changing adjustmentSpeed speeds up future adaptation without moving rateAtTarget at the reparametrization.
    function test_reparam_adjustmentSpeedShift_changesFutureAdaptation_keepsState() public {
        _wired(_defaultConfig());
        _poke(TARGET); // seed rateAtTarget := initial (at target, no adaptation yet)
        int256 rateBefore = _rateAtTarget();

        // Reparametrize to a 4x faster adjustmentSpeed; bounds wide, curve otherwise identical.
        IMarketConfig.Config memory fasterConfig = _config(rateBefore, rateBefore / 4, rateBefore * 4);
        fasterConfig.adjustmentSpeed = int256(80 ether) / Y;
        _reparam(fasterConfig);
        assertEq(
            _rateAtTarget(), rateBefore, "adjustmentSpeed change does not move the stored rate at reparametrization"
        );

        // One off-target step under the fast speed.
        _poke(0.3 ether);
        int256 fastRate = _rateAtTarget();

        // Control: same start and same 5-day step under the ORIGINAL (slow) speed.
        IMarketConfig.Config memory slowerConfig = _config(rateBefore, rateBefore / 4, rateBefore * 4);
        slowerConfig.adjustmentSpeed = int256(20 ether) / Y;
        (AdaptiveCurveIrm control, MarketParams memory controlParams) = _seededControl(slowerConfig, rateBefore);
        Market memory controlMarket = _market(0.3 ether);
        vm.warp(block.timestamp + 5 days);
        control.borrowRate(controlParams, controlMarket);
        int256 slowRate = control.rateAtTarget(controlParams.id());

        // Both adapt down; the faster speed moves the rate further in the same step.
        assertLt(fastRate, rateBefore, "rate adapted down");
        assertLt(fastRate, slowRate, "faster adjustmentSpeed adapts further in the same step");
    }

    /// The periphery matches the contract and follows the new config after a reparametrization.
    function test_reparam_periphery_tracksReparam() public {
        _wired(_defaultConfig());
        _adaptUp();
        bytes32 idBytes = Id.unwrap(id);

        Market memory market = _market(0.8 ether);
        market.lastUpdate = uint128(block.timestamp - 3 days);
        assertEq(
            AdaptiveCurveIrmLib.borrowRateView(idBytes, market, address(irm)),
            irm.borrowRateView(params, market),
            "periphery matches the contract (config A)"
        );

        // Reparametrize to a different curve (steeper, lower target, with a cap); periphery must follow.
        int256 storedRate = _rateAtTarget();
        IMarketConfig.Config memory newConfig = _config(storedRate, storedRate / 4, storedRate * 4);
        newConfig.curveSteepness = int256(3 ether);
        newConfig.targetUtilization = int256(0.5 ether);
        newConfig.maxBorrowRate = uint256(storedRate * 2);
        _reparam(newConfig);

        Market memory reparamMarket = _market(0.8 ether);
        reparamMarket.lastUpdate = uint128(block.timestamp - 3 days);
        assertEq(
            AdaptiveCurveIrmLib.borrowRateView(idBytes, reparamMarket, address(irm)),
            irm.borrowRateView(params, reparamMarket),
            "periphery follows the new config after reparametrization (config B, incl. cap)"
        );
    }

    /* HELPERS */

    /// @dev Shorthand Config: steepness/speed/target fixed, only the initial/min/max rate band varies.
    function _config(int256 initialRate, int256 minRate, int256 maxRate)
        internal
        pure
        returns (IMarketConfig.Config memory)
    {
        return IMarketConfig.Config({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: int256(20 ether) / Y,
            targetUtilization: int256(TARGET),
            initialRateAtTarget: initialRate,
            minRateAtTarget: minRate,
            maxRateAtTarget: maxRate,
            maxBorrowRate: 0
        });
    }

    function _defaultConfig() internal pure returns (IMarketConfig.Config memory) {
        return _config(int256(0.04 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y);
    }

    /// @dev Deploys the factory + IRM (test as morpho + owner), wires the market (`params`/`id`), and sets `config`.
    function _wired(IMarketConfig.Config memory config) internal {
        factory = new MarketConfigFactory();
        irm = new AdaptiveCurveIrm(address(this), address(this));
        params = MarketParams({
            loanToken: address(0xA11CE),
            collateralToken: address(0xB0B),
            oracle: address(0x0AC1E),
            irm: address(irm),
            lltv: 0.8 ether
        });
        id = params.id();
        _register(address(irm), id, config);
    }

    /// @dev Reparametrizes the live market by pointing it at a fresh MarketConfig under the same id (replaces it).
    function _reparam(IMarketConfig.Config memory config) internal {
        _register(address(irm), id, config);
    }

    function _register(address irmAddress, Id marketId, IMarketConfig.Config memory config) internal {
        AdaptiveCurveIrm(irmAddress).setConfig(marketId, factory.createConfig(config));
    }

    /// @dev A standalone IRM for `config` seeded to `seededRate` on the wired market — the "same curve, applied from
    /// scratch" reference.
    function _seededControl(IMarketConfig.Config memory config, int256 seededRate)
        internal
        returns (AdaptiveCurveIrm control, MarketParams memory controlParams)
    {
        control = new AdaptiveCurveIrm(address(this), address(this));
        controlParams = params;
        controlParams.irm = address(control);
        _register(address(control), controlParams.id(), config);
        _setRateAtTarget(address(control), controlParams.id(), seededRate);
    }

    /// @dev Forces the IRM's stored `rateAtTarget[id]` to `rate` via vm.store (slot 0), to start from a known state.
    function _setRateAtTarget(address irmAddress, Id marketId, int256 rate) internal {
        vm.store(irmAddress, keccak256(abi.encode(Id.unwrap(marketId), uint256(0))), bytes32(uint256(rate)));
    }

    function _adaptDown() internal {
        _poke(TARGET);
        for (uint256 i; i < 6; ++i) {
            _poke(0.3 ether);
        }
    }

    function _adaptUp() internal {
        _poke(TARGET);
        for (uint256 i; i < 6; ++i) {
            _poke(0.98 ether);
        }
    }

    function _poke(uint256 utilizationWad) internal {
        _pokeFor(utilizationWad, 5 days);
    }

    function _pokeFor(uint256 utilizationWad, uint256 elapsed) internal {
        Market memory market = _market(utilizationWad);
        vm.warp(block.timestamp + elapsed);
        irm.borrowRate(params, market);
    }

    function _borrowAtTarget() internal view returns (uint256) {
        return irm.borrowRateView(params, _market(TARGET)) * uint256(Y);
    }

    function _rateAtTarget() internal view returns (int256) {
        return irm.rateAtTarget(id);
    }

    function _crawl(uint256 utilizationWad, uint256 elapsed, uint256 steps) internal {
        for (uint256 i; i < steps; ++i) {
            _pokeFor(utilizationWad, elapsed);
        }
    }

    function _market(uint256 utilizationWad) internal view returns (Market memory market) {
        market.totalSupplyAssets = uint128(SUPPLY);
        market.totalBorrowAssets = uint128(SUPPLY * utilizationWad / 1e18);
        market.lastUpdate = uint128(block.timestamp);
    }
}
