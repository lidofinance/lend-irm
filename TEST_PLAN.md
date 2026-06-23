# AdaptiveCurveIrm Fork — Test Plan

The fork makes four additive changes to Morpho's `AdaptiveCurveIrm`: per-deployment curve parameters (validated constructor inputs in place of `ConstantsLib` constants), an optional borrow-rate cap, proxy upgradeability, and a periphery library that reads params live from the instance. The curve and its adaptation are byte-identical to upstream. This lists each change and the scenario/fuzz tests that cover it. Pure unit-level checks (getters, event emission) are not listed. Everything below the curve surface is inherited Morpho: the retained upstream suite — adapted to the `Config` constructor (default from `test/ConstantsLib.sol`); `testConstants` dropped, now covered by constructor validation — plus a config-parametrized differential oracle that re-proves the forked curve still equals an independent reference (`testFuzz_curveMatchesConfigParametrizedReference`).

Tests live in `test/AdaptiveCurveIrm{,Lib,Proxy}Test.sol` and `certora/{confs,specs}/`.

---

## 1. Per-deployment configuration

**What changed.** The six `ConstantsLib` curve constants become a `Config` struct of immutables fixed at construction, so each deployment defines its own curve. The constructor gains `_validateConfig`, which reverts unless every parameter sits in its valid range (the table in SPECIFICATION.md §Configuration). The bounds guarantee well-formedness only — non-overflowing math, a non-negative non-reverting rate — not economic soundness; inside them the deployer owns the curve.

**Tests.**
- `testDeploymentExposesImmutableParams` — every `Config` field round-trips through its immutable getter and `getConfig()`.
- `testDeploymentRevertsOnInvalidParams` — the constructor rejects each parameter just outside both ends of its range.
- `testDefaultConfigIsValid` — the upstream-equivalent default config passes validation and deploys.
- `testFuzz_validConfigInvariants` / `testFuzz_fullRangeConfigUpholdsInvariants` — across the operating-band config space and the full accepted space up to the validation ceilings, one `borrowRate` call upholds the output invariants (view == state, cap holds, rate under a sane bound, `rateAtTarget ∈ [min, max]`) without reverting.
- Config edges within validation: `test_edge_steepnessOne_flatCurve` (flat curve), `test_edge_zeroAdjustmentSpeed_neverAdapts` (frozen adaptation), `test_edge_pinnedRateAtTarget_minEqualsMax` (min == max pins the rate), `test_edge_configAtLimitsDeploysAndComputes` (ceilings compute without `int256` overflow), `test_edge_utilizationAboveOne_doesNotRevert`, `test_edge_zeroSupplyPositiveBorrow_actsAsZeroUtilization`.
- `test_marketsAdaptIndependently` — two markets (distinct ids) on one IRM adapt independently, one up, one down.
- `testBorrowRateOnlyMorpho` — access control unchanged: state-changing `borrowRate` is Morpho-only, `borrowRateView` open to anyone.
- Certora `RateAtTargetBand` — inductive proof that `borrowRate` routes only in-band values into `rateAtTarget[id]` (first interaction → `INITIAL`, no adaptation → unchanged, adaptation → bounded), under symbolic immutables that satisfy `_validateConfig`.

---

## 2. Borrow-rate cap (`MAX_BORROW_RATE`)

**What changed.** An optional hard ceiling on the charged rate: `returned = min(curveRate, MAX_BORROW_RATE)` when the cap is non-zero, `0` disables it. It clamps only the value returned to Morpho and never touches the stored `rateAtTarget`, so the adaptation state machine behaves identically whether the cap is on or off, and removing/raising it returns the rate to the curve on the next call.

