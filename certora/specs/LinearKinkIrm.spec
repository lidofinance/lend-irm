// SPDX-License-Identifier: MIT

// Verification of the fork-added LinearKinkIrm: a stateless, per-market piecewise-linear ("jump rate") IRM.
//
// The scene is the production contract alone -- no harness. Rules never need to recompute the market id from
// `marketParams`: where a rule must relate the stored parameters to the returned rate, it routes them through the
// real `setMarketKinkParams` (so the stored values are exactly what the setter accepted, written and read on the
// contract's own id-derivation path). Where it must talk about storage across all markets, it reads it directly
// (`currentContract.marketKinkParams[id]`). Starting the setter rules from all-zero storage additionally pins the
// id agreement: the only configured slot is the one the setter wrote, so a successful read proves the view resolves
// the same id. The rate math is light integer mul-div (no exp / no Taylor), so no internal summarization is needed
// for the rules to be reachable and non-vacuous.

methods {
    function MAX_BORROW_RATE() external returns (uint256) envfree;
}

// The peak of every stored curve is capped by MAX_BORROW_RATE: zero at construction, and every write goes through
// setMarketKinkParams, which enforces the bound. Justifies the storage precondition of `rateNeverExceedsMax`.
invariant peakCapped(LinearKinkIrm.Id id)
    currentContract.marketKinkParams[id].baseRate + currentContract.marketKinkParams[id].slope1
        + currentContract.marketKinkParams[id].slope2 <= to_mathint(MAX_BORROW_RATE());

// (a) capRespected: whatever parameters the setter accepts, the rate charged afterwards never exceeds the curve's
//     peak (baseRate + slope1 + slope2), and hence never exceeds MAX_BORROW_RATE (the setter validates the peak).
//     Unconditional in the market state: utilization is clamped to WAD inside _borrowRate, so the bound holds even
//     for out-of-range view inputs (totalBorrowAssets > totalSupplyAssets).
rule capRespected(
    env eSet,
    env e,
    LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.LinearKinkParams params,
    LinearKinkIrm.Market market
) {
    // Route the parameters through the real setter: what it accepted is exactly what borrowRateView will read,
    // stored and loaded at the id the contract itself derives from `marketParams`.
    setMarketKinkParams(eSet, marketParams, params);

    uint256 rate = borrowRateView(e, marketParams, market);

    assert rate <= params.baseRate + params.slope1 + params.slope2;
    assert rate <= MAX_BORROW_RATE();
}

// (b) rateNeverExceedsMax: on any storage where every stored peak is capped -- which `peakCapped` proves is every
//     reachable storage -- the returned rate never exceeds MAX_BORROW_RATE, whatever market it is computed for.
//     Together with the invariant this closes the induction that capRespected states only for the setter path.
rule rateNeverExceedsMax(env e, LinearKinkIrm.MarketParams marketParams, LinearKinkIrm.Market market) {
    // Contract calls are disallowed inside quantified formulas -- bind the constant outside the forall.
    mathint maxBorrowRate = MAX_BORROW_RATE();
    require forall LinearKinkIrm.Id id.
        currentContract.marketKinkParams[id].baseRate + currentContract.marketKinkParams[id].slope1
            + currentContract.marketKinkParams[id].slope2 <= maxBorrowRate;

    uint256 rate = borrowRateView(e, marketParams, market);
    assert rate <= MAX_BORROW_RATE();
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
//     freshly initialized proxy), `borrowRateView` reverts for every market (`config not set` —
//     `optimalUtilization == 0` is the unset sentinel and the setter makes it unreachable for a configured market).
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
    LinearKinkIrm.LinearKinkParams params,
    LinearKinkIrm.Market market
) {
    require forall LinearKinkIrm.Id id. currentContract.marketKinkParams[id].optimalUtilization == 0;

    setMarketKinkParams(eSet, marketParams, params);

    require e.msg.value == 0; // borrowRateView is non-payable
    borrowRateView@withrevert(e, marketParams, market);
    assert !lastReverted;
}

// (g) setterRoundTrip: the curve read back through `borrowRateView` is exactly the curve the setter was given --
//     the rate is `baseRate` at zero utilization and precisely `baseRate + slope1 + slope2` at full utilization
//     (both points are exact, no rounding). From all-zero storage as above, this pins the stored fields
//     (order and packing included) to the setter's arguments.
rule setterRoundTrip(
    env eSet,
    env e,
    LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.LinearKinkParams params,
    LinearKinkIrm.Market mZero,
    LinearKinkIrm.Market mFull
) {
    require forall LinearKinkIrm.Id id. currentContract.marketKinkParams[id].optimalUtilization == 0;

    setMarketKinkParams(eSet, marketParams, params);

    require mZero.totalSupplyAssets == 1 && mZero.totalBorrowAssets == 0; // U = 0
    require mFull.totalSupplyAssets == 1 && mFull.totalBorrowAssets == 1; // U = WAD exactly

    uint256 rateAtZero = borrowRateView(e, marketParams, mZero);
    uint256 rateAtFull = borrowRateView(e, marketParams, mFull);

    assert to_mathint(rateAtZero) == to_mathint(params.baseRate);
    assert rateAtFull == params.baseRate + params.slope1 + params.slope2;
}
