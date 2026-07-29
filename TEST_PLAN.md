# Lido Lend IRM — Test Plan

The fork refactors and extends Morpho's `AdaptiveCurveIrm` with external per-market configs, owner/manager authorization, an optional output cap, reconfiguration, router-only state-changing pricing, and a periphery library that reads the selected config live. The Adaptive curve and adaptation formulas remain unchanged.

The fork also replaces `FixedRateIrm` with `LinearKinkIrm`, adds the proxied `IrmRouter`, and includes a separate permissionless `IrmConfigFactory`. Both IRMs expose `IConfigurableIrm.applyIrmConfig(MarketParams,address)`: Adaptive stores the supplied config address, while LinearKink copies the returned parameters. The IRMs do not deploy configs, store config-parameter hashes, deduplicate configs, or maintain a config registry; deploy-or-reuse mappings exist only in `IrmConfigFactory`.

The retained upstream tests apply a default config built from `test/ConstantsLib.sol`. Constructor validation replaces the removed upstream `testConstants`, and `bound`-based market shaping replaces rejection-heavy `vm.assume` filters. The sections below map each documented property to its tests.

| Change | Suites |
|---|---|
| Per-market configuration | `AdaptiveCurveConfigTest`, `AdaptiveCurveIrmTest` |
| Authorization (owner/manager) | `AdaptiveCurveIrmTest`, `LinearKinkIrmTest` |
| Borrow-rate cap | `AdaptiveCurveIrmTest`, Certora `MaxBorrowRate` |
| Reparametrization | `AdaptiveCurveIrmReparamTest` |
| Periphery library | `AdaptiveCurveIrmLibTest`, Certora `BorrowRateView` / `ExpectedMarketBalances` |
| Upgradeable (router proxy) | `IrmRouterProxyTest` |
| LinearKinkIrm (replaces `FixedRateIrm`) | `LinearKinkConfigTest`, `LinearKinkIrmTest`, Certora `LinearKinkIrm` |
| IrmRouter (routing) | `IrmRouterTest`, Certora `IrmRouter` |
| Permissionless config factory | `IrmConfigFactoryTest` |

**Exactness policy.** Differential Adaptive checks use `test/CurveRefHelper.sol`, a separate implementation that reuses the low-level arithmetic libraries but does not call `AdaptiveCurveMathLib`; it independently composes the curve, adaptation, and cap. The ping-every-minute tests compare every step exactly, and the stateful invariant compares an exact probe after each fuzzed call sequence; the preceding fuzzed calls are not individually asserted.

The retained upstream scenario tests keep their coarse `assertApproxEqRel` checks, while separate differential tests provide exact reference coverage. `ExpLibTest` retains its directional and banded checks. `LinearKinkIrmTest.testFuzz_monotonicAndBounded` is directional. Of the three router `assertGt` checks, two establish an adapted-rate setup and one checks switch-time debt growth qualitatively. The migration test also uses a qualitative inequality to confirm that the two models return different rates; its forwarding checks and the router's equality checks are exact.

Run the default suite with `forge test`. Run a deep campaign with `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_INVARIANT_RUNS=4096 forge test`.

Coverage is complete across executable `src/` code with `forge coverage --offline --no-match-test "PingEveryMinute" --no-match-coverage "^test/" --report summary`. The command runs 144 tests and excludes the two 1B-gas ping loops because they do not complete under coverage instrumentation. All executable `src/` files remain in the coverage denominator.

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `src/adaptive-curve-irm/AdaptiveCurveIrm.sol` | 100% (29/29) | 100% (31/31) | 100% (7/7) | 100% (5/5) |
| `src/adaptive-curve-irm/AdaptiveCurveConfig.sol` | 100% (24/24) | 100% (21/21) | 100% (24/24) | 100% (3/3) |
| `src/adaptive-curve-irm/libraries/**` (5 executable files) | 100% (67/67) | 100% (95/95) | 100% (13/13) | 100% (11/11) |
| `src/common/OwnerManagerBase.sol` | 100% (19/19) | 100% (13/13) | 100% (8/8) | 100% (6/6) |
| `src/irm-config-factory/IrmConfigFactory.sol` | 100% (18/18) | 100% (16/16) | 100% (2/2) | 100% (4/4) |
| `src/irm-router/IrmRouter.sol` | 100% (30/30) | 100% (29/29) | 100% (15/15) | 100% (5/5) |
| `src/linear-kink-irm/LinearKinkConfig.sol` | 100% (10/10) | 100% (8/8) | 100% (6/6) | 100% (2/2) |
| `src/linear-kink-irm/LinearKinkIrm.sol` | 100% (23/23) | 100% (29/29) | 100% (5/5) | 100% (5/5) |
| **Total** | **100% (220/220)** | **100% (242/242)** | **100% (80/80)** | **100% (41/41)** |

