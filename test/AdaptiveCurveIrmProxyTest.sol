// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import "../src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol";

import "../lib/forge-std/src/Test.sol";

// Minimal ERC-1967 upgradeable proxy, test-only (no admin gating, not production code).
contract TestERC1967Proxy {
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant _IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    constructor(address implementation_) {
        _setImplementation(implementation_);
    }

    function upgradeTo(address newImplementation) external {
        _setImplementation(newImplementation);
    }

    function setAdmin(address newAdmin) external {
        assembly {
            sstore(_ADMIN_SLOT, newAdmin)
        }
    }

    function admin() external view returns (address a) {
        assembly {
            a := sload(_ADMIN_SLOT)
        }
    }

    function implementation() external view returns (address impl) {
        impl = _implementation();
    }

    function _setImplementation(address newImplementation) private {
        require(newImplementation.code.length > 0, "impl not a contract");
        assembly {
            sstore(_IMPL_SLOT, newImplementation)
        }
    }

    function _implementation() private view returns (address impl) {
        assembly {
            impl := sload(_IMPL_SLOT)
        }
    }

    fallback() external payable {
        address impl = _implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

contract AdaptiveCurveIrmProxyTest is Test {
    using MarketParamsLib for MarketParams;

    int256 internal constant Y = 365 days;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TARGET = 0.9 ether;

    MarketParams internal params;
    Id internal id;

    /// Immutable curve params are readable through the proxy (delegatecall reads the impl bytecode).
    function test_immutableParamsReadableThroughProxy() public {
        IAdaptiveCurveIrm.Config memory cfg =
            _cfg(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y);
        address impl = _impl(cfg);
        address proxy = _proxy(impl);

        assertEq(TestERC1967Proxy(payable(proxy)).implementation(), impl, "implementation slot");
        // Read through the proxy (delegatecall): immutables come from the impl bytecode, MORPHO from the impl too.
        assertEq(AdaptiveCurveIrm(proxy).MORPHO(), address(this), "MORPHO");
        assertEq(AdaptiveCurveIrm(proxy).CURVE_STEEPNESS(), cfg.curveSteepness, "curveSteepness");
        assertEq(AdaptiveCurveIrm(proxy).TARGET_UTILIZATION(), cfg.targetUtilization, "targetUtilization");
        assertEq(AdaptiveCurveIrm(proxy).INITIAL_RATE_AT_TARGET(), cfg.initialRateAtTarget, "initialRateAtTarget");
        assertEq(AdaptiveCurveIrm(proxy).MIN_RATE_AT_TARGET(), cfg.minRateAtTarget, "minRateAtTarget");
        assertEq(AdaptiveCurveIrm(proxy).MAX_RATE_AT_TARGET(), cfg.maxRateAtTarget, "maxRateAtTarget");
    }

    /// Upgrading within bounds that still contain the rate preserves rateAtTarget with no spike.
    function test_upgrade_statePersists_noSpike_whenBoundsContainRate() public {
        address proxy = _wiredProxy(_cfg(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y));
        _adaptDown(proxy);

        int256 ratBefore = _rat(proxy);
        uint256 borrowBefore = _borrowAtTarget(proxy);

        _upgrade(proxy, _impl(_cfg(ratBefore, ratBefore / 2, ratBefore * 2)));

        assertEq(_rat(proxy), ratBefore, "rateAtTarget persisted through the upgrade (proxy storage intact)");
        assertEq(_borrowAtTarget(proxy), borrowBefore, "no spike: borrow continues from the persisted rate");
    }

    /// A new MIN above the stored rate snaps rateAtTarget up on the next adapting call.
    function test_upgrade_rateRises_whenNewMinAboveStoredRate() public {
        address proxy = _wiredProxy(_cfg(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y));
        _adaptDown(proxy);

        int256 ratBefore = _rat(proxy);
        int256 newMin = ratBefore * 3 / 2;
        _upgrade(proxy, _impl(_cfg(newMin, newMin, newMin * 4)));

        assertEq(_rat(proxy), ratBefore, "stored rate unchanged until the next adapting call");

        _poke(proxy, 0.95 ether);
        int256 ratAfter = _rat(proxy);
        assertGe(ratAfter, newMin, "rate clamped up to the new MIN");
        assertGt(ratAfter, ratBefore, "rate jumped up after the upgrade (the spike)");
    }

    /// A new MAX below the stored rate snaps rateAtTarget down on the next adapting call.
    function test_upgrade_rateDrops_whenNewMaxBelowStoredRate() public {
        address proxy = _wiredProxy(_cfg(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y));
        _adaptDown(proxy);

        int256 ratBefore = _rat(proxy);
        int256 newMax = ratBefore * 2 / 3;
        _upgrade(proxy, _impl(_cfg(newMax, ratBefore / 4, newMax)));

        assertEq(_rat(proxy), ratBefore, "stored rate unchanged until the next adapting call");

        _poke(proxy, 0.95 ether);
        int256 ratAfter = _rat(proxy);
        assertLe(ratAfter, newMax, "rate clamped down to the new MAX");
        assertLt(ratAfter, ratBefore, "rate jumped down after the upgrade");
    }

    /// The cap applies through the proxy and a tighter cap takes effect on the next call after upgrade.
    function test_maxBorrowRate_appliesThroughProxyAndTightensOnUpgrade() public {
        int256 initial = int256(0.04 ether) / Y;
        int256 min = int256(0.005 ether) / Y;
        int256 max = int256(0.08 ether) / Y;

        // Uncapped tip at 100% util (first interaction) = initial * curveSteepness = 0.06/yr.
        IAdaptiveCurveIrm.Config memory cfg = _cfg(initial, min, max);
        cfg.maxBorrowRate = 0.05 ether / uint256(Y); // below the 0.06/yr tip
        address proxy = _wiredProxy(cfg);

        assertEq(AdaptiveCurveIrm(proxy).MAX_BORROW_RATE(), cfg.maxBorrowRate, "cap readable through the proxy");
        assertEq(
            AdaptiveCurveIrm(proxy).borrowRateView(params, _market(1 ether)),
            cfg.maxBorrowRate,
            "charged rate clamped to MAX_BORROW_RATE through the proxy"
        );

        // Upgrade to a tighter cap (same curve); the new ceiling takes effect on the next call.
        IAdaptiveCurveIrm.Config memory cfg2 = _cfg(initial, min, max);
        cfg2.maxBorrowRate = 0.03 ether / uint256(Y);
        _upgrade(proxy, address(new AdaptiveCurveIrm(address(this), cfg2)));

        assertEq(AdaptiveCurveIrm(proxy).MAX_BORROW_RATE(), cfg2.maxBorrowRate, "tighter cap exposed after upgrade");
        assertEq(
            AdaptiveCurveIrm(proxy).borrowRateView(params, _market(1 ether)),
            cfg2.maxBorrowRate,
            "tighter cap bites after the upgrade"
        );
    }

    /// A cap below the adapted rate clamps the charged rate immediately, leaving rateAtTarget intact.
    function test_upgrade_capBelowAdaptedRate_clampsImmediately_keepsState() public {
        address proxy = _wiredProxy(_cfg(int256(0.02 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y));
        _adaptUp(proxy);

        int256 ratBefore = _rat(proxy);
        uint256 chargedBefore = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(TARGET));

        int256 cap = ratBefore / 2;
        IAdaptiveCurveIrm.Config memory c = _cfg(ratBefore, ratBefore / 2, ratBefore * 2);
        c.maxBorrowRate = uint256(cap);
        _upgrade(proxy, _impl(c));

        assertEq(_rat(proxy), ratBefore, "rateAtTarget preserved across the upgrade");

        uint256 chargedAfter = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(TARGET));
        assertEq(chargedAfter, uint256(cap), "charged rate clamped to the new cap on the next call");
        assertLt(chargedAfter, chargedBefore, "charged rate dropped after the upgrade");
        assertEq(_rat(proxy), ratBefore, "the cap did not touch rateAtTarget");
    }

    /// After tightening MAX, an at-target poke leaves rateAtTarget out of range until a later off-target call.
    function test_upgrade_tighterMax_atTargetPokeDefersRebound() public {
        address proxy = _wiredProxy(_cfg(int256(0.02 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y));
        _adaptUp(proxy);

        int256 ratBefore = _rat(proxy);
        int256 newMax = ratBefore / 2;
        _upgrade(proxy, _impl(_cfg(newMax, int256(0.005 ether) / Y, newMax)));

        _poke(proxy, TARGET);
        assertEq(_rat(proxy), ratBefore, "at-target poke leaves the stored rate unbounded");
        assertGt(_rat(proxy), newMax, "rateAtTarget still above the new MAX (rebound deferred)");
        assertEq(
            AdaptiveCurveIrm(proxy).borrowRateView(params, _market(TARGET)),
            uint256(ratBefore),
            "uncapped: the stale above-MAX rate is charged as-is"
        );

        _poke(proxy, 0.3 ether);
        assertLe(_rat(proxy), newMax, "off-target poke re-bounds rateAtTarget down to the new MAX");
    }

    /// Widening lets rateAtTarget creep up; a later narrowing snaps it onto the new ceiling in one step.
    function test_upgrade_widenLetsRateCreep_thenNarrowShocks() public {
        int256 min0 = int256(0.005 ether) / Y;
        int256 max0 = int256(0.05 ether) / Y;

        address proxy = _wiredProxy(_cfg(max0, min0, max0));
        _poke(proxy, TARGET);
        assertEq(_rat(proxy), max0, "seed: at-target exactly at the 5%/yr ceiling");

        _upgrade(proxy, _impl(_cfg(max0, min0, int256(0.2 ether) / Y)));
        assertEq(_rat(proxy), max0, "widen alone: at-target still exactly 5%/yr");

        _crawl(proxy, 0.98 ether, 1 hours, 1);
        assertApproxEqRel(_ratAnnual(proxy), 0.0501 ether, 0.002 ether, "after 1h: at-target ~5.01%/yr");
        _crawl(proxy, 0.98 ether, 1 hours, 7);
        assertApproxEqRel(_ratAnnual(proxy), 0.0507 ether, 0.002 ether, "after 8h: at-target ~5.07%/yr");
        _crawl(proxy, 0.98 ether, 1 hours, 4);
        assertApproxEqRel(_ratAnnual(proxy), 0.0511 ether, 0.002 ether, "after 12h: at-target ~5.11%/yr");
        int256 crept = _rat(proxy);

        int256 maxTight = int256(0.03 ether) / Y;
        _upgrade(proxy, _impl(_cfg(maxTight, min0, maxTight)));
        assertEq(_rat(proxy), crept, "narrow alone: at-target unchanged (~5.11%/yr)");

        _crawl(proxy, 0.98 ether, 1 hours, 1);
        assertEq(_rat(proxy), maxTight, "shock: at-target snapped exactly onto the new 3%/yr ceiling in one step");
    }

    /// Changing targetUtilization shifts the charged rate at the same utilization, without moving rateAtTarget.
    function test_upgrade_targetShift_changesChargedRate_keepsState() public {
        address proxy = _wiredProxy();
        _poke(proxy, TARGET);

        int256 rat = _rat(proxy);
        uint256 chargedBefore = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(0.8 ether));

        IAdaptiveCurveIrm.Config memory c = _cfg(rat, rat / 2, rat * 2);
        c.targetUtilization = int256(0.5 ether);
        _upgrade(proxy, _impl(c));

        assertEq(_rat(proxy), rat, "target change does not move the stored rate");
        uint256 chargedAfter = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(0.8 ether));
        assertGt(chargedAfter, chargedBefore, "same utilization charges more after the target moves below it");
    }

    /// Changing curveSteepness shifts the charged rate above target, without moving rateAtTarget.
    function test_upgrade_steepnessShift_changesChargedRate_keepsState() public {
        address proxy = _wiredProxy();
        _poke(proxy, TARGET);

        int256 rat = _rat(proxy);
        uint256 chargedBefore = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(0.98 ether));

        IAdaptiveCurveIrm.Config memory c = _cfg(rat, rat / 2, rat * 2);
        c.curveSteepness = int256(4 ether);
        _upgrade(proxy, _impl(c));

        assertEq(_rat(proxy), rat, "steepness change does not move the stored rate");
        uint256 chargedAfter = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(0.98 ether));
        assertGt(chargedAfter, chargedBefore, "steeper curve charges more above target at the same utilization");
    }

    /// The first call after an upgrade prices the whole interval since lastUpdate at the new params.
    function test_upgrade_newParamsPriceWholeIntervalSinceLastUpdate() public {
        address proxy = _wiredProxy();
        _adaptUp(proxy);
        int256 ratStart = _rat(proxy);

        // Market stamped "now"; a long span elapses before the next call touches it.
        Market memory m = _market(0.98 ether); // m.lastUpdate = block.timestamp
        vm.warp(block.timestamp + 60 days);

        // Upgrade mid-span to a faster adjustmentSpeed; the curve is otherwise the same and the bounds keep ratStart.
        IAdaptiveCurveIrm.Config memory cfgB = _cfg(ratStart, ratStart / 4, ratStart * 4);
        cfgB.adjustmentSpeed = int256(80 ether) / Y; // 4x the original 20/yr
        _upgrade(proxy, _impl(cfgB));

        // The first borrowRate after the upgrade prices the whole [lastUpdate, now] span at the NEW params,
        // even though lastUpdate predates the upgrade.
        AdaptiveCurveIrm(proxy).borrowRate(params, m);
        int256 ratProxy = _rat(proxy);

        // Reference: a standalone impl B seeded to the same start, applied to the same span from scratch.
        (AdaptiveCurveIrm control, MarketParams memory cp) = _seededControl(cfgB, ratStart);
        control.borrowRate(cp, m);

        assertEq(control.rateAtTarget(cp.id()), ratProxy, "whole pre-upgrade span priced at the new params");
        assertTrue(ratProxy != ratStart, "the span moved the stored rate");
    }

    /// Changing adjustmentSpeed speeds up future adaptation without moving rateAtTarget at the upgrade.
    function test_upgrade_adjustmentSpeedShift_changesFutureAdaptation_keepsState() public {
        address proxy = _wiredProxy();
        _poke(proxy, TARGET); // seed rateAtTarget := initial (at target, no adaptation yet)
        int256 ratBefore = _rat(proxy);

        // Upgrade to a 4x faster adjustmentSpeed; bounds wide, curve otherwise identical.
        IAdaptiveCurveIrm.Config memory cfgFast = _cfg(ratBefore, ratBefore / 4, ratBefore * 4);
        cfgFast.adjustmentSpeed = int256(80 ether) / Y;
        _upgrade(proxy, _impl(cfgFast));
        assertEq(_rat(proxy), ratBefore, "adjustmentSpeed change does not move the stored rate at the upgrade");

        // One off-target step under the fast speed.
        _poke(proxy, 0.3 ether);
        int256 ratFast = _rat(proxy);

        // Control: same start and same 5-day step under the ORIGINAL (slow) speed.
        IAdaptiveCurveIrm.Config memory cfgSlow = _cfg(ratBefore, ratBefore / 4, ratBefore * 4);
        cfgSlow.adjustmentSpeed = int256(20 ether) / Y;
        (AdaptiveCurveIrm control, MarketParams memory cp) = _seededControl(cfgSlow, ratBefore);
        Market memory cm = _market(0.3 ether);
        vm.warp(block.timestamp + 5 days);
        control.borrowRate(cp, cm);
        int256 ratSlow = control.rateAtTarget(cp.id());

        // Both adapt down; the faster speed moves the rate further in the same step.
        assertLt(ratFast, ratBefore, "rate adapted down");
        assertLt(ratFast, ratSlow, "faster adjustmentSpeed adapts further in the same step");
    }

    /// The periphery matches the contract through the proxy and follows the new impl after an upgrade.
    function test_periphery_borrowRateView_tracksProxyUpgrade() public {
        address proxy = _wiredProxy();
        _adaptUp(proxy);
        bytes32 pid = Id.unwrap(id);

        // Periphery reads the live impl through the proxy; over a non-zero span it matches the contract's own view.
        Market memory m = _market(0.8 ether);
        m.lastUpdate = uint128(block.timestamp - 3 days);
        assertEq(
            AdaptiveCurveIrmLib.borrowRateView(pid, m, proxy),
            AdaptiveCurveIrm(proxy).borrowRateView(params, m),
            "periphery matches the contract through the proxy (impl A)"
        );

        // Reparametrize to a different curve (steeper, lower target, with a cap); periphery must follow.
        int256 rat = _rat(proxy);
        IAdaptiveCurveIrm.Config memory c = _cfg(rat, rat / 4, rat * 4);
        c.curveSteepness = int256(3 ether);
        c.targetUtilization = int256(0.5 ether);
        c.maxBorrowRate = uint256(rat * 2);
        _upgrade(proxy, _impl(c));

        Market memory m2 = _market(0.8 ether);
        m2.lastUpdate = uint128(block.timestamp - 3 days);
        assertEq(
            AdaptiveCurveIrmLib.borrowRateView(pid, m2, proxy),
            AdaptiveCurveIrm(proxy).borrowRateView(params, m2),
            "periphery follows the new impl after upgrade (impl B, incl. cap)"
        );
    }

    /// The EIP-1967 impl and admin slots never collide with rateAtTarget at slot 0.
    function test_proxyImplAndAdminSlots_doNotCollideWithRateAtTarget() public {
        address proxy = _wiredProxy();
        _adaptUp(proxy); // put a non-zero rateAtTarget in slot 0
        int256 rat = _rat(proxy);
        assertGt(rat, int256(0), "rateAtTarget seeded in slot 0");

        // The EIP-1967 impl and admin pointers must live in their own slots, never touching slot 0.
        TestERC1967Proxy(payable(proxy)).setAdmin(address(0xADA));
        _upgrade(proxy, _impl(_cfg(rat, rat / 4, rat * 4))); // rewrites the impl slot

        assertEq(TestERC1967Proxy(payable(proxy)).admin(), address(0xADA), "admin slot written");
        assertEq(_rat(proxy), rat, "rateAtTarget (slot 0) intact after impl + admin slot writes");
    }

    /* HELPERS */

    /// @dev Shorthand Config for proxy tests: steepness/speed/target are fixed, only the initial/min/max rate
    /// band varies (that is what these tests actually exercise).
    function _cfg(int256 initial, int256 min, int256 max) internal pure returns (IAdaptiveCurveIrm.Config memory) {
        return IAdaptiveCurveIrm.Config({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: int256(20 ether) / Y,
            targetUtilization: int256(TARGET),
            initialRateAtTarget: initial,
            minRateAtTarget: min,
            maxRateAtTarget: max,
            maxBorrowRate: 0
        });
    }

    /// @dev Deploys a standalone implementation for `cfg` — the contract a proxy delegatecalls into.
    function _impl(IAdaptiveCurveIrm.Config memory cfg) internal returns (address) {
        return address(new AdaptiveCurveIrm(address(this), cfg));
    }

    /// @dev The one-line setup most tests start with: a proxy over a fresh default-curve impl, already wired
    /// to a market (`params` / `id`).
    function _wiredProxy() internal returns (address) {
        return _wiredProxy(_cfg(int256(0.04 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y));
    }

    /// @dev Same one-line setup as `_wiredProxy()`, but with an explicit `cfg`.
    function _wiredProxy(IAdaptiveCurveIrm.Config memory cfg) internal returns (address proxy) {
        proxy = _proxy(_impl(cfg));
        _wire(proxy);
    }

    /// @dev A standalone IRM for `cfg` seeded to `rat` on the wired market — the reference a proxy result is
    /// checked against ("same curve, applied from scratch").
    function _seededControl(IAdaptiveCurveIrm.Config memory cfg, int256 rat)
        internal
        returns (AdaptiveCurveIrm control, MarketParams memory cp)
    {
        control = new AdaptiveCurveIrm(address(this), cfg);
        cp = params;
        cp.irm = address(control);
        _setRateAtTarget(address(control), cp.id(), rat);
    }

    /// @dev Forces the IRM's stored `rateAtTarget[id]` to `rate` via vm.store, to start from a known state without
    /// adapting.
    function _setRateAtTarget(address irmAddr, Id marketId, int256 rate) internal {
        vm.store(irmAddr, keccak256(abi.encode(Id.unwrap(marketId), uint256(0))), bytes32(uint256(rate)));
    }

    function _proxy(address impl) internal returns (address) {
        return address(new TestERC1967Proxy(impl));
    }

    /// @dev Reparametrizes the live market: points the proxy at `newImpl` (the new Config takes effect on the next
    /// call).
    function _upgrade(address proxy, address newImpl) internal {
        TestERC1967Proxy(payable(proxy)).upgradeTo(newImpl);
    }

    /// @dev Picks the market the test operates on: sets the shared `params` (irm = proxy) and its `id`.
    function _wire(address proxy) internal {
        params = MarketParams({
            loanToken: address(0xA11CE),
            collateralToken: address(0xB0B),
            oracle: address(0x0AC1E),
            irm: proxy,
            lltv: 0.8 ether
        });
        id = params.id();
    }

    /// @dev Drives the IRM into an already-adapted state below the initial rate: seed at target, then poke
    /// repeatedly below target. Run before an upgrade test.
    function _adaptDown(address proxy) internal {
        _poke(proxy, TARGET);
        for (uint256 i; i < 6; ++i) {
            _poke(proxy, 0.3 ether);
        }
    }

    /// @dev Mirror of `_adaptDown`: drives rateAtTarget up by poking above target. Run before an upgrade test.
    function _adaptUp(address proxy) internal {
        _poke(proxy, TARGET);
        for (uint256 i; i < 6; ++i) {
            _poke(proxy, 0.98 ether);
        }
    }

    /// @dev One adaptation step: borrowRate at `utilWad` after a 5-day gap. The basic "advance the model" move.
    function _poke(address proxy, uint256 utilWad) internal {
        _pokeFor(proxy, utilWad, 5 days);
    }

    /// @dev `_poke` with an explicit gap: one adaptation step at `utilWad` after `dt` elapses.
    function _pokeFor(address proxy, uint256 utilWad, uint256 dt) internal {
        Market memory m = _market(utilWad);
        vm.warp(block.timestamp + dt);
        AdaptiveCurveIrm(proxy).borrowRate(params, m);
    }

    /// @dev What a borrower at target utilization currently pays, annualized (%/yr) — for readable assertions.
    function _borrowAtTarget(address proxy) internal view returns (uint256) {
        return AdaptiveCurveIrm(proxy).borrowRateView(params, _market(TARGET)) * uint256(Y);
    }

    /// @dev Reads the proxy's stored rateAtTarget (per second — the raw state).
    function _rat(address proxy) internal view returns (int256) {
        return AdaptiveCurveIrm(proxy).rateAtTarget(id);
    }

    /// @dev `_rat` annualized (%/yr), for assertions against human-readable numbers.
    function _ratAnnual(address proxy) internal view returns (uint256) {
        return uint256(_rat(proxy)) * uint256(Y);
    }

    /// @dev Many small steps in a row: repeats a `dt` poke at `utilWad` `steps` times (gradual drift).
    function _crawl(address proxy, uint256 utilWad, uint256 dt, uint256 steps) internal {
        for (uint256 i; i < steps; ++i) {
            _pokeFor(proxy, utilWad, dt);
        }
    }

    /// @dev Builds the `Market` a poke or view runs against: `utilWad` utilization over SUPPLY, lastUpdate = now.
    function _market(uint256 utilWad) internal view returns (Market memory m) {
        m.totalSupplyAssets = uint128(SUPPLY);
        m.totalBorrowAssets = uint128(SUPPLY * utilWad / 1e18);
        m.lastUpdate = uint128(block.timestamp);
    }
}
