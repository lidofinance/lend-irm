// SPDX-License-Identifier: MIT

// Fork invariant: the adapting state `rateAtTarget[id]` is kept within the per-deployment band
// [MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET]. Inductive form: if it is in band (or 0, the uninitialized
// sentinel) before a `borrowRate`, it is in band after.
//
// `_newRateAtTarget` is summarized to an arbitrary value within [MIN, MAX] -- exactly the guarantee of its
// final `.bound(MIN, MAX)` -- so the rule checks that the contract routes only in-band values into storage
// (first interaction -> INITIAL, no adaptation -> unchanged, adaptation -> bounded). `_curve` is NONDET (it
// feeds only the returned rate, not the stored state).
//
// `validConfig()` assumes the invariants the constructor (`_validateConfig`) guarantees but the Prover does
// not model on the immutables. The market/elapsed bounds keep the inline WAD math from overflowing, giving a
// reachable, non-reverting path.

methods {
    function MIN_RATE_AT_TARGET() external returns (int256) envfree;
    function MAX_RATE_AT_TARGET() external returns (int256) envfree;
    function INITIAL_RATE_AT_TARGET() external returns (int256) envfree;
    function CURVE_STEEPNESS() external returns (int256) envfree;
    function TARGET_UTILIZATION() external returns (int256) envfree;
    function ADJUSTMENT_SPEED() external returns (int256) envfree;
    function rateAtTargetOf(AdaptiveCurveIrmHarness.MarketParams) external returns (int256) envfree;

    function AdaptiveCurveIrm._newRateAtTarget(int256, int256) internal returns (int256) => inBand();
    function AdaptiveCurveIrm._curve(int256, int256) internal returns (int256) => NONDET;
}

definition WAD() returns int256 = 1000000000000000000;

// Models `.bound(MIN, MAX)`: an arbitrary value within the band.
function inBand() returns int256 {
    int256 r;
    require r >= MIN_RATE_AT_TARGET() && r <= MAX_RATE_AT_TARGET();
    return r;
}

// What the constructor's _validateConfig guarantees about the immutables.
function validConfig() {
    require MIN_RATE_AT_TARGET() > 0;
    require MAX_RATE_AT_TARGET() >= MIN_RATE_AT_TARGET();
    require INITIAL_RATE_AT_TARGET() >= MIN_RATE_AT_TARGET() && INITIAL_RATE_AT_TARGET() <= MAX_RATE_AT_TARGET();
    require CURVE_STEEPNESS() >= WAD();
    require TARGET_UTILIZATION() > 0 && TARGET_UTILIZATION() < WAD();
    // Bounded above (>= the real MAX_ADJUSTMENT_SPEED) only so `speed * elapsed` cannot overflow on the path.
    require ADJUSTMENT_SPEED() >= 0 && ADJUSTMENT_SPEED() <= 1000000000000000;
}

rule rateAtTargetStaysInBand(env e, AdaptiveCurveIrmHarness.MarketParams marketParams, AdaptiveCurveIrmHarness.Market market) {
    validConfig();

    int256 before = rateAtTargetOf(marketParams);
    // Inductive hypothesis: previously in band, or the 0 first-interaction sentinel.
    require before == 0 || (before >= MIN_RATE_AT_TARGET() && before <= MAX_RATE_AT_TARGET());
    // Keep the inline WAD math from overflowing on the reachable path.
    require market.totalBorrowAssets <= market.totalSupplyAssets;
    require market.lastUpdate <= e.block.timestamp;
    require to_mathint(e.block.timestamp) - to_mathint(market.lastUpdate) <= 365 * 86400;

    borrowRate(e, marketParams, market);

    int256 afterVal = rateAtTargetOf(marketParams);
    assert afterVal >= MIN_RATE_AT_TARGET() && afterVal <= MAX_RATE_AT_TARGET();
}
