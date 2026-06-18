// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/adaptive-curve-irm/AdaptiveCurveIrm.sol";

import "../lib/forge-std/src/Test.sol";

// Minimal ERC-1967 upgradeable proxy, test-only (no admin gating, not production code).
contract TestERC1967Proxy {
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant _IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation_) {
        _setImplementation(implementation_);
    }

    function upgradeTo(address newImplementation) external {
        _setImplementation(newImplementation);
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

    function test_immutableParamsReadableThroughProxy() public {
        AdaptiveCurveIrm.Config memory cfg =
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

    function test_upgrade_statePersists_noSpike_whenBoundsContainRate() public {
        address proxy = _proxy(_impl(_cfg(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y)));
        _wire(proxy);
        _adaptDown(proxy);

        int256 ratBefore = _rat(proxy);
        uint256 borrowBefore = _borrowAtTarget(proxy);

        _upgrade(proxy, _impl(_cfg(ratBefore, ratBefore / 2, ratBefore * 2)));

        assertEq(_rat(proxy), ratBefore, "rateAtTarget persisted through the upgrade (proxy storage intact)");
        assertEq(_borrowAtTarget(proxy), borrowBefore, "no spike: borrow continues from the persisted rate");
    }

    function test_upgrade_rateRises_whenNewMinAboveStoredRate() public {
        address proxy = _proxy(_impl(_cfg(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y)));
        _wire(proxy);
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

    function test_upgrade_rateDrops_whenNewMaxBelowStoredRate() public {
        address proxy = _proxy(_impl(_cfg(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y)));
        _wire(proxy);
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

    function test_maxBorrowRate_appliesThroughProxyAndTightensOnUpgrade() public {
        int256 initial = int256(0.04 ether) / Y;
        int256 min = int256(0.005 ether) / Y;
        int256 max = int256(0.08 ether) / Y;

        // Uncapped tip at 100% util (first interaction) = initial * curveSteepness = 0.06/yr.
        AdaptiveCurveIrm.Config memory cfg = _cfg(initial, min, max);
        cfg.maxBorrowRate = int256(0.05 ether) / Y; // below the 0.06/yr tip
        address proxy = _proxy(address(new AdaptiveCurveIrm(address(this), cfg)));
        _wire(proxy);

        assertEq(AdaptiveCurveIrm(proxy).MAX_BORROW_RATE(), cfg.maxBorrowRate, "cap readable through the proxy");
        assertEq(
            AdaptiveCurveIrm(proxy).borrowRateView(params, _market(1 ether)),
            uint256(cfg.maxBorrowRate),
            "charged rate clamped to MAX_BORROW_RATE through the proxy"
        );

        // Upgrade to a tighter cap (same curve); the new ceiling takes effect on the next call.
        AdaptiveCurveIrm.Config memory cfg2 = _cfg(initial, min, max);
        cfg2.maxBorrowRate = int256(0.03 ether) / Y;
        _upgrade(proxy, address(new AdaptiveCurveIrm(address(this), cfg2)));

        assertEq(AdaptiveCurveIrm(proxy).MAX_BORROW_RATE(), cfg2.maxBorrowRate, "tighter cap exposed after upgrade");
        assertEq(
            AdaptiveCurveIrm(proxy).borrowRateView(params, _market(1 ether)),
            uint256(cfg2.maxBorrowRate),
            "tighter cap bites after the upgrade"
        );
    }

    function test_upgrade_capBelowAdaptedRate_clampsImmediately_keepsState() public {
        address proxy = _proxy(_impl(_cfg(int256(0.02 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y)));
        _wire(proxy);
        _adaptUp(proxy);

        int256 ratBefore = _rat(proxy);
        uint256 chargedBefore = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(TARGET));

        int256 cap = ratBefore / 2;
        AdaptiveCurveIrm.Config memory c = _cfg(ratBefore, ratBefore / 2, ratBefore * 2);
        c.maxBorrowRate = cap;
        _upgrade(proxy, _impl(c));

        assertEq(_rat(proxy), ratBefore, "rateAtTarget preserved across the upgrade");

        uint256 chargedAfter = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(TARGET));
        assertEq(chargedAfter, uint256(cap), "charged rate clamped to the new cap on the next call");
        assertLt(chargedAfter, chargedBefore, "charged rate dropped after the upgrade");
        assertEq(_rat(proxy), ratBefore, "the cap did not touch rateAtTarget");
    }

    function test_upgrade_tighterMax_atTargetPokeDefersRebound() public {
        address proxy = _proxy(_impl(_cfg(int256(0.02 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y)));
        _wire(proxy);
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

    function test_upgrade_widenLetsRateCreep_thenNarrowShocks() public {
        int256 min0 = int256(0.005 ether) / Y;
        int256 max0 = int256(0.05 ether) / Y;

        address proxy = _proxy(_impl(_cfg(max0, min0, max0)));
        _wire(proxy);
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

    function test_upgrade_targetShift_changesChargedRate_keepsState() public {
        address proxy = _proxy(_impl(_cfg(int256(0.04 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y)));
        _wire(proxy);
        _poke(proxy, TARGET);

        int256 rat = _rat(proxy);
        uint256 chargedBefore = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(0.8 ether));

        AdaptiveCurveIrm.Config memory c = _cfg(rat, rat / 2, rat * 2);
        c.targetUtilization = int256(0.5 ether);
        _upgrade(proxy, _impl(c));

        assertEq(_rat(proxy), rat, "target change does not move the stored rate");
        uint256 chargedAfter = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(0.8 ether));
        assertGt(chargedAfter, chargedBefore, "same utilization charges more after the target moves below it");
    }

    function test_upgrade_steepnessShift_changesChargedRate_keepsState() public {
        address proxy = _proxy(_impl(_cfg(int256(0.04 ether) / Y, int256(0.005 ether) / Y, int256(0.2 ether) / Y)));
        _wire(proxy);
        _poke(proxy, TARGET);

        int256 rat = _rat(proxy);
        uint256 chargedBefore = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(0.98 ether));

        AdaptiveCurveIrm.Config memory c = _cfg(rat, rat / 2, rat * 2);
        c.curveSteepness = int256(4 ether);
        _upgrade(proxy, _impl(c));

        assertEq(_rat(proxy), rat, "steepness change does not move the stored rate");
        uint256 chargedAfter = AdaptiveCurveIrm(proxy).borrowRateView(params, _market(0.98 ether));
        assertGt(chargedAfter, chargedBefore, "steeper curve charges more above target at the same utilization");
    }

    /* HELPERS */

    function _cfg(int256 initial, int256 min, int256 max) internal pure returns (AdaptiveCurveIrm.Config memory) {
        return AdaptiveCurveIrm.Config({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: int256(20 ether) / Y,
            targetUtilization: int256(TARGET),
            initialRateAtTarget: initial,
            minRateAtTarget: min,
            maxRateAtTarget: max,
            maxBorrowRate: 0
        });
    }

    function _impl(AdaptiveCurveIrm.Config memory cfg) internal returns (address) {
        return address(new AdaptiveCurveIrm(address(this), cfg));
    }

    function _proxy(address impl) internal returns (address) {
        return address(new TestERC1967Proxy(impl));
    }

    function _upgrade(address proxy, address newImpl) internal {
        TestERC1967Proxy(payable(proxy)).upgradeTo(newImpl);
    }

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

    function _adaptDown(address proxy) internal {
        _poke(proxy, TARGET);
        for (uint256 i; i < 6; ++i) {
            _poke(proxy, 0.3 ether);
        }
    }

    function _adaptUp(address proxy) internal {
        _poke(proxy, TARGET);
        for (uint256 i; i < 6; ++i) {
            _poke(proxy, 0.98 ether);
        }
    }

    function _poke(address proxy, uint256 utilWad) internal {
        _pokeFor(proxy, utilWad, 5 days);
    }

    function _pokeFor(address proxy, uint256 utilWad, uint256 dt) internal {
        Market memory m = _market(utilWad);
        vm.warp(block.timestamp + dt);
        AdaptiveCurveIrm(proxy).borrowRate(params, m);
    }

    function _borrowAtTarget(address proxy) internal view returns (uint256) {
        return AdaptiveCurveIrm(proxy).borrowRateView(params, _market(TARGET)) * uint256(Y);
    }

    function _rat(address proxy) internal view returns (int256) {
        return AdaptiveCurveIrm(proxy).rateAtTarget(id);
    }

    function _ratAnnual(address proxy) internal view returns (uint256) {
        return uint256(_rat(proxy)) * uint256(Y);
    }

    function _crawl(address proxy, uint256 utilWad, uint256 dt, uint256 steps) internal {
        for (uint256 i; i < steps; ++i) {
            _pokeFor(proxy, utilWad, dt);
        }
    }

    function _market(uint256 utilWad) internal view returns (Market memory m) {
        m.totalSupplyAssets = uint128(SUPPLY);
        m.totalBorrowAssets = uint128(SUPPLY * utilWad / 1e18);
        m.lastUpdate = uint128(block.timestamp);
    }
}
