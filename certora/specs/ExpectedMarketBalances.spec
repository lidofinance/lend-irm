// SPDX-License-Identifier: MIT

using AdaptiveCurveIrm as AdaptiveCurveIrm;
using AdaptiveCurveIrmLibHarness as AdaptiveCurveIrmLibHarness;
using Morpho as Morpho;

// Both paths reach the IRM's borrow rate, which reads the market's curve params from its AdaptiveCurveConfig via an external
// `getCurveParams()` static call (the config address resolved from the `marketCurveConfig` mapping). `getCurveParams()` is
// summarized to a single ghost-backed Params and the mapping/state reads are dispatched to the linked IRM, so the
// lib reads the same state and params as the contract.
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
    function _.market(AdaptiveCurveIrm.Id) external => DISPATCHER(true);
    function _.borrowRateView(AdaptiveCurveIrm.MarketParams, AdaptiveCurveIrm.Market) external => DISPATCHER(true);
    function _.getCurveParams() external => getCurveParamsSummary() expect AdaptiveCurveIrm.AdaptiveCurveParams;
}

// Rule: AdaptiveCurveIrmBalancesLib behaves identically to MorphoBalancesLib
rule balancesLibEquivalence(env e, address morpho, AdaptiveCurveIrm.MarketParams marketParams) {
    require marketParams.irm == AdaptiveCurveIrm;

    AdaptiveCurveIrm.Id id = AdaptiveCurveIrmLibHarness.toId(marketParams);

    // Get results from both libraries
    uint256 adaptiveTotalSupplyAssets;
    uint256 adaptiveTotalSupplyShares;
    uint256 adaptiveTotalBorrowAssets;
    uint256 adaptiveTotalBorrowShares;
    (adaptiveTotalSupplyAssets, adaptiveTotalSupplyShares, adaptiveTotalBorrowAssets, adaptiveTotalBorrowShares) =
        AdaptiveCurveIrmLibHarness.adaptiveCurveIrmLibExpectedMarketBalances(e, morpho, id, AdaptiveCurveIrm);

    uint256 morphoTotalSupplyAssets;
    uint256 morphoTotalSupplyShares;
    uint256 morphoTotalBorrowAssets;
    uint256 morphoTotalBorrowShares;
    (morphoTotalSupplyAssets, morphoTotalSupplyShares, morphoTotalBorrowAssets, morphoTotalBorrowShares) =
        AdaptiveCurveIrmLibHarness.morphoBalancesLibExpectedMarketBalances(e, morpho, marketParams);

    // Both libraries should return identical results
    assert adaptiveTotalSupplyAssets == morphoTotalSupplyAssets;
    assert adaptiveTotalSupplyShares == morphoTotalSupplyShares;
    assert adaptiveTotalBorrowAssets == morphoTotalBorrowAssets;
    assert adaptiveTotalBorrowShares == morphoTotalBorrowShares;
}

rule balancesLibLiveness(env e, address morpho, AdaptiveCurveIrm.MarketParams marketParams) {
    require marketParams.irm == AdaptiveCurveIrm;

    AdaptiveCurveIrm.Id id = AdaptiveCurveIrmLibHarness.toId(marketParams);

    AdaptiveCurveIrmLibHarness.adaptiveCurveIrmLibExpectedMarketBalances@withrevert(e, morpho, id, AdaptiveCurveIrm);
    bool adaptiveCurveIrmReverted = lastReverted;

    AdaptiveCurveIrmLibHarness.morphoBalancesLibExpectedMarketBalances@withrevert(e, morpho, marketParams);
    bool morphoReverted = lastReverted;

    assert adaptiveCurveIrmReverted == morphoReverted;
}
