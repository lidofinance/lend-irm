# Lido Lend IRMs

Interest rate models for Lido Lend, and the router that fronts them. A fork of [Morpho Blue IRM](https://github.com/morpho-org/morpho-blue-irm) — the fork point, the per-file footprint, and the full change record live in [FORK_NOTES.md](FORK_NOTES.md).

A Lido Lend market can never change its `irm`, so every market is created pointing at the proxied `IrmRouter` — the one eternal address — which forwards rate queries to a switchable per-market implementation: market → `IrmRouter` → `marketIrm[id]` → `AdaptiveCurveIrm` (reading its market's `AdaptiveCurveConfig`) or `LinearKinkIrm`.

- [IrmRouter](src/irm-router/IrmRouter.sol) — the proxied `IIrm` all markets point at. The router `owner` or `manager` routes each market to an implementation via `setMarketIrm`, so a live market can migrate between rate models. The IRMs behind it are immutable: upgrading routing logic is a proxy upgrade, fixing rate math is a new implementation plus a migration.
- [AdaptiveCurveIrm](src/adaptive-curve-irm/AdaptiveCurveIrm.sol) — upstream Morpho's adaptive model with the curve math unchanged, but the hardcoded curve constants become per-market parameters, held in immutable [AdaptiveCurveConfig](src/adaptive-curve-irm/AdaptiveCurveConfig.sol) contracts set by the `owner` or `manager`, plus an optional `maxBorrowRate` cap.
- [LinearKinkIrm](src/linear-kink-irm/LinearKinkIrm.sol) — a stateless kinked ("jump rate") model à la Aave/Compound, replacing upstream's `FixedRateIrm`. One instance serves many markets, each with its own four curve parameters set by the `owner` or `manager`.

The exact semantics — parameter validation, reparametrization, cap behavior, routing and migration rules — are specified in [SPECIFICATION.md](SPECIFICATION.md).

Core interfaces and libraries resolve to the [lib/lido-lend](https://github.com/lidofinance/lido-lend) submodule, Lido's fork of Morpho Blue. This repo is in turn imported as a submodule into `lido-lend-markets`, the product repository hosting the market and controller scaffolding: the proxy in front of `IrmRouter` and the deploy scripts live there, not here. Nothing is deployed to production yet.

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) — `forge` auto-installs the pinned solc 0.8.35.

```sh
git clone --recurse-submodules git@github.com:lidofinance/lido-blue-irm.git
cd lido-blue-irm
forge test
```

Deep fuzz campaigns: `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_INVARIANT_RUNS=4096 forge test`. The coverage command, the exactness policy, and the property-to-test map are in [TEST_PLAN.md](TEST_PLAN.md).

Formal verification with [Certora](https://docs.certora.com/): `certoraRun certora/confs/<Name>.conf` — the specs cover both IRMs and the router, see the "Tests and verification" section of [FORK_NOTES.md](FORK_NOTES.md). Runs need the Certora CLI, an access key, and `solc-0.8.35` on `PATH`.

## Documentation

- [SPECIFICATION.md](SPECIFICATION.md) — the normative spec of everything this fork adds or changes.
- [FORK_NOTES.md](FORK_NOTES.md) — fork point, per-file footprint, and the change record against upstream.
- [TEST_PLAN.md](TEST_PLAN.md) — test inventory, exactness policy, and coverage.

Upstream background — the [Morpho docs](https://docs.morpho.org/concepts/morpho-blue/core-concepts/irm#the-adaptivecurveirm) and the [announcement article](https://morpho.mirror.xyz/aaUjIF85aIi5RT6-pLhVWBzuiCpOb4BV03OYNts2BHQ) describe the constants-based upstream `AdaptiveCurveIRM`, which this fork parameterizes per market.

## Audits

The [audits](audits) folder holds the upstream Morpho audits inherited from the fork point. They cover the forked code — the Lido modifications and additions (per-market configs, `LinearKinkIrm`, `IrmRouter`) have not been audited yet.

## Security

Report vulnerabilities through the [Lido bug bounty on Immunefi](https://immunefi.com/bounty/lido/) — do not open public issues.

## Licenses

The Lido Lend IRM sources are MIT, see [LICENSE](LICENSE). The `lido-lend` core interfaces and libraries they import — and compile into the bytecode — are GPL-2.0-or-later.
