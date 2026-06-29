// SPDX-License-Identifier: MIT

// Fork invariant: the adapting state `rateAtTarget[id]` is kept within the market's band
// [minRateAtTarget, maxRateAtTarget]. Inductive form: if it is in band (or 0, the uninitialized
// sentinel) before a `borrowRate`, it is in band after.
//
// The curve parameters live in a per-market MarketConfig that the IRM reads via an external `getConfig()` static
// call. The spec links a MarketConfig (`Cfg`) and pins it as the config registered for the market (`configOf`).
// `_newRateAtTarget` is summarized to an arbitrary value within [min, max] -- exactly the guarantee of its final
// `.bound(min, max)` -- so the rule checks that the contract routes only in-band values into storage (first
// interaction -> initial, no adaptation -> unchanged, adaptation -> bounded). `_curve` is NONDET (it feeds only
// the returned rate, not the stored state).
//
// `validConfig()` assumes the invariants `MarketConfig`'s constructor (`_validateConfig`) guarantees but the Prover
// does not model on the linked config's immutables. The market/elapsed bounds keep the inline WAD math from
// overflowing, giving a reachable, non-reverting path.

using AdaptiveCurveIrmHarness as Irm;
using MarketConfig as Cfg;

methods {
    function configOf(AdaptiveCurveIrmHarness.MarketParams) external returns (address) envfree;
    function rateAtTargetOf(AdaptiveCurveIrmHarness.MarketParams) external returns (int256) envfree;
    function Cfg.getConfig() external returns (IMarketConfig.Config) envfree;

    function _.getConfig() external => DISPATCHER(true);

    function AdaptiveCurveIrm._newRateAtTarget(int256, int256, IMarketConfig.Config memory) internal returns (int256)
        => inBand();
    function AdaptiveCurveIrm._curve(int256, int256, int256) internal returns (int256) => NONDET;
}

definition WAD() returns int256 = 1000000000000000000;

// Models `.bound(min, max)`: an arbitrary value within the band of the linked config.
function inBand() returns int256 {
    IMarketConfig.Config cfg = Cfg.getConfig();
    int256 r;
    require r >= cfg.minRateAtTarget && r <= cfg.maxRateAtTarget;
    return r;
}

// What MarketConfig's _validateConfig guarantees about the linked config's params.
function validConfig() {
    IMarketConfig.Config cfg = Cfg.getConfig();
    require cfg.minRateAtTarget > 0;
    require cfg.maxRateAtTarget >= cfg.minRateAtTarget;
    require cfg.initialRateAtTarget >= cfg.minRateAtTarget && cfg.initialRateAtTarget <= cfg.maxRateAtTarget;
    require cfg.curveSteepness >= WAD();
    require cfg.targetUtilization > 0 && cfg.targetUtilization < WAD();
    // Bounded above (>= the real MAX_ADJUSTMENT_SPEED) only so `speed * elapsed` cannot overflow on the path.
    require cfg.adjustmentSpeed >= 0 && cfg.adjustmentSpeed <= 1000000000000000;
}

rule rateAtTargetStaysInBand(env e, AdaptiveCurveIrmHarness.MarketParams marketParams, AdaptiveCurveIrmHarness.Market market) {
    require configOf(marketParams) == Cfg;            // the registered config is the linked MarketConfig
    validConfig();
    IMarketConfig.Config cfg = Cfg.getConfig();

    int256 before = rateAtTargetOf(marketParams);
    // Inductive hypothesis: previously in band, or the 0 first-interaction sentinel.
    require before == 0 || (before >= cfg.minRateAtTarget && before <= cfg.maxRateAtTarget);
    // Keep the inline WAD math from overflowing on the reachable path.
    require market.totalBorrowAssets <= market.totalSupplyAssets;
    require market.lastUpdate <= e.block.timestamp;
    require to_mathint(e.block.timestamp) - to_mathint(market.lastUpdate) <= 365 * 86400;

    borrowRate(e, marketParams, market);

    int256 afterVal = rateAtTargetOf(marketParams);
    assert afterVal >= cfg.minRateAtTarget && afterVal <= cfg.maxRateAtTarget;
}
