// SPDX-License-Identifier: MIT

using AdaptiveCurveIrm as AdaptiveCurveIrm;
using AdaptiveCurveIrmLibHarness as AdaptiveCurveIrmLibHarness;
using Morpho as Morpho;

methods {
    function AdaptiveCurveIrmLibHarness.toId(AdaptiveCurveIrm.MarketParams) external returns (AdaptiveCurveIrm.Id) envfree;

    function _.rateAtTarget(AdaptiveCurveIrm.Id id) external => DISPATCHER(true);
    function _.market(Morpho.Id) external => DISPATCHER(true);
    function _.borrowRateView(Morpho.MarketParams, Morpho.Market) external => DISPATCHER(true);
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
