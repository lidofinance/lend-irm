// SPDX-License-Identifier: MIT

// Verification of the fork-added LinearKinkIrm: a stateless, per-market piecewise-linear ("jump rate") IRM.
//
// The scene is the production IRM plus one linked config (`Cfg`) -- no harness. Rules that must relate stored
// parameters to the returned rate use Cfg through the real `applyIrmConfig(MarketParams,address)` path,
// then compare against `Cfg.getKinkParams()`. `validConfig()` assumes that the getter returns parameters satisfying
// the valid-parameter assumptions when applied. The IRM setter deliberately performs no value validation. This
// exercises the production getter call and packed snapshot write. Where a rule must talk about
// storage across all markets, it reads
// `currentContract.marketKinkParams[id]` directly. Starting setter rules from all-zero storage additionally pins id
// agreement: the only configured slot is the one the setter wrote, so a successful read proves the view resolves
// the same id. The rate math is light integer mul-div, so no internal summarization is needed.

using LinearKinkConfig as Cfg;

methods {
    function Cfg.getKinkParams() external returns (LinearKinkIrm.LinearKinkParams) envfree;

    function _.getKinkParams() external => DISPATCHER(true);
}

definition WAD() returns uint256 = 1000000000000000000;
// 8e18 / 365 days, rounded down: the maximum valid peak rate.
definition VALID_CONFIG_MAX_PEAK_RATE() returns uint256 = 253678335870;

// Models the LinearKinkConfig constructor assumptions for the `getKinkParams()` result when it is applied.
// `applyIrmConfig` copies the returned snapshot without performing value validation.
function validConfig() {
    LinearKinkIrm.LinearKinkParams params = Cfg.getKinkParams();
    require params.optimalUtilization > 0 && params.optimalUtilization < WAD();
    require to_mathint(params.baseRate) + to_mathint(params.slope1) + to_mathint(params.slope2)
        <= to_mathint(VALID_CONFIG_MAX_PEAK_RATE());
}

// (a) validConfigCeilingRespected: under the LinearKinkConfig constructor assumptions, the rate never exceeds its
//     copied peak or that config's 800%/year peak ceiling. The IRM has no ceiling getter or setter-side check.
//     Unconditional in market state: utilization is clamped to WAD inside _borrowRate, so the bound also holds for
//     out-of-range view inputs.
rule validConfigCeilingRespected(
    env eSet,
    env e,
    LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market market
) {
    validConfig();
    LinearKinkIrm.LinearKinkParams params = Cfg.getKinkParams();
    // Route the linked config through the real setter. Its copied snapshot is exactly what borrowRateView reads at
    // the id the contract itself derives from `marketParams`.
    applyIrmConfig(eSet, marketParams, Cfg);

    uint256 rate = borrowRateView(e, marketParams, market);

    assert rate <= params.baseRate + params.slope1 + params.slope2;
    assert rate <= VALID_CONFIG_MAX_PEAK_RATE();
}

// (b) rateNeverExceedsValidConfigCeiling: conditional on every stored snapshot satisfying the LinearKinkConfig peak
//     ceiling, the returned rate never exceeds 800%/year. This is intentionally a precondition rather than a
//     reachable-storage invariant: applyIrmConfig copies arbitrary returned values without validation.
rule rateNeverExceedsValidConfigCeiling(
    env e,
    LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market market
) {
    mathint maxConfigPeak = VALID_CONFIG_MAX_PEAK_RATE();
    require forall LinearKinkIrm.Id id.
        currentContract.marketKinkParams[id].baseRate + currentContract.marketKinkParams[id].slope1
            + currentContract.marketKinkParams[id].slope2 <= maxConfigPeak;

    uint256 rate = borrowRateView(e, marketParams, market);
    assert rate <= VALID_CONFIG_MAX_PEAK_RATE();
}

