// SPDX-License-Identifier: MIT

// For the linked immutable config, the adapting state `rateAtTarget[id]` is kept within the market's band
// [minRateAtTarget, maxRateAtTarget]. Two rules: the inductive `borrowRate` step -- in band (or 0, the
// uninitialized sentinel) before implies in band after -- and the setter's eager re-clamp, which restores the
// inductive hypothesis whenever a reparametrization moves the band.
//
// The curve parameters come from the config that the IRM reads via a `getCurveParams()` static call. The spec
// includes one linked config (`Cfg`): the inductive rule pins it as the bound address, and the setter applies it
// through the real `applyIrmConfig(MarketParams,address)` path. The market id is derived with the pure
// `Lib.toId` helper, which computes the same `MarketParamsLib.id()` the contract computes internally.
// `_newRateAtTarget` is summarized to an arbitrary value within [min, max] -- exactly the guarantee of its final
// `.bound(min, max)` -- so the rule checks that only in-band values reach storage.
// `_curve` is NONDET (it feeds only the returned rate, not the stored state).
//
// The linked `AdaptiveCurveConfig` is immutable, so its parameters do not change within this proof.
// `validConfig()` assumes they are valid; the IRM setter does not validate them. The market/elapsed bounds keep the
// inline WAD math from overflowing, giving a reachable, non-reverting path.

using AdaptiveCurveIrm as Irm;
using AdaptiveCurveConfig as Cfg;
using AdaptiveCurveIrmLibHarness as Lib;

methods {
    function Irm.marketCurveConfig(AdaptiveCurveIrm.Id) external returns (address) envfree;
    function Irm.rateAtTarget(AdaptiveCurveIrm.Id) external returns (int256) envfree;
    function Lib.toId(AdaptiveCurveIrm.MarketParams) external returns (AdaptiveCurveIrm.Id) envfree;
    function Cfg.getCurveParams() external returns (AdaptiveCurveIrm.AdaptiveCurveParams) envfree;

    function _.getCurveParams() external => DISPATCHER(true);

    function AdaptiveCurveIrm._newRateAtTarget(int256, int256, AdaptiveCurveIrm.AdaptiveCurveParams memory) internal returns (int256)
        => inBand();
    function AdaptiveCurveIrm._curve(int256, int256, int256) internal returns (int256) => NONDET;
}

definition WAD() returns int256 = 1000000000000000000;

// Models `.bound(min, max)`: an arbitrary value within the band of the linked config.
function inBand() returns int256 {
    AdaptiveCurveIrm.AdaptiveCurveParams cfg = Cfg.getCurveParams();
    int256 r;
    require r >= cfg.minRateAtTarget && r <= cfg.maxRateAtTarget;
    return r;
}

// Models the valid-parameter assumptions for the linked config.
function validConfig() {
    AdaptiveCurveIrm.AdaptiveCurveParams cfg = Cfg.getCurveParams();
    require cfg.minRateAtTarget > 0;
    require cfg.maxRateAtTarget >= cfg.minRateAtTarget;
    require cfg.initialRateAtTarget >= cfg.minRateAtTarget && cfg.initialRateAtTarget <= cfg.maxRateAtTarget;
    require cfg.curveSteepness >= WAD();
    require cfg.targetUtilization > 0 && cfg.targetUtilization < WAD();
    // Bounded above (>= the real MAX_ADJUSTMENT_SPEED) only so `speed * elapsed` cannot overflow on the path.
    require cfg.adjustmentSpeed >= 0 && cfg.adjustmentSpeed <= 1000000000000000;
}

rule rateAtTargetStaysInBand(env e, AdaptiveCurveIrm.MarketParams marketParams, AdaptiveCurveIrm.Market market) {
    AdaptiveCurveIrm.Id id = Lib.toId(marketParams);
    require Irm.marketCurveConfig(id) == Cfg;              // the bound config is the linked config
    validConfig();
    AdaptiveCurveIrm.AdaptiveCurveParams cfg = Cfg.getCurveParams();

    int256 before = Irm.rateAtTarget(id);
    // Inductive hypothesis: previously in band, or the 0 first-interaction sentinel.
    require before == 0 || (before >= cfg.minRateAtTarget && before <= cfg.maxRateAtTarget);
    // Keep the inline WAD math from overflowing on the reachable path.
    require market.totalBorrowAssets <= market.totalSupplyAssets;
    require market.lastUpdate <= e.block.timestamp;
    require to_mathint(e.block.timestamp) - to_mathint(market.lastUpdate) <= 365 * 86400;

    borrowRate(e, marketParams, market);

    int256 afterVal = Irm.rateAtTarget(id);
    assert afterVal >= cfg.minRateAtTarget && afterVal <= cfg.maxRateAtTarget;
}

// The setter reads and binds the linked config, clamps a non-zero stored rateAtTarget into the returned band, and
// leaves the 0 sentinel alone. `validConfig()` is an assumption, not setter-side validation.
rule setterClampsRateIntoNewBand(env e, AdaptiveCurveIrm.MarketParams marketParams) {
    AdaptiveCurveIrm.Id id = Lib.toId(marketParams);
    int256 before = Irm.rateAtTarget(id);
    validConfig();
    AdaptiveCurveIrm.AdaptiveCurveParams newParams = Cfg.getCurveParams();

    applyIrmConfig(e, marketParams, Cfg);

    int256 afterVal = Irm.rateAtTarget(id);
    assert Irm.marketCurveConfig(id) == Cfg;
    assert before == 0 => afterVal == 0;
    assert before != 0 => (afterVal >= newParams.minRateAtTarget && afterVal <= newParams.maxRateAtTarget);
}
