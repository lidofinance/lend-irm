# Lido Lend IRM — Test Plan

This document maps the behavior in [SPECIFICATION.md](SPECIFICATION.md) to Foundry tests and Certora configurations. The main changes are per-market Adaptive configs, owner/manager authorization, an optional Adaptive output cap, reconfiguration, LinearKinkIrm, IrmRouter, and the optional config factory.

The retained upstream Adaptive tests use a default config built from `test/ConstantsLib.sol`. New differential tests compose the expected result separately from `AdaptiveCurveMathLib`, while reusing the same low-level arithmetic helpers. The table below states what each style of check proves.

| Change | Suites |
|---|---|
| Per-market configuration | `AdaptiveCurveConfigTest`, `AdaptiveCurveIrmTest` |
| Authorization (owner/manager) | `AdaptiveCurveIrmTest`, `LinearKinkIrmTest` |
| Borrow-rate cap | `AdaptiveCurveIrmTest`, Certora `MaxBorrowRate` |
| Adaptive reconfiguration | `AdaptiveCurveIrmReparamTest` |
| Periphery library | `AdaptiveCurveIrmLibTest`, Certora `BorrowRateView` / `ExpectedMarketBalances` |
| Upgradeable (router proxy) | `IrmRouterProxyTest` |
| LinearKinkIrm (replaces `FixedRateIrm`) | `LinearKinkConfigTest`, `LinearKinkIrmTest`, Certora `LinearKinkIrm` |
| IrmRouter (routing) | `IrmRouterTest`, Certora `IrmRouter` |
| Permissionless config factory | `IrmConfigFactoryTest` |

| Check style | What it establishes |
| --- | --- |
| Adaptive differential tests | Exact equality with a separately composed reference that reuses the same low-level arithmetic and exponential helpers. The minute-by-minute tests compare every step. |
| Adaptive stateful invariant | Exact equality for one probe after each fuzzed call sequence; it does not inspect every earlier call in the sequence. |
| Retained upstream and `ExpLib` tests | Approximate, directional, or bounded behavior where the test uses `assertApproxEqRel` or inequality checks. |
| LinearKink and router scenarios | Monotonicity and setup inequalities are directional. Forwarding, route state, and equality checks are exact. |

Run the default suite with `forge test`. Run a larger campaign with `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_INVARIANT_RUNS=4096 forge test`.

Generate coverage for the exact reviewed commit with `forge coverage --offline --no-match-test "PingEveryMinute" --no-match-coverage "^test/" --report summary`. The two long ping loops are excluded because coverage instrumentation cannot complete them. Record the command output with the reviewed commit instead of copying percentages from an earlier run.

## 1. Adaptive configuration and math

