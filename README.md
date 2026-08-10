# Lido Lend IRMs

Interest rate models for Lido Lend, the router that fronts them, and a permissionless factory for their immutable configs. This is a fork of [Morpho Blue IRM](https://github.com/morpho-org/morpho-blue-irm); the fork point, per-file footprint, and change record are in [FORK_NOTES.md](FORK_NOTES.md).

A Lido Lend market cannot change its `irm` after creation. Markets using this package therefore point at the proxied `IrmRouter`, which keeps the market-facing address stable while forwarding rate queries to a switchable per-market implementation: market → `IrmRouter` → `marketIrm[id]` → `AdaptiveCurveIrm` (reading its market's config) or `LinearKinkIrm`.

- [IrmRouter](src/irm-router/IrmRouter.sol) — the proxied `IIrm` used as the market-facing address. The router owner or manager routes each market to an implementation through `setMarketIrm`, so a live market can migrate between rate models. The supplied IRMs are non-upgradeable: routing-logic changes use a proxy upgrade, while rate-math changes require a new IRM implementation and migration.
- [AdaptiveCurveIrm](src/adaptive-curve-irm/AdaptiveCurveIrm.sol) — upstream Morpho's adaptive model with the curve math unchanged, but the hardcoded curve constants become per-market parameters supplied by config contracts, plus an optional `maxBorrowRate` cap. The IRM keeps the selected config address and reads it while pricing. [AdaptiveCurveConfig](src/adaptive-curve-irm/AdaptiveCurveConfig.sol) is an included immutable, constructor-validated implementation, not a required concrete type.
- [LinearKinkIrm](src/linear-kink-irm/LinearKinkIrm.sol) — a piecewise-linear kinked ("jump rate") model with no adapting state, replacing upstream's `FixedRateIrm`. [LinearKinkConfig](src/linear-kink-irm/LinearKinkConfig.sol) is an included immutable, constructor-validated implementation, not a required concrete type; the IRM copies the four returned parameters into packed per-market storage.
- [IrmConfigFactory](src/irm-config-factory/IrmConfigFactory.sol) — an optional permissionless factory for the included config implementations. Its get-or-deploy functions index each model separately by `keccak256(abi.encode(params))`; a cache miss deploys the concrete config, whose constructor performs validation, while a cache hit returns the existing address. Typed getters resolve a config address directly from its parameter struct.

Both implementations inherit the same owner-or-manager-gated `IConfigurableIrm.applyIrmConfig(MarketParams,address)` ABI and emit `IrmConfigApplied`. Their runtime representations differ: Adaptive stores the config address and reads it on every rate calculation, so that contract must return valid parameters on every read; LinearKink copies a parameter snapshot on each application and never calls the config while pricing. Config deployment remains outside both IRMs: the optional factory deploys or reuses the included immutable configs, but the IRMs do not reference it, store parameter hashes, deduplicate configs, or maintain a config registry, and they continue to accept any ABI-compatible config selected by an authorized caller.

The owner or manager that applies a config guarantees the validity of its parameters; for Adaptive this applies to every later read from the selected config as well. The included `AdaptiveCurveConfig` and `LinearKinkConfig` implementations validate their own constructor inputs independently, while the IRMs do not separately check bytecode, interface support, or returned values. An `applyIrmConfig` call succeeds only if the supplied config returns ABI-decodable parameters from the required getter. The zero address, an EOA, a formerly deployed address whose code was removed, and the tested wrong-interface contracts all revert during that call.

The config constructors retain the pinned model-specific validation bounds. Adaptive permits steepness up to 100, adjustment speed and `maxRateAtTarget` up to 10,000/year, and an optional cap up to the maximum curve output at utilization no greater than 100% implied by those ceilings. LinearKink bounds its peak at 8/year (800% APR). These constructor limits are not exposed by either IRM.

For a new market, anyone may first obtain a config through `IrmConfigFactory`; the IRM owner or manager then calls `applyIrmConfig`, the router owner or manager calls `setMarketIrm`, and `createMarket` activates the fully configured route. `applyIrmConfig` and `setMarketIrm` may be called in either order before creation.

The exact semantics — parameter validation, reparametrization, cap behavior, routing and migration rules — are specified in [SPECIFICATION.md](SPECIFICATION.md).

Core interfaces and libraries resolve to the [lib/lido-lend](https://github.com/lidofinance/lido-lend) submodule, Lido's fork of Morpho Blue. This repo is in turn imported as a submodule into `lido-lend-markets`, the product repository hosting the market and controller scaffolding; the proxy in front of `IrmRouter` and the product deployment scripts live there, while the optional config factory implementation lives here.

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) — `forge` auto-installs the pinned solc 0.8.36.

```sh
git clone --recurse-submodules git@github.com:lidofinance/lido-blue-irm.git
cd lido-blue-irm
forge test
```

Deep fuzz campaigns: `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_INVARIANT_RUNS=4096 forge test`. The coverage command, the exactness policy, and the property-to-test map are in [TEST_PLAN.md](TEST_PLAN.md).

Formal verification with [Certora](https://docs.certora.com/): `certoraRun certora/confs/<Name>.conf` — the specs cover both IRMs and the router, see the "Tests and verification" section of [FORK_NOTES.md](FORK_NOTES.md). Runs need the Certora CLI, an access key, and `solc-0.8.36` on `PATH`.

## Documentation

- [SPECIFICATION.md](SPECIFICATION.md) — the normative spec of everything this fork adds or changes.
- [FORK_NOTES.md](FORK_NOTES.md) — fork point, per-file footprint, and the change record against upstream.
- [TEST_PLAN.md](TEST_PLAN.md) — test inventory, exactness policy, and coverage.

For upstream background, the [Morpho docs](https://docs.morpho.org/get-started/resources/contracts/irm/) document the original hardcoded parameters, and the [announcement article](https://paragraph.com/@morpho/1U4zd8k6uRI2ICUmcjhP) explains the model's rationale and adaptation mechanism.

## Audits

The [audits](audits) folder contains audits of the upstream code inherited at the fork point. They do not cover the Lido modifications and additions described in this repository.

## Security

Report vulnerabilities through the [Lido bug bounty on Immunefi](https://immunefi.com/bounty/lido/) — do not open public issues.

## Licenses

The Lido Lend IRM sources are MIT; see [LICENSE](LICENSE). Imported `lido-lend` interfaces and libraries retain their own GPL-2.0-or-later SPDX licenses.
