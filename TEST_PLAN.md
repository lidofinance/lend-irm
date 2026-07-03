# AdaptiveCurveIrm Fork — Test Plan

The fork makes additive changes to Morpho's `AdaptiveCurveIrm`: per-market curve parameters (immutable `AdaptiveCurveConfig` contracts, deployed and deduplicated by the IRM itself), an owner/manager authorization model, an optional borrow-rate cap, reparametrization by re-pointing a market at new parameters, proxy-compatibility, and a periphery library that reads params live from the pointed-at config. The curve math and its adaptation are unchanged from upstream. Each section below states what changed and maps every covered property to its test. The rest is inherited Morpho, covered by the retained upstream suite, adapted to the per-market-config model (the IRM is `initialize`d with an owner and manager, and a default config from `test/ConstantsLib.sol` is set per market via `setMarketCurveParams`; `testConstants` dropped, now covered by `AdaptiveCurveConfig` validation; the `vm.assume` market filters reworked into `bound`-based squeezing so deep fuzz campaigns pass at Foundry's default rejection cap). `FixedRateIrm`, `ExpLib`, and `UtilsLib` are unchanged from upstream and keep their upstream suites (`FixedRateIrmTest`, `ExpLibTest`, `UtilsLibTest`) as-is.

| Change | Suites |
|---|---|
| Per-market configuration | `AdaptiveCurveConfigTest`, `AdaptiveCurveIrmTest` |
| Authorization (owner/manager) | `AdaptiveCurveIrmTest` |
| Borrow-rate cap | `AdaptiveCurveIrmTest`, Certora `MaxBorrowRate` |
| Reparametrization | `AdaptiveCurveIrmReparamTest` |
| Periphery library | `AdaptiveCurveIrmLibTest`, Certora `BorrowRateView` / `ExpectedMarketBalances` |
| Upgradeable (proxy) | `AdaptiveCurveIrmProxyTest` |

**Exactness policy.** Every check is exact: the suites assert equality against `test/CurveRefHelper.sol` — an independent reference implementation of the curve, adaptation, and cap, parametrized by the market's params — or against closed-form expected values. There are no directional (`Gt`/`Lt`) assertions; the only two inequalities left are documented domain properties in `ExpLibTest` (`testWExpPositive`/`testWExpNegative`), which have no exact counterpart. The upstream ping-every-minute scenarios and the stateful invariant are differential: every interaction in them is asserted equal to the reference.

Run with `forge test`. Deep campaigns need only the run counts — no rejection-cap override: `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_INVARIANT_RUNS=4096 forge test` (verified clean).

