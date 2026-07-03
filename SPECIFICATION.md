# Lido Lend IRM — Specification

This document specifies the two interest rate models of this fork. [AdaptiveCurveIrm](#adaptivecurveirm) is the upstream Morpho adaptive model plus the Lido additions — per-market configuration, an owner and a manager, reparametrization, an optional borrow-rate cap, and upgradeability. [LinearKinkIrm](#linearkinkirm) is fork-only, with no upstream counterpart: a stateless kinked ("jump rate") model, specified here from scratch. Both inherit the same owner/manager/`initialize` base (`OwnerManagerBase`) and are meant to run behind a proxy.

## AdaptiveCurveIrm

### Overview

`AdaptiveCurveIrm` is the interest rate model (IRM) Morpho Blue calls to set a market's borrow rate. It maps utilization to a per-second rate through a curve whose height, `rateAtTarget`, is the rate charged at target utilization. That height adapts over time to pull utilization back toward the target, with no governance action required.

The curve and its adaptation are the [upstream Morpho model](https://github.com/morpho-org/morpho-blue-irm) (`morpho-org/morpho-blue-irm` @ `2bce6da`, `src/adaptive-curve-irm/AdaptiveCurveIrm.sol`), **unchanged** in this fork. Anything not specified in this document matches that source. Together with the Morpho whitepaper, it is the normative reference for the exact formulas. This document specifies only the additions of the Lido version:

- **per-market configuration** — the curve constants become a validated, immutable `AdaptiveCurveConfig` contract. The IRM keeps a per-market pointer to one and reads it through an external static call, so each market can define its own curve.
- **owner and manager** — two privileged addresses in storage: the `owner` manages authorization (rotates itself and the `manager`), and either the `owner` or the `manager` sets a market's curve via a single `setMarketCurveParams` call that deploys (or reuses) the config internally.
- **reparametrization** — the same call re-points a live market at a different curve without redeploying the market.
- **upgradeability** — the IRM is meant to run behind a proxy. The `owner` and `manager` live in storage (set via `initialize`, rotated via `transferOwnership`/`setManager`), while changing the logic is a proxy upgrade to a freshly-constructed implementation, and the per-market configs, `rateAtTarget`, and both addresses persist.
- an optional **borrow-rate cap** — a hard upper bound on the rate charged to borrowers, applied to the curve's output.

The `borrowRate` / `borrowRateView` interface is unchanged, so the model is a drop-in replacement. `borrowRate` is still Morpho-only and state-changing, and `borrowRateView` is still public and read-only.

### Configuration

Upstream, every market shares one curve, since its parameters are compile-time constants. Lido runs several markets that may each want a different curve, so the fork moves those constants into `AdaptiveCurveConfig` contracts — immutable holders of one curve's parameters, validated at construction — with a per-market pointer on the IRM (`marketCurveConfig[Id]`), read through an external static call (`getCurveParams()`) when pricing. The curve math that consumes them is byte-identical to upstream.

Setting (or changing) a market's curve is a single privileged call:

- **`setMarketCurveParams(marketParams, curveParams)`** derives the market `id` from `marketParams`, then resolves a config for `curveParams`: it deploys a fresh `AdaptiveCurveConfig(curveParams)` — whose constructor validates the parameters and reverts if any is out of range — unless a config for **identical** parameters was already deployed, in which case it reuses that one. The market is then pointed at the resolved config. Deployment and activation are a single step — there is no separate config-deployment surface.
- **The IRM deduplicates by parameter hash.** `deployedCurveConfigs[keccak256(abi.encode(curveParams))]` caches the canonical config for a param-set, so identical parameters resolve to one shared `AdaptiveCurveConfig` across markets and calls (an immutable config is safely shareable). The first deployment for a hash emits `ConfigDeployed`, and every set emits `MarketCurveParamsSet`.
- **The call is owner-or-manager gated.** `setMarketCurveParams` is callable only by the IRM `owner` or `manager` (storage variables, see Upgradeable), reverting `not authorized` otherwise. The IRM does not gate *which* parameters — it trusts the caller (governance / an operator) to choose an appropriate curve — validation guarantees only well-formedness, not economic soundness. This mirrors how Euler V2 gates its rate-model setter to the vault governor. A market with `marketCurveConfig == address(0)` is simply unpriced (reverts `config not set`) until set.

| Parameter | Validation |
| --- | --- |
| `curveSteepness` (WAD) | in `[WAD, 100*WAD]` |
| `adjustmentSpeed` (WAD/s) | in `[0, ~10000/year]` |
| `targetUtilization` (WAD) | in `(0, WAD)` |
| `initialRateAtTarget` (WAD/s) | in `[minRateAtTarget, maxRateAtTarget]` |
| `minRateAtTarget` (WAD/s) | `> 0` |
| `maxRateAtTarget` (WAD/s) | in `[minRateAtTarget, ~1e6%/year]` |
| `maxBorrowRate` (WAD/s) | unvalidated (`0` = disabled) |

These bounds keep the curve math inside its non-overflowing range, so `borrowRate` runs without reverting and returns a non-negative rate. They only guarantee that the market works, not that the curve makes economic sense. The caller can choose any values inside the bounds.

A market with no config set cannot be priced: `borrowRate` / `borrowRateView` revert with `config not set` until the owner or manager has set one. Morpho's `createMarket` itself calls `borrowRate` to initialize the IRM, so a market using this IRM cannot even be created until its curve is set.

### Reparametrization

Upstream a deployment's curve cannot change. In the fork, the owner or manager reparametrizes a live market by calling `setMarketCurveParams(marketParams, newCurveParams)` again: the IRM deploys (or reuses) the config for the new parameters and re-points the market at it. The market's `rateAtTarget` is untouched by the swap and keeps adapting from where it was. There is no in-place parameter setter — an `AdaptiveCurveConfig` is itself immutable, so changing a curve always means resolving a (new or cached) config and re-pointing.

The new parameters take effect on the **next** `borrowRate` call, where they can shift the rate:

| New parameter | Effect on the next call | Timing |
| --- | --- | --- |
| `maxBorrowRate` | borrow rate limited to the new cap, `rateAtTarget` untouched | immediate, even at target |
| `curveSteepness` | new slope: the same `rateAtTarget` and utilization give a different borrow rate | immediate |
| `targetUtilization` | the error is recomputed for the same utilization, so the rate shifts | immediate |
| `minRateAtTarget` / `maxRateAtTarget` | the new bound snaps the saved `rateAtTarget` into the new range | lazy (see below) |
| `adjustmentSpeed` | changes the speed of future adaptation | gradual |

Only a change to the `minRateAtTarget` / `maxRateAtTarget` bounds can move the stored `rateAtTarget` discontinuously. When the new range still contains the stored value (for instance, a widened range), adaptation continues from where it was, with no jump. When the range is **narrowed** below the current value, the next adapting call snaps `rateAtTarget` to the nearest new bound in one step. The size of that jump is the gap between the old value and the new bound, which the caller sets by choosing the bound.

The graph illustrates both: a new range that still contains the stored `rateAtTarget` (smooth), and a new `maxRateAtTarget` below it (snap down).

![Reparametrizing the rate-at-target bounds: smooth vs. snap](assets/upgrading-rate-target.png)

Two more things to know about a reparametrization:

* **The re-clamp is lazy.** `rateAtTarget` is re-clamped into the new range only on a call where utilization is off target **and** time has elapsed. Pointing a market at a tighter range followed by an at-target (or same-block) call leaves `rateAtTarget` out of range, used unchanged, until a later off-target call snaps it in. `maxBorrowRate` is the only bound that applies immediately in that interval.
* **The new parameters apply to the whole period since the last update.** The first `borrowRate` after a swap averages over the entire interval since `market.lastUpdate`, which may precede the swap — old and new parameters are not blended at the swap timestamp. To settle the pre-reparametrization interval at the old parameters, call `accrueInterest` immediately before swapping.

### Upgradeable

The IRM holds no curve parameters of its own. Its only immutable is `MORPHO` (read but never written). Its storage is laid out for a proxy and only ever appended to. The `owner` and `manager` come from the shared `OwnerManagerBase`, so they occupy the first slots: the `owner` (slot 0) and the `manager` packed with the `isInitialized` flag (slot 1). The IRM appends its own fields after them: the adapting `rateAtTarget[Id]` (slot 2), the per-market config pointer `marketCurveConfig[Id]` (slot 3), and the dedup cache `deployedCurveConfigs[hash]` (slot 4). The constructor takes only `morpho` and writes no proxy storage besides marking the *implementation itself* initialized (see below), so the `owner` and `manager` are set post-deployment via `initialize(owner, manager)` — a one-shot setter guarded on `isInitialized`, rejecting the zero address for either.

A single implementation sits behind an upgradeable **proxy**: `MORPHO` comes from the implementation's bytecode under `delegatecall`, and the storage belongs to the proxy. Deployment is deploy-implementation, deploy-proxy, then `initialize` — the last two (or all three) executed **atomically** by the deploying script so the owner/manager slots cannot be front-run. The constructor sets `isInitialized = true` on the implementation's own storage, so a raw implementation can never be `initialize`d directly — only a freshly-deployed proxy (whose storage starts zeroed) can be initialized, exactly once.

Two privileged addresses live in storage:

- **`owner`** — rotates itself via `transferOwnership` and the manager via `setManager` (both owner-only, both rejecting the zero address, emitting `OwnershipTransferred` / `ManagerSet`), and may call `setMarketCurveParams`.
- **`manager`** — an operational address that may call `setMarketCurveParams` (day-to-day curve setting) but holds no power over `owner`/`manager` themselves.

Changing the curve logic is a **proxy upgrade** to a freshly-constructed implementation. The proxy's storage (every market's config pointer, the dedup cache, `rateAtTarget`, and both addresses) persists across the swap. The **proxy admin** remains the ultimate authority — it can overwrite any slot, including `owner`/`manager`, by upgrading — so a truly fixed owner and logic are reached only by ossifying the proxy. ERC-1967 impl/admin pointers sit in dedicated (keccak-derived) slots that never collide with the sequential storage slots. Any future storage field must be appended after `deployedCurveConfigs`. The proxy lives in the product repo. Each implementation must be constructed with the correct `MORPHO` and initialized with the correct owner and manager, a deploy/upgrade invariant for governance to uphold.

### Borrow-rate cap

Upstream puts no ceiling on the charged rate. Above target the curve multiplies `rateAtTarget` by up to `curveSteepness`. With `curveSteepness` 4 and 4%/year at target, the rate runs from 1%/year at zero utilization to 16%/year at full utilization, and climbs further as `rateAtTarget` adapts toward `maxRateAtTarget`. The fork adds an optional hard ceiling on what a borrower can be charged, applied to the **output** returned to Morpho:

```
returned = min( curveRate,  maxBorrowRate )      # only when maxBorrowRate != 0
```

The cap only clamps the returned value and never touches the stored `rateAtTarget`. Adaptation responds to the utilization error rather than the current rate, so clamping `rateAtTarget` would interfere with the control loop, while clamping the output leaves it running exactly as upstream. The state machine behaves the same whether the cap is on or off, and raising or removing the cap (by re-pointing the market at a new config) brings the borrow rate straight back to the curve value on the next call.

The cap clips the high-utilization peak of the curve, or the whole curve if it sits below `rateAtTarget`. Setting `maxBorrowRate` to 0 turns it off. A cap below the curve's operating range makes the market effectively interest-free — that is what the chosen value does, and avoiding it is on the caller, not a contract defect.

With an `8%/year` cap on the same curve, the charged rate follows the curve, then holds flat where it would otherwise exceed the cap.

![Borrow-rate cap: charged = min(curve, maxBorrowRate)](assets/borrow-rate-cap.png)

### Periphery library

`AdaptiveCurveIrmLib` recomputes `borrowRateView` and `expectedMarketBalances` from a market `Id` alone, for integrators that hold the id rather than the full `MarketParams`. Because each market's curve is read from its own `AdaptiveCurveConfig` (which the owner/manager can re-point), it differs from upstream in two ways:

- it resolves the market's config from the IRM (`marketCurveConfig(id)`) and reads it **live from that `AdaptiveCurveConfig`** (via `getCurveParams()`), tracking whichever config the market currently points at, and applies the same cap, reverting with `config not set` when none is set (mirroring the IRM).
- its results are **market-specific**, per the current `AdaptiveCurveConfig`, and must be queried with the market's actual `AdaptiveCurveIrm` address and `Id`.
- equivalence to the contract is **proven in Certora**, for both the returned values and the revert conditions.

### Trust Assumptions

This section states what each actor can do to the model. Who holds each, and through what process it acts, is a governance matter outside this spec.

**IRM owner** (governance) holds authorization and the curve: it rotates itself (`transferOwnership`) and the manager (`setManager`), and can set or re-point any market's curve (`setMarketCurveParams`), swapping its entire curve — and with it every future rate the market reads — in a single transaction, with `rateAtTarget` carrying across the swap. The owner is trusted to choose well-formed parameters (the config constructor's validation ensures `borrowRate` neither reverts nor returns a negative rate) and to judge whether a curve is economically sound and `maxBorrowRate` set sensibly. The model never custodies funds, so this is power over the rate Morpho reads, not over deposits.

