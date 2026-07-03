# AdaptiveCurveIrm Fork — Test Plan

The fork makes additive changes to Morpho's `AdaptiveCurveIrm`: per-market curve parameters (an immutable `AdaptiveCurveConfig` contract per market, deployed and deduplicated by the IRM itself and read through an external static call), an owner/manager authorization model, an optional borrow-rate cap, reparametrization by re-pointing a market at new parameters, proxy-compatibility (the IRM runs behind a proxy; `owner` and `manager` live in storage, changing the logic is an upgrade), and a periphery library that reads params live from the pointed-at config. The curve and its adaptation are byte-identical to upstream. This lists each change and the scenario/fuzz tests that cover it. Pure unit-level checks (getters, event emission) are not listed. Everything below the curve surface is inherited Morpho: the retained upstream suite — adapted to the per-market-config model (the IRM is `initialize`d with an owner and manager, and a default config from `test/ConstantsLib.sol` is set per market via `setMarketCurveParams`); `testConstants` dropped, now covered by `AdaptiveCurveConfig` validation — plus a config-parametrized differential oracle that re-proves the forked curve still equals an independent reference (`AdaptiveCurveIrmTest.testFuzz_curveMatchesConfigParametrizedReference`).

Tests live in `test/AdaptiveCurveIrm{,Lib,Reparam,Proxy}Test.sol`, `test/AdaptiveCurveConfigTest.sol`, and `certora/{confs,specs}/`.

---

## 1. Per-market configuration

**What changed.** The six `ConstantsLib` curve constants (plus `maxBorrowRate`) become an `AdaptiveCurveParams` struct frozen into an immutable `AdaptiveCurveConfig` contract, validated in its constructor. The IRM keeps a per-market pointer `marketCurveConfig[Id] => IAdaptiveCurveConfig` and reads a market's parameters by an external static call to its `AdaptiveCurveConfig` (`getCurveParams()`). The bounds guarantee well-formedness only — non-overflowing math, a non-negative non-reverting rate — not economic soundness.

**Tests.**
- `AdaptiveCurveConfigTest.testDeploymentRevertsOnInvalidParams` — the `AdaptiveCurveConfig` constructor rejects each parameter just outside both ends of its range.
- `AdaptiveCurveConfigTest.testGetConfigRoundTrips` — every `AdaptiveCurveParams` field round-trips through `getCurveParams()`.
- `AdaptiveCurveConfigTest.testDefaultConfigIsValid` — the upstream-equivalent default config passes validation and deploys.
- `AdaptiveCurveIrmTest.testBorrowRateRevertsWhenConfigNotSet` — `borrowRate` and `borrowRateView` revert `CONFIG_NOT_SET` for a market with no config set.
- `AdaptiveCurveIrmTest.testFuzz_validConfigInvariants` / `testFuzz_fullRangeConfigUpholdsInvariants` — across the operating-band config space and the full accepted space up to the validation ceilings, one `borrowRate` call upholds the output invariants (view == state, cap holds, rate under a sane bound, `rateAtTarget ∈ [min, max]`) without reverting.
- Config edges within validation: `test_edge_steepnessOne_flatCurve`, `test_edge_zeroAdjustmentSpeed_neverAdapts`, `test_edge_pinnedRateAtTarget_minEqualsMax`, `test_edge_configAtLimitsDeploysAndComputes`, `test_edge_utilizationAboveOne_doesNotRevert`, `test_edge_zeroSupplyPositiveBorrow_actsAsZeroUtilization`.
- `AdaptiveCurveIrmTest.test_marketsAdaptIndependently` — two markets (distinct ids, each with its own config) on one IRM adapt independently, one up, one down.
- `AdaptiveCurveIrmTest.testBorrowRateOnlyMorpho` — access control unchanged: state-changing `borrowRate` is Morpho-only, `borrowRateView` open to anyone.
- `AdaptiveCurveIrmTest.invariantGeMinRateAtTarget` / `invariantLeMaxRateAtTarget` — stateful invariants: `rateAtTarget[id]` stays within `[minRateAtTarget, maxRateAtTarget]` across arbitrary call sequences.
- Certora `RateAtTargetBand` — inductive proof that `borrowRate` routes only in-band values into `rateAtTarget[id]`, under symbolic config (read from a linked `AdaptiveCurveConfig`) that satisfies the validation bounds.

---

## 2. Authorization (owner and manager)

**What changed.** There is no factory. `setMarketCurveParams(marketParams, curveParams)` deploys `new AdaptiveCurveConfig(curveParams)` inline — or reuses the one already cached for identical params (`deployedCurveConfigs[keccak256(abi.encode(params))]`) — and points the market at it. The call is gated to the `owner` **or** `manager` (`NOT_AUTHORIZED` otherwise), with no on-chain provenance/economic gate — the IRM trusts the caller. Authorization management is owner-only: `transferOwnership` and `setManager` rotate the two addresses and reject the zero address; both are set once via `initialize(owner, manager)`. `owner`/`manager` live in storage (see §6).