## 1. Per-market configuration

**What changed.** Adaptive curve constants become per-market values returned by an external config. `applyIrmConfig` reads the config for clamping and stores its address without validating returned values; the caller guarantees their validity. Pricing reads that address again. The included `AdaptiveCurveConfig` validates its constructor inputs, including steepness up to 100, adjustment speed and `maxRateAtTarget` up to 10,000/year, and an optional cap up to the maximum curve output at utilization no greater than 100% implied by those ceilings. See SPECIFICATION §Configuration.

| Verifies | Test |
|---|---|
| The `AdaptiveCurveConfig` constructor rejects representative violations of every constructor invariant, including both boundaries where applicable | `AdaptiveCurveConfigTest.testDeploymentRevertsOnInvalidParams` |
| Every `AdaptiveCurveParams` field round-trips through `getCurveParams()` | `AdaptiveCurveConfigTest.testGetConfigRoundTrips` |
| The upstream-equivalent default config passes validation and deploys | `AdaptiveCurveConfigTest.testDefaultConfigIsValid` |
| The cap's constructor boundary—the maximum output at utilization up to 100% implied by the pinned parameter ceilings—is accepted, and zero remains the disabled value | `AdaptiveCurveConfigTest.testMaxBorrowRateBoundary` |
| `applyIrmConfig` binds the exact supplied config address, emits `IrmConfigApplied`, and the bound config prices the market | `AdaptiveCurveIrmTest.testApplyIrmConfigBindsSuppliedConfigAndEmits` |
| Zero and EOA addresses fail to return ABI-decodable parameters, and the tested wrong-interface contract reverts during the getter call | `testApplyIrmConfigRejectsZeroAndEoa`, `testApplyIrmConfigRejectsWrongConfigType` |
| Returned values are deliberately not validated: an authorized caller can bind an ABI-compatible mock returning invalid Adaptive parameters; this demonstrates missing enforcement, not a supported config | `testApplyIrmConfigDoesNotValidateReturnedValues` |
| Adaptive reads the selected config again while pricing; changing the mutable mock's valid `curveSteepness` changes the calculated rate without another `applyIrmConfig` call | `testBorrowRateReadsSelectedConfigAtRuntime` |
| `borrowRate` and `borrowRateView` revert `CONFIG_NOT_SET` for a market with no config selected | `AdaptiveCurveIrmTest.testBorrowRateRevertsWhenConfigNotSet` |
| First and adapting calls match the reference over the operating ranges and over the full constructor ranges for the curve and adaptation fields; the exercised cap range reaches 10,000/year rather than the higher constructor cap ceiling | `testFuzz_validConfigInvariants`, `testFuzz_fullRangeConfigUpholdsInvariants` |
| The charged rate and `rateAtTarget` match the parameterized reference over the full constructor ranges for curve and adaptation fields and the exercised cap range up to 10,000/year | `testFuzz_curveMatchesConfigParametrizedReference` |
| Edge cases: steepness 1, adjustment speed 0, a pinned rate band, the steepness/speed/rate ceilings, utilization above 100%, and zero supply | `test_edge_*` (6 tests) |
| Two markets (distinct ids, each with its own config) on one IRM adapt independently, each exactly per the reference | `test_marketsAdaptIndependently` |
| State-changing `borrowRate` accepts only `ROUTER`; `borrowRateView` is open to anyone | `testBorrowRateOnlyRouter` |
| After any fuzzed call sequence, a probe interaction matches the reference exactly on both paths and lands `rateAtTarget` on the reference's end value | `invariantRateMatchesReference` |

## 2. Authorization (owner and manager)

**What changed.** Both IRMs inherit the same `IConfigurableIrm.applyIrmConfig(MarketParams,address)` selector. The function is gated to `owner` **or** `manager`; role management is owner-only and both roles are set at construction (there is no `initialize` on the IRMs). The IRMs do not deploy configs or store parameter hashes, deduplication state, or config registries. See SPECIFICATION §Configuration and §Deployment and authorization.

