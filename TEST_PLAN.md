# Lido Lend IRM — Test Plan

The fork makes additive changes to Morpho's `AdaptiveCurveIrm`: per-market curve parameters (immutable `AdaptiveCurveConfig` contracts, deployed and deduplicated by the IRM itself), an owner/manager authorization model (extracted into the shared `OwnerManagerBase`, with the roles set at construction), an optional borrow-rate cap, reparametrization by re-pointing a market at new parameters, an immutable deployment behind the proxied `IrmRouter` (changing a market's rate logic means re-routing it at the router), and a periphery library that reads params live from the pointed-at config. The curve math and its adaptation are unchanged from upstream. Each section below states what changed and maps every covered property to its test. The rest is inherited Morpho, covered by the retained upstream suite, adapted to the per-market-config model: the IRM is constructed with an owner and manager, a default config from `test/ConstantsLib.sol` is set per market via `setMarketCurveParams`, `testConstants` is dropped (now covered by `AdaptiveCurveConfig` validation), and the `vm.assume` market filters are reworked into `bound`-based squeezing so deep fuzz campaigns pass at Foundry's default rejection cap. The upstream `FixedRateIrm` is removed and replaced by the fork-only `LinearKinkIrm` (§8). The proxied `IrmRouter` is covered in §6 (the proxy) and §9 (the routing). `ExpLib` and `UtilsLib` are unchanged from upstream and keep their upstream suites (`ExpLibTest`, `UtilsTest`), adapted only in import paths and one strengthened overflow assertion in `testWExpDoesNotLeadToOverflow`.

| Change | Suites |
|---|---|
| Per-market configuration | `AdaptiveCurveConfigTest`, `AdaptiveCurveIrmTest` |
| Authorization (owner/manager) | `AdaptiveCurveIrmTest` |
| Borrow-rate cap | `AdaptiveCurveIrmTest`, Certora `MaxBorrowRate` |
| Reparametrization | `AdaptiveCurveIrmReparamTest` |
| Periphery library | `AdaptiveCurveIrmLibTest`, Certora `BorrowRateView` / `ExpectedMarketBalances` |
| Upgradeable (router proxy) | `IrmRouterProxyTest` |
| LinearKinkIrm (replaces `FixedRateIrm`) | `LinearKinkIrmTest`, Certora `LinearKinkIrm` |
| IrmRouter (routing) | `IrmRouterTest`, Certora `IrmRouter` |

**Exactness policy.** The core property checks assert exact equality against `test/CurveRefHelper.sol` — an independent reference implementation of the curve, adaptation, and cap, parametrized by the market's params — or against closed-form expected values, and the router suites assert exact forwarding equality against the routed implementation. The upstream ping-every-minute scenarios are differential with the reference threaded through the loop: every ping is asserted equal to it. The stateful invariant asserts a probe interaction against the reference computed from the currently stored `rateAtTarget` after every fuzzed call — the fuzzed calls themselves are not asserted. The documented exceptions: the inherited upstream tests in `AdaptiveCurveIrmTest` keep their coarse `assertApproxEqRel` sanity bands alongside the exact reference checks, the inherited `ExpLibTest` checks are directional or banded (the `testWExpPositive`/`testWExpNegative` domain properties, `testWExp`'s 1% band against solmate's `wadExp`, `testWExpSmall`, and the upper-bound continuity band), `LinearKinkIrmTest.testFuzz_monotonicAndBounded` is inherently directional, and three `assertGt` guards in `IrmRouterTest` only qualify the setup (a rate adapted, interest accrued) before the property itself is checked exactly.

Run with `forge test`. Deep campaigns need only the run counts — no rejection-cap override: `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_INVARIANT_RUNS=4096 forge test` (verified clean).

