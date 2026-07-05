// SPDX-License-Identifier: MIT

using AdaptiveCurveIrm as AdaptiveCurveIrm;
using AdaptiveCurveIrmLibHarness as AdaptiveCurveIrmLibHarness;

// The periphery lib recomputes the rate from a market id by reading the IRM's per-market config mapping (`marketCurveConfig`), the stored
// `rateAtTarget`, and the market's AdaptiveCurveConfig (`getCurveParams`) -- all via external calls. They are dispatched to the
// linked IRM so the lib reads the same state the contract reads directly. `getCurveParams()` is summarized to a single
// ghost-backed Params so both sides see identical params (equivalence is about computing the same rate from the same
// config, not about a particular config value).
ghost int256 g_curveSteepness;
ghost int256 g_adjustmentSpeed;
ghost int256 g_targetUtilization;
ghost int256 g_initialRateAtTarget;
ghost int256 g_minRateAtTarget;
ghost int256 g_maxRateAtTarget;
ghost uint256 g_maxBorrowRate;

function getCurveParamsSummary() returns AdaptiveCurveIrm.AdaptiveCurveParams {
    AdaptiveCurveIrm.AdaptiveCurveParams c;
    require c.curveSteepness == g_curveSteepness;
    require c.adjustmentSpeed == g_adjustmentSpeed;
    require c.targetUtilization == g_targetUtilization;
    require c.initialRateAtTarget == g_initialRateAtTarget;
    require c.minRateAtTarget == g_minRateAtTarget;
    require c.maxRateAtTarget == g_maxRateAtTarget;
    require c.maxBorrowRate == g_maxBorrowRate;
    return c;
}

methods {
    function AdaptiveCurveIrmLibHarness.toId(AdaptiveCurveIrm.MarketParams) external returns (AdaptiveCurveIrm.Id) envfree;

    function _.rateAtTarget(AdaptiveCurveIrm.Id id) external => DISPATCHER(true);
    function _.marketCurveConfig(AdaptiveCurveIrm.Id id) external => DISPATCHER(true);
    function _.getCurveParams() external => getCurveParamsSummary() expect AdaptiveCurveIrm.AdaptiveCurveParams;
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