| Verifies | Test |
|---|---|
| Both IRMs expose exactly `applyIrmConfig((address,address,address,address,uint256),address)` | `LinearKinkIrmTest.test_applyIrmConfigSelectorMatchesAdaptiveCurveIrm` |
| An unauthorized caller (neither owner nor manager) cannot apply a config through either IRM | `AdaptiveCurveIrmTest.testApplyIrmConfigOnlyOwnerOrManager`, `LinearKinkIrmTest.test_applyIrmConfig_unauthorizedReverts` |
| A manager can apply configs through either IRM but cannot rotate the roles | `AdaptiveCurveIrmTest.testManagerRoleSeparation`, `LinearKinkIrmTest.test_applyIrmConfig_managerCanApply`, `LinearKinkIrmTest.test_setManager_ownerOnly` |
| The owner rotates ownership in place — the old owner loses the owner-only powers, the new owner gains them | `testTransferOwnership` |
| `transferOwnership` is owner-only, and the zero address is rejected for both roles (neither can be unset) | `testTransferOwnershipOnlyOwner`, `testTransferOwnershipRejectsZero`, `testSetManagerRejectsZero` |
| The Adaptive constructor rejects a zero `router` and a zero owner or manager, and sets both roles at construction | `testDeployment` |
| The constructor emits both role events, and `transferOwnership`/`setManager` emit theirs with exact fields | `testConstructorEmitsRoleEvents`, `testRoleRotationEmitsEvents` |

## 3. Borrow-rate cap (`maxBorrowRate`)

**What changed.** An optional hard ceiling on the charged rate: `returned = min(curveRate, maxBorrowRate)` when the cap is non-zero, `0` disables it. It clamps only the value returned to Morpho and never touches the stored `rateAtTarget`. See SPECIFICATION §Borrow-rate cap.

| Verifies | Test |
|---|---|
| A cap below the curve's tip clamps the charged rate to `maxBorrowRate` | `testMaxBorrowRateClampsChargedRate` |
| The cap bounds only the charged rate — `rateAtTarget` adapts exactly as in the uncapped run | `testMaxBorrowRateDoesNotAffectRateAtTarget` |
| Cap behaviour under reparametrization | §4 |

## 4. Reparametrization (re-pointing)

**What changed.** Calling `applyIrmConfig` again re-points a market to the supplied config, clamps a non-zero stored `rateAtTarget` into the returned band, and preserves the zero sentinel. The tests deploy constructor-valid configs and compare pricing with the reference. See SPECIFICATION §Reparametrization.

| Verifies | Test |
|---|---|
| A new band that still contains the stored rate preserves `rateAtTarget` with no spike | `test_reparam_statePersists_noSpike_whenBoundsContainRate` |
| A narrowed band clamps the stored rate exactly onto the nearest new bound at the swap itself, and the next call adapts from the clamped value exactly per the reference | `test_reparam_rateRises_whenNewMinAboveStoredRate`, `test_reparam_rateDrops_whenNewMaxBelowStoredRate` |
| Widening lets the rate creep (12 hourly steps, each exact per the reference, ceiling not reached), and a later narrowing clamps it onto the new ceiling at the swap | `test_reparam_widenLetsRateCreep_thenNarrowClampsAtSwap` |
| A tightened `maxRateAtTarget` applies immediately even at target utilization (the at-target poke charges the clamped rate), and a never-priced market keeps its 0 sentinel through swaps with the first interaction still seeding the initial rate | `test_reparam_tighterMax_appliesImmediately_evenAtTarget`, `test_reparam_freshMarketKeepsSentinel_thenSeedsInitialRate` |
| Changing `targetUtilization` / `curveSteepness` reprices the same utilization exactly per the reference with the new params, without moving `rateAtTarget` | `test_reparam_targetShift_changesChargedRate_keepsState`, `test_reparam_steepnessShift_changesChargedRate_keepsState` |
| A new `adjustmentSpeed` changes future adaptation (both the fast arm and a slow control are exact per the reference) without moving the rate at the swap | `test_reparam_adjustmentSpeedShift_changesFutureAdaptation_keepsState` |
| The cap applies and a tighter cap takes effect immediately on the next call, leaving `rateAtTarget` intact | `test_reparam_capAppliesAndTightens`, `test_reparam_capBelowAdaptedRate_clampsImmediately_keepsState` |
| The first state-changing call after a swap updates `rateAtTarget` as if the whole interval since `lastUpdate` used the new parameters | `test_reparam_newParamsPriceWholeIntervalSinceLastUpdate` |
| The periphery follows the newly applied config | `test_reparam_periphery_tracksReparam` |

