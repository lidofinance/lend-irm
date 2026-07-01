# AdaptiveCurveIrm

## Overview

`AdaptiveCurveIrm` is the interest rate model (IRM) Morpho Blue calls to set a market's borrow rate. It maps utilization to a per-second rate through a curve whose height, `rateAtTarget`, is the rate charged at target utilization. That height adapts over time to pull utilization back toward the target, with no governance action required.

The curve and its adaptation are the [upstream Morpho model](https://github.com/morpho-org/morpho-blue-irm) (`morpho-org/morpho-blue-irm` @ `2bce6da`, `src/adaptive-curve-irm/AdaptiveCurveIrm.sol`), **unchanged** in this fork. Anything not specified in this document matches that source; it and the Morpho whitepaper are the normative reference for the exact formulas. This document specifies only the additions of the Lido version:

- **per-market configuration** — the curve constants become a validated, immutable `AdaptiveCurveConfig` contract; the IRM keeps a per-market pointer to one and reads it through an external static call, so each market can define its own curve;
- **reparametrization** — the IRM owner can point a market at a different config, changing its curve without redeploying the market;
- **upgradeability** — the IRM is meant to run behind a proxy; the owner lives in storage (set via `initialize`, transferred via `transferOwnership`), while changing the logic is a proxy upgrade to a freshly-constructed implementation, and the per-market configs, `rateAtTarget`, and owner persist;
- an optional **borrow-rate cap** — a hard upper bound on the rate charged to borrowers, applied to the curve's output.

The `borrowRate` / `borrowRateView` interface is unchanged, so the model is a drop-in replacement. `borrowRate` is still Morpho-only and state-changing; `borrowRateView` is still public and read-only.

## Configuration

Upstream, every market shares one curve, since its parameters are compile-time constants. Lido runs several markets that may each want a different curve, so the fork moves those constants into a per-market `AdaptiveCurveConfig`: an immutable contract holding one curve's parameters, validated at construction. The IRM keeps a per-market pointer `config[Id] => address` and, when pricing a market, reads its parameters through an external static call (`AdaptiveCurveConfig.getCurveParams()`). The curve math that consumes them is byte-identical to upstream.

Two privileges are deliberately separated:

- **Deploying a config carries no power.** A `AdaptiveCurveConfig` is an inert, validated data holder; anyone may deploy one. The `AdaptiveCurveConfigFactory` is a **permissionless** deployer: `createConfig(cfg)` deploys an `AdaptiveCurveConfig` (whose constructor validates the parameters and reverts if any is out of range), or returns the existing config when identical params were already deployed (dedup — one canonical config per param-set). It records provenance under the params hash, `configFor[keccak256(abi.encode(cfg))]` — a record kept for off-chain/periphery verification, not consumed on-chain.
- **Activating a config for a market is owner-gated.** `IRM.setConfig(id, config)` is callable only by the IRM `owner` (a storage variable, see Upgradeable). The IRM does not gate which config — it trusts the owner (governance) to point a market at an appropriate `AdaptiveCurveConfig`. This mirrors how Euler V2 gates its rate-model setter to the vault governor and leaves config provenance to a separate periphery layer. A market with `config == address(0)` is simply unpriced (reverts `config not set`) until set.

| Parameter | Validation |
| --- | --- |
| `curveSteepness` (WAD) | in `[WAD, 100*WAD]` |
| `adjustmentSpeed` (WAD/s) | in `[0, ~10000/year]` |
| `targetUtilization` (WAD) | in `(0, WAD)` |
| `initialRateAtTarget` (WAD/s) | in `[minRateAtTarget, maxRateAtTarget]` |
| `minRateAtTarget` (WAD/s) | `> 0` |
| `maxRateAtTarget` (WAD/s) | in `[minRateAtTarget, ~1e6%/year]` |
| `maxBorrowRate` (WAD/s) | `>= 0` (`0` = disabled) |

These bounds keep the curve math inside its non-overflowing range, so `borrowRate` runs without reverting and returns a non-negative rate. They only guarantee that the market works, not that the curve makes economic sense. The deployer can choose any values inside the bounds.

A market with no config set cannot be priced: `borrowRate` / `borrowRateView` revert with `config not set` until the owner has set one. In practice the owner sets a market's config before the market is used.

## Reparametrization

Upstream a deployment's curve cannot change. In the fork, the owner reparametrizes a live market by pointing it at a new config: deploy a fresh immutable `AdaptiveCurveConfig` (via the factory) and call `setConfig(id, newConfig)`. The market's `rateAtTarget` is untouched by the swap; it keeps adapting from where it was. There is no parameter setter — an `AdaptiveCurveConfig` is itself immutable, so changing a curve always means deploying a new config and re-pointing.

The new parameters take effect on the **next** `borrowRate` call, where they can shift the rate:

| New parameter | Effect on the next call | Timing |
| --- | --- | --- |
| `maxBorrowRate` | borrow rate limited to the new cap, `rateAtTarget` untouched | immediate, even at target |
| `curveSteepness` | new slope: the same `rateAtTarget` and utilization give a different borrow rate | immediate |
| `targetUtilization` | the error is recomputed for the same utilization, so the rate shifts | immediate |
| `minRateAtTarget` / `maxRateAtTarget` | the new bound snaps the saved `rateAtTarget` into the new range | lazy (see below) |
| `adjustmentSpeed` | changes the speed of future adaptation | gradual |

Only a change to the `minRateAtTarget` / `maxRateAtTarget` bounds can move the stored `rateAtTarget` discontinuously. When the new range still contains the stored value (for instance, a widened range), adaptation continues from where it was, with no jump. When the range is **narrowed** below the current value, the next adapting call snaps `rateAtTarget` to the nearest new bound in one step; the size of that jump is the gap between the old value and the new bound, which the owner sets by choosing the bound.

The graph illustrates both: a new range that still contains the stored `rateAtTarget` (smooth), and a new `maxRateAtTarget` below it (snap down).

![Reparametrizing the rate-at-target bounds: smooth vs. snap](assets/upgrading-rate-target.png)

Two more things to know about a reparametrization:

* **The re-clamp is lazy.** `rateAtTarget` is re-clamped into the new range only on a call where utilization is off target **and** time has elapsed. Pointing a market at a tighter range followed by an at-target (or same-block) call leaves `rateAtTarget` out of range, used unchanged, until a later off-target call snaps it in. `maxBorrowRate` is the only bound that applies immediately in that interval.
* **The new parameters apply to the whole period since the last update.** The first `borrowRate` after a swap averages over the entire interval since `market.lastUpdate`, which may precede the swap; old and new parameters are not blended at the swap timestamp. To settle the pre-reparametrization interval at the old parameters, call `accrueInterest` immediately before swapping.

## Upgradeable

The IRM holds no curve parameters of its own. Its only immutable is `MORPHO` (read but never written); its storage is the adapting `rateAtTarget[Id]` (slot 0, as upstream), the per-market config pointer `config[Id]` (slot 1), and the `owner` (slot 2, appended after `config`). The constructor takes only `morpho` and writes no proxy storage, so the owner is set post-deployment via `initialize(owner)` — a one-shot setter guarded on `owner == address(0)`. A single implementation sits behind an upgradeable **proxy**: `MORPHO` comes from the implementation's bytecode under `delegatecall`, and the storage belongs to the proxy. Deployment is deploy-implementation, deploy-proxy, then `initialize` — the last two (or all three) executed **atomically** by the deploying factory/script so the owner slot cannot be front-run.

The owner is rotated in place via `transferOwnership` (owner-only, rejects the zero address); no upgrade is needed. Changing the curve logic is a **proxy upgrade** to a freshly-constructed implementation; the proxy's storage (every market's config pointer, `rateAtTarget`, and the owner) persists across the swap. The **proxy admin** remains the ultimate authority — it can overwrite any slot, including the owner, by upgrading — so a truly fixed owner and logic are reached only by ossifying the proxy. ERC-1967 impl/admin pointers sit in dedicated slots that never collide with slot 0, the config pointer, or the owner; any future storage field must be appended after `owner`. The proxy lives in the product repo. Each implementation must be constructed with the correct `MORPHO` and initialized with the correct owner, a deploy/upgrade invariant for governance to uphold.