Adaptive curve constants become per-market values returned by a live config. `applyIrmConfig` reads the config for clamping and stores its address without validating returned values. Pricing reads that address again. The included `AdaptiveCurveConfig` validates its constructor inputs. See [Adaptive config application](SPECIFICATION.md#adaptive-config-application) and [Adaptive rate calculation](SPECIFICATION.md#adaptive-rate-calculation).

### Config selection and validation

| Verifies | Test |
|---|---|
| The `AdaptiveCurveConfig` constructor rejects representative violations of every constructor invariant, including both boundaries where applicable | `AdaptiveCurveConfigTest.testDeploymentRevertsOnInvalidParams` |
| Every `AdaptiveCurveParams` field round-trips through `getCurveParams()` | `AdaptiveCurveConfigTest.testGetConfigRoundTrips` |
| The upstream-equivalent default config passes validation and deploys | `AdaptiveCurveConfigTest.testDefaultConfigIsValid` |
| The cap's constructor boundary—the maximum output at utilization up to 100% implied by the pinned parameter ceilings—is accepted, and zero remains the disabled value | `AdaptiveCurveConfigTest.testMaxBorrowRateBoundary` |
| `applyIrmConfig` binds the exact supplied config address, emits `IrmConfigApplied`, and the bound config prices the market | `AdaptiveCurveIrmTest.testApplyIrmConfigBindsSuppliedConfigAndEmits` |
| Zero and externally owned account (EOA) addresses fail to return ABI-decodable parameters, and the tested wrong-interface contract reverts during the getter call | `testApplyIrmConfigRejectsZeroAndEoa`, `testApplyIrmConfigRejectsWrongConfigType` |
| Returned values are deliberately not validated: an authorized caller can bind an ABI-compatible mock returning invalid Adaptive parameters; this demonstrates missing enforcement, not a supported config | `testApplyIrmConfigDoesNotValidateReturnedValues` |
| Adaptive reads the selected config again while pricing; changing the mutable mock's valid `curveSteepness` changes the calculated rate without another `applyIrmConfig` call | `testBorrowRateReadsSelectedConfigAtRuntime` |
| `borrowRate` and `borrowRateView` revert `CONFIG_NOT_SET` for a market with no config selected | `AdaptiveCurveIrmTest.testBorrowRateRevertsWhenConfigNotSet` |

### Rate math and state

| Verifies | Test |
|---|---|
| First and adapting calls match the reference over the operating ranges and the full constructor ranges for the curve and adaptation fields. Cap inputs cover zero through 10,000/year, not the cap's full constructor range. | `testFuzz_validConfigInvariants`, `testFuzz_fullRangeConfigUpholdsInvariants` |
| The charged rate and `rateAtTarget` match the parameterized reference over the full constructor ranges for curve and adaptation fields and the exercised cap range up to 10,000/year | `testFuzz_curveMatchesConfigParametrizedReference` |
| Edge cases: steepness 1, adjustment speed 0, a pinned rate band, the steepness/speed/rate ceilings, utilization above 100%, and zero supply | `test_edge_*` (6 tests) |
| Two markets with distinct ids and configs adapt independently, each exactly per the reference | `test_marketsAdaptIndependently` |
| After any fuzzed call sequence, one probe matches the reference exactly on both pricing paths and stores the reference end value | `invariantRateMatchesReference` |

## 2. Authorization (owner and manager)

Both IRMs inherit the same `IConfigurableIrm.applyIrmConfig(MarketParams,address)` selector. The function accepts the owner or manager. Role management is owner-only, and both roles are set at construction. The IRMs do not deploy configs or store parameter hashes or registries. See [Roles](SPECIFICATION.md#roles).

| Verifies | Test |
|---|---|
| Both IRMs expose exactly `applyIrmConfig((address,address,address,address,uint256),address)` | `LinearKinkIrmTest.test_applyIrmConfigSelectorMatchesAdaptiveCurveIrm` |
| Adaptive state-changing `borrowRate` accepts only `ROUTER`; `borrowRateView` remains open | `AdaptiveCurveIrmTest.testBorrowRateOnlyRouter` |
| An unauthorized caller (neither owner nor manager) cannot apply a config through either IRM | `AdaptiveCurveIrmTest.testApplyIrmConfigOnlyOwnerOrManager`, `LinearKinkIrmTest.test_applyIrmConfig_unauthorizedReverts` |
| A manager can apply configs through either IRM but cannot rotate the roles | `AdaptiveCurveIrmTest.testManagerRoleSeparation`, `LinearKinkIrmTest.test_applyIrmConfig_managerCanApply`, `LinearKinkIrmTest.test_setManager_ownerOnly` |
| The owner rotates ownership in place — the old owner loses the owner-only powers, the new owner gains them | `testTransferOwnership` |
| `transferOwnership` is owner-only, and the zero address is rejected for both roles (neither can be unset) | `testTransferOwnershipOnlyOwner`, `testTransferOwnershipRejectsZero`, `testSetManagerRejectsZero` |
| The Adaptive constructor rejects a zero `router` and a zero owner or manager, and sets both roles at construction | `testDeployment` |
| The constructor emits both role events, and `transferOwnership`/`setManager` emit theirs with exact fields | `testConstructorEmitsRoleEvents`, `testRoleRotationEmitsEvents` |
| LinearKink constructor roles, owner-only rotation, successful rotation, and zero-address rejection follow the shared base | `test_constructor_setsRoles`, `test_constructor_rejectsZeroOwner`, `test_constructor_rejectsZeroManager`, `test_transferOwnership_*`, `test_setManager_*` |

## 3. Borrow-rate cap (`maxBorrowRate`)

The optional cap returns `min(rawBorrowRate, maxBorrowRate)` when non-zero; zero disables it. For the same input state, the cap does not change that call's `rateAtTarget` transition. See [Adaptive rate calculation](SPECIFICATION.md#adaptive-rate-calculation).

| Verifies | Test |
|---|---|
| A cap below the uncapped curve rate clamps the charged rate to `maxBorrowRate` | `testMaxBorrowRateClampsChargedRate` |
| For identical input state, the capped and uncapped calls produce the same `rateAtTarget` transition | `testMaxBorrowRateDoesNotAffectRateAtTarget` |
| Cap behavior under reconfiguration | [Adaptive reconfiguration](#4-adaptive-reconfiguration) |

## 4. Adaptive reconfiguration

Calling `applyIrmConfig` again selects the supplied config, clamps a non-zero stored `rateAtTarget` into the returned band, and leaves zero unchanged. For the constructor-valid configs used here, zero is the uninitialized sentinel because the initial rate must be positive. The tests compare pricing with the reference. See [Adaptive reconfiguration](SPECIFICATION.md#adaptive-reconfiguration).

| Verifies | Test |
|---|---|
| A new band that still contains the stored rate preserves `rateAtTarget` with no spike | `test_reparam_statePersists_noSpike_whenBoundsContainRate` |
| A narrowed band clamps the stored rate exactly onto the nearest new bound during application, and the next call adapts from the clamped value exactly per the reference | `test_reparam_rateRises_whenNewMinAboveStoredRate`, `test_reparam_rateDrops_whenNewMaxBelowStoredRate` |
| Widening permits gradual adaptation over 12 hourly steps, each exact against the reference; a later narrowing clamps to the new ceiling during application | `test_reparam_widenLetsRateCreep_thenNarrowClampsAtSwap` |
| A tightened `maxRateAtTarget` applies immediately even at target utilization (the at-target call charges the clamped rate), and a never-priced market keeps stored zero through reconfiguration so its first interaction still seeds the initial rate | `test_reparam_tighterMax_appliesImmediately_evenAtTarget`, `test_reparam_freshMarketKeepsSentinel_thenSeedsInitialRate` |
| Changing `targetUtilization` / `curveSteepness` reprices the same utilization exactly per the reference with the new params, without moving `rateAtTarget` | `test_reparam_targetShift_changesChargedRate_keepsState`, `test_reparam_steepnessShift_changesChargedRate_keepsState` |
| A new `adjustmentSpeed` changes future adaptation in both compared runs without moving the rate during application | `test_reparam_adjustmentSpeedShift_changesFutureAdaptation_keepsState` |
| The cap applies and a tighter cap takes effect immediately on the next call, leaving `rateAtTarget` intact | `test_reparam_capAppliesAndTightens`, `test_reparam_capBelowAdaptedRate_clampsImmediately_keepsState` |
| The first state-changing call after reconfiguration updates `rateAtTarget` as if the whole interval since `lastUpdate` used the new parameters | `test_reparam_newParamsPriceWholeIntervalSinceLastUpdate` |
| The periphery follows the newly applied config | `test_reparam_periphery_tracksReparam` |

## 5. Periphery library (`AdaptiveCurveIrmLib`)

The library resolves the market's config from the IRM, reads it live, applies the same output cap, and reverts `CONFIG_NOT_SET` when none is selected. The tests use caller-independent getters. See [Adaptive periphery library](SPECIFICATION.md#adaptive-periphery-library).

| Verifies | Test |
|---|---|
| The rate recompute matches the direct Adaptive IRM. Under `borrow <= supply` and the test's timestamp/fee bounds, expected balances match `MorphoBalancesLib`, including symmetric overflow reverts | `testBorrowRateView`, `testExpectedMarketBalances` |
| The library's `borrowRateView` matches the contract view over full constructor ranges for curve/adaptation fields and the exercised cap range up to 10,000/year | `testFuzz_borrowRateView_matchesContract_acrossConfigs` |
| A market with no config selected reverts `CONFIG_NOT_SET` through the library as well | `testBorrowRateViewRevertsWhenConfigNotSet` |

## 6. Router proxy

`IrmRouter`, not either supplied IRM, is proxied. `MORPHO` is read from implementation bytecode under delegatecall. The ERC-7201 router namespace stores `owner` at its base, `manager` and `isInitialized` at base + 1, and `marketIrm` at base + 2. The constructor locks implementation storage; the proxy uses one-shot initialization. See [Router initialization and proxy](SPECIFICATION.md#router-initialization-and-proxy).

| Verifies | Test |
|---|---|
| `initialize` through the proxy sets `owner` and `manager` exactly once — a second call reverts `ALREADY_INITIALIZED`, and a zero owner or manager is rejected with `ZERO_ADDRESS` | `test_initializeThroughProxy_isOneShot`, `test_initializeThroughProxy_rejectsZeroRoles` |
| The raw implementation is locked: `initialize` on it reverts `ALREADY_INITIALIZED` while a freshly-deployed proxy initializes fine | `test_implementationIsLockedAtConstruction` |
| The constructor rejects a zero Morpho | `test_constructor_rejectsZeroMorpho` |
| `MORPHO`/`owner` read correctly through `delegatecall`, and a market routed through the proxy prices | `test_morphoReadsThroughProxy`, `test_routedMarketPricesThroughProxy` |
| The roles rotate in place through the proxy (storage write, no upgrade needed) | `test_rolesRotateThroughProxy` |
| A logic upgrade preserves `marketIrm[id]` and both addresses | `test_upgrade_logicSwap_preservesState` |
| Writing the test proxy's EIP-1967 implementation and admin slots leaves the tested owner and market route intact | `test_proxyImplAndAdminSlots_doNotCollideWithMarketIrm` |

## 7. Formal verification

Specifications live in `certora/{confs,specs}/`. Every configuration selects Solidity 0.8.36. A configuration defines an intended proof; cite a property as proved only with a successful report or CI run for the reviewed commit.

| Configuration | Intended property | Modeling boundary |
|---|---|---|
| `BorrowRateView` | The periphery and Adaptive contract return the same rate and have the same modeled revert behavior. | Both paths receive the same summarized config values and IRM state. Caller-dependent config behavior is outside the model. |
| `ExpectedMarketBalances` | The periphery and `MorphoBalancesLib` return the same expected balances and have the same modeled revert behavior. | Uses direct-Adaptive `MarketParams` and gives both paths the same external market and config state. |
| `MaxBorrowRate` | A non-zero Adaptive cap bounds both pricing functions. | Assumes borrow assets do not exceed supply assets. Curve and adaptation internals are arbitrary so the rule isolates the final cap. |
| `RateAtTargetBand` | For successful calls, a zero-or-in-band prestate leads `borrowRate` to store an in-band value; `applyIrmConfig` preserves zero or clamps a non-zero value into the new band. | Uses one linked immutable config satisfying the Certora spec's modeled `validConfig()` assumptions, which are the assumptions needed by this proof rather than the config constructor's complete validation surface. Utilization is at most 100%, `lastUpdate` is not in the future, elapsed time is at most 365 days, and the adaptation helper is modeled as returning an in-band value. |
| `LinearKinkIrm` | Covers the included config ceiling, the same conditional bound on stored values, monotonicity, equal pricing functions, the unset revert, config application, and endpoint rates. | Ceiling claims assume values accepted by `LinearKinkConfig`; the IRM itself still accepts arbitrary ABI-decodable getter output. |
| `IrmRouter` | Covers view forwarding to linked LinearKink, the `borrowRate` Morpho gate, routing-table changes only through an owner-or-manager `setMarketIrm` and never to zero, one-shot initialization, zero-table reverts, no pre-creation `accrueInterest` or implementation `borrowRate` call, and exactly one accrual plus probe on a successful live route. | Core market state and accrual are summarized. Every implementation `borrowRate` call, including normal state-changing forwarding and the live probe, is modeled as a successful arbitrary return; only `borrowRateView` forwarding is dispatched to linked implementation code. Self-routing is excluded to prevent recursive dispatch, although pre-creation `setMarketIrm` can create that state because it performs no probe. |

## 8. LinearKinkIrm — Lido fork addition

`LinearKinkIrm` is a piecewise-linear replacement for the removed `FixedRateIrm`. The included config validates four immutable `uint64` values and an 800% nominal annual peak. The IRM copies ABI-decodable values into one packed slot without validating them, then never calls or stores the config address. Both pricing functions are view-only and equal. See [LinearKinkIrm](SPECIFICATION.md#linearkinkirm).

| Verifies | Test |
|---|---|
| `LinearKinkConfig` stores all four values immutably, its getter round-trips, constructor validation rejects both invalid utilization boundaries and an excessive peak, and accepts the exact maximum | `LinearKinkConfigTest` |
| The curve returns `baseRate`, `baseRate + slope1`, and the peak at zero, kink, and full utilization, and is linear on each leg | `test_rateAtZeroUtilizationIsBaseRate`, `test_rateAtKinkIsBasePlusSlope1`, `test_rateAtFullUtilizationIsPeak`, `test_rateIsLinearOnSlope1Leg`, `test_rateIsLinearOnSlope2Leg` |
| No evolving rate state, plus fuzzed monotonicity in utilization and the peak bound | `test_borrowRateEqualsBorrowRateView`, `testFuzz_monotonicAndBounded` |
| Adversarial view inputs: utilization above 100% clamps at the curve's peak, and zero supply prices as zero utilization | `test_overUtilizationClampsAtPeak`, `test_zeroSupplyActsAsZeroUtilization` |
| Two markets on one IRM keep independent params | `test_marketsAreIndependent` |
| An unconfigured market reverts `CONFIG_NOT_SET` | `test_revertsWhenParamsNotSet` |
| Every params field round-trips through the `marketKinkParams` getter | `test_paramsAreStoredAndReadable` |
| Zero, an externally owned account, and a formerly deployed address with code removed fail to return ABI-decodable parameters; the tested wrong-interface contract also reverts during the getter call | `test_applyIrmConfig_revertsForZeroAddress`, `test_applyIrmConfig_revertsForEoa`, `test_applyIrmConfig_revertsWhenConfigCodeWasRemoved`, `test_applyIrmConfig_revertsForWrongConfigType` |
| The function emits the supplied config address and copies each field, while later mutation of a mock config cannot change the stored parameters or calculated rate | `test_applyIrmConfig_copiesParamsAndEmitsConfig`, `test_rateCalculationUsesCopiedParamsNotConfig` |
| Returned values are deliberately not validated: an authorized caller can snapshot an ABI-compatible mock returning invalid LinearKink parameters; this demonstrates missing enforcement, not a supported config. An outsider cannot apply a config, the manager can, and a second valid config overwrites the first snapshot | `test_applyIrmConfig_doesNotValidateReturnedValues`, `test_applyIrmConfig_unauthorizedReverts`, `test_applyIrmConfig_managerCanApply`, `test_applyIrmConfig_reparametrizesInPlace` |

## 9. IrmRouter — Lido fork addition

Markets using this package point at a proxied `IrmRouter`. Its core-only `borrowRate` and public `borrowRateView` forward to `marketIrm[id]`. Owner or manager may route a market. A live switch asks the core to accrue, lets the old route price any elapsed interval, and probes the new implementation before storing it. Pre-creation routing does not call the implementation. See [IrmRouter](SPECIFICATION.md#irmrouter).

These unit tests use a mock LidoLend core for direct control of market state. The mock stores markets, calls the market IRM during accrual and creation, and updates `lastUpdate`.

| Verifies | Test |
|---|---|
| `borrowRate` / `borrowRateView` return exactly what the routed kink implementation returns, including the full mock-accrual path (adaptive forwarding is asserted in the migration scenario below) | `test_forwarding_routedKinkMatchesDirect`, `test_forwarding_accrueInterestPathUsesKinkRate` |
| `borrowRate` from a non-core caller reverts `NOT_MORPHO`. An unrouted market reverts `IRM_NOT_SET` in the view and after the state-changing path passes its core-only caller check. | `test_borrowRate_nonMorphoCallerReverts`, `test_unroutedMarketReverts` |
| The manager routes a market alongside the owner, a stranger reverts `NOT_AUTHORIZED`, the zero-address implementation reverts `ZERO_ADDRESS`, and marketParams carrying a foreign `irm` field revert `NOT_ROUTER_MARKET` | `test_setMarketIrm_managerCanRoute`, `test_setMarketIrm_outsiderReverts`, `test_setMarketIrm_zeroIrmReverts`, `test_setMarketIrm_wrongIrmFieldReverts` |
| An unconfigured or wrong-`ROUTER` implementation reverts a live-market switch through the probe, while pre-creation the same failures surface at `createMarket`, which creates nothing | `test_setMarketIrm_unconfiguredRoutesButCreateMarketReverts`, `test_setMarketIrm_probeCatchesUnconfiguredImpl`, `test_setMarketIrm_probeCatchesWrongRouterGate` |
| Pre-creation routing writes no implementation state, the launch seed comes from `createMarket`, a live attach of a fresh Adaptive implementation seeds through the probe, and a live switch triggers one accrual, advances debt, updates `lastUpdate`, and completes the route | `test_setMarketIrm_repeatBeforeCreateMarketKeepsSeededRate`, `test_setMarketIrm_seedSemantics`, `test_setMarketIrm_accruesBeforeSwitch` |
| `createMarket` pings `borrowRate` through the router — it reverts for an unrouted market and succeeds after `applyIrmConfig` + `setMarketIrm` | `test_createMarket_revertsUntilRouted` |
| A live market migrates between models and uses the selected implementation after each switch; in the same-block snapshot scenario a fresh Adaptive implementation seeds from the old value; reattaching a previously used Adaptive implementation resumes its stored value | `test_migration_kinkToAdaptiveAndBack`, `test_migration_snapshotSeedsFreshAdaptive`, `test_migration_backToUsedAdaptiveResumesStaleRate` |

Coverage does not currently include a reentrant implementation, a non-reverting implementation that returns an unusable rate, recovery from such an active route, a live same-route assignment, a pre-creation self-route, or a router upgrade that changes immutable `MORPHO`.

## 10. IrmConfigFactory — Lido fork addition

`IrmConfigFactory` permissionlessly returns an existing included immutable config for a parameter set or deploys one if absent. It uses separate model mappings and delegates validation to the config constructors. It is optional and is not an allowlist. See [IrmConfigFactory](SPECIFICATION.md#irmconfigfactory).

| Verifies | Test |
|---|---|
| Before deployment the parameter-based getter returns zero; any caller can get or deploy each concrete config, the getter then resolves its address, the returned parameters round-trip, and the model-specific deployment event contains the exact parameter hash and address | `test_getOrDeployAdaptiveCurveConfig_deploysAndResolvesByParams`, `test_getOrDeployLinearKinkConfig_deploysAndResolvesByParams` |
| Repeating the same parameter set from another caller returns the same address and emits no new deployment event | `test_getOrDeployAdaptiveCurveConfig_reusesExistingConfig`, `test_getOrDeployLinearKinkConfig_reusesExistingConfig` |
| The tested one-field parameter changes produce distinct hashes and config addresses in the corresponding mapping | `test_getOrDeployAdaptiveCurveConfig_distinctParamsDeployDistinctConfigs`, `test_getOrDeployLinearKinkConfig_distinctParamsDeployDistinctConfigs` |
| Invalid parameters propagate the concrete constructor revert and leave the corresponding mapping empty | `test_getOrDeployAdaptiveCurveConfig_constructorValidationReverts`, `test_getOrDeployLinearKinkConfig_constructorValidationReverts` |
