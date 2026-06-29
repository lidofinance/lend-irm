# AdaptiveCurveIrm Fork — Test Plan

The fork makes five additive changes to Morpho's `AdaptiveCurveIrm`: per-market curve parameters (an immutable `MarketConfig` contract per market, deployed by a permissionless factory and pointed at by the IRM, read through an external static call), an optional borrow-rate cap, owner-gated reparametrization (the owner is immutable), proxy-compatibility (the IRM runs behind a proxy; changing the owner or logic is an upgrade), and a periphery library that reads params live from the pointed-at config. The curve and its adaptation are byte-identical to upstream. This lists each change and the scenario/fuzz tests that cover it. Pure unit-level checks (getters, event emission) are not listed. Everything below the curve surface is inherited Morpho: the retained upstream suite — adapted to the per-market-config model (the IRM is deployed with an owner, and a default config from `test/ConstantsLib.sol` is set per market); `testConstants` dropped, now covered by `MarketConfig` validation — plus a config-parametrized differential oracle that re-proves the forked curve still equals an independent reference (`testFuzz_curveMatchesConfigParametrizedReference`).

Tests live in `test/AdaptiveCurveIrm{,Lib,Reparam,Proxy}Test.sol`, `test/MarketConfigTest.sol`, `test/MarketConfigFactoryTest.sol`, and `certora/{confs,specs}/`.

---

## 1. Per-market configuration

**What changed.** The six `ConstantsLib` curve constants (plus `maxBorrowRate`) become a `Config` frozen into an immutable `MarketConfig` contract, validated in its constructor. The IRM keeps a per-market pointer `marketConfig[Id] => IMarketConfig` and reads a market's parameters by an external static call to its `MarketConfig`. The bounds guarantee well-formedness only — non-overflowing math, a non-negative non-reverting rate — not economic soundness.

**Tests.**
- `MarketConfigTest.testDeploymentRevertsOnInvalidParams` — the `MarketConfig` constructor rejects each parameter just outside both ends of its range.
- `MarketConfigTest.testGetConfigRoundTrips` — every `Config` field round-trips through `getConfig()`.
- `MarketConfigTest.testDefaultConfigIsValid` — the upstream-equivalent default config passes validation and deploys.
- `AdaptiveCurveIrmTest.testBorrowRateRevertsWhenConfigNotSet` — `borrowRate` and `borrowRateView` revert `CONFIG_NOT_SET` for a market with no config set.
- `AdaptiveCurveIrmTest.testFuzz_validConfigInvariants` / `testFuzz_fullRangeConfigUpholdsInvariants` — across the operating-band config space and the full accepted space up to the validation ceilings, one `borrowRate` call upholds the output invariants (view == state, cap holds, rate under a sane bound, `rateAtTarget ∈ [min, max]`) without reverting.
- Config edges within validation: `test_edge_steepnessOne_flatCurve`, `test_edge_zeroAdjustmentSpeed_neverAdapts`, `test_edge_pinnedRateAtTarget_minEqualsMax`, `test_edge_configAtLimitsDeploysAndComputes`, `test_edge_utilizationAboveOne_doesNotRevert`, `test_edge_zeroSupplyPositiveBorrow_actsAsZeroUtilization`.
- `AdaptiveCurveIrmTest.test_marketsAdaptIndependently` — two markets (distinct ids, each with its own config) on one IRM adapt independently, one up, one down.
- `AdaptiveCurveIrmTest.testBorrowRateOnlyMorpho` — access control unchanged: state-changing `borrowRate` is Morpho-only, `borrowRateView` open to anyone.
- Certora `RateAtTargetBand` — inductive proof that `borrowRate` routes only in-band values into `rateAtTarget[id]`, under symbolic config (read from a linked `MarketConfig`) that satisfies the validation bounds.

---

## 2. Factory and ownership

**What changed.** `MarketConfigFactory` is permissionless (no owner, no IRM reference): `createConfig(cfg)` deploys an immutable `MarketConfig` and records `isValidDeployment` (provenance for off-chain use). Activating a config is the only gated action: `IRM.setConfig(id, config)` is `OWNER`-only, with no on-chain provenance gate — the IRM trusts the owner. `OWNER` is immutable; changing it is a proxy upgrade (see §6).

**Tests.**
- `MarketConfigFactoryTest.testCreateConfigIsPermissionless` — any caller can deploy a config; it is recorded in `isValidDeployment` and round-trips through `getConfig()`.
- `MarketConfigFactoryTest.testCreateConfigEmitsEvent` — `createConfig` emits `ConfigCreated` with the deployed address.
- `MarketConfigFactoryTest.testIsValidDeploymentFalseForUnknown` — a directly-deployed config (and `address(0)`) are not recorded as factory deployments.
- `AdaptiveCurveIrmTest.testSetConfigOnlyOwner` — a non-owner caller reverts `NOT_OWNER`.
- `AdaptiveCurveIrmTest.testSetConfigAcceptsDirectlyDeployedConfig` — no provenance gate: a config deployed directly (not via the factory) can be set and prices the market.
- `AdaptiveCurveIrmTest.testSetConfigAcceptsDirectlyDeployedConfig` — there is no provenance gate: a config deployed directly (not via the factory) can be set and prices the market.
- `AdaptiveCurveIrmTest.testDeployment` — the constructor rejects a zero morpho or owner.

---

## 3. Borrow-rate cap (`maxBorrowRate`)

**What changed.** An optional hard ceiling on the charged rate: `returned = min(curveRate, maxBorrowRate)` when the cap is non-zero, `0` disables it. It clamps only the value returned to Morpho and never touches the stored `rateAtTarget`, so the adaptation state machine behaves identically whether the cap is on or off, and removing/raising it (by pointing at a new config) returns the rate to the curve on the next call.

