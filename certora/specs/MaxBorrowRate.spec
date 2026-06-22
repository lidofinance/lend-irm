// SPDX-License-Identifier: MIT

// Property of the fork-added MAX_BORROW_RATE cap.
//
// Verified through AdaptiveCurveIrmHarness (a subclass) so the Prover runs the constructor: the curve
// immutables are then symbolic and valid (they satisfy _validateConfig), instead of being pinned to 0 as they
// are when AdaptiveCurveIrm is verified bare.
//
// The curve evaluation (`_curve`) and adaptation step (`_newRateAtTarget`) are abstracted to NONDET. That is
// exactly the cap property: whatever the curve produces, an enabled cap must bound the charged rate via the
// final clamp (rate = cap != 0 && rate > cap ? cap : rate). It also keeps the heavy WAD/exp math off the
// reachable path, so the rules verify non-vacuously (rule_sanity passes).

methods {
    function MAX_BORROW_RATE() external returns (uint256) envfree;

    function AdaptiveCurveIrm._curve(int256, int256) internal returns (int256) => NONDET;
    function AdaptiveCurveIrm._newRateAtTarget(int256, int256) internal returns (int256) => NONDET;
}

// `borrowRateView` never returns more than the cap, when the cap is enabled.
rule borrowRateViewRespectsCap(env e, AdaptiveCurveIrmHarness.MarketParams marketParams, AdaptiveCurveIrmHarness.Market market) {
    require MAX_BORROW_RATE() != 0; // cap enabled
    require market.totalBorrowAssets <= market.totalSupplyAssets; // utilization <= 1, so `err` does not overflow

    uint256 rate = borrowRateView(e, marketParams, market);
    assert rate <= MAX_BORROW_RATE();
}

// The state-changing `borrowRate` (Morpho only) likewise never returns more than the cap.
rule borrowRateRespectsCap(env e, AdaptiveCurveIrmHarness.MarketParams marketParams, AdaptiveCurveIrmHarness.Market market) {
    require MAX_BORROW_RATE() != 0; // cap enabled
    require market.totalBorrowAssets <= market.totalSupplyAssets; // utilization <= 1, so `err` does not overflow

    uint256 rate = borrowRate(e, marketParams, market);
    assert rate <= MAX_BORROW_RATE();
}
