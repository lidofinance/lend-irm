# Lido Lend IRM — Specification

This document specifies three runtime contracts—two interest rate models and the router in front of them—and the included config implementations. [AdaptiveCurveIrm](#adaptivecurveirm) is the upstream Morpho adaptive model plus per-market configuration, owner/manager authorization, reparametrization, and an optional borrow-rate cap. [LinearKinkIrm](#linearkinkirm) is a fork-only kinked ("jump rate") model with no adapting state, implemented from scratch. Both IRMs inherit `OwnerManagerBase` and the shared `IConfigurableIrm` surface: `applyIrmConfig(MarketParams,address)` and `IrmConfigApplied`. They are standalone non-proxied contracts intended to sit behind [IrmRouter](#irmrouter), the proxied market-facing contract that routes each market to an implementation.

The identical config-application ABI is the common abstraction; the runtime representation is deliberately IRM-specific. Adaptive stores the config address and reads it while pricing, whereas LinearKink copies the config's values into packed storage and does not retain the address. The IRMs neither know nor constrain how a config address was created or selected. They do not validate values returned by config getters; the owner or manager that applies a config guarantees that its parameters are valid.

## AdaptiveCurveIrm

### Overview

`AdaptiveCurveIrm` maps utilization to a per-second rate through a curve whose height, `rateAtTarget`, is the uncapped curve rate at target utilization. That height adapts over time to pull utilization back toward the target. Markets use it through `IrmRouter`.

The curve and adaptation formulas come unchanged from [Morpho Blue IRM](https://github.com/morpho-org/morpho-blue-irm) at `a1a87fd`. This fork supplies their inputs per market instead of reading compile-time constants and optionally caps the output. The Lido-specific changes are:

- **per-market configuration** — the curve constants become parameters supplied by a config contract. The IRM keeps a per-market pointer and reads it through a static call, so each market can define its own curve. This package includes the immutable, constructor-validated `AdaptiveCurveConfig` implementation, but the IRM does not require that concrete type.
- **owner and manager** — two privileged addresses in storage: the `owner` manages authorization (rotates itself and the `manager`), and either the `owner` or the `manager` applies configs through `applyIrmConfig`.
- **reparametrization** — the same call re-points a live market at a different curve without redeploying the market.
- **standalone deployment behind the router** — the non-proxied IRM stores a `ROUTER` immutable and accepts state-changing `borrowRate` only from that address; changing its logic requires a new implementation and a router migration.
- an optional **borrow-rate cap** — a hard upper bound on the rate charged to borrowers, applied to the curve's output.

The `IIrm` function signatures are unchanged, but deployment is not drop-in: the constructor and trusted caller changed, and each market needs a config and a router entry. `borrowRate` is state-changing and accepts only `ROUTER`; `borrowRateView` is public and read-only.

### Configuration

Upstream, every market shares one curve because its parameters are compile-time constants. This fork moves those constants behind `getCurveParams()` and stores one config pointer per market in `marketCurveConfig[Id]`. With upstream-equivalent parameters and the optional cap disabled, the parameterized formulas compute the upstream result. The differential tests also compare the implementation exactly with `test/CurveRefHelper.sol`.

Setting (or changing) a market's curve is a single privileged call:

- **`applyIrmConfig(marketParams, config)`** calls `IAdaptiveCurveConfig(config).getCurveParams()` to obtain the new clamp bounds, derives the market `id`, stores the exact address in `marketCurveConfig[id]`, and emits `IrmConfigApplied(id, config)`. There is no separate bytecode or interface check; the call succeeds only if the config returns ABI-decodable parameters from that getter.
- **The call is owner-or-manager gated.** Only the IRM `owner` or `manager` may apply a config (`not authorized` otherwise). The function deliberately does not validate returned parameter values; the caller guarantees their validity. The IRM has no config deployment path, parameter hash, deduplication cache, or config registry.
- **The config is read live.** Every rate calculation calls the selected address again. The caller guarantees that every returned parameter set is valid. A later getter revert can stop pricing, and invalid values can revert or produce invalid results. If a mutable config changes its returned band without another `applyIrmConfig` call, pricing uses the new values but the function's eager clamp does not run.

The included `AdaptiveCurveConfig` implementation validates these bounds directly in its constructor; the IRM does not require that concrete type. A market with `marketCurveConfig == address(0)` is unpriced and reverts `config not set` until a config is applied.

| Parameter | Constructor validation |
| --- | --- |
| `curveSteepness` (WAD) | in `[WAD, 100*WAD]` |
| `adjustmentSpeed` (WAD/s) | in `[0, 10_000/year]` |
| `targetUtilization` (WAD) | in `(0, WAD)` |
| `initialRateAtTarget` (WAD/s) | in `[minRateAtTarget, maxRateAtTarget]` |
| `minRateAtTarget` (WAD/s) | `> 0` |
| `maxRateAtTarget` (WAD/s) | in `[minRateAtTarget, 10_000/year]` (approximately 1,000,000% APR) |
| `maxBorrowRate` (WAD/s) | `0` (optional cap disabled) or at most `maxRateAtTargetLimit * maxSteepness` (approximately 100,000,000% APR) |

These pinned upper bounds keep the curve math inside its non-overflowing, non-negative range for protocol-reachable market states. The `maxBorrowRate` limit is derived from the maximum target rate and steepness; a larger cap could not bind at utilization up to 100% within that range.

A market with no config cannot be priced: `borrowRate` and `borrowRateView` revert with `config not set`. LidoLend's `createMarket` calls `borrowRate` to initialize a stateful IRM, so a router-fronted Adaptive market must be routed and configured before creation can succeed.

### Reparametrization

Upstream a deployment's curve cannot change. In this fork, the owner or manager reparametrizes a market by calling `applyIrmConfig(marketParams, config)` again, with either a new config address or the same config returning new valid parameters. The call stores that address and clamps a non-zero `rateAtTarget` into the returned `[minRateAtTarget, maxRateAtTarget]` band; a value already inside is unchanged. There is no in-place parameter setter or config preparation path on the IRM.

The newly applied config is visible to the next pricing call, whether `borrowRate` or `borrowRateView`. The `applyIrmConfig` call itself updates `rateAtTarget` only through the non-zero clamp.

If later getter calls return the same parameter set read by `applyIrmConfig`, the individual parameter effects are:

| New parameter | Effect on pricing | Timing |
| --- | --- | --- |
| `maxBorrowRate` | borrow rate limited to the new cap, `rateAtTarget` untouched | immediate, even at target |
| `curveSteepness` | new slope: the same `rateAtTarget` and utilization give a different borrow rate | immediate |
| `targetUtilization` | the error is recomputed for the same utilization, so the rate shifts | immediate |
| `minRateAtTarget` / `maxRateAtTarget` | prices from the `rateAtTarget` already clamped into the new range at the swap | immediate, even at target |
| `initialRateAtTarget` | seeds a market whose stored `rateAtTarget` is zero | on that market's first state-changing pricing call |
| `adjustmentSpeed` | changes the next state transition; its effect scales with utilization error and elapsed time | on the next state-changing pricing call |

During `applyIrmConfig` itself, only the new `minRateAtTarget` and `maxRateAtTarget` can move stored `rateAtTarget`. If the returned band contains the stored value, it is unchanged. If the band excludes it, the function clamps it to the nearest bound. Later state-changing pricing calls can move it through the normal adaptation formula.

The graph illustrates both: a new range that still contains the stored `rateAtTarget` (smooth), and a new `maxRateAtTarget` below it (snap down).

![Reparametrizing the rate-at-target bounds: smooth vs. snap](assets/upgrading-rate-target.png)

Two more things to know about a reparametrization:

- **The re-clamp is eager.** The application call clamps a non-zero stored `rateAtTarget` into the new range. A stored zero, meaning this IRM instance has never priced the market, remains zero so the first state-changing pricing call still seeds `initialRateAtTarget`.
- **A non-zero stored rate uses the new parameters for the whole period since the last update.** The first `borrowRate` after a swap averages over the entire interval since `market.lastUpdate`, which may precede the swap; old and new parameters are not blended at the swap timestamp. A zero stored sentinel instead seeds `initialRateAtTarget` without elapsed adaptation. To settle an elapsed interval using the old parameters, call `accrueInterest` immediately before `applyIrmConfig`.

### Deployment and authorization

The IRM holds no curve parameters of its own. It is a standalone, non-proxied contract whose code is not upgradeable. Its only immutable variable is `ROUTER`, the address whose calls `borrowRate` accepts: the `IrmRouter` in front of it. The constructor takes `(router, owner, manager)`, rejects a zero `router`, and sets the two roles directly (both rejecting the zero address) — there is no `initialize` and no implementation lock. Upgradeability lives in the router: a market is created with the router as its `irm`, and changing that market's rate logic means deploying a freshly-constructed implementation and re-routing the market via `setMarketIrm` (see the IrmRouter part) — this contract's math can never change in place.

The `owner` and `manager` come from the shared `OwnerManagerBase`, so they occupy the first slots: the `owner` (slot 0) and the `manager` (slot 1). The IRM appends the adapting `rateAtTarget[Id]` (slot 2) and the per-market config pointer `marketCurveConfig[Id]` (slot 3). It has no config registry or parameter-hash storage.

Two privileged addresses live in storage:

- **`owner`** — rotates itself via `transferOwnership` and the manager via `setManager` (both owner-only, both rejecting the zero address, emitting `OwnershipTransferred` / `ManagerSet`), and may call `applyIrmConfig`.
- **`manager`** — an operational address that may call `applyIrmConfig` (day-to-day curve setting) but holds no power over `owner`/`manager` themselves.

### Borrow-rate cap

Upstream has no independent output cap; its maximum follows from the fixed `maxRateAtTarget` and `curveSteepness`. This fork parameterizes those values and adds an optional hard ceiling to the **output** returned to Morpho. With `curveSteepness` 4 and 4%/year at target, the uncapped rate runs from 1%/year at zero utilization to 16%/year at full utilization and rises further as `rateAtTarget` adapts toward `maxRateAtTarget`.

```
returned = min( curveRate,  maxBorrowRate )      # only when maxBorrowRate != 0
```

The cap only clamps the returned value and never touches stored `rateAtTarget`. For identical market inputs, enabling or changing the cap leaves the internal `rateAtTarget` transition unchanged. In the full market, however, a capped rate changes accrued balances and can therefore change later utilization inputs. Raising, lowering, or removing the cap through the selected config affects the next pricing call.

The cap clips every part of the curve above it. A cap below the curve's minimum output flattens the entire curve at that value. Setting `maxBorrowRate` to zero disables the output clamp.

With an `8%/year` cap on the same curve, the charged rate follows the curve, then holds flat where it would otherwise exceed the cap.

![Borrow-rate cap: charged = min(curve, maxBorrowRate)](assets/borrow-rate-cap.png)

### Periphery library

`AdaptiveCurveIrmLib` recomputes `borrowRateView` and `expectedMarketBalances` from a market `Id` and an `AdaptiveCurveIrm` address. It is intended for markets currently routed to that Adaptive implementation.

- It resolves `marketCurveConfig(id)`, reads `getCurveParams()` live, reads the IRM's stored `rateAtTarget`, and applies the same optional output cap.
- It reverts with `config not set` when the IRM has no config for the supplied `Id`.
- It calls the config from the library host's context, not from the IRM. Equality with the IRM therefore requires the getter to return the same parameters and call outcome to both callers; a caller-dependent getter can make separately executed reads differ.

The unit tests compare the library with the Adaptive contract directly. The Certora rules model `getCurveParams()` as the same successful ghost-backed return on both paths, and `ExpectedMarketBalances` uses direct-IRM `MarketParams`. The separate router proof covers forwarding to its linked LinearKink implementation; it does not prove the complete router-plus-Adaptive-periphery composition.

### Trust Assumptions

This section states what each actor can do to the model. Who holds each, and through what process it acts, is a governance matter outside this spec.

**IRM owner** (governance) rotates itself (`transferOwnership`) and the manager (`setManager`) and may call `applyIrmConfig` for any market. An `applyIrmConfig` call can replace the entire curve and clamp a non-zero stored `rateAtTarget` into the returned band. The owner must ensure that the config returns valid parameters and must judge their economic suitability; the function does neither. The model never custodies funds, so this is authority over the rate Morpho reads, not over deposits.

**IRM manager** (operations) is scoped: it may call `applyIrmConfig` to set or reparametrize any market's curve but cannot change `owner` or `manager` (`transferOwnership`/`setManager` are owner-only). It exists so day-to-day curve tuning need not use the owner key. Its power over rates is the same as the owner's — it simply cannot change authorization.

**No proxy admin or in-place upgrade.** This IRM's code cannot change. Replacing its logic requires a new implementation and a migration through `IrmRouter`, whose owner and proxy admin are described below. The actions above are the owner and manager's direct configuration authority over this contract; operational controls such as a timelock are outside this specification.

**The `ROUTER` caller** is the only privileged pricing caller: only it may call state-changing `borrowRate`, while `borrowRateView` is public. The model also calls the selected config during pricing.

### References

- Upstream IRM source at `morpho-org/morpho-blue-irm` @ `a1a87fd` and the Morpho whitepaper — references for the curve and its adaptation.
- `FORK_NOTES.md` — the fork point, source footprint, and change summary.
- `src/common/OwnerManagerBase.sol` (with `IOwnerManager.sol` and `OwnerManagerErrors.sol`) — the two-role base all three contracts inherit, with the roles set from the inheriting constructor (or, for the router, via its own `initialize`) — normative for the authorization semantics this document describes.
- `src/irm-router/IrmRouter.sol` — the proxied router this IRM sits behind, specified in the IrmRouter part below.
- `src/common/IConfigurableIrm.sol` — the shared `applyIrmConfig(MarketParams,address)` and `IrmConfigApplied` surface inherited by both IRM-specific interfaces.
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol` — the typed contract surface: the per-market config pointer, adapting state, owner/manager roles, and inherited common config and `IIrm` interfaces.
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol` — the per-market config contract surface (`getCurveParams()` and the per-field getters).
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol` — the shared top-level `AdaptiveCurveParams` struct.
- `src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol` — the periphery recompute library described above.

## LinearKinkIrm

### Overview

`LinearKinkIrm` is fork-only and replaces the removed upstream `FixedRateIrm`. Its per-second borrow rate is a piecewise-linear function of current utilization that steepens after `optimalUtilization`. The contract is implemented from scratch.

Unlike `AdaptiveCurveIrm`, the model has no adapting state: the rate depends only on the supplied market balances and the copied parameters. `borrowRate` is view-only and returns exactly what `borrowRateView` returns. One instance serves many markets keyed by `Id`; its owner and manager are set at construction and remain rotatable through `OwnerManagerBase`.

### The curve

With `U` the market's utilization (WAD-scaled), the returned per-second WAD rate is:

```
U = totalSupplyAssets == 0 ? 0 : wDivDown(totalBorrowAssets, totalSupplyAssets)
U = min(U, WAD)

U <= optimalUtilization:
    rate = baseRate + wMulDown(slope1, wDivDown(U, optimalUtilization))
U > optimalUtilization:
    rate = baseRate + slope1 + wMulDown(slope2, wDivDown(U - optimalUtilization, WAD - optimalUtilization))
```

- For parameters satisfying `0 < optimalUtilization < WAD`, the rate is `baseRate` at zero utilization, exactly `baseRate + slope1` at the kink, and exactly `baseRate + slope1 + slope2` at full utilization. The two branch formulas meet at the same kink endpoint, and the rate is non-decreasing in utilization.
- **The peak is the ceiling implied by valid stored parameters.** The IRM clamps utilization to 100%, including for out-of-range view inputs, so the rate does not exceed `baseRate + slope1 + slope2`. The included `LinearKinkConfig` limits that sum to 800%/year in its constructor. `LinearKinkIrm` exposes and enforces no such constructor limit.
- For parameters satisfying `0 < optimalUtilization < WAD`, utilization is first rounded down from the asset balances. Each leg then rounds down its normalized segment fraction and the multiplication by its slope. The result does not exceed the corresponding ideal rational interpolation and is exact at zero utilization, the kink, and full utilization.
- For a priced market (`optimalUtilization != 0`), zero supply is treated as zero utilization and returns `baseRate`.

### Configuration

`LinearKinkConfig` is the included immutable, constructor-validated implementation of the config ABI, not a concrete-type requirement of the IRM. After `applyIrmConfig`, each market's four returned `uint64` parameters are packed into a single storage slot (`LinearKinkParams`, 4×`uint64`; rates are per-second and WAD-scaled):

| Parameter | Constructor validation |
| --- | --- |
| `optimalUtilization` (WAD) | in `(0, WAD)`, both ends exclusive |
| `baseRate`, `slope1`, `slope2` (WAD/s) | jointly: `baseRate + slope1 + slope2 <= 8/year` (800% APR) |

- **`applyIrmConfig(marketParams, config)`** calls `ILinearKinkConfig(config).getKinkParams()`, copies the returned values into `marketKinkParams[id]`, and emits `IrmConfigApplied(id, config)`. It is owner-or-manager gated (`not authorized` otherwise). There is no separate bytecode or interface check; the call succeeds only if the getter returns ABI-decodable parameters. The function does not validate decoded values; the caller guarantees their validity.
- **Application takes a snapshot.** The IRM does not store the config address and rate calculation never calls it. The copied packed parameters are authoritative, so even a mutable mock changing later cannot affect pricing. This is intentionally different from Adaptive's live config binding.
- **Reparametrization repeats the same call.** A new snapshot, from either a new config address or the same address, overwrites the old parameters. The next pricing call uses the new curve. If the next core accrual covers time before the snapshot changed, it applies the new curve to that whole interval; call `accrueInterest` immediately before `applyIrmConfig` to settle the interval using the old curve.
- **A zero `optimalUtilization` is the unset sentinel.** Both pricing functions revert with `config not set` while it is zero. A valid parameter set makes it non-zero, but the application function itself enforces neither this condition nor any config-constructor invariant.

### Deployment and authorization

`LinearKinkIrm` is a standalone non-proxied contract intended to sit behind `IrmRouter`. Its constructor takes `(owner, manager)`. Storage contains `owner` at slot 0, `manager` at slot 1, and `marketKinkParams[Id]` at slot 2. There is no `ROUTER` immutable because both pricing functions are view-only and ungated. The IRM has no borrow-rate ceiling constant or getter; the 800%/year guard exists only in the included `LinearKinkConfig` constructor.

### Trust Assumptions

The **owner** and **manager** may replace a market's snapshot through `applyIrmConfig`, so the next pricing call can return a discontinuously different rate. The caller guarantees that the returned parameters are valid; the function does not validate them. The IRM itself has no proxy or in-place upgrade path, and replacing its logic requires routing to a new implementation. It never custodies funds.

Unlike the adaptive IRM, `borrowRate` is view-only and ungated because it does not update adapting state. `applyIrmConfig` calls the supplied config once, but pricing makes no config call: the market state is passed by value and the copied parameters live in the IRM's storage.

### References

- `src/linear-kink-irm/LinearKinkConfig.sol` and `interfaces/ILinearKinkConfig.sol` — the included immutable config implementation and the `getKinkParams()` ABI consumed by the IRM.
- `src/linear-kink-irm/interfaces/ILinearKinkIrm.sol` — the typed contract surface: `marketKinkParams(Id)` and the inherited common config, `IIrm`, and owner/manager interfaces.
- `src/linear-kink-irm/interfaces/ILinearKinkTypes.sol` — the packed `LinearKinkParams` struct.
- `TEST_PLAN.md` (§8) and `certora/specs/LinearKinkIrm.spec` — the test and formal-verification coverage of the properties above.

## IrmRouter

### Overview

A Morpho market cannot change its `irm` after creation, so markets using this package point at `IrmRouter` as their stable market-facing address. The router implements `IIrm` and forwards `borrowRate` and `borrowRateView` to a per-market implementation chosen by the router owner or manager. A live market can therefore migrate between rate models without changing its `MarketParams`.

The router calls implementations with CALL, not delegatecall. The supplied IRMs are standalone contracts and keep their own per-market storage; `AdaptiveCurveIrm` must be constructed with its `ROUTER` set to this router, while `LinearKinkIrm` has no pricing caller gate. The router's `borrowRate` is Morpho-only, its `borrowRateView` is public, and both revert `irm not set` when `marketIrm[id]` is zero. `setMarketIrm` can replace a non-zero pointer but cannot clear it; a retained pointer does not guarantee that arbitrary implementation code will continue to price successfully.

### Routing

Routing (and re-routing) a market is a single privileged call:

- **Validation and authorization.** `setMarketIrm(marketParams, irm)` is owner-or-manager gated, rejects a zero implementation, and requires `marketParams.irm == address(this)`. Because the market id includes the `irm` field, that equality prevents writing a route under an id that the router-fronted market will not use.
- **Live-market sequence.** If Morpho reports `lastUpdate != 0`, the router calls `accrueInterest(marketParams)`, reloads the market, and calls `irm.borrowRate(marketParams, market)` through the same ABI and caller path used by router forwarding. It stores `marketIrm[id]` and emits `MarketIrmSet` only after that probe succeeds. The accrual settles any elapsed interval under the old route; the probe can seed a fresh Adaptive implementation.
- **Probe scope.** The probe checks that the new implementation can price the current post-accrual market state when called by the router. It catches an implementation with no effective parameters and an Adaptive implementation constructed for another router, but it cannot guarantee future behavior of arbitrary or mutable implementation code.
- **Pre-creation routing.** The router always reads `market(id)` from Morpho. If the returned `lastUpdate` is zero, it then stores the pointer without calling `accrueInterest` or the implementation. This avoids prematurely seeding a stateful IRM. `createMarket` later performs the first `borrowRate` call and reverts atomically if the route or implementation cannot price the new market.

For a **new** market using either supplied IRM, call `setMarketIrm` and `applyIrmConfig` in either order, then call `createMarket`. Creation reverts with `irm not set` while the route is zero and with `config not set` while the selected IRM has no effective parameters. Each successful pre-creation routing call may change the router pointer and emits an event, but it does not touch implementation state.

### Migration

The router settles the old model and probes the new one, but each implementation keeps its own per-market state, and that state is what a migration must mind:

- **Away from an `AdaptiveCurveIrm`.** The switch calls `accrueInterest` before changing the route. Afterward, pricing no longer updates the old implementation's `rateAtTarget[id]`; an owner-or-manager `applyIrmConfig` call can still clamp that stored value while the implementation is detached.
- **To a fresh `AdaptiveCurveIrm`.** Its first state-changing pricing call seeds `rateAtTarget[id]` from `initialRateAtTarget`: the live-market probe during migration or `createMarket` during launch. To carry a previous Adaptive implementation's value exactly, first accrue the old route, read the resulting `rateAtTarget`, choose a valid new config whose band contains that value and whose `initialRateAtTarget` equals it, and switch without another elapsed interval. Otherwise `setMarketIrm` may update the old value during its pre-switch accrual after the snapshot was taken.
- **Back to a previously used `AdaptiveCurveIrm`.** Unless it was reconfigured while detached, its `rateAtTarget[id]` remains at the value last stored before departure. The probe resumes from that value rather than reseeding because the seeding path runs only when storage is zero. A fresh implementation provides a clean seed; reconfiguring the old implementation instead applies the normal non-zero clamp.
- **`LinearKinkIrm`, either direction.** The model has no adapting state, so migration requires no seed and leaves no evolving rate state behind. The copied curve applies on the next pricing call.

### Upgradeable

The router, not the IRMs, is proxied. Its only immutable is `MORPHO`, read from implementation bytecode under delegatecall. Router storage uses the ERC-7201 namespace `lido.lend.storage.IrmRouter`: `owner` is at the namespace base, `manager` and `isInitialized` share base + 1, and `marketIrm[Id]` is at base + 2.

The constructor takes `morpho`, rejects zero, and marks the implementation's own storage initialized; it cannot write proxy storage. A proxy starts with zeroed router storage and calls the one-shot `initialize(owner, manager)`, which rejects zero roles. Production deployment must initialize the proxy atomically before exposing it so another account cannot claim the roles.

Changing the routing logic requires a **proxy upgrade** to a new implementation. The proxy's storage contents persist, and a storage-compatible implementation continues to read the existing roles and `marketIrm` pointers. ERC-1967 implementation/admin pointers occupy dedicated slots that do not collide with the router's ERC-7201 namespace. A future field in the same layout must be appended after `marketIrm`. The proxy lives in the product repository, and each router implementation must be constructed with the correct `MORPHO`.

### Trust Assumptions

**The core's IRM choice stops at the router.** LidoLend's owner-gated `createMarket` records the router as the market's `irm` and enables that address implicitly. The market cannot later replace it. Choosing an implementation then belongs to the router owner or manager, while the proxy admin can replace the routing logic itself. Integrators must therefore evaluate router governance, not only the market's `irm` address.

**Router owner** (governance) rotates itself and the manager and can point a market at any non-zero `IIrm`. A live-market change is subject to the current-state probe; a pre-creation route is not probed until `createMarket`. The router never custodies funds, but this role controls which model Morpho reads.

**Router manager** (operations) may call `setMarketIrm` but cannot change either role. It can select arbitrary implementation code. A successful live-market probe checks only the current call and does not constrain later behavior.

**Proxy admin** (governance) can replace the router logic and can write any router storage slot through an upgrade, including the roles and routing pointers. The supplied Adaptive and LinearKink implementations are non-upgradeable, so changing their math requires deploying another implementation and migrating markets. Timelocks and other operational controls are outside this specification.

**Morpho** is the only caller of state-changing `borrowRate`, while `borrowRateView` is public and read-only. The router depends only on Morpho (market state and accrual during a switch) and on the implementations it forwards to.

### References

- `src/irm-router/IrmRouter.sol` — the contract this part specifies.
- `src/irm-router/interfaces/IIrmRouter.sol` — the typed contract surface: `MORPHO()`, `marketIrm(Id)`, `setMarketIrm` (with the `MarketIrmSet` event), `isInitialized()`/`initialize`, and the inherited `IIrm` and `IOwnerManager` interfaces.
- `src/irm-router/libraries/ErrorsLib.sol` — the router's errors (`already initialized`, `not Morpho`, `irm not set`, `irm is not this router`).
- `TEST_PLAN.md` (§§6, 9) and `certora/specs/IrmRouter.spec` — the test and formal-verification coverage of the properties above.
