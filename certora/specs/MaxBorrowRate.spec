// SPDX-License-Identifier: MIT

// Property of the fork-added maxBorrowRate cap.
//
// The curve parameters live in a per-market AdaptiveCurveConfig that the IRM reads via an external `getCurveParams()` static
// call. The spec links an AdaptiveCurveConfig (`Cfg`), pins it as the config registered for the market (via the native
// `marketCurveConfig(id)` getter), and reads the cap from it. The market id is derived from `marketParams` with the pure
// `Lib.toId` helper, which computes the same `MarketParamsLib.id()` the contract computes internally. The curve
// evaluation (`_curve`) and adaptation step (`_newRateAtTarget`) are abstracted to NONDET -- that is exactly the cap
// property: whatever the curve produces, an enabled cap must bound the charged rate via the final clamp. It also
// keeps the heavy WAD/exp math off the reachable path, so the rules verify non-vacuously (rule_sanity passes).

using AdaptiveCurveIrm as Irm;
using AdaptiveCurveConfig as Cfg;
using AdaptiveCurveIrmLibHarness as Lib;

methods {
    function Irm.marketCurveConfig(AdaptiveCurveIrm.Id) external returns (address) envfree;
    function Lib.toId(AdaptiveCurveIrm.MarketParams) external returns (AdaptiveCurveIrm.Id) envfree;
    function Cfg.getCurveParams() external returns (AdaptiveCurveIrm.AdaptiveCurveParams) envfree;

    function _.getCurveParams() external => DISPATCHER(true);

    function AdaptiveCurveIrm._curve(int256, int256, int256) internal returns (int256) => NONDET;
    function AdaptiveCurveIrm._newRateAtTarget(int256, int256, AdaptiveCurveIrm.AdaptiveCurveParams memory) internal returns (int256)
        => NONDET;
}

// `borrowRateView` never returns more than the cap, when the cap is enabled.
rule borrowRateViewRespectsCap(env e, AdaptiveCurveIrm.MarketParams marketParams, AdaptiveCurveIrm.Market market) {
    AdaptiveCurveIrm.Id id = Lib.toId(marketParams);
    require Irm.marketCurveConfig(id) == Cfg;              // the registered config is the linked AdaptiveCurveConfig
    AdaptiveCurveIrm.AdaptiveCurveParams cfg = Cfg.getCurveParams();
    require cfg.maxBorrowRate != 0;                   // cap enabled
    require market.totalBorrowAssets <= market.totalSupplyAssets; // utilization <= 1, so `err` does not overflow

    uint256 rate = borrowRateView(e, marketParams, market);
    assert rate <= cfg.maxBorrowRate;
}

// The state-changing `borrowRate` (Morpho only) likewise never returns more than the cap.
rule borrowRateRespectsCap(env e, AdaptiveCurveIrm.MarketParams marketParams, AdaptiveCurveIrm.Market market) {
    AdaptiveCurveIrm.Id id = Lib.toId(marketParams);
    require Irm.marketCurveConfig(id) == Cfg;
    AdaptiveCurveIrm.AdaptiveCurveParams cfg = Cfg.getCurveParams();
    require cfg.maxBorrowRate != 0;
    require market.totalBorrowAssets <= market.totalSupplyAssets;

    uint256 rate = borrowRate(e, marketParams, market);
    assert rate <= cfg.maxBorrowRate;
}
