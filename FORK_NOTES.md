# Lido Lend IRM fork notes

This document records the source delta from Morpho Blue IRM. Runtime behavior belongs in [SPECIFICATION.md](SPECIFICATION.md); verification coverage belongs in [TEST_PLAN.md](TEST_PLAN.md).

## Fork point

- Upstream repository: [`morpho-org/morpho-blue-irm`](https://github.com/morpho-org/morpho-blue-irm).
- Upstream commit: [`a1a87fd5a7ee13873ea9d2bbd87e9c7b2cdbbef3`](https://github.com/morpho-org/morpho-blue-irm/tree/a1a87fd5a7ee13873ea9d2bbd87e9c7b2cdbbef3).
- Core interfaces and libraries: the pinned [`lib/lido-lend`](lib/lido-lend) submodule.

Inherited interfaces retain Morpho names such as `IMorpho` and `IIrm`. In this repository, those interfaces target the LidoLend core.

The fork-point commit is an ancestor of this repository's `main` branch, so the native diff below is the authoritative committed source change record. Reproduce it with:

```sh
git diff a1a87fd5a7ee13873ea9d2bbd87e9c7b2cdbbef3 HEAD -- src/
```

## Source footprint

| Status | Paths | Change |
| --- | --- | --- |
| Modified | `src/adaptive-curve-irm/AdaptiveCurveIrm.sol`, its interface, error library, periphery library, and `MathLib` import/attribution | Replaces hardcoded constants with per-market config, adds authorization and an optional output cap. |
| Added | `src/adaptive-curve-irm/AdaptiveCurveConfig.sol`, Adaptive config interfaces/types | Included immutable and constructor-validated config implementation. |
| Added | `src/adaptive-curve-irm/libraries/AdaptiveCurveMathLib.sol` | Shared Adaptive rate calculation used by the contract and periphery. |
| Removed | Upstream `src/fixed-rate-irm/` | The upstream fixed-rate module is not part of this fork. |
| Added | `src/linear-kink-irm/` | Non-adapting piecewise-linear model, config, interfaces, and errors. |
| Added | `src/irm-router/` | Proxied market-facing router with per-market implementation selection. |
| Added | `src/irm-config-factory/` | Optional permissionless get-or-deploy factory for the included immutable configs, with per-model reuse by `keccak256(abi.encode(params))` and typed lookup by parameter struct. |
| Added | `src/common/` | Shared owner/manager authorization plus the common `applyIrmConfig(MarketParams,address)` ABI and `IrmConfigApplied` event. |
| Relocated | `src/adaptive-curve-irm/libraries/ConstantsLib.sol` | Upstream constants are retained only under `test/` as reference parameters. |
| Unchanged | `src/adaptive-curve-irm/libraries/ExpLib.sol`, `src/adaptive-curve-irm/libraries/UtilsLib.sol` | Byte-identical to upstream at the fork point. |

No other `src/` files differ from the fork point. `MathLib.sol` changes only its import path and attribution header.

## Storage and deployment

- `AdaptiveCurveIrm` is direct and non-proxied: owner slot 0, manager slot 1, `rateAtTarget` slot 2, `marketCurveConfig` slot 3.
- `LinearKinkIrm` is direct and non-proxied: owner slot 0, manager slot 1, `marketKinkParams` slot 2.
- `IrmRouter` is proxied and uses ERC-7201 namespace `lido.lend.storage.IrmRouter`: owner at the namespace base, manager and `isInitialized` at base + 1, and `marketIrm` at base + 2.
- Included config contracts are immutable. The factory is direct and permissionless.

Deployment ABIs are `IrmRouter(core)` plus atomic proxy initialization through `initialize(owner, manager)`, `AdaptiveCurveIrm(router, owner, manager)`, and `LinearKinkIrm(owner, manager)`. The core, router, and role addresses must be non-zero.

The [Lido Lend Markets](https://github.com/lidofinance/lido-lend-markets) product repository owns the router proxy, deployment scripts, and concrete role assignments.

## Compatibility boundary

- The core-facing `IIrm` selectors are unchanged, but deployment and operating semantics are not drop-in.
- Adaptive formulas are upstream-compatible when supplied the upstream parameters and with `maxBorrowRate == 0`.
- Adaptive deployment adds the trusted router and role constructor arguments, and every market needs a config.
- A router-fronted market must set `MarketParams.irm` to the router. The selected model address is stored only in the router.
- The optional factory is a deployment cache, not an allowlist or source of trusted config addresses. The IRMs accept any ABI-compatible config selected by an authorized caller, who is responsible for its returned values; Adaptive reads it on every pricing call, while LinearKink trusts it only during application.
- The repository's default Foundry profile pins Solidity 0.8.36, targets the Paris EVM, enables the optimizer with 200 runs, and disables via-IR. Upstream `AdaptiveCurveIrm` pinned Solidity 0.8.19; imported dependencies retain compatible pragma ranges.

## Tests and formal verification

[TEST_PLAN.md](TEST_PLAN.md) maps Foundry coverage and Certora's modeled properties, assumptions, and proof-evidence boundary.

## Audit boundary

The `audits/` directory contains reports with different historical scopes. It includes reports for removed or unrelated components, including FixedRateIrm and vault or adapter code. Review each report's audited commit and scope before applying it to this source tree. The presence of a report does not imply coverage of the router, LinearKink, config contracts, factory, or other Lido changes.

## License

Local IRM source uses MIT. Imported LidoLend interfaces and libraries retain `GPL-2.0-or-later` SPDX identifiers.