**Tests.**
- `AdaptiveCurveIrmTest.testMaxBorrowRateClampsChargedRate` — a cap below the curve's tip clamps the charged rate to `maxBorrowRate`.
- `AdaptiveCurveIrmTest.testMaxBorrowRateDoesNotAffectRateAtTarget` — the cap bounds only the charged rate; `rateAtTarget` adapts exactly as in the uncapped run.
- Certora `MaxBorrowRate` — proves both `borrowRate` and `borrowRateView` never return more than the cap when enabled, with the curve and adaptation abstracted to NONDET (so it is the cap's final clamp that is verified, non-vacuously).
- Cap behaviour under reparametrization is exercised in §4.

---

## 4. Reparametrization (config re-pointing)

**What changed.** The owner reparametrizes a live market by deploying a fresh `MarketConfig` and calling `setConfig(id, newConfig)` (variant A allows re-pointing). `rateAtTarget` is untouched by the swap and keeps adapting; the new parameters take effect on the next `borrowRate`, where they can shift the rate (immediately, lazily, or gradually, per parameter). The dynamics are emergent from reading whichever config is currently set + the unchanged curve math + persisted `rateAtTarget`.

**Tests** (`AdaptiveCurveIrmReparamTest`, each re-points via `setConfig`):
- `test_reparam_statePersists_noSpike_whenBoundsContainRate` — a new band that still contains the stored rate preserves `rateAtTarget` with no spike.
- `test_reparam_rateRises_whenNewMinAboveStoredRate` / `test_reparam_rateDrops_whenNewMaxBelowStoredRate` — a narrowed band snaps the stored rate to the nearest new bound on the next adapting call.
- `test_reparam_widenLetsRateCreep_thenNarrowShocks` — widening lets the rate creep, a later narrowing snaps it onto the new ceiling in one step.
- `test_reparam_tighterMax_atTargetPokeDefersRebound` — the re-clamp is lazy: after tightening `maxRateAtTarget`, an at-target poke leaves `rateAtTarget` out of range until a later off-target call.
- `test_reparam_targetShift_changesChargedRate_keepsState` / `test_reparam_steepnessShift_changesChargedRate_keepsState` — changing `targetUtilization` / `curveSteepness` shifts the charged rate at the same utilization without moving `rateAtTarget`.
- `test_reparam_adjustmentSpeedShift_changesFutureAdaptation_keepsState` — a new `adjustmentSpeed` speeds up future adaptation without moving the rate at the swap.
- `test_reparam_capAppliesAndTightens` / `test_reparam_capBelowAdaptedRate_clampsImmediately_keepsState` — the cap applies and a tighter cap takes effect immediately on the next call, leaving `rateAtTarget` intact.
- `test_reparam_newParamsPriceWholeIntervalSinceLastUpdate` — the first call after a swap prices the whole interval since `lastUpdate` at the new params (no blending at the swap timestamp).
- `test_reparam_periphery_tracksReparam` — the periphery follows the newly-set config (see §5).

---

## 5. Periphery library (`AdaptiveCurveIrmLib`)

**What changed.** Recomputes `borrowRateView` and `expectedMarketBalances` from a market `Id` alone. It now resolves the market's config from the IRM (`marketConfig(id)`) and reads it live from that `MarketConfig` (via `getConfig()`) instead of `ConstantsLib`, tracking whichever config the market currently points at, and applies the same cap; it reverts `CONFIG_NOT_SET` when none is set. The public surface is unchanged but results are market-specific per the current `Config`.

**Tests.**
- `AdaptiveCurveIrmLibTest.testBorrowRateView` / `testExpectedMarketBalances` — the lib's recompute matches the IRM for a given stored `rateAtTarget` and market.
- `AdaptiveCurveIrmLibTest.testFuzz_borrowRateView_matchesContract_acrossConfigs` — the lib's `borrowRateView` matches the contract's own view across the full config space.
- Certora `BorrowRateView` and `ExpectedMarketBalances` — prove the lib equivalent to the contract / `MorphoBalancesLib` for both the returned values **and** the revert conditions, with the lib forced to resolve params from the linked IRM and its pointed-at `MarketConfig`.

---

## 6. Upgradeable (proxy)

**What changed.** Both immutables (`MORPHO`, `OWNER`) are read from implementation bytecode under `delegatecall`, and the constructor writes no storage, so the IRM runs behind a proxy with no initializer; the only storage (`rateAtTarget` slot 0, `marketConfig` slot 1) lives in the proxy. Changing the owner or the curve logic is a proxy upgrade to a freshly-constructed implementation; the per-market configs and `rateAtTarget` persist. The proxy admin can thus replace even the immutable `OWNER`.

**Tests** (`AdaptiveCurveIrmProxyTest`, against a minimal test-only ERC-1967 proxy):
- `test_immutablesReadableThroughProxy` — `MORPHO`/`OWNER` read correctly through `delegatecall`, and a config set through the proxy prices the market.
- `test_upgrade_logicSwap_preservesConfigAndRateAtTarget` — a logic upgrade (same owner) preserves `marketConfig[id]` and `rateAtTarget`.
- `test_upgrade_changesOwner` — upgrading to an implementation constructed with a new owner changes `OWNER`; the old owner can no longer `setConfig`, the new one can, and state persists.
- `test_proxyImplAndAdminSlots_doNotCollideWithRateAtTarget` — the EIP-1967 impl/admin slots never collide with `rateAtTarget` (slot 0).