Coverage (`forge coverage --no-match-test "PingEveryMinute" --no-match-coverage "^test/" --report summary` — the two 1B-gas ping loops do not survive coverage instrumentation and are excluded from the run, not from the metric's denominator) is complete across `src/`:

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `src/adaptive-curve-irm/AdaptiveCurveIrm.sol` | 100% (59/59) | 100% (69/69) | 100% (13/13) | 100% (7/7) |
| `src/adaptive-curve-irm/AdaptiveCurveConfig.sol` | 100% (24/24) | 100% (21/21) | 100% (24/24) | 100% (3/3) |
| `src/adaptive-curve-irm/libraries/**` (4 files) | 100% (65/65) | 100% (93/93) | 100% (13/13) | 100% (10/10) |
| `src/common/OwnerManagerBase.sol` | 100% (19/19) | 100% (13/13) | 100% (8/8) | 100% (6/6) |
| `src/irm-router/IrmRouter.sol` | 100% (30/30) | 100% (29/29) | 100% (15/15) | 100% (5/5) |
| `src/linear-kink-irm/LinearKinkIrm.sol` | 100% (25/25) | 100% (30/30) | 100% (11/11) | 100% (5/5) |
| **Total** | **100% (222/222)** | **100% (255/255)** | **100% (84/84)** | **100% (36/36)** |

## 1. Per-market configuration

**What changed.** The curve constants become per-market, validated `AdaptiveCurveConfig` contracts the IRM reads live. The bounds guarantee well-formedness, not economic soundness. See SPECIFICATION §Configuration.

| Verifies | Test |
|---|---|
| The `AdaptiveCurveConfig` constructor rejects each parameter just outside both ends of its range | `AdaptiveCurveConfigTest.testDeploymentRevertsOnInvalidParams` |
| Every `AdaptiveCurveParams` field round-trips through `getCurveParams()` | `AdaptiveCurveConfigTest.testGetConfigRoundTrips` |
| The upstream-equivalent default config passes validation and deploys | `AdaptiveCurveConfigTest.testDefaultConfigIsValid` |
| The cap's boundary: the largest value the curve can ever output deploys, and `0` stays the explicit "disabled" | `AdaptiveCurveConfigTest.testMaxBorrowRateBoundary` |
| `borrowRate` and `borrowRateView` revert `CONFIG_NOT_SET` for a market with no config set | `AdaptiveCurveIrmTest.testBorrowRateRevertsWhenConfigNotSet` |
| Across the operating-band config space and the full accepted space up to the validation ceilings, one interaction matches the reference exactly on both paths | `testFuzz_validConfigInvariants`, `testFuzz_fullRangeConfigUpholdsInvariants` |
| The charged rate and `rateAtTarget` match the config-parametrized reference across the full accepted config space | `testFuzz_curveMatchesConfigParametrizedReference` |
| Config edges within validation: flat curve at steepness 1, frozen adaptation at speed 0, pinned band (min == max), the validation ceilings compute without overflow, utilization above 100% and zero-supply markets price exactly per the curve formula | `test_edge_*` (6 tests) |
| Two markets (distinct ids, each with its own config) on one IRM adapt independently, each exactly per the reference | `test_marketsAdaptIndependently` |
| State-changing `borrowRate` accepts only `ROUTER` (the IrmRouter in production), `borrowRateView` open to anyone | `testBorrowRateOnlyRouter` |
| After any fuzzed call sequence, a probe interaction matches the reference exactly on both paths and lands `rateAtTarget` on the reference's end value | `invariantRateMatchesReference` |

## 2. Authorization (owner and manager)

**What changed.** `setMarketCurveParams` deploys/deduplicates configs inline and is gated to `owner` **or** `manager`. Role management is owner-only, both roles set at construction (there is no `initialize` on the IRMs), with the machinery shared through `OwnerManagerBase` (role errors live in `common/OwnerManagerErrors.sol`). See SPECIFICATION §Configuration and §Deployment and authorization.

| Verifies | Test |
|---|---|
| `setMarketCurveParams` deploys a config from the given params, points the market at it, and the market then prices | `testSetConfigDeploysAndPrices` |
| Identical params share one config across markets — a dedup hit emits no second `ConfigDeployed` (exactly one log: the bind) and reuses the cached address, while different params get their own config | `testSetMarketCurveParamsDeduplicatesConfigs` |
| Registry self-consistency: after sets and reparams, every market's config is exactly the cached config for its own params | `testConfigRegistryRoundTrips` |
| An unauthorized caller (neither owner nor manager) reverts `NOT_AUTHORIZED` | `testSetConfigOnlyOwner` |
| A manager distinct from the owner can set market curve params but cannot rotate either role | `testManagerRoleSeparation` |
| The owner rotates ownership in place — the old owner loses the owner-only powers, the new owner gains them | `testTransferOwnership` |
| `transferOwnership` is owner-only, and the zero address is rejected for both roles (neither can be unset) | `testTransferOwnershipOnlyOwner`, `testTransferOwnershipRejectsZero`, `testSetManagerRejectsZero` |
| The constructor rejects a zero `router` and a zero owner or manager, and sets both roles at construction | `testDeployment` |
| The constructor emits both role events, and `transferOwnership`/`setManager` emit theirs with exact fields | `testConstructorEmitsRoleEvents`, `testRoleRotationEmitsEvents` |

## 3. Borrow-rate cap (`maxBorrowRate`)

**What changed.** An optional hard ceiling on the charged rate: `returned = min(curveRate, maxBorrowRate)` when the cap is non-zero, `0` disables it. It clamps only the value returned to Morpho and never touches the stored `rateAtTarget`. See SPECIFICATION §Borrow-rate cap.

| Verifies | Test |
|---|---|
| A cap below the curve's tip clamps the charged rate to `maxBorrowRate` | `testMaxBorrowRateClampsChargedRate` |
| The cap bounds only the charged rate — `rateAtTarget` adapts exactly as in the uncapped run | `testMaxBorrowRateDoesNotAffectRateAtTarget` |
| Cap behaviour under reparametrization | §4 |

## 4. Reparametrization (re-pointing)

**What changed.** Re-calling `setMarketCurveParams` re-points a live market, clamping a non-zero stored `rateAtTarget` into the new band at the swap. See SPECIFICATION §Reparametrization. Every poke in these tests (`_pokeExpecting`) asserts the charged rate and the resulting `rateAtTarget` exactly against the reference under the currently-registered params.

| Verifies | Test |
|---|---|
| A new band that still contains the stored rate preserves `rateAtTarget` with no spike | `test_reparam_statePersists_noSpike_whenBoundsContainRate` |
| A narrowed band clamps the stored rate exactly onto the nearest new bound at the swap itself, and the next call adapts from the clamped value exactly per the reference | `test_reparam_rateRises_whenNewMinAboveStoredRate`, `test_reparam_rateDrops_whenNewMaxBelowStoredRate` |
| Widening lets the rate creep (12 hourly steps, each exact per the reference, ceiling not reached), and a later narrowing clamps it onto the new ceiling at the swap | `test_reparam_widenLetsRateCreep_thenNarrowClampsAtSwap` |
| A tightened `maxRateAtTarget` applies immediately even at target utilization (the at-target poke charges the clamped rate), and a never-priced market keeps its 0 sentinel through swaps with the first interaction still seeding the initial rate | `test_reparam_tighterMax_appliesImmediately_evenAtTarget`, `test_reparam_freshMarketKeepsSentinel_thenSeedsInitialRate` |
| Changing `targetUtilization` / `curveSteepness` reprices the same utilization exactly per the reference with the new params, without moving `rateAtTarget` | `test_reparam_targetShift_changesChargedRate_keepsState`, `test_reparam_steepnessShift_changesChargedRate_keepsState` |
| A new `adjustmentSpeed` changes future adaptation (both the fast arm and a slow control are exact per the reference) without moving the rate at the swap | `test_reparam_adjustmentSpeedShift_changesFutureAdaptation_keepsState` |
| The cap applies and a tighter cap takes effect immediately on the next call, leaving `rateAtTarget` intact | `test_reparam_capAppliesAndTightens`, `test_reparam_capBelowAdaptedRate_clampsImmediately_keepsState` |
| The first call after a swap prices the whole interval since `lastUpdate` at the new params (no blending at the swap timestamp) | `test_reparam_newParamsPriceWholeIntervalSinceLastUpdate` |
| The periphery follows the newly-set config | `test_reparam_periphery_tracksReparam` |

## 5. Periphery library (`AdaptiveCurveIrmLib`)

**What changed.** The lib resolves the market's config from the IRM and reads it live, applying the same cap, and reverts `CONFIG_NOT_SET` when none is set. See SPECIFICATION §Periphery library.

| Verifies | Test |
|---|---|
| The lib's recompute matches the IRM for a given stored `rateAtTarget` and market, and balances match `MorphoBalancesLib`, with revert symmetry across the whole uint128 range (accrual overflow included) | `testBorrowRateView`, `testExpectedMarketBalances` |
| The lib's `borrowRateView` matches the contract's own view across the full config space | `testFuzz_borrowRateView_matchesContract_acrossConfigs` |
| A market with no config registered reverts `CONFIG_NOT_SET` through the lib as well | `testBorrowRateViewRevertsWhenConfigNotSet` |

## 6. Upgradeable (router proxy)

**What changed.** The proxied contract is now the `IrmRouter` — the IRMs are immutable standalone contracts (§§2, 8) with no proxy of their own. The router's `MORPHO` is read from implementation bytecode under `delegatecall`, while the storage sits at the router's ERC-7201 namespaced base slot: `owner` (base), `manager` packed with `isInitialized` (base + 1), `marketIrm` (base + 2), with the one-shot `initialize` and the impl-lock declared by the router itself on top of the shared `OwnerManagerBase`. Rotating `owner`/`manager` is a storage write, not an upgrade. Changing the routing logic is a proxy upgrade to a freshly-constructed implementation, and every market's `marketIrm` pointer persists. The proxy admin can overwrite any slot via upgrade.

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

Specs live in `certora/{confs,specs}/`, and all rules pass. All confs pin `solc-0.8.35` — the LidoLend core compiles with the same solc as the IRM sources, so `ExpectedMarketBalances.conf` links `lib/lido-lend/src/LidoLend.sol` directly.

| Proves | Conf |
|---|---|
| The periphery `borrowRateView` is equivalent to the contract's, for both the returned values and the revert conditions, with params resolved from the linked IRM and its pointed-at `AdaptiveCurveConfig` | `BorrowRateView` |
| The periphery `expectedMarketBalances` is equivalent to `MorphoBalancesLib`'s (values and reverts) | `ExpectedMarketBalances` |
| `borrowRate` and `borrowRateView` never return more than `maxBorrowRate` when the cap is enabled (curve and adaptation abstracted to NONDET, so the final clamp is verified non-vacuously) | `MaxBorrowRate` |
| `borrowRate` keeps `rateAtTarget[id]` within `[minRateAtTarget, maxRateAtTarget]` under symbolic config satisfying the validation bounds, and `setMarketCurveParams` clamps a non-zero stored rate into the new band at the swap (the 0 sentinel survives) | `RateAtTargetBand` |
| The fork-only kinked IRM never charges above the setter's peak (`capRespected`) or `MAX_BORROW_RATE` on any reachable storage (`peakCapped` invariant + `rateNeverExceedsMax`), is monotone in utilization (`monotonic`), returns `borrowRate == borrowRateView` (`stateless`), reverts `config not set` when unconfigured (`revertsWhenUnset`), and round-trips the setter's parameters through the view with same-id agreement (`configuredMarketSucceeds`, `setterRoundTrip`) — the scene is the production contract alone, no harness | `LinearKinkIrm` |
| The router forwards `borrowRateView` to exactly the routed implementation's value (the state-changing forward is summarized away by the probe model), `borrowRate` is Morpho-only, the routing table moves only through authorized `setMarketIrm` calls and never back to zero, unrouted markets revert on every pricing call, `initialize` is one-shot, routing a not-yet-created market makes no call into Morpho or the implementation (`uncreatedMarketRoutesUntouched`, the pre-creation decay regression at the call-occurrence level), and a live-market switch accrues and probes exactly once (`liveMarketRoutesAccruedAndProbed`) | `IrmRouter` |

## 8. LinearKinkIrm (fork-only)

**What changed.** A new stateless kinked ("jump rate") IRM, not derived from upstream (it replaces the removed `FixedRateIrm`): each market's params (`optimalUtilization`, `baseRate`, `slope1`, `slope2`) live packed in one slot in `mapping(Id => LinearKinkParams)` and are set in place by the `owner`/`manager` via `setMarketKinkParams(marketParams, params)` — validated to `optimalUtilization` strictly inside `(0, WAD)` and peak `baseRate + slope1 + slope2 <= MAX_BORROW_RATE`. The rate is piecewise-linear in utilization, carries no state (`borrowRate == borrowRateView`), and an unconfigured market reverts `CONFIG_NOT_SET`. Authorization comes from the same shared `OwnerManagerBase` as the AdaptiveCurveIrm, with the roles set at construction (`LinearKinkIrm(owner, manager)`).

| Verifies | Test |
|---|---|
| The curve returns `baseRate`, `baseRate + slope1`, and the peak at zero, kink, and full utilization, and is linear on each leg | `test_rateAtZeroUtilizationIsBaseRate`, `test_rateAtKinkIsBasePlusSlope1`, `test_rateAtFullUtilizationIsPeak`, `test_rateIsLinearOnSlope1Leg`, `test_rateIsLinearOnSlope2Leg` |
| Statelessness, plus fuzzed monotonicity in utilization and the peak bound | `test_borrowRateEqualsBorrowRateView`, `testFuzz_monotonicAndBounded` |
| Adversarial view inputs: utilization above 100% clamps at the curve's peak, and zero supply prices as zero utilization | `test_overUtilizationClampsAtPeak`, `test_zeroSupplyActsAsZeroUtilization` |
| Two markets on one IRM keep independent params | `test_marketsAreIndependent` |
| An unconfigured market reverts `CONFIG_NOT_SET` | `test_revertsWhenParamsNotSet` |
| Every params field round-trips through the `marketKinkParams` getter | `test_paramsAreStoredAndReadable` |
| Setter validation and authorization | `test_setRevertsOnZeroOptimalUtilization`, `test_setRevertsOnFullOptimalUtilization`, `test_setRevertsWhenPeakRateExceedsMax`, `test_setMarketKinkParams_unauthorizedReverts`, `test_setMarketKinkParams_managerCanSet`, `test_setMarketKinkParams_reparametrizesInPlace` |
| Shared `OwnerManagerBase` lifecycle: role rotation, zero-address rejection for either role at construction (the `initialize` one-shot and impl-lock coverage lives in §6, on the router) | `test_transferOwnership_ownerOnly`, `test_transferOwnership_works`, `test_transferOwnership_rejectsZero`, `test_setManager_ownerOnly`, `test_setManager_works`, `test_constructor_setsRoles`, `test_constructor_rejectsZeroOwner`, `test_constructor_rejectsZeroManager` |

## 9. IrmRouter (fork-only)

**What changed.** A new proxied router that markets are created pointing at as their `irm`: it forwards `borrowRate` (Morpho-only, `NOT_MORPHO` otherwise) and `borrowRateView` (public) to the per-market implementation in `mapping(Id => IIrm) marketIrm`, reverting `IRM_NOT_SET` for an unrouted market. `setMarketIrm(marketParams, irm)` is owner-or-manager gated (`NOT_AUTHORIZED` otherwise), rejects the zero address (the mapping is never clearable) and marketParams whose `irm` field is not the router itself (`NOT_ROUTER_MARKET`), accrues a live market before switching (the elapsed period settles at the old model's rate), and probes the new implementation with the exact `borrowRate` call Morpho will make — reverting a live-market switch when the implementation cannot price the market or gates on the wrong `ROUTER`. A not-yet-created market is routed without touching the implementation (a pre-creation probe would prematurely write a stateful model's `rateAtTarget`), and the same failures surface at `createMarket`, which reverts and creates nothing.

| Verifies | Test |
|---|---|
| `borrowRate` / `borrowRateView` return exactly what the routed kink implementation returns, including the full mock-accrual path (adaptive forwarding is asserted in the migration scenario below) | `test_forwarding_routedKinkMatchesDirect`, `test_forwarding_accrueInterestPathUsesKinkRate` |
| `borrowRate` from a non-Morpho caller reverts `NOT_MORPHO`, and an unrouted market reverts `IRM_NOT_SET` on both entry points | `test_borrowRate_nonMorphoCallerReverts`, `test_unroutedMarketReverts` |
| The manager routes a market alongside the owner, a stranger reverts `NOT_AUTHORIZED`, the zero-address implementation reverts `ZERO_ADDRESS`, and marketParams carrying a foreign `irm` field revert `NOT_ROUTER_MARKET` | `test_setMarketIrm_managerCanRoute`, `test_setMarketIrm_outsiderReverts`, `test_setMarketIrm_zeroIrmReverts`, `test_setMarketIrm_wrongIrmFieldReverts` |
| An unconfigured or wrong-`ROUTER` implementation reverts a live-market switch through the probe, while pre-creation the same failures surface at `createMarket`, which creates nothing | `test_setMarketIrm_unconfiguredRoutesButCreateMarketReverts`, `test_setMarketIrm_probeCatchesWrongRouterGate` |
| Pre-creation routing writes no implementation state and is idempotent (regression: a repeated pre-creation probe decayed the seeded rate to the floor), the launch seed comes from `createMarket`'s ping, a live-market attach of a fresh adaptive implementation seeds through the probe, and switching a live market settles the elapsed period at the old model's rate first | `test_setMarketIrm_repeatBeforeCreateMarketKeepsSeededRate`, `test_setMarketIrm_seedSemantics`, `test_setMarketIrm_accruesBeforeSwitch` |
| `createMarket` pings `borrowRate` through the router — it reverts for an unrouted market and succeeds after config + `setMarketIrm` | `test_createMarket_revertsUntilRouted` |
| A live market migrates between models and is priced by the correct model after each switch, the old rate carries onto a fresh adaptive implementation when `initialRateAtTarget` is chosen equal to its snapshot, and a route back to a previously-used adaptive implementation resumes from its stale `rateAtTarget` | `test_migration_kinkToAdaptiveAndBack`, `test_migration_snapshotSeedsFreshAdaptive`, `test_migration_backToUsedAdaptiveResumesStaleRate` |

The mock stands in for the LidoLend core, keeping the suite a unit test with direct market-state control: it stores markets, pings the market's IRM the way the core does on accrual and creation, and stamps `lastUpdate`.
