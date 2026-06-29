// SPDX-License-Identifier: MIT

// Property of the fork-added maxBorrowRate cap.
//
// The curve parameters live in a per-market MarketConfig that the IRM reads via an external `getConfig()` static
// call. The spec links a MarketConfig (`Cfg`), pins it as the config registered for the market (`configOf`), and
// reads the cap from it. The curve evaluation (`_curve`) and adaptation step (`_newRateAtTarget`) are abstracted to
// NONDET -- that is exactly the cap property: whatever the curve produces, an enabled cap must bound the charged
// rate via the final clamp. It also keeps the heavy WAD/exp math off the reachable path, so the rules verify
// non-vacuously (rule_sanity passes).

using AdaptiveCurveIrmHarness as Irm;
using MarketConfig as Cfg;

methods {
    function configOf(AdaptiveCurveIrmHarness.MarketParams) external returns (address) envfree;
    function Cfg.getConfig() external returns (IMarketConfig.Config) envfree;

    function _.getConfig() external => DISPATCHER(true);

    function AdaptiveCurveIrm._curve(int256, int256, int256) internal returns (int256) => NONDET;
    function AdaptiveCurveIrm._newRateAtTarget(int256, int256, IMarketConfig.Config memory) internal returns (int256)
        => NONDET;
}

// `borrowRateView` never returns more than the cap, when the cap is enabled.
rule borrowRateViewRespectsCap(env e, AdaptiveCurveIrmHarness.MarketParams marketParams, AdaptiveCurveIrmHarness.Market market) {
    require configOf(marketParams) == Cfg;            // the registered config is the linked MarketConfig
    IMarketConfig.Config cfg = Cfg.getConfig();
    require cfg.maxBorrowRate != 0;                   // cap enabled
    require market.totalBorrowAssets <= market.totalSupplyAssets; // utilization <= 1, so `err` does not overflow

    uint256 rate = borrowRateView(e, marketParams, market);
    assert rate <= cfg.maxBorrowRate;
}

// The state-changing `borrowRate` (Morpho only) likewise never returns more than the cap.
rule borrowRateRespectsCap(env e, AdaptiveCurveIrmHarness.MarketParams marketParams, AdaptiveCurveIrmHarness.Market market) {
    require configOf(marketParams) == Cfg;
    IMarketConfig.Config cfg = Cfg.getConfig();
    require cfg.maxBorrowRate != 0;
    require market.totalBorrowAssets <= market.totalSupplyAssets;

    uint256 rate = borrowRate(e, marketParams, market);
    assert rate <= cfg.maxBorrowRate;
}