**Tests.**
- `AdaptiveCurveIrmTest.testSetConfigDeploysAndPrices` — `setMarketCurveParams` deploys a config from the given params, points the market at it, and the market then prices.
- `AdaptiveCurveIrmTest.testSetConfigOnlyOwner` — an unauthorized caller (neither owner nor manager) reverts `NOT_AUTHORIZED`.
- `AdaptiveCurveIrmTest.testTransferOwnership` — the owner rotates ownership in place; the new owner is authorized.
- `AdaptiveCurveIrmTest.testTransferOwnershipOnlyOwner` — a non-owner caller reverts `NOT_OWNER`.
- `AdaptiveCurveIrmTest.testTransferOwnershipRejectsZero` — `transferOwnership(address(0))` reverts `ZERO_ADDRESS`.
- `AdaptiveCurveIrmTest.testDeployment` — the constructor rejects a zero `morpho`.

---

## 3. Borrow-rate cap (`maxBorrowRate`)

**What changed.** An optional hard ceiling on the charged rate: `returned = min(curveRate, maxBorrowRate)` when the cap is non-zero, `0` disables it. It clamps only the value returned to Morpho and never touches the stored `rateAtTarget`, so the adaptation state machine behaves identically whether the cap is on or off, and removing/raising it (by re-pointing at a new config) returns the rate to the curve on the next call.

**Tests.**
- `AdaptiveCurveIrmTest.testMaxBorrowRateClampsChargedRate` — a cap below the curve's tip clamps the charged rate to `maxBorrowRate`.
- `AdaptiveCurveIrmTest.testMaxBorrowRateDoesNotAffectRateAtTarget` — the cap bounds only the charged rate; `rateAtTarget` adapts exactly as in the uncapped run.
- Certora `MaxBorrowRate` — proves both `borrowRate` and `borrowRateView` never return more than the cap when enabled, with the curve and adaptation abstracted to NONDET (so it is the cap's final clamp that is verified, non-vacuously).
- Cap behaviour under reparametrization is exercised in §4.

---

## 4. Reparametrization (re-pointing)

**What changed.** The owner or manager reparametrizes a live market by calling `setMarketCurveParams(marketParams, newParams)` again; the IRM resolves (deploys or reuses) the config and re-points the market. `rateAtTarget` is untouched by the swap and keeps adapting; the new parameters take effect on the next `borrowRate`, where they can shift the rate (immediately, lazily, or gradually, per parameter). The dynamics are emergent from reading whichever config is currently set + the unchanged curve math + persisted `rateAtTarget`.

**Tests** (`AdaptiveCurveIrmReparamTest`, each re-points via `setMarketCurveParams`):
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

**What changed.** Recomputes `borrowRateView` and `expectedMarketBalances` from a market `Id` alone. It now resolves the market's config from the IRM (`marketCurveConfig(id)`) and reads it live from that `AdaptiveCurveConfig` (via `getCurveParams()`) instead of `ConstantsLib`, tracking whichever config the market currently points at, and applies the same cap; it reverts `CONFIG_NOT_SET` when none is set. The public surface is unchanged but results are market-specific per the current params.

**Tests.**
- `AdaptiveCurveIrmLibTest.testBorrowRateView` / `testExpectedMarketBalances` — the lib's recompute matches the IRM for a given stored `rateAtTarget` and market.
- `AdaptiveCurveIrmLibTest.testFuzz_borrowRateView_matchesContract_acrossConfigs` — the lib's `borrowRateView` matches the contract's own view across the full config space.
- Certora `BorrowRateView` and `ExpectedMarketBalances` — prove the lib equivalent to the contract / `MorphoBalancesLib` for both the returned values **and** the revert conditions, with the lib forced to resolve params from the linked IRM and its pointed-at `AdaptiveCurveConfig`.

---

## 6. Upgradeable (proxy)

**What changed.** `MORPHO` is read from implementation bytecode under `delegatecall`; `owner`, `manager`, and all other state live in the proxy's storage (`rateAtTarget` slot 0, `marketCurveConfig` slot 1, `deployedCurveConfigs` slot 2, `owner` slot 3, `manager`+`isInitialized` slot 4). The constructor marks the implementation itself initialized so only a freshly-deployed proxy can be `initialize`d, once. Rotating `owner`/`manager` is a storage write (`transferOwnership`/`setManager`), not an upgrade; changing the curve logic is a proxy upgrade to a freshly-constructed implementation, and the per-market configs, dedup cache, and `rateAtTarget` persist. The proxy admin can overwrite any slot via upgrade.

**Tests** (`AdaptiveCurveIrmProxyTest`, against a minimal test-only ERC-1967 proxy):
- `test_morphoAndOwnerThroughProxy` — `MORPHO`/`owner` read correctly through `delegatecall`, and a config set through the proxy prices the market.
- `test_transferOwnershipThroughProxy` — ownership is rotated in place through the proxy (storage variable, no upgrade needed).
- `test_upgrade_logicSwap_preservesState` — a logic upgrade preserves `marketCurveConfig[id]` and `rateAtTarget`.
- `test_proxyImplAndAdminSlots_doNotCollideWithRateAtTarget` — the EIP-1967 impl/admin slots never collide with `rateAtTarget` (slot 0).