## Borrow-rate cap

Upstream puts no ceiling on the charged rate. Above target the curve multiplies `rateAtTarget` by up to `curveSteepness`; with `curveSteepness` 4 and 4%/year at target, the rate runs from 1%/year at zero utilization to 16%/year at full utilization, and climbs further as `rateAtTarget` adapts toward `maxRateAtTarget`. The fork adds an optional hard ceiling on what a borrower can be charged, applied to the **output** returned to Morpho:

```
returned = min( curveRate,  maxBorrowRate )      # only when maxBorrowRate != 0
```

The cap only clamps the returned value and never touches the stored `rateAtTarget`. Adaptation responds to the utilization error rather than the current rate, so clamping `rateAtTarget` would interfere with the control loop, while clamping the output leaves it running exactly as upstream. The state machine behaves the same whether the cap is on or off, and raising or removing the cap (by pointing the market at a new config) brings the borrow rate straight back to the curve value on the next call.

The cap clips the high-utilization peak of the curve, or the whole curve if it sits below `rateAtTarget`. Setting `maxBorrowRate` to 0 turns it off. A cap below the curve's operating range makes the market effectively interest-free; that is what the chosen value does, and avoiding it is on the deployer, not a contract defect.

With an `8%/year` cap on the same curve, the charged rate follows the curve, then holds flat where it would otherwise exceed the cap.