**Tests.**
- `testMaxBorrowRateClampsChargedRate` — a cap below the curve's tip clamps the charged rate to `MAX_BORROW_RATE`.
- `testMaxBorrowRateDoesNotAffectRateAtTarget` — the cap bounds only the charged rate; `rateAtTarget` adapts exactly as in the uncapped run.
- Certora `MaxBorrowRate` — proves both `borrowRate` and `borrowRateView` never return more than the cap when enabled, with the curve and adaptation abstracted to NONDET (so it is the cap's final clamp that is verified, non-vacuously).
- Cap behaviour through the proxy is exercised in §3.

---

## 3. Upgradeable (proxy)

**What changed.** Immutables live in implementation bytecode and the only storage is `rateAtTarget` at slot 0 (as upstream), so one implementation can sit behind an upgradeable proxy. Governance reparametrizes a live market by pointing the proxy at a new implementation carrying a new `Config`; `rateAtTarget` survives the swap. There is no parameter setter — changing the curve is always an upgrade, taking effect on the next `borrowRate`, where it can shift the rate (immediately, lazily, or gradually, per parameter).

**Tests.** Deployed through a minimal test-only ERC-1967 proxy:
- `test_immutableParamsReadableThroughProxy` — immutable params read correctly through `delegatecall`.
- `test_proxyImplAndAdminSlots_doNotCollideWithRateAtTarget` — the EIP-1967 impl/admin slots never collide with `rateAtTarget` at slot 0.
- `test_upgrade_statePersists_noSpike_whenBoundsContainRate` — an upgrade whose new band still contains the stored rate preserves `rateAtTarget` with no spike.
- `test_upgrade_rateRises_whenNewMinAboveStoredRate` / `test_upgrade_rateDrops_whenNewMaxBelowStoredRate` — a narrowed band snaps the stored rate to the nearest new bound on the next adapting call.
- `test_upgrade_widenLetsRateCreep_thenNarrowShocks` — widening lets the rate creep, a later narrowing snaps it onto the new ceiling in one step.
- `test_upgrade_tighterMax_atTargetPokeDefersRebound` — the re-clamp is lazy: after tightening `MAX`, an at-target poke leaves `rateAtTarget` out of range until a later off-target call.
- `test_upgrade_targetShift_changesChargedRate_keepsState` / `test_upgrade_steepnessShift_changesChargedRate_keepsState` — changing `targetUtilization` / `curveSteepness` shifts the charged rate at the same utilization without moving `rateAtTarget`.
- `test_upgrade_adjustmentSpeedShift_changesFutureAdaptation_keepsState` — a new `adjustmentSpeed` speeds up future adaptation without moving the rate at the upgrade.
- `test_maxBorrowRate_appliesThroughProxyAndTightensOnUpgrade` / `test_upgrade_capBelowAdaptedRate_clampsImmediately_keepsState` — the cap applies through the proxy and a tighter cap takes effect immediately on the next call, leaving `rateAtTarget` intact.
- `test_upgrade_newParamsPriceWholeIntervalSinceLastUpdate` — the first call after an upgrade prices the whole interval since `lastUpdate` at the new params (no blending at the upgrade timestamp).
- `test_periphery_borrowRateView_tracksProxyUpgrade` — the periphery follows the new implementation after an upgrade (see §4).

---

## 4. Periphery library (`AdaptiveCurveIrmLib`)

**What changed.** Recomputes `borrowRateView` and `expectedMarketBalances` from a market `Id` alone. It now reads the curve parameters live from the IRM instance (via the immutable getters / `getConfig()`) instead of `ConstantsLib`, tracking whichever implementation a proxy currently points to, and applies the same cap. The public surface is unchanged but results are instance-specific per the deployed `Config`.

**Tests.**
- `testBorrowRateView` / `testExpectedMarketBalances` — the lib's recompute matches the IRM for a given stored `rateAtTarget` and market.
- `testFuzz_borrowRateView_matchesContract_acrossConfigs` — the lib's `borrowRateView` matches the contract's own view across the full config space.
- Certora `BorrowRateView` and `ExpectedMarketBalances` — prove the lib equivalent to the contract / `MorphoBalancesLib` for both the returned values **and** the revert conditions, with the lib forced to resolve params from the linked IRM.