## 5. Periphery library (`AdaptiveCurveIrmLib`)

**What changed.** The library resolves the market's config from the IRM, reads it live, applies the same output cap, and reverts `CONFIG_NOT_SET` when none is selected. The tests use caller-independent getters. See SPECIFICATION §Periphery library.

| Verifies | Test |
|---|---|
| The rate recompute matches the direct Adaptive IRM. Under `borrow <= supply` and the test's timestamp/fee bounds, expected balances match `MorphoBalancesLib`, including symmetric overflow reverts | `testBorrowRateView`, `testExpectedMarketBalances` |
| The library's `borrowRateView` matches the contract view over full constructor ranges for curve/adaptation fields and the exercised cap range up to 10,000/year | `testFuzz_borrowRateView_matchesContract_acrossConfigs` |
| A market with no config selected reverts `CONFIG_NOT_SET` through the library as well | `testBorrowRateViewRevertsWhenConfigNotSet` |

## 6. Upgradeable (router proxy)

**What changed.** `IrmRouter`, not either supplied IRM, is proxied. `MORPHO` is read from implementation bytecode under delegatecall. The ERC-7201 router namespace stores `owner` at its base, `manager` and `isInitialized` at base + 1, and `marketIrm` at base + 2. The constructor locks the implementation's own storage; the proxy uses one-shot `initialize`. A proxy upgrade preserves router storage, while the proxy admin remains able to change it through new logic.

| Verifies | Test |
|---|---|
| `initialize` through the proxy sets `owner` and `manager` exactly once — a second call reverts `ALREADY_INITIALIZED`, and a zero owner or manager is rejected with `ZERO_ADDRESS` | `test_initializeThroughProxy_isOneShot`, `test_initializeThroughProxy_rejectsZeroRoles` |
| The raw implementation is locked: `initialize` on it reverts `ALREADY_INITIALIZED` while a freshly-deployed proxy initializes fine | `test_implementationIsLockedAtConstruction` |
| The constructor rejects a zero Morpho | `test_constructor_rejectsZeroMorpho` |
| `MORPHO`/`owner` read correctly through `delegatecall`, and a market routed through the proxy prices | `test_morphoReadsThroughProxy`, `test_routedMarketPricesThroughProxy` |
| The roles rotate in place through the proxy (storage write, no upgrade needed) | `test_rolesRotateThroughProxy` |
| A logic upgrade preserves `marketIrm[id]` and both addresses | `test_upgrade_logicSwap_preservesState` |
| The EIP-1967 impl/admin slots never collide with `marketIrm` (the router storage sits at its ERC-7201 namespaced base) | `test_proxyImplAndAdminSlots_doNotCollideWithMarketIrm` |

## 7. Formal verification (Certora)

Specs live in `certora/{confs,specs}/`. All confs pin `solc-0.8.35` — the LidoLend core compiles with the same solc as the IRM sources, so `ExpectedMarketBalances.conf` links `lib/lido-lend/src/LidoLend.sol` directly.

| Proves | Conf |
|---|---|
| The periphery `borrowRateView` equals the direct Adaptive contract for returned values and modeled reverts when `getCurveParams()` is summarized to the same successful ghost-backed return on both paths | `BorrowRateView` |
| The periphery `expectedMarketBalances` equals `MorphoBalancesLib` for direct-IRM `MarketParams` under the same dispatched external-state and summarized-getter model | `ExpectedMarketBalances` |
| With `totalBorrowAssets <= totalSupplyAssets`, both Adaptive pricing functions return no more than a non-zero `maxBorrowRate`; curve and adaptation internals are abstracted so the final clamp is isolated | `MaxBorrowRate` |
| For a linked immutable config satisfying `validConfig()`, a `borrowRate` step preserves the rate band from a zero-or-in-band prestate under the spec's utilization, timestamp, and elapsed-time assumptions; `applyIrmConfig` clamps non-zero state and preserves zero | `RateAtTargetBand` |
| Under the `LinearKinkConfig` constructor assumptions, the config-application path never charges above its copied peak or that config's 800%/year ceiling (`validConfigCeilingRespected`); `rateNeverExceedsValidConfigCeiling` proves the same bound conditionally for storage satisfying the peak assumption. The spec also proves monotonicity (`monotonic`), `borrowRate == borrowRateView` (`stateless`), the unset revert (`revertsWhenUnset`), successful config application (`configuredMarketSucceeds`), and the linked config's endpoint rates (`setterEndpointRoundTrip`). It deliberately does not claim that `applyIrmConfig` validates arbitrary returned values. | `LinearKinkIrm` |
| The router's view forwards to the linked LinearKink implementation; `borrowRate` is Morpho-only; assuming no entry self-routes to the router, routing-table changes require authorized `setMarketIrm` calls and cannot write zero; both pricing entry points revert when the modeled table is entirely zero; initialization is one-shot; an uncreated route makes no `accrueInterest` or implementation `borrowRate` call; and a successful live route makes exactly one of each | `IrmRouter` |