![Borrow-rate cap: charged = min(curve, maxBorrowRate)](assets/borrow-rate-cap.png)

## Periphery library

`AdaptiveCurveIrmLib` recomputes `borrowRateView` and `expectedMarketBalances` from a market `Id` alone, for integrators that hold the id rather than the full `MarketParams`. Because each market's curve is read from its own `AdaptiveCurveConfig` (which the owner can re-point), it differs from upstream in three ways:

- it resolves the market's config from the IRM (`config(id)`) and reads it **live from that `AdaptiveCurveConfig`** (via `getCurveParams()`), tracking whichever config the market currently points at, and applies the same cap; it reverts with `config not set` when none is set, mirroring the IRM;
- its results are **market-specific**, per the current `AdaptiveCurveConfig`, and must be queried with the market's actual `AdaptiveCurveIrm` address and `Id`;
- equivalence to the contract is **proven in Certora**, for both the returned values and the revert conditions.

## Trust Assumptions

This section states what each actor can do to the model. Who holds each role, and through what process it acts, is a governance matter outside this spec.

**IRM owner** (governance) chooses each market's `AdaptiveCurveConfig` and can re-point a market at any time, swapping its entire curve — and with it every future rate the market reads — in a single transaction; `rateAtTarget` carries across the swap. The owner is trusted to point a market only at a well-formed `AdaptiveCurveConfig` (one produced by the factory, or any contract whose constructor ran the same validation — so `borrowRate` neither reverts nor returns a negative rate); the IRM does not re-check this on `setConfig`. Whether a chosen curve is economically sound, and whether `maxBorrowRate` is set sensibly, is the owner's judgment. The model never custodies funds, so this is power over the rate Morpho reads, not over deposits.

**Proxy admin** (governance) is the ultimate authority: it can upgrade the implementation, replacing the curve logic, and can overwrite any storage slot — including the `owner` — via that upgrade, while the per-market configs and `rateAtTarget` persist. This is the largest trust the design places. Constraints on the admin and the owner (timelock, governance) are operational and outside this spec; a truly fixed owner and logic are reached only by ossifying the proxy.

**Config deployers** are unprivileged: anyone may deploy an `AdaptiveCurveConfig` (through the factory or directly), but a deployed config is inert until the owner points a market at it. The factory's `configFor` record exists for off-chain/periphery verification of a config's provenance, not as an on-chain gate.

**Morpho** is the only caller of state-changing `borrowRate`; `borrowRateView` is public and read-only. The model has no other privileged caller, and it depends on no external contract beyond the Morpho market that calls it and the `AdaptiveCurveConfig` it reads through a static call.

## References

- Upstream IRM source at `morpho-org/morpho-blue-irm` @ `2bce6da` and the Morpho whitepaper — normative for the curve and its adaptation.
- `FORK_NOTES.md` — the fork point and the full per-file delta against upstream.
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol` — the typed contract surface: the per-market config pointer, `setConfig`, `owner`/`initialize`/`transferOwnership`, and the inherited `IIrm` interface.
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol` — the `Params` struct and the per-market config contract surface.
- `src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfigFactory.sol` — the permissionless factory that deploys configs and records their provenance.
- `src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol` — the periphery recompute library described above.