Coverage (`forge coverage --no-match-test "PingEveryMinute" --no-match-coverage "^test/" --report summary`; the two 1B-gas ping loops do not survive coverage instrumentation and are excluded from the run, not from the metric's denominator) is complete across `src/`:

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `src/adaptive-curve-irm/AdaptiveCurveIrm.sol` | 100% (75/75) | 100% (80/80) | 100% (24/24) | 100% (12/12) |
| `src/adaptive-curve-irm/AdaptiveCurveConfig.sol` | 100% (23/23) | 100% (20/20) | 100% (22/22) | 100% (3/3) |
| `src/adaptive-curve-irm/libraries/**` (4 files) | 100% (65/65) | 100% (93/93) | 100% (13/13) | 100% (10/10) |
| `src/fixed-rate-irm/FixedRateIrm.sol` | 100% (14/14) | 100% (11/11) | 100% (10/10) | 100% (3/3) |
| **Total** | **100% (177/177)** | **100% (204/204)** | **100% (69/69)** | **100% (28/28)** |

---

## 1. Per-market configuration

**What changed.** The curve constants become per-market, validated `AdaptiveCurveConfig` contracts the IRM reads live; the bounds guarantee well-formedness, not economic soundness. See SPECIFICATION §Configuration.

| Verifies | Test |
|---|---|
| The `AdaptiveCurveConfig` constructor rejects each parameter just outside both ends of its range | `AdaptiveCurveConfigTest.testDeploymentRevertsOnInvalidParams` |
| Every `AdaptiveCurveParams` field round-trips through `getCurveParams()` | `AdaptiveCurveConfigTest.testGetConfigRoundTrips` |
| The upstream-equivalent default config passes validation and deploys | `AdaptiveCurveConfigTest.testDefaultConfigIsValid` |
| `borrowRate` and `borrowRateView` revert `CONFIG_NOT_SET` for a market with no config set | `AdaptiveCurveIrmTest.testBorrowRateRevertsWhenConfigNotSet` |
| Across the operating-band config space and the full accepted space up to the validation ceilings, one interaction matches the reference exactly on both paths | `testFuzz_validConfigInvariants`, `testFuzz_fullRangeConfigUpholdsInvariants` |
| The charged rate and `rateAtTarget` match the config-parametrized reference across the full accepted config space | `testFuzz_curveMatchesConfigParametrizedReference` |
| Config edges within validation: flat curve at steepness 1, frozen adaptation at speed 0, pinned band (min == max), the validation ceilings compute without overflow, utilization above 100% and zero-supply markets price exactly per the curve formula | `test_edge_*` (6 tests) |
| Two markets (distinct ids, each with its own config) on one IRM adapt independently, each exactly per the reference | `test_marketsAdaptIndependently` |
| State-changing `borrowRate` is Morpho-only, `borrowRateView` open to anyone | `testBorrowRateOnlyMorpho` |
| After any fuzzed call sequence, a probe interaction matches the reference exactly on both paths and lands `rateAtTarget` on the reference's end value | `invariantRateMatchesReference` |

## 2. Authorization (owner and manager)

**What changed.** `setMarketCurveParams` deploys/deduplicates configs inline and is gated to `owner` **or** `manager`; role management is owner-only, both roles set once via `initialize`. See SPECIFICATION §Configuration and §Upgradeable.

| Verifies | Test |
|---|---|
| `setMarketCurveParams` deploys a config from the given params, points the market at it, and the market then prices | `testSetConfigDeploysAndPrices` |
| Identical params share one config across markets — a dedup hit emits no second `ConfigDeployed` (exactly one log: the bind) and reuses the cached address; different params get their own config | `testSetMarketCurveParamsDeduplicatesConfigs` |
| Registry self-consistency: after sets and reparams, every market's config is exactly the cached config for its own params | `testConfigRegistryRoundTrips` |
| An unauthorized caller (neither owner nor manager) reverts `NOT_AUTHORIZED` | `testSetConfigOnlyOwner` |
| A manager distinct from the owner can set market curve params but cannot rotate either role | `testManagerRoleSeparation` |
| The owner rotates ownership in place; the old owner loses the owner-only powers, the new owner gains them | `testTransferOwnership` |
| `transferOwnership` is owner-only; the zero address is rejected for both roles (neither can be unset) | `testTransferOwnershipOnlyOwner`, `testTransferOwnershipRejectsZero`, `testSetManagerRejectsZero` |
| The constructor rejects a zero `morpho` and locks the implementation; `initialize` rejects a zero owner, sets both roles once, and rejects a second call | `testDeployment` |
| `initialize` emits both role events; `transferOwnership`/`setManager` emit theirs with exact fields | `testInitializeEmitsRoleEvents`, `testRoleRotationEmitsEvents` |

## 3. Borrow-rate cap (`maxBorrowRate`)

**What changed.** `returned = min(curveRate, maxBorrowRate)` when the cap is non-zero; it never touches the stored `rateAtTarget`. See SPECIFICATION §Borrow-rate cap.

| Verifies | Test |
|---|---|
| A cap below the curve's tip clamps the charged rate to `maxBorrowRate` | `testMaxBorrowRateClampsChargedRate` |
| The cap bounds only the charged rate; `rateAtTarget` adapts exactly as in the uncapped run | `testMaxBorrowRateDoesNotAffectRateAtTarget` |
| Cap behaviour under reparametrization | §4 |

## 4. Reparametrization (re-pointing)

**What changed.** Re-calling `setMarketCurveParams` re-points a live market; `rateAtTarget` is untouched by the swap and the new params take effect on the next call. See SPECIFICATION §Reparametrization. Every poke in these tests (`_pokeExpecting`) asserts the charged rate and the resulting `rateAtTarget` exactly against the reference under the currently-registered params.

| Verifies | Test |
|---|---|
| A new band that still contains the stored rate preserves `rateAtTarget` with no spike | `test_reparam_statePersists_noSpike_whenBoundsContainRate` |
| A narrowed band snaps the stored rate exactly onto the nearest new bound on the next adapting call | `test_reparam_rateRises_whenNewMinAboveStoredRate`, `test_reparam_rateDrops_whenNewMaxBelowStoredRate` |
| Widening lets the rate creep (12 hourly steps, each exact per the reference, ceiling not reached); a later narrowing snaps it exactly onto the new ceiling in one step | `test_reparam_widenLetsRateCreep_thenNarrowShocks` |
| The re-clamp is lazy: after tightening `maxRateAtTarget`, an at-target poke leaves `rateAtTarget` exactly unchanged (out of range, charged as-is) until an off-target call re-bounds it exactly onto the new MAX | `test_reparam_tighterMax_atTargetPokeDefersRebound` |
| Changing `targetUtilization` / `curveSteepness` reprices the same utilization exactly per the reference with the new params, without moving `rateAtTarget` | `test_reparam_targetShift_changesChargedRate_keepsState`, `test_reparam_steepnessShift_changesChargedRate_keepsState` |
| A new `adjustmentSpeed` changes future adaptation (both the fast arm and a slow control are exact per the reference) without moving the rate at the swap | `test_reparam_adjustmentSpeedShift_changesFutureAdaptation_keepsState` |
| The cap applies and a tighter cap takes effect immediately on the next call, leaving `rateAtTarget` intact | `test_reparam_capAppliesAndTightens`, `test_reparam_capBelowAdaptedRate_clampsImmediately_keepsState` |
| The first call after a swap prices the whole interval since `lastUpdate` at the new params (no blending at the swap timestamp) | `test_reparam_newParamsPriceWholeIntervalSinceLastUpdate` |
| The periphery follows the newly-set config | `test_reparam_periphery_tracksReparam` |

## 5. Periphery library (`AdaptiveCurveIrmLib`)

**What changed.** The lib resolves the market's config from the IRM and reads it live, applying the same cap; it reverts `CONFIG_NOT_SET` when none is set. See SPECIFICATION §Periphery library.

| Verifies | Test |
|---|---|
| The lib's recompute matches the IRM for a given stored `rateAtTarget` and market; balances match `MorphoBalancesLib`, with revert symmetry across the whole uint128 range (accrual overflow included) | `testBorrowRateView`, `testExpectedMarketBalances` |
| The lib's `borrowRateView` matches the contract's own view across the full config space | `testFuzz_borrowRateView_matchesContract_acrossConfigs` |
| A market with no config registered reverts `CONFIG_NOT_SET` through the lib as well | `testBorrowRateViewRevertsWhenConfigNotSet` |

## 6. Upgradeable (proxy)

**What changed.** `MORPHO` is implementation bytecode; everything else is proxy storage, and the constructor locks the implementation itself. See SPECIFICATION §Upgradeable. Tests run against a minimal test-only ERC-1967 proxy; where a test seeds `rateAtTarget`, the seed is asserted exactly per the reference.

| Verifies | Test |
|---|---|
| `MORPHO`/`owner` read correctly through `delegatecall`, and a config set through the proxy prices the market | `test_morphoAndOwnerThroughProxy` |
| Ownership is rotated in place through the proxy (storage write, no upgrade needed) | `test_transferOwnershipThroughProxy` |
| A logic upgrade preserves `marketCurveConfig[id]` and `rateAtTarget` | `test_upgrade_logicSwap_preservesState` |
| The dedup cache survives an upgrade: a post-upgrade set of the same params on another market reuses the config deployed before the upgrade | `test_upgrade_preservesDeployedCurveConfigs` |
| The EIP-1967 impl/admin slots never collide with `rateAtTarget` (slot 0) | `test_proxyImplAndAdminSlots_doNotCollideWithRateAtTarget` |

## 7. Formal verification (Certora)

Specs live in `certora/{confs,specs}/`; all rules pass. `ExpectedMarketBalances.conf` maps `lib/morpho-blue`'s core to `solc-0.8.19` via `solc_map` (upstream pins that pragma); the IRM sources compile with `solc-0.8.35`.

| Proves | Conf |
|---|---|
| The periphery `borrowRateView` is equivalent to the contract's, for both the returned values and the revert conditions, with params resolved from the linked IRM and its pointed-at `AdaptiveCurveConfig` | `BorrowRateView` |
| The periphery `expectedMarketBalances` is equivalent to `MorphoBalancesLib`'s (values and reverts) | `ExpectedMarketBalances` |
| `borrowRate` and `borrowRateView` never return more than `maxBorrowRate` when the cap is enabled (curve and adaptation abstracted to NONDET, so the final clamp is verified non-vacuously) | `MaxBorrowRate` |
| `borrowRate` keeps `rateAtTarget[id]` within `[minRateAtTarget, maxRateAtTarget]`, under symbolic config satisfying the validation bounds | `RateAtTargetBand` |
