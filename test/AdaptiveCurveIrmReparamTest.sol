// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {IAdaptiveCurveConfig} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "../src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import "../src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol";

import "../lib/forge-std/src/Test.sol";

import {CurveRefHelper} from "./CurveRefHelper.sol";

/// Reparametrization in the per-market-config model: re-registering a new AdaptiveCurveConfig under the SAME id swaps
/// the market's curve. The dynamics (snap on the next adapting call, lazy re-clamp, whole-interval repricing) are
/// emergent
/// from reading whichever config is currently registered + the unchanged curve math + the persisted rateAtTarget — no
/// proxy involved. Variant A allows the re-registration these tests exercise.
contract AdaptiveCurveIrmReparamTest is Test, CurveRefHelper {
    using MarketParamsLib for MarketParams;

    int256 internal constant Y = 365 days;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TARGET = 0.9 ether;

    AdaptiveCurveIrm internal irm;
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
        AdaptiveCurveParams memory newConfig = _config(newMinRate, newMinRate, newMinRate * 4);
        _reparam(newConfig);

        assertEq(_rateAtTarget(), rateBefore, "stored rate unchanged until the next adapting call");

        // The 5-day above-target drift alone grows the rate by only ~e^0.137, so the new MIN (1.5x) binds:
        // the spike lands exactly on it.
        int256 rateAfter = _pokeExpecting(newConfig, 0.95 ether);
        assertEq(rateAfter, newMinRate, "the up-snap lands exactly on the new MIN");
    }

    /// A new MAX below the stored rate snaps rateAtTarget down on the next adapting call.
    function test_reparam_rateDrops_whenNewMaxBelowStoredRate() public {
        _wired(_config(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y));
        _adaptDown();

        int256 rateBefore = _rateAtTarget();
        int256 newMaxRate = rateBefore * 2 / 3;
        AdaptiveCurveParams memory newConfig = _config(newMaxRate, rateBefore / 4, newMaxRate);
        _reparam(newConfig);

        assertEq(_rateAtTarget(), rateBefore, "stored rate unchanged until the next adapting call");

        // The above-target poke drifts the rate UP, so the new MAX (2/3x) binds: the drop lands exactly on it.
        int256 rateAfter = _pokeExpecting(newConfig, 0.95 ether);
        assertEq(rateAfter, newMaxRate, "the down-snap lands exactly on the new MAX");
    }

    /// The cap applies after registration and a tighter cap takes effect on the next call.
    function test_reparam_capAppliesAndTightens() public {
        int256 initialRate = int256(0.04 ether) / Y;
        int256 minRate = int256(0.005 ether) / Y;
        int256 maxRate = int256(0.08 ether) / Y;

        // Uncapped tip at 100% util (first interaction) = initial * curveSteepness = 0.06/yr.
        AdaptiveCurveParams memory config = _config(initialRate, minRate, maxRate);
        config.maxBorrowRate = 0.05 ether / uint256(Y); // below the 0.06/yr tip
        _wired(config);

        assertEq(
            irm.borrowRateView(params, _market(1 ether)),
            config.maxBorrowRate,
            "charged rate clamped to MAX_BORROW_RATE"
        );

        // Reparametrize to a tighter cap (same curve); the new ceiling takes effect on the next call.
        AdaptiveCurveParams memory tighterCapConfig = _config(initialRate, minRate, maxRate);
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
        assertEq(chargedBefore, uint256(rateBefore), "at target the charged rate equals the stored rate");

        int256 capRate = rateBefore / 2;
        AdaptiveCurveParams memory cappedConfig = _config(rateBefore, rateBefore / 2, rateBefore * 2);
        cappedConfig.maxBorrowRate = uint256(capRate);
        _reparam(cappedConfig);

        assertEq(_rateAtTarget(), rateBefore, "rateAtTarget preserved across reparametrization");

        uint256 chargedAfter = irm.borrowRateView(params, _market(TARGET));
        assertEq(chargedAfter, uint256(capRate), "charged rate clamped to the new cap on the next call");
        assertEq(_rateAtTarget(), rateBefore, "the cap did not touch rateAtTarget");
    }

    /// After tightening MAX, an at-target poke leaves rateAtTarget out of range until a later off-target call.
    function test_reparam_tighterMax_atTargetPokeDefersRebound() public {
        _wired(_config(int256(0.02 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y));
        _adaptUp();

        int256 rateBefore = _rateAtTarget();
        int256 newMaxRate = rateBefore / 2;
        AdaptiveCurveParams memory newConfig = _config(newMaxRate, int256(0.005 ether) / Y, newMaxRate);
        _reparam(newConfig);

        // The at-target poke (err == 0) leaves the stored rate EXACTLY where it was — still above the new MAX
        // (it equals 2 * newMaxRate): the rebound is deferred.
        _pokeExpecting(newConfig, TARGET);
        assertEq(_rateAtTarget(), rateBefore, "at-target poke leaves the stored rate unbounded");
        assertEq(
            irm.borrowRateView(params, _market(TARGET)),
            uint256(rateBefore),
            "uncapped: the stale above-MAX rate is charged as-is"
        );

        // The off-target poke's own downward drift (~e^-0.18) does not reach MAX/2, so the clamp binds: the
        // re-bound lands exactly on the new MAX.
        _pokeExpecting(newConfig, 0.3 ether);
        assertEq(_rateAtTarget(), newMaxRate, "off-target poke re-bounds exactly onto the new MAX");
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

        // Off-target above target makes rateAtTarget creep up: every hourly step is checked EXACTLY against the
        // reference, and after 12h the crept rate has not reached the widened ceiling (creep, not snap).
        AdaptiveCurveParams memory wideConfig = _config(initialMaxRate, initialMinRate, wideMaxRate);
        int256 crept;
        for (uint256 i; i < 12; ++i) {
            crept = _pokeExpecting(wideConfig, 0.98 ether, 1 hours);
        }
        assertTrue(crept != wideMaxRate, "creep stays below the widened ceiling (creep, not snap)");

        // Narrow the ceiling below the crept rate (it sits above tightMax by construction: it crept up from
        // initialMaxRate == 0.05/yr > 0.03/yr): unchanged until the next adapting call, then snapped in one step.
        int256 tightMaxRate = int256(0.03 ether) / Y;
        AdaptiveCurveParams memory tightConfig = _config(tightMaxRate, initialMinRate, tightMaxRate);
        _reparam(tightConfig);
        assertEq(_rateAtTarget(), crept, "narrow alone leaves the crept rate unchanged");

        _pokeExpecting(tightConfig, 0.98 ether, 1 hours);
        assertEq(_rateAtTarget(), tightMaxRate, "shock: snapped exactly onto the new tight ceiling in one step");
    }

    /// Changing targetUtilization shifts the charged rate at the same utilization, without moving rateAtTarget.
    function test_reparam_targetShift_changesChargedRate_keepsState() public {
        _wired(_defaultConfig());
        _poke(TARGET);

        int256 storedRate = _rateAtTarget();
        (uint256 expectedBefore,) = _refBorrowRate(_defaultConfig(), storedRate, _market(0.8 ether));
        assertEq(
            irm.borrowRateView(params, _market(0.8 ether)),
            expectedBefore,
            "below the old target: the down-branch of the curve"
        );

        AdaptiveCurveParams memory newConfig = _config(storedRate, storedRate / 2, storedRate * 2);
        newConfig.targetUtilization = int256(0.5 ether);
        _reparam(newConfig);

        assertEq(_rateAtTarget(), storedRate, "target change does not move the stored rate");
        // The same utilization now sits ABOVE the target: the reference (with the new target) prices it on the
        // up-branch of the curve.
        (uint256 expectedAfter,) = _refBorrowRate(newConfig, storedRate, _market(0.8 ether));
        assertEq(
            irm.borrowRateView(params, _market(0.8 ether)),
            expectedAfter,
            "the new target reprices the same utilization on the up-branch"
        );
    }

    /// Changing curveSteepness shifts the charged rate above target, without moving rateAtTarget.
    function test_reparam_steepnessShift_changesChargedRate_keepsState() public {
        _wired(_defaultConfig());
        _poke(TARGET);

        int256 storedRate = _rateAtTarget();
        (uint256 expectedBefore,) = _refBorrowRate(_defaultConfig(), storedRate, _market(0.98 ether));
        assertEq(
            irm.borrowRateView(params, _market(0.98 ether)), expectedBefore, "above target under the old steepness"
        );

        AdaptiveCurveParams memory newConfig = _config(storedRate, storedRate / 2, storedRate * 2);
        newConfig.curveSteepness = int256(4 ether);
        _reparam(newConfig);

        assertEq(_rateAtTarget(), storedRate, "steepness change does not move the stored rate");
        (uint256 expectedAfter,) = _refBorrowRate(newConfig, storedRate, _market(0.98 ether));
        assertEq(
            irm.borrowRateView(params, _market(0.98 ether)),
            expectedAfter,
            "the steeper curve reprices the same utilization exactly per the reference"
        );
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
        AdaptiveCurveParams memory fasterConfig = _config(startRate, startRate / 4, startRate * 4);
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
        AdaptiveCurveParams memory fasterConfig = _config(rateBefore, rateBefore / 4, rateBefore * 4);
        fasterConfig.adjustmentSpeed = int256(80 ether) / Y;
        _reparam(fasterConfig);
        assertEq(
            _rateAtTarget(), rateBefore, "adjustmentSpeed change does not move the stored rate at reparametrization"
        );

        // One off-target step under the fast speed, checked exactly against the reference (the 4x speed is in
        // the exponent of the expected adaptation).
        int256 fastRate = _pokeExpecting(fasterConfig, 0.3 ether);

        // Control: same start and same 5-day step under the ORIGINAL (slow) speed, also exact per the reference.
        AdaptiveCurveParams memory slowerConfig = _config(rateBefore, rateBefore / 4, rateBefore * 4);
        slowerConfig.adjustmentSpeed = int256(20 ether) / Y;
        (AdaptiveCurveIrm control, MarketParams memory controlParams) = _seededControl(slowerConfig, rateBefore);
        Market memory controlMarket = _market(0.3 ether);
        vm.warp(block.timestamp + 5 days);
        (, int256 expectedSlowRate) = _refBorrowRate(slowerConfig, rateBefore, controlMarket);
        control.borrowRate(controlParams, controlMarket);
        int256 slowRate = control.rateAtTarget(controlParams.id());
        assertEq(slowRate, expectedSlowRate, "the slow control matches the reference");

        assertTrue(fastRate != slowRate, "the two speeds land on different rates for the same step");
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
        AdaptiveCurveParams memory newConfig = _config(storedRate, storedRate / 4, storedRate * 4);
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

    /// @dev Shorthand `Params`: steepness/speed/target fixed, only the initial/min/max rate band varies.
    function _config(int256 initialRate, int256 minRate, int256 maxRate)
        internal
        pure
        returns (AdaptiveCurveParams memory)
    {
        return AdaptiveCurveParams({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: int256(20 ether) / Y,
            targetUtilization: int256(TARGET),
            initialRateAtTarget: initialRate,
            minRateAtTarget: minRate,
            maxRateAtTarget: maxRate,
            maxBorrowRate: 0
        });
    }

    function _defaultConfig() internal pure returns (AdaptiveCurveParams memory) {
        return _config(int256(0.04 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y);
    }

    /// @dev Deploys the IRM (test as morpho + owner), wires the market (`params`/`id`), and sets `config`.
    function _wired(AdaptiveCurveParams memory config) internal {
        irm = _deployIrm();
        params = MarketParams({
            loanToken: address(0xA11CE),
            collateralToken: address(0xB0B),
            oracle: address(0x0AC1E),
            irm: address(irm),
            lltv: 0.8 ether
        });
        id = params.id();
        _register(address(irm), params, config);
    }

    /// @dev Reparametrizes the live market by pointing it at a fresh AdaptiveCurveConfig under the same id (replaces
    /// it).
    function _reparam(AdaptiveCurveParams memory config) internal {
        _register(address(irm), params, config);
    }

    /// @dev Deploys the IRM directly (no proxy) and clears the implementation lock so it can be initialized with the
    /// test as owner and manager, letting it call `setMarketCurveParams`.
    function _deployIrm() internal returns (AdaptiveCurveIrm deployed) {
        deployed = new AdaptiveCurveIrm(address(this));
        // `isInitialized` is packed with `manager` in slot 1 (both zero-clearable here since manager is unset);
        // clearing it lets a directly-deployed (non-proxy) IRM be initialized.
        vm.store(address(deployed), bytes32(uint256(1)), bytes32(0));
        deployed.initialize(address(this), address(this));
    }

    function _register(address irmAddress, MarketParams memory marketParams, AdaptiveCurveParams memory config)
        internal
    {
        AdaptiveCurveIrm(irmAddress).setMarketCurveParams(marketParams, config);
    }

    /// @dev A standalone IRM for `config` seeded to `seededRate` on the wired market — the "same curve, applied from
    /// scratch" reference.
    function _seededControl(AdaptiveCurveParams memory config, int256 seededRate)
        internal
        returns (AdaptiveCurveIrm control, MarketParams memory controlParams)
    {
        control = _deployIrm();
        controlParams = params;
        controlParams.irm = address(control);
        _register(address(control), controlParams, config);
        _setRateAtTarget(address(control), controlParams.id(), seededRate);
    }

    /// @dev Forces the IRM's stored `rateAtTarget[id]` to `rate` via vm.store (mapping base slot 2), to start from a
    /// known state.
    function _setRateAtTarget(address irmAddress, Id marketId, int256 rate) internal {
        vm.store(irmAddress, keccak256(abi.encode(Id.unwrap(marketId), uint256(2))), bytes32(uint256(rate)));
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

    /// @dev A `_pokeFor` whose charged rate and resulting rateAtTarget are checked EXACTLY against the reference
    /// under `activeConfig` (the params currently registered for the market). Returns the new rateAtTarget.
    function _pokeExpecting(AdaptiveCurveParams memory activeConfig, uint256 utilizationWad) internal returns (int256) {
        return _pokeExpecting(activeConfig, utilizationWad, 5 days);
    }

    function _pokeExpecting(AdaptiveCurveParams memory activeConfig, uint256 utilizationWad, uint256 elapsed)
        internal
        returns (int256 endRate)
    {
        Market memory market = _market(utilizationWad);
        vm.warp(block.timestamp + elapsed);
        (uint256 expectedRate, int256 expectedEndRate) = _refBorrowRate(activeConfig, _rateAtTarget(), market);
        assertEq(irm.borrowRate(params, market), expectedRate, "charged rate matches the reference");
        endRate = _rateAtTarget();
        assertEq(endRate, expectedEndRate, "rateAtTarget matches the reference");
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
