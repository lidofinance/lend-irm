# Lido Lend IRM — Specification

This document specifies the three contracts of this fork: two interest rate models and the router in front of them. [AdaptiveCurveIrm](#adaptivecurveirm) is the upstream Morpho adaptive model plus the Lido additions — per-market configuration, an owner and a manager, reparametrization, and an optional borrow-rate cap. [LinearKinkIrm](#linearkinkirm) is fork-only, with no upstream counterpart: a stateless kinked ("jump rate") model, specified here from scratch. Both IRMs inherit the same owner/manager base (`OwnerManagerBase`) and are immutable standalone contracts with the roles set at construction. They are meant to sit behind [IrmRouter](#irmrouter) — the proxied contract markets are created with, which routes each market to an implementation and lets the router owner or manager migrate a live market between rate models.

## AdaptiveCurveIrm

### Overview

`AdaptiveCurveIrm` is the adaptive rate model markets price through (via the `IrmRouter` in front of it). It maps utilization to a per-second rate through a curve whose height, `rateAtTarget`, is the rate charged at target utilization. That height adapts over time to pull utilization back toward the target, with no governance action required.

The curve and its adaptation are the [upstream Morpho model](https://github.com/morpho-org/morpho-blue-irm) (`morpho-org/morpho-blue-irm` @ `a1a87fd`, `src/adaptive-curve-irm/AdaptiveCurveIrm.sol`): the formulas are **unchanged** — the fork parameterizes them per market instead of reading compile-time constants, and clamps the output with the optional cap. Anything not specified in this document matches that source. Together with the Morpho whitepaper, it is the normative reference for the exact formulas. This document specifies only the additions of the Lido version:

- **per-market configuration** — the curve constants become a validated, immutable `AdaptiveCurveConfig` contract. The IRM keeps a per-market pointer to one and reads it through an external static call, so each market can define its own curve.
- **owner and manager** — two privileged addresses in storage: the `owner` manages authorization (rotates itself and the `manager`), and either the `owner` or the `manager` sets a market's curve via a single `setMarketCurveParams` call that deploys (or reuses) the config internally.
- **reparametrization** — the same call re-points a live market at a different curve without redeploying the market.
- **an immutable contract behind the router** — the IRM is a standalone, non-proxied contract whose `owner` and `manager` are set at construction (rotated via `transferOwnership`/`setManager`). It is meant to sit behind `IrmRouter` — the `ROUTER` immutable, the only caller `borrowRate` accepts — and upgradeability lives in the router: changing a market's rate logic means deploying a fresh implementation and re-routing the market (see the IrmRouter part).
- an optional **borrow-rate cap** — a hard upper bound on the rate charged to borrowers, applied to the curve's output.

The `borrowRate` / `borrowRateView` interface is unchanged, so the model is a drop-in replacement. `borrowRate` is still gated to a single trusted caller (`ROUTER`, the IrmRouter in production) and state-changing, and `borrowRateView` is still public and read-only.

### Configuration

Upstream, every market shares one curve, since its parameters are compile-time constants. Lido runs several markets that may each want a different curve, so the fork moves those constants into `AdaptiveCurveConfig` contracts — immutable holders of one curve's parameters, validated at construction — with a per-market pointer on the IRM (`marketCurveConfig[Id]`), read through an external static call (`getCurveParams()`) when pricing. The math that consumes them keeps the upstream formulas — parameterized, not modified — and, given equal parameter values, computes the same rates, which the differential tests assert exactly against the `test/CurveRefHelper.sol` reference.

Setting (or changing) a market's curve is a single privileged call:

- **`setMarketCurveParams(marketParams, curveParams)`** derives the market `id` from `marketParams`, then resolves a config for `curveParams`: it deploys a fresh `AdaptiveCurveConfig(curveParams)` — whose constructor validates the parameters and reverts if any is out of range — unless a config for **identical** parameters was already deployed, in which case it reuses that one. The market is then pointed at the resolved config. Deployment and activation are a single step — there is no separate config-deployment surface.
- **The IRM deduplicates by parameter hash.** `deployedCurveConfigs[keccak256(abi.encode(curveParams))]` caches the canonical config for a param-set, so identical parameters resolve to one shared `AdaptiveCurveConfig` across markets and calls (an immutable config is safely shareable). The first deployment for a hash emits `ConfigDeployed`, and every set emits `MarketCurveParamsSet`.
- **The call is owner-or-manager gated.** `setMarketCurveParams` is callable only by the IRM `owner` or `manager` (storage variables, see Deployment and authorization), reverting `not authorized` otherwise. The IRM does not gate *which* parameters — it trusts the caller (governance / an operator) to choose an appropriate curve — validation guarantees only well-formedness, not economic soundness. This mirrors how Euler V2 gates its rate-model setter to the vault governor. A market with `marketCurveConfig == address(0)` is simply unpriced (reverts `config not set`) until set.

| Parameter | Validation |
| --- | --- |
| `curveSteepness` (WAD) | in `[WAD, 100*WAD]` |
| `adjustmentSpeed` (WAD/s) | in `[0, ~10000/year]` |
| `targetUtilization` (WAD) | in `(0, WAD)` |
| `initialRateAtTarget` (WAD/s) | in `[minRateAtTarget, maxRateAtTarget]` |
| `minRateAtTarget` (WAD/s) | `> 0` |
| `maxRateAtTarget` (WAD/s) | in `[minRateAtTarget, ~1e6%/year]` |
| `maxBorrowRate` (WAD/s) | `0` (disabled) or at most the curve's maximum possible output (max rate-at-target x max steepness, ~1e8%/year) |

These bounds keep the curve math inside its non-overflowing range, so `borrowRate` runs without reverting and returns a non-negative rate.

A market with no config set cannot be priced: `borrowRate` / `borrowRateView` revert with `config not set` until the owner or manager has set one. Morpho's `createMarket` itself calls `borrowRate` to initialize the IRM, so a market using this IRM cannot even be created until its curve is set.

### Reparametrization

Upstream a deployment's curve cannot change. In the fork, the owner or manager reparametrizes a live market by calling `setMarketCurveParams(marketParams, newCurveParams)` again: the IRM deploys (or reuses) the config for the new parameters and re-points the market at it. The swap clamps a non-zero stored `rateAtTarget` into the new `[minRateAtTarget, maxRateAtTarget]` band (a value already inside is untouched) and adaptation continues from there. There is no in-place parameter setter — an `AdaptiveCurveConfig` is itself immutable, so changing a curve always means resolving a (new or cached) config and re-pointing.

The new parameters take effect on the **next** `borrowRate` call, where they can shift the rate:

| New parameter | Effect on the next call | Timing |
| --- | --- | --- |
| `maxBorrowRate` | borrow rate limited to the new cap, `rateAtTarget` untouched | immediate, even at target |
| `curveSteepness` | new slope: the same `rateAtTarget` and utilization give a different borrow rate | immediate |
| `targetUtilization` | the error is recomputed for the same utilization, so the rate shifts | immediate |
| `minRateAtTarget` / `maxRateAtTarget` | prices from the `rateAtTarget` already clamped into the new range at the swap | immediate, even at target |
| `adjustmentSpeed` | changes the speed of future adaptation | gradual |

Only a change to the `minRateAtTarget` / `maxRateAtTarget` bounds can move the stored `rateAtTarget` discontinuously. When the new range still contains the stored value (for instance, a widened range), adaptation continues from where it was, with no jump. When the range is **narrowed** past the stored value, the setter clamps `rateAtTarget` onto the nearest new bound at the swap itself. The size of that jump is the gap between the old value and the new bound, which the caller sets by choosing the bound.

The graph illustrates both: a new range that still contains the stored `rateAtTarget` (smooth), and a new `maxRateAtTarget` below it (snap down).

![Reparametrizing the rate-at-target bounds: smooth vs. snap](assets/upgrading-rate-target.png)

Two more things to know about a reparametrization:

* **The re-clamp is eager.** The setter clamps a non-zero stored `rateAtTarget` into the new range at the swap, so a narrowed band takes effect on the very next call — even at target utilization, in the same block, or with `adjustmentSpeed` 0. A stored rate of 0 (a market this instance has never priced) is left alone, and the first interaction still seeds `initialRateAtTarget`.
* **The new parameters apply to the whole period since the last update.** The first `borrowRate` after a swap averages over the entire interval since `market.lastUpdate`, which may precede the swap — old and new parameters are not blended at the swap timestamp. To settle the pre-reparametrization interval at the old parameters, call `accrueInterest` immediately before swapping.

### Deployment and authorization

The IRM holds no curve parameters of its own. It is an **immutable**, standalone contract — not proxied and not upgradeable. Its only immutable variable is `ROUTER`, the address whose calls `borrowRate` accepts: the `IrmRouter` in front of it. The constructor takes `(router, owner, manager)`, rejects a zero `router`, and sets the two roles directly (both rejecting the zero address) — there is no `initialize` and no implementation lock. Upgradeability lives in the router: a market is created with the router as its `irm`, and changing that market's rate logic means deploying a freshly-constructed implementation and re-routing the market via `setMarketIrm` (see the IrmRouter part) — this contract's math can never change in place.

The `owner` and `manager` come from the shared `OwnerManagerBase`, so they occupy the first slots: the `owner` (slot 0) and the `manager` (slot 1). The IRM appends its own fields after them: the adapting `rateAtTarget[Id]` (slot 2), the per-market config pointer `marketCurveConfig[Id]` (slot 3), and the dedup cache `deployedCurveConfigs[hash]` (slot 4).

Two privileged addresses live in storage:

- **`owner`** — rotates itself via `transferOwnership` and the manager via `setManager` (both owner-only, both rejecting the zero address, emitting `OwnershipTransferred` / `ManagerSet`), and may call `setMarketCurveParams`.
- **`manager`** — an operational address that may call `setMarketCurveParams` (day-to-day curve setting) but holds no power over `owner`/`manager` themselves.

### Borrow-rate cap

Upstream puts no ceiling on the charged rate. Above target the curve multiplies `rateAtTarget` by up to `curveSteepness`. With `curveSteepness` 4 and 4%/year at target, the rate runs from 1%/year at zero utilization to 16%/year at full utilization, and climbs further as `rateAtTarget` adapts toward `maxRateAtTarget`. The fork adds an optional hard ceiling on what a borrower can be charged, applied to the **output** returned to Morpho:

```
returned = min( curveRate,  maxBorrowRate )      # only when maxBorrowRate != 0
```

The cap only clamps the returned value and never touches the stored `rateAtTarget`. Adaptation responds to the utilization error rather than the current rate, so clamping `rateAtTarget` would interfere with the control loop, while clamping the output leaves it running exactly as upstream. The state machine behaves the same whether the cap is on or off, and raising or removing the cap (by re-pointing the market at a new config) brings the borrow rate straight to `min(curve value, new cap)` on the next call.

The cap clips the high-utilization peak of the curve, or the whole curve if it sits below `rateAtTarget`. Setting `maxBorrowRate` to 0 turns it off. A cap below the curve's operating range makes the market effectively interest-free — that is what the chosen value does, and avoiding it is on the caller, not a contract defect.

With an `8%/year` cap on the same curve, the charged rate follows the curve, then holds flat where it would otherwise exceed the cap.

![Borrow-rate cap: charged = min(curve, maxBorrowRate)](assets/borrow-rate-cap.png)

### Periphery library

`AdaptiveCurveIrmLib` recomputes `borrowRateView` and `expectedMarketBalances` from a market `Id` alone, for integrators that hold the id rather than the full `MarketParams`. Because each market's curve is read from its own `AdaptiveCurveConfig` (which the owner/manager can re-point), it differs from upstream in two ways, and the equivalence is machine-checked:

- it resolves the market's config from the IRM (`marketCurveConfig(id)`) and reads it **live from that `AdaptiveCurveConfig`** (via `getCurveParams()`), tracking whichever config the market currently points at, and applies the same cap, reverting with `config not set` when none is set (mirroring the IRM).
- its results are **market-specific**, per the current `AdaptiveCurveConfig`, and must be queried with the market's actual `AdaptiveCurveIrm` address and `Id`.
- equivalence to the contract is **proven in Certora**, for both the returned values and the revert conditions.

### Trust Assumptions

This section states what each actor can do to the model. Who holds each, and through what process it acts, is a governance matter outside this spec.

**IRM owner** (governance) holds authorization and the curve: it rotates itself (`transferOwnership`) and the manager (`setManager`), and can set or re-point any market's curve (`setMarketCurveParams`), swapping its entire curve — and with it every future rate the market reads — in a single transaction, with `rateAtTarget` carried across the swap, clamped into the new band. The owner is trusted to choose well-formed parameters (the config constructor's validation ensures `borrowRate` neither reverts nor returns a negative rate) and to judge whether a curve is economically sound and `maxBorrowRate` set sensibly. The model never custodies funds, so this is power over the rate Morpho reads, not over deposits.

**IRM manager** (operations) is scoped: it may call `setMarketCurveParams` — set or reparametrize any market's curve — but cannot change `owner` or `manager` (`transferOwnership`/`setManager` are owner-only). It exists so day-to-day curve tuning need not use the owner key. Its power over rates is the same as the owner's — it simply cannot change authorization.

**No proxy admin, no upgrade path.** The rate math is immutable: no one can swap the curve logic under a market in place, and fixing an implementation bug means deploying a new implementation and migrating the affected markets at the `IrmRouter` — whose owner and proxy admin (the ultimate authority of this stack) are specified in the IrmRouter part. The trade-off is deliberate: what the owner and manager can do above is the full extent of anyone's power over this contract. Constraints on the owner and manager (timelock, governance) are operational and outside this spec.

**The `ROUTER` caller** — the `IrmRouter` in production — is the only caller of state-changing `borrowRate`, while `borrowRateView` is public and read-only. The model has no other privileged caller, and it depends on no external contract beyond the caller that prices through it and the `AdaptiveCurveConfig` it reads through a static call.

### References

- Upstream IRM source at `morpho-org/morpho-blue-irm` @ `a1a87fd` and the Morpho whitepaper — normative for the curve and its adaptation.
- `FORK_NOTES.md` — the fork point and the full per-file delta against upstream.
- `src/common/OwnerManagerBase.sol` (with `IOwnerManager.sol` and `OwnerManagerErrors.sol`) — the two-role base all three contracts inherit, with the roles set from the inheriting constructor (or, for the router, via its own `initialize`) — normative for the authorization semantics this document describes.
- `src/irm-router/IrmRouter.sol` — the proxied router this IRM sits behind, specified in the IrmRouter part below.
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol` — the typed contract surface: the per-market config pointer and dedup cache, `setMarketCurveParams`, the `owner` and `manager` addresses (`transferOwnership`/`setManager`), and the inherited `IIrm` interface.
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol` — the per-market config contract surface (`getCurveParams()` and the per-field getters).
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol` — the shared top-level `AdaptiveCurveParams` struct.
- `src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol` — the periphery recompute library described above.

## LinearKinkIrm

### Overview

`LinearKinkIrm` is the second IRM of this fork — fork-only, with no upstream counterpart (it replaces the removed upstream `FixedRateIrm`). It is the classic kinked ("jump rate") model of Compound's `JumpRateModel`, Aave's default reserve strategy, and Euler's `IRMLinearKink`: the per-second borrow rate is a piecewise-linear function of the market's current utilization that steepens past a kink at `optimalUtilization`.

Unlike `AdaptiveCurveIrm`, the model is **stateless**: the rate depends only on the utilization Morpho passes in and the market's stored parameters. Nothing adapts over time, `borrowRate` writes nothing and returns exactly what `borrowRateView` returns, and when a rate should move, the owner or manager moves it by setting new parameters. One instance serves many markets keyed by `Id`, with authorization shared with `AdaptiveCurveIrm` through `OwnerManagerBase` and the same immutable, behind-the-router deployment (roles set at construction).

### The curve

With `U` the market's utilization (WAD-scaled), the returned per-second WAD rate is:

```
U = totalBorrowAssets / totalSupplyAssets        # 0 when totalSupplyAssets == 0; clamped to WAD

U <= optimalUtilization:   rate = baseRate + slope1 * U / optimalUtilization
U >  optimalUtilization:   rate = baseRate + slope1 + slope2 * (U - optimalUtilization) / (WAD - optimalUtilization)
```

- At zero utilization the rate is `baseRate`, at the kink exactly `baseRate + slope1`, and at full utilization exactly the peak `baseRate + slope1 + slope2`. The curve is continuous at the kink and non-decreasing in utilization.
- **The peak is the market's absolute rate ceiling.** Utilization is clamped to 100% (Morpho cannot exceed it, and the clamp also defends the public view against out-of-range inputs), and there is no adapting state, so the rate can never exceed `baseRate + slope1 + slope2`. The ceiling is the curve's own shape — no separate `maxBorrowRate` parameter is needed — to guarantee "never above X", choose parameters whose sum is X. The setter additionally bounds the peak by the contract-wide `MAX_BORROW_RATE` constant (800%/year), a fat-finger guard rather than an operating ceiling.
- Each leg rounds down twice (`wDivDown` on the utilization ratio, then `wMulDown` by the slope), so the returned rate never exceeds the ideal curve value — it equals its floor or falls a wei below it — and is exact at `U = 0`, the kink, and full utilization.
- Zero supply prices as zero utilization: an empty market charges `baseRate`.

### Configuration

Each market's four parameters are packed into a single storage slot (`LinearKinkParams`, 4×`uint64`, per-second WAD rates — `uint64` holds any rate up to `MAX_BORROW_RATE` losslessly):

| Parameter | Validation |
| --- | --- |
| `optimalUtilization` (WAD) | in `(0, WAD)`, both ends exclusive |
| `baseRate`, `slope1`, `slope2` (WAD/s) | jointly: `baseRate + slope1 + slope2 <= MAX_BORROW_RATE` |

- **`setMarketKinkParams(marketParams, kinkParams)`** derives the market `id` from `marketParams`, validates, and overwrites the market's parameters in place, emitting `MarketKinkParamsSet`. The call is owner-or-manager gated (`not authorized` otherwise), with the same trust stance as `setMarketCurveParams`: validation guarantees well-formedness, not economic soundness.
- **Reparametrization is the same call.** There is no config contract and no dedup cache here — parameters are overwritten where they live, and because nothing adapts there is no state to carry across: the new curve prices the very next `borrowRate` in full. As in the adaptive model, the first call after a change applies the new parameters to the whole period since `market.lastUpdate` — to settle the old interval at the old curve, call `accrueInterest` immediately before changing.
- **An unconfigured market cannot be priced.** `optimalUtilization == 0` is the unset sentinel — validation makes it unreachable for a configured market — and `borrowRate`/`borrowRateView` revert with `config not set` until parameters are set.

### Deployment and authorization

The deployment stance is the shared one specified in the AdaptiveCurveIrm part above: an immutable standalone contract with the `OwnerManagerBase` roles set at construction (`owner` slot 0, `manager` slot 1), meant to sit behind `IrmRouter`, with upgradeability living in the router. The constructor takes only `(owner, manager)` — there is no `ROUTER` immutable and no caller gate to construct, since `borrowRate` is a read (see Trust Assumptions). This contract appends only `marketKinkParams[Id]` (slot 2). `MAX_BORROW_RATE` is a compile-time constant in the bytecode — changing it means a new implementation, routed in via the router.

### Trust Assumptions

The **owner** and **manager** hold the same power as in the adaptive model, in a more immediate form: `setMarketKinkParams` moves a market's rate discontinuously on the next call — bounded by `MAX_BORROW_RATE` — with no adapting state to smooth the change. As in the adaptive model there is no proxy admin and no upgrade path — replacing the logic means a new implementation routed in at the `IrmRouter`. The model never custodies funds.

Unlike the adaptive IRM, `borrowRate` is ungated: there is no state to protect, so it is a read, callable by anyone, and the router simply forwards to it. The contract depends on no external contract at all — the market state is passed in by value and the parameters live in its own storage.

### References

- `src/linear-kink-irm/interfaces/ILinearKinkIrm.sol` — the typed contract surface: `marketKinkParams(Id)`, `setMarketKinkParams`, `MAX_BORROW_RATE`, and the inherited `IIrm`/`IOwnerManager` interfaces.
- `src/linear-kink-irm/interfaces/ILinearKinkTypes.sol` — the packed `LinearKinkParams` struct.
- Compound's `JumpRateModel`, Euler's `IRMLinearKink`, Aave's `DefaultReserveInterestRateStrategy` — the model family — this contract is a from-scratch implementation, not a port of any of them.
- `TEST_PLAN.md` (§8) and `certora/specs/LinearKinkIrm.spec` — the test and formal-verification coverage of the properties above.

## IrmRouter

### Overview

A Morpho market can never change its `irm`, so markets are created pointing at `IrmRouter` — the fork's one eternal address. It implements the `IIrm` surface and forwards `borrowRate` / `borrowRateView` to a per-market implementation — `AdaptiveCurveIrm`, `LinearKinkIrm`, or any future `IIrm` — chosen by the router `owner` or `manager`. That indirection is what upgradeability means in this fork: the market keeps pricing through the same address while the rate model behind it can be switched, so a live market can migrate between models.

Implementations are standalone immutable contracts, called with a plain CALL (no delegatecall). Each holds its own per-market state and parameters, and a state-changing implementation must be constructed with its `ROUTER` immutable set to the router address so it accepts the router's calls (the stateless `LinearKinkIrm` has no such gate). `borrowRate` is Morpho-only (`not Morpho` otherwise) and `borrowRateView` is public, and both revert `irm not set` for a market that has not been routed. The mapping `marketIrm[Id]` can be re-pointed but never cleared (`setMarketIrm` rejects the zero address), so a market once routed always prices.

### Routing

Routing (and re-routing) a market is a single privileged call:

- **`setMarketIrm(marketParams, irm)`** requires `marketParams` to carry the router itself as its `irm` (the id commits to that field, so a mistyped address would route a phantom market), derives the market `id`, and, when the market is already live (`lastUpdate != 0`), first calls Morpho's `accrueInterest(marketParams)` — the period since the last update is settled at the **old** model's rate, so the new model prices only time after the switch — and then probes the new implementation with the exact call Morpho will make at the next accrual: `irm.borrowRate(marketParams, market)`, sent by the router itself. Only after the probe succeeds is `marketIrm[id]` stored and `MarketIrmSet` emitted. A not-yet-created market is routed **without touching the implementation**: there is nothing to accrue or brick, a probe would prematurely write a stateful model's `rateAtTarget` (a repeated pre-creation probe would then decay the seeded rate over the whole epoch), and `createMarket` performs the correct first-interaction ping itself, with `lastUpdate` freshly stamped.
- **The probe is the safety gate for live markets.** A routed implementation that reverts would brick every interaction with the market (Morpho accrues on each one), so a live-market switch reverts unless the implementation can actually price the market: an unconfigured market (`config not set`) and an implementation constructed with the wrong `ROUTER` (`not router`) both fail here. The ungated `borrowRateView` would not catch the second, which is why the probe is the state-changing call. When attaching a fresh `AdaptiveCurveIrm` to a live market, the probe also seeds the market's `rateAtTarget` (see Migration). For a not-yet-created market the same failures surface at `createMarket`, which reverts and creates nothing — a fail-safe, not a brick.
- **The call is owner-or-manager gated.** Like the parameter setters on the implementations, routing is the operational surface: the router `owner` or `manager` may call it (`not authorized` otherwise), while rotating the roles themselves stays owner-only.

Ordering for a **new** market: route it (`setMarketIrm`) and set the implementation's per-market config (`setMarketCurveParams` / `setMarketKinkParams`) in either order, then `createMarket` — market creation pings `borrowRate` through the router and reverts `irm not set` until the market is routed and `config not set` until the implementation is configured. Pre-creation routing is idempotent: re-routing any number of times writes no implementation state.

### Migration

The router settles the old model and probes the new one, but each implementation keeps its own per-market state, and that state is what a migration must mind:

- **Away from an `AdaptiveCurveIrm`.** The switch's `accrueInterest` closes the old model's period at its rate, and the old implementation's `rateAtTarget[id]` is left behind, frozen at its last value.
- **To a fresh `AdaptiveCurveIrm`.** The market is new to the implementation, so the first interaction seeds `rateAtTarget[id] = initialRateAtTarget` from the market's configured curve — the live-market probe for a migration, or `createMarket`'s own ping for a launch. To carry the previous rate across the migration, snapshot it and choose `initialRateAtTarget` equal to the snapshot when configuring the curve — adaptation then continues from where the old model left off instead of jumping.
- **Back to a previously-used `AdaptiveCurveIrm`.** Its `rateAtTarget[id]` still holds the value frozen when the market was routed away, and the probe resumes adaptation from that **stale** value, not from `initialRateAtTarget` (the seeding path runs only while the stored value is zero). To re-enter at a chosen rate, use a fresh `AdaptiveCurveIrm` instance per re-entry rather than reusing one with stale state.
- **`LinearKinkIrm`, either direction.** The model is stateless — the rate depends only on the passed-in utilization and the stored parameters — so it migrates seamlessly: nothing to seed, nothing to go stale, the configured curve prices the very next call in full.

### Upgradeable

The router — not the IRMs — is the proxied contract of this fork. Its only immutable is `MORPHO` (Morpho itself, read from the implementation's bytecode under `delegatecall`). Its storage sits at an ERC-7201 namespaced base slot (`layout at`, namespace `lido.lend.storage.IrmRouter`) and is only ever appended to: the `owner` (base) and the `manager` packed with the `isInitialized` flag (base + 1) come from the shared `OwnerManagerBase`, and the router appends `marketIrm[Id]` (base + 2) along with the flag itself. The constructor takes only `morpho` and writes no proxy storage besides marking the *implementation itself* initialized, so the `owner` and `manager` are set post-deployment via `initialize(owner, manager)` — a one-shot setter guarded on `isInitialized`, rejecting the zero address for either. Deployment is deploy-implementation, deploy-proxy, then `initialize` — the last two (or all three) executed **atomically** by the deploying script so the owner/manager slots cannot be front-run. A raw implementation can never be `initialize`d directly — only a freshly-deployed proxy (whose storage starts zeroed) can be, exactly once.

Changing the routing logic is a **proxy upgrade** to a freshly-constructed implementation. The proxy's storage — every market's `marketIrm` pointer and both addresses — persists across the swap. ERC-1967 impl/admin pointers sit in dedicated slots that never collide with the router's ERC-7201 namespaced storage. Any future storage field must be appended after `marketIrm`. The proxy lives in the product repo. Each implementation must be constructed with the correct `MORPHO` (and the first one initialized with the correct owner and manager), a deploy/upgrade invariant for governance to uphold.

### Trust Assumptions

**The core's IRM choice stops at the router.** LidoLend's `createMarket` is owner-gated and enables the market's `irm` implicitly, so the core owner chooses the router once, at market creation — and from then on the choice of implementation for every router-fronted market belongs to the router `owner`, forever. The core cannot constrain, vet, or revoke individual implementations. Creating markets on the router is a delegation of the per-market IRM choice to the router's governance, and integrators must evaluate that governance, not just the market's `irm` address.

**Router owner** (governance) holds authorization and the routing: it rotates itself (`transferOwnership`) and the `manager` (`setManager`), and can point any market at any `IIrm` in a single transaction (subject to the probe), swapping the market's entire rate model — and with it every future rate the market reads. The router never custodies funds — this is power over which model Morpho reads, not over deposits.

**Router manager** (operations) is scoped the same way as on the implementations: it may call `setMarketIrm` — route or re-route any market — but cannot change `owner` or `manager`. Its power over which model prices a market is the same as the owner's, and it is trusted accordingly: a routed implementation is arbitrary code the router calls on every accrual, bounded only by the probe.

**Proxy admin** (governance) is the ultimate authority: it can upgrade the router implementation, replacing the routing logic, and can overwrite any storage slot — including `owner`/`manager` and any `marketIrm` pointer — via that upgrade. This is the largest trust the design places, and it is deliberately concentrated here: the rate math in the implementations is immutable, so fixing an implementation bug means deploying a new implementation and migrating markets, never rewriting a model in place. Constraints on the admin and owner (timelock, governance) are operational and outside this spec. A truly fixed routing is reached only by ossifying the proxy.

**Morpho** is the only caller of state-changing `borrowRate`, while `borrowRateView` is public and read-only. The router depends only on Morpho (market state and accrual during a switch) and on the implementations it forwards to.

### References

- `src/irm-router/IrmRouter.sol` — the contract this part specifies.
- `src/irm-router/interfaces/IIrmRouter.sol` — the typed contract surface: `MORPHO()`, `marketIrm(Id)`, `setMarketIrm` (with the `MarketIrmSet` event), `isInitialized()`/`initialize`, and the inherited `IIrm` and `IOwnerManager` interfaces.
- `src/irm-router/libraries/ErrorsLib.sol` — the router's errors (`already initialized`, `not Morpho`, `irm not set`, `irm is not this router`).
- `TEST_PLAN.md` (§§6, 9) and `certora/specs/IrmRouter.spec` — the test and formal-verification coverage of the properties above.