**IRM manager** (operations) is scoped: it may call `setMarketCurveParams` — set or reparametrize any market's curve — but cannot change `owner` or `manager` (`transferOwnership`/`setManager` are owner-only). It exists so day-to-day curve tuning need not use the owner key. Its power over rates is the same as the owner's — it simply cannot change authorization.

**Proxy admin** (governance) is the ultimate authority: it can upgrade the implementation, replacing the curve logic, and can overwrite any storage slot — including `owner`/`manager` — via that upgrade, while the per-market configs and `rateAtTarget` persist. This is the largest trust the design places. Constraints on the admin, owner, and manager (timelock, governance) are operational and outside this spec. A truly fixed owner and logic are reached only by ossifying the proxy.

**Morpho** is the only caller of state-changing `borrowRate`, while `borrowRateView` is public and read-only. The model has no other privileged caller, and it depends on no external contract beyond the Morpho market that calls it and the `AdaptiveCurveConfig` it reads through a static call.

### References

- Upstream IRM source at `morpho-org/morpho-blue-irm` @ `2bce6da` and the Morpho whitepaper — normative for the curve and its adaptation.
- `FORK_NOTES.md` — the fork point and the full per-file delta against upstream.
- `src/common/OwnerManagerBase.sol` (with `IOwnerManager.sol` and `OwnerManagerErrors.sol`) — the shared owner/manager/`initialize` base both IRMs inherit — normative for the authorization and initialization semantics this document describes.
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol` — the typed contract surface: the per-market config pointer and dedup cache, `setMarketCurveParams`, the `owner` and `manager` addresses (`initialize`/`transferOwnership`/`setManager`), and the inherited `IIrm` interface.
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol` — the config contract surface (`getCurveParams()` and the per-field getters).
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol` — the shared top-level `AdaptiveCurveParams` struct.
- `src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol` — the periphery recompute library described above.

## LinearKinkIrm

### Overview

`LinearKinkIrm` is the second IRM of this fork — fork-only, with no upstream counterpart (it replaces the removed upstream `FixedRateIrm`). It is the classic kinked ("jump rate") model of Compound's `JumpRateModel`, Aave's default reserve strategy, and Euler's `IRMLinearKink`: the per-second borrow rate is a piecewise-linear function of the market's current utilization that steepens past a kink at `optimalUtilization`.

Unlike `AdaptiveCurveIrm`, the model is **stateless**: the rate depends only on the utilization Morpho passes in and the market's stored parameters. Nothing adapts over time, `borrowRate` writes nothing and returns exactly what `borrowRateView` returns, and when a rate should move, the owner or manager moves it by setting new parameters. One instance serves many markets keyed by `Id`, with authorization, `initialize`, and the proxy model shared with `AdaptiveCurveIrm` through `OwnerManagerBase`.

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

### Upgradeable

Authorization, `initialize`, the implementation lock, and the proxy model are the shared `OwnerManagerBase` semantics specified in the AdaptiveCurveIrm part above (`owner` slot 0, `manager` packed with `isInitialized` slot 1). This contract appends only `marketKinkParams[Id]` (slot 2), and any future field after it. There is no `MORPHO` immutable and no constructor argument: the constructor only locks the implementation. `MAX_BORROW_RATE` is a compile-time constant in the implementation bytecode — changing it is a logic upgrade.

### Trust Assumptions

The **owner** and **manager** hold the same power as in the adaptive model, in a more immediate form: `setMarketKinkParams` moves a market's rate discontinuously on the next call — bounded by `MAX_BORROW_RATE` — with no adapting state to smooth the change. The **proxy admin** remains the ultimate authority, as above. The model never custodies funds.

Unlike the adaptive IRM, `borrowRate` is not Morpho-gated: there is no state to protect, so it is a read, callable by anyone, and Morpho's accrual simply reads it through the `IIrm` interface. The contract depends on no external contract at all — the market state is passed in by value and the parameters live in its own storage.

### References

- `src/linear-kink-irm/interfaces/ILinearKinkIrm.sol` — the typed contract surface: `marketKinkParams(Id)`, `setMarketKinkParams`, `MAX_BORROW_RATE`, and the inherited `IIrm`/`IOwnerManager` interfaces.
- `src/linear-kink-irm/interfaces/ILinearKinkTypes.sol` — the packed `LinearKinkParams` struct.
- Compound's `JumpRateModel`, Euler's `IRMLinearKink`, Aave's `DefaultReserveInterestRateStrategy` — the model family — this contract is a from-scratch implementation, not a port of any of them.
- `TEST_PLAN.md` (§7) and `certora/specs/LinearKinkIrm.spec` — the test and formal-verification coverage of the properties above.