// (c) stateless: `borrowRate` and `borrowRateView` return the same value for all inputs. Both are `view` here, so
//     there is no env-sensitivity to reason about -- plain equality.
rule stateless(env e, LinearKinkIrm.MarketParams marketParams, LinearKinkIrm.Market market) {
    uint256 rw = borrowRate(e, marketParams, market);
    uint256 rv = borrowRateView(e, marketParams, market);
    assert rw == rv;
}

// (d) monotonic: for two markets identical except for `totalBorrowAssets` (b1 <= b2, same supply), the rate is
//     non-decreasing in utilization. Holds for arbitrary stored parameters: each leg is a non-decreasing floor
//     composition of U, the curve is continuous-monotone across the kink (segment-1 max = baseRate + slope1 =
//     segment-2 infimum), the WAD clamp preserves order, and paths that revert (e.g. an unset market) are pruned
//     by the plain (non-@withrevert) calls.
rule monotonic(
    env e,
    LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market m1,
    LinearKinkIrm.Market m2
) {
    require m1.totalSupplyAssets == m2.totalSupplyAssets;
    require m1.totalBorrowAssets <= m2.totalBorrowAssets;

    uint256 r1 = borrowRateView(e, marketParams, m1);
    uint256 r2 = borrowRateView(e, marketParams, m2);
    assert r1 <= r2;
}

// (e) revertsWhenUnset: on a contract where no market has been configured (all-zero `marketKinkParams`, e.g. a
//     freshly constructed instance), `borrowRateView` reverts for every market with `config not set`.
//     `optimalUtilization == 0` is the unset sentinel. Valid returned parameters make it unreachable on the
//     supported setter path; applyIrmConfig itself does not enforce that condition.
rule revertsWhenUnset(env e, LinearKinkIrm.MarketParams marketParams, LinearKinkIrm.Market market) {
    require forall LinearKinkIrm.Id id. currentContract.marketKinkParams[id].optimalUtilization == 0;

    borrowRateView@withrevert(e, marketParams, market);
    assert lastReverted;
}

// (f) configuredMarketSucceeds: from all-zero storage, configuring a market makes its `borrowRateView` succeed for
//     every market state. On that storage the only configured slot is the one the setter wrote, so success proves
//     the setter and the view derive the SAME id from `marketParams` (guards against id-confusion, which the
//     setter-then-read rules alone cannot see).
rule configuredMarketSucceeds(
    env eSet,
    env e,
    LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market market
) {
    require forall LinearKinkIrm.Id id. currentContract.marketKinkParams[id].optimalUtilization == 0;

    validConfig();
    applyIrmConfig(eSet, marketParams, Cfg);

    require e.msg.value == 0; // borrowRateView is non-payable
    borrowRateView@withrevert(e, marketParams, market);
    assert !lastReverted;
}

// (g) setterEndpointRoundTrip: after applying the linked config, `borrowRateView` returns `baseRate` at zero
//     utilization and precisely `baseRate + slope1 + slope2` at full utilization. Both endpoint values are exact,
//     with no rounding.
rule setterEndpointRoundTrip(
    env eSet,
    env e,
    LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market mZero,
    LinearKinkIrm.Market mFull
) {
    require forall LinearKinkIrm.Id id. currentContract.marketKinkParams[id].optimalUtilization == 0;

    validConfig();
    LinearKinkIrm.LinearKinkParams params = Cfg.getKinkParams();
    applyIrmConfig(eSet, marketParams, Cfg);

    require mZero.totalSupplyAssets == 1 && mZero.totalBorrowAssets == 0; // U = 0
    require mFull.totalSupplyAssets == 1 && mFull.totalBorrowAssets == 1; // U = WAD exactly

    uint256 rateAtZero = borrowRateView(e, marketParams, mZero);
    uint256 rateAtFull = borrowRateView(e, marketParams, mFull);

    assert to_mathint(rateAtZero) == to_mathint(params.baseRate);
    assert rateAtFull == params.baseRate + params.slope1 + params.slope2;
}
