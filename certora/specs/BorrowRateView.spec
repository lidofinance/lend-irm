// SPDX-License-Identifier: MIT

using AdaptiveCurveIrm as AdaptiveCurveIrm;
using AdaptiveCurveIrmLibHarness as AdaptiveCurveIrmLibHarness;

methods {
    function AdaptiveCurveIrmLibHarness.toId(AdaptiveCurveIrm.MarketParams) external returns (AdaptiveCurveIrm.Id) envfree;

    function _.rateAtTarget(AdaptiveCurveIrm.Id id) external => DISPATCHER(true);
    // The periphery lib reads the curve params from the IRM instance, so the getters must be resolved to the
    // linked AdaptiveCurveIrm rather than havoc'd.
    function _.CURVE_STEEPNESS() external => DISPATCHER(true);
    function _.ADJUSTMENT_SPEED() external => DISPATCHER(true);
    function _.TARGET_UTILIZATION() external => DISPATCHER(true);
    function _.INITIAL_RATE_AT_TARGET() external => DISPATCHER(true);
    function _.MIN_RATE_AT_TARGET() external => DISPATCHER(true);
    function _.MAX_RATE_AT_TARGET() external => DISPATCHER(true);
    function _.MAX_BORROW_RATE() external => DISPATCHER(true);
}

// Rule: the lib returns the same result as the contract
rule borrowRateViewEquivalence(env e, AdaptiveCurveIrm.MarketParams marketParams, AdaptiveCurveIrm.Market market) {
    AdaptiveCurveIrm.Id id = AdaptiveCurveIrmLibHarness.toId(marketParams);

    uint256 originalRate = AdaptiveCurveIrm.borrowRateView(e, marketParams, market);
    uint256 libRate = AdaptiveCurveIrmLibHarness.borrowRateView(e, id, market, AdaptiveCurveIrm);

    assert originalRate == libRate;
}

// Rule: the lib reverts exactly when the contract reverts
rule borrowRateView2Liveness(env e, AdaptiveCurveIrm.MarketParams marketParams, AdaptiveCurveIrm.Market market) {
    AdaptiveCurveIrm.Id id = AdaptiveCurveIrmLibHarness.toId(marketParams);

    AdaptiveCurveIrm.borrowRateView@withrevert(e, marketParams, market);
    bool originalReverted = lastReverted;

    AdaptiveCurveIrmLibHarness.borrowRateView@withrevert(e, id, market, AdaptiveCurveIrm);
    bool view2Reverted = lastReverted;

    assert originalReverted == view2Reverted;
}