## 8. LinearKinkIrm (fork-only)

**What changed.** `LinearKinkIrm` is a new piecewise-linear IRM replacing `FixedRateIrm`. The included `LinearKinkConfig` stores four immutable `uint64` values and validates them, including an 800%/year peak limit. `LinearKinkIrm.applyIrmConfig` accepts any getter result ABI-decodable as `LinearKinkParams`, copies it into one packed `marketKinkParams[id]` slot, and performs no value validation. It does not retain or call the config afterward. Both pricing functions are view-only and equal; a zero copied `optimalUtilization` is treated as unconfigured.

| Verifies | Test |
|---|---|
| `LinearKinkConfig` stores all four values immutably, its getter round-trips, constructor validation rejects both invalid utilization boundaries and an excessive peak, and accepts the exact maximum | `LinearKinkConfigTest` |
| The curve returns `baseRate`, `baseRate + slope1`, and the peak at zero, kink, and full utilization, and is linear on each leg | `test_rateAtZeroUtilizationIsBaseRate`, `test_rateAtKinkIsBasePlusSlope1`, `test_rateAtFullUtilizationIsPeak`, `test_rateIsLinearOnSlope1Leg`, `test_rateIsLinearOnSlope2Leg` |
| Statelessness, plus fuzzed monotonicity in utilization and the peak bound | `test_borrowRateEqualsBorrowRateView`, `testFuzz_monotonicAndBounded` |
| Adversarial view inputs: utilization above 100% clamps at the curve's peak, and zero supply prices as zero utilization | `test_overUtilizationClampsAtPeak`, `test_zeroSupplyActsAsZeroUtilization` |
| Two markets on one IRM keep independent params | `test_marketsAreIndependent` |
| An unconfigured market reverts `CONFIG_NOT_SET` | `test_revertsWhenParamsNotSet` |
| Every params field round-trips through the `marketKinkParams` getter | `test_paramsAreStoredAndReadable` |
| Zero, EOA, and a formerly deployed address with code removed fail to return ABI-decodable parameters; the tested wrong-interface contract also reverts during the getter call | `test_applyIrmConfig_revertsForZeroAddress`, `test_applyIrmConfig_revertsForEoa`, `test_applyIrmConfig_revertsWhenConfigCodeWasRemoved`, `test_applyIrmConfig_revertsForWrongConfigType` |
| The function emits the supplied config address and copies each field, while later mutation of a mock config cannot change the stored parameters or calculated rate | `test_applyIrmConfig_copiesParamsAndEmitsConfig`, `test_rateCalculationUsesCopiedParamsNotConfig` |
| Returned values are deliberately not validated: an authorized caller can snapshot an ABI-compatible mock returning invalid LinearKink parameters; this demonstrates missing enforcement, not a supported config. An outsider cannot apply a config, the manager can, and a second valid config overwrites the first snapshot | `test_applyIrmConfig_doesNotValidateReturnedValues`, `test_applyIrmConfig_unauthorizedReverts`, `test_applyIrmConfig_managerCanApply`, `test_applyIrmConfig_reparametrizesInPlace` |
| Shared `OwnerManagerBase` lifecycle: role rotation, zero-address rejection for either role at construction (the `initialize` one-shot and impl-lock coverage lives in §6, on the router) | `test_transferOwnership_ownerOnly`, `test_transferOwnership_works`, `test_transferOwnership_rejectsZero`, `test_setManager_ownerOnly`, `test_setManager_works`, `test_constructor_setsRoles`, `test_constructor_rejectsZeroOwner`, `test_constructor_rejectsZeroManager` |

## 9. IrmRouter (fork-only)

