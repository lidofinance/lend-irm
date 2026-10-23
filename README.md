# Lido Lend IRMs

This repository is a fork of [Morpho Blue IRMs](https://github.com/morpho-org/morpho-blue-irm) that provides two interest-rate models (IRMs), a router that lets each live market change its selected implementation, and an optional factory for immutable parameter contracts. [FORK_NOTES.md](FORK_NOTES.md) records the exact fork point and source delta.

A LidoLend market stores its IRM address permanently in `MarketParams`. Markets using this package store the `IrmRouter` address there. The router keeps that market-facing address stable and selects the current model for each market. [SPECIFICATION.md](SPECIFICATION.md#runtime-topology) shows the complete runtime topology.

## Contracts

| Contract | Purpose |
| --- | --- |
| [`IrmRouter`](src/irm-router/IrmRouter.sol) | Proxied market-facing IRM. The owner or manager selects one implementation per market. |
| [`AdaptiveCurveIrm`](src/adaptive-curve-irm/AdaptiveCurveIrm.sol) | Stateful fork of Morpho's adaptive model with per-market parameters and an optional `maxBorrowRate` cap. It reads a selected config on every pricing call. |
| [`LinearKinkIrm`](src/linear-kink-irm/LinearKinkIrm.sol) | Non-adapting piecewise-linear replacement for upstream `FixedRateIrm`. It copies config values into per-market storage when the config is applied. |
| [`AdaptiveCurveConfig`](src/adaptive-curve-irm/AdaptiveCurveConfig.sol) | Included immutable and constructor-validated Adaptive config. |
| [`LinearKinkConfig`](src/linear-kink-irm/LinearKinkConfig.sol) | Included immutable and constructor-validated LinearKink config. |
| [`IrmConfigFactory`](src/irm-config-factory/IrmConfigFactory.sol) | Optional permissionless factory that deploys or reuses the included immutable configs. It is not an allowlist. |

Both IRMs implement `IConfigurableIrm`, expose the same owner-or-manager-gated `applyIrmConfig(MarketParams,address)` ABI, and emit `IrmConfigApplied`. They accept any ABI-compatible config and do not require it to come from the factory. The IRMs do not semantically validate returned parameters: the authorized caller guarantees their validity, including on every later Adaptive read.

## Deployment and market setup

Deploy the shared contracts once:

1. Deploy `IrmRouter(core)`, then deploy its proxy and pass `initialize(owner, manager)` as the proxy's initialization calldata so initialization is atomic. The core and both roles must be non-zero.
2. Deploy `AdaptiveCurveIrm(router, owner, manager)` and/or `LinearKinkIrm(owner, manager)`. Adaptive accepts state-changing pricing calls only from `router`; the router and both IRM roles must be non-zero.
3. Optionally deploy `IrmConfigFactory` for reusable immutable configs.

For a new router-fronted market:

1. Build `MarketParams` with `irm` set to the router address. This field is part of the market id.
2. Apply a config to the selected IRM. A config may come from `IrmConfigFactory` or another compatible contract.
3. Route the market to that IRM with `setMarketIrm`.
4. Create the market in LidoLend. Config application and routing may happen in either order before creation.

For a live market, `setMarketIrm` asks the core to accrue interest, probes the new implementation against the latest market state, and stores the new route only if the probe succeeds. The old route prices the elapsed interval when time has advanced since the previous market update.

## Choose a model

| Property | AdaptiveCurveIrm | LinearKinkIrm |
| --- | --- | --- |
| Rate state | Adapting `rateAtTarget` per market | No adapting state |
| Config use | Stores a config address and reads it on every price calculation | Copies four values when `applyIrmConfig` runs |
| State-changing `borrowRate` | Router-only | View-only and ungated |
| Reconfiguration | New values affect pricing and may clamp stored `rateAtTarget` | New values replace the stored snapshot |
| Migration back to a used instance | Resumes its stored `rateAtTarget` | Uses its current copied parameters |

## Start here

- [SPECIFICATION.md](SPECIFICATION.md) defines market identity, setup, routing, exact model math, reconfiguration, storage, and trust assumptions.
- [FORK_NOTES.md](FORK_NOTES.md) records the fork point and source delta from Morpho Blue IRMs.
- [TEST_PLAN.md](TEST_PLAN.md) maps requirements to Foundry and Certora checks.
- [SECURITY.md](SECURITY.md) gives the private vulnerability-reporting route.

The core interfaces come from [LidoLend](https://github.com/lidofinance/lend), pinned as the `lib/lido-lend` submodule. The [`lend-markets`](https://github.com/lidofinance/lend-markets) product repository deploys the router proxy and assigns operational roles.

## Development

The repository uses [Foundry](https://www.getfoundry.sh/introduction/installation) with Solidity 0.8.36 pinned in [foundry.toml](foundry.toml).

From a checkout, initialize the submodules and run the suite:

```sh
git submodule update --init --recursive
forge test
```

For larger local campaigns: `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_INVARIANT_RUNS=4096 forge test`.

Run a proof with `certoraRun certora/confs/<Name>.conf`. Certora runs require the Certora CLI, an access key, and the compiler selected by each configuration. [TEST_PLAN.md](TEST_PLAN.md#7-formal-verification) records the modeled properties and proof-evidence boundary.

## Audits

Audit reports for Morpho Blue IRMs are kept in the [upstream repository at the fork-point commit](https://github.com/morpho-org/morpho-blue-irm/tree/a1a87fd5a7ee13873ea9d2bbd87e9c7b2cdbbef3/audits). Each report covers only the commit and scope named in that report. None of them covers later upstream changes or the Lido fork changes.

Lido publishes its own audit reports in the [lidofinance/audits](https://github.com/lidofinance/audits) repository.

## License

The local IRM sources use `MIT`. Imported LidoLend interfaces and libraries keep their own `GPL-2.0-or-later` SPDX headers. See [LICENSE](LICENSE) for the repository license terms.