**What changed.** Markets using this package point at a proxied `IrmRouter`. Its Morpho-only `borrowRate` and public `borrowRateView` forward to `marketIrm[id]` and revert `IRM_NOT_SET` when that pointer is zero. Owner or manager may route a market; zero implementations and market params whose `irm` is not the router are rejected. For a live market, `setMarketIrm` calls `accrueInterest`, reloads the market, and probes the new implementation before storing it. For an uncreated market, it stores the route without touching the implementation; `createMarket` later performs the first pricing call.

| Verifies | Test |
|---|---|
| `borrowRate` / `borrowRateView` return exactly what the routed kink implementation returns, including the full mock-accrual path (adaptive forwarding is asserted in the migration scenario below) | `test_forwarding_routedKinkMatchesDirect`, `test_forwarding_accrueInterestPathUsesKinkRate` |
| `borrowRate` from a non-Morpho caller reverts `NOT_MORPHO`, and an unrouted market reverts `IRM_NOT_SET` on both entry points | `test_borrowRate_nonMorphoCallerReverts`, `test_unroutedMarketReverts` |
| The manager routes a market alongside the owner, a stranger reverts `NOT_AUTHORIZED`, the zero-address implementation reverts `ZERO_ADDRESS`, and marketParams carrying a foreign `irm` field revert `NOT_ROUTER_MARKET` | `test_setMarketIrm_managerCanRoute`, `test_setMarketIrm_outsiderReverts`, `test_setMarketIrm_zeroIrmReverts`, `test_setMarketIrm_wrongIrmFieldReverts` |
| An unconfigured or wrong-`ROUTER` implementation reverts a live-market switch through the probe, while pre-creation the same failures surface at `createMarket`, which creates nothing | `test_setMarketIrm_unconfiguredRoutesButCreateMarketReverts`, `test_setMarketIrm_probeCatchesUnconfiguredImpl`, `test_setMarketIrm_probeCatchesWrongRouterGate` |
| Pre-creation routing writes no implementation state, the launch seed comes from `createMarket`, a live attach of a fresh Adaptive implementation seeds through the probe, and a live switch triggers one accrual, advances debt, updates `lastUpdate`, and completes the route | `test_setMarketIrm_repeatBeforeCreateMarketKeepsSeededRate`, `test_setMarketIrm_seedSemantics`, `test_setMarketIrm_accruesBeforeSwitch` |
| `createMarket` pings `borrowRate` through the router — it reverts for an unrouted market and succeeds after `applyIrmConfig` + `setMarketIrm` | `test_createMarket_revertsUntilRouted` |
| A live market migrates between models and uses the selected implementation after each switch; in the same-block snapshot scenario a fresh Adaptive implementation seeds from the old value; reattaching a previously used Adaptive implementation resumes its stored value | `test_migration_kinkToAdaptiveAndBack`, `test_migration_snapshotSeedsFreshAdaptive`, `test_migration_backToUsedAdaptiveResumesStaleRate` |

The mock stands in for the LidoLend core, keeping the suite a unit test with direct market-state control: it stores markets, pings the market's IRM the way the core does on accrual and creation, and stamps `lastUpdate`.

## 10. IrmConfigFactory (fork-only)

**What changed.** `IrmConfigFactory` permissionlessly returns an existing included immutable config implementation for a parameter set or deploys one if absent. It computes `keccak256(abi.encode(params))`, uses separate mappings for Adaptive and LinearKink, and delegates all validation to the config constructors. It is optional: neither IRM references it or restricts applied configs to its outputs.

| Verifies | Test |
|---|---|
| Before deployment the parameter-based getter returns zero; any caller can get or deploy each concrete config, the getter then resolves its address, the returned parameters round-trip, and the model-specific deployment event contains the exact parameter hash and address | `test_getOrDeployAdaptiveCurveConfig_deploysAndResolvesByParams`, `test_getOrDeployLinearKinkConfig_deploysAndResolvesByParams` |
| Repeating the same parameter set from another caller returns the same address and emits no new deployment event | `test_getOrDeployAdaptiveCurveConfig_reusesExistingConfig`, `test_getOrDeployLinearKinkConfig_reusesExistingConfig` |
| Distinct valid parameter sets produce distinct hashes and config addresses in the corresponding mapping | `test_getOrDeployAdaptiveCurveConfig_distinctParamsDeployDistinctConfigs`, `test_getOrDeployLinearKinkConfig_distinctParamsDeployDistinctConfigs` |
| Invalid parameters propagate the concrete constructor revert and leave the corresponding mapping empty | `test_getOrDeployAdaptiveCurveConfig_constructorValidationReverts`, `test_getOrDeployLinearKinkConfig_constructorValidationReverts` |
