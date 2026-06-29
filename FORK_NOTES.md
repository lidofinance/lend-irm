# Morpho Blue IRM Fork Notes

A fork of [Morpho Blue IRM](https://github.com/morpho-org/morpho-blue-irm) (Morpho Labs), extended for Lido lending and imported by the product repository as a subrepository. Only `AdaptiveCurveIrm` and its directly-coupled files change; `FixedRateIrm`, `ExpLib`, `MathLib`, `UtilsLib` keep upstream behavior.

## Fork point

- Upstream `morpho-org/morpho-blue-irm` @ `2bce6da3ebe910ceeec963781aa3f4b4322c296e` (PR #139, feat/balances-lib-2).
- Sources are vendored (this repo starts at its own `forge init`), so there is no shared git ancestor: the change record is this document plus the per-file diff against that commit. Inherited files are edited in place under their upstream names; the untouched ones (`ExpLib`, `MathLib`, `UtilsLib`, `FixedRateIrm`, `IFixedRateIrm`) are byte-identical to it.
- Upstream `AdaptiveCurveIrm` is the contract deployed [on Ethereum](https://etherscan.io/address/0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC); this fork's bytecode no longer matches it.

Reproduce the diff:

```sh
git clone https://github.com/morpho-org/morpho-blue-irm /tmp/mbi
git -C /tmp/mbi checkout 2bce6da3ebe910ceeec963781aa3f4b4322c296e
diff -rq src /tmp/mbi/src
```

Footprint:

- **Modified** in place: `AdaptiveCurveIrm.sol`, `interfaces/IAdaptiveCurveIrm.sol`, `libraries/ErrorsLib.sol`, `libraries/periphery/AdaptiveCurveIrmLib.sol`.
- **New** (fork-only): `MarketConfig.sol`, `MarketConfigFactory.sol`, `interfaces/IMarketConfig.sol`, `interfaces/IMarketConfigFactory.sol`.
- **Relocated**: `libraries/ConstantsLib.sol` moved to `test/` (the canonical default config the tests build on; upstream-only here).
- Everything else is identical.

## Core changes

The curve math and its adaptation are **byte-identical to upstream**. The fork only changes where the curve parameters come from and adds an optional output cap.

- **Per-market config in its own immutable contract.** Upstream's six `ConstantsLib` curve constants (plus the new `maxBorrowRate`) become a `Config` struct frozen into a `MarketConfig` contract, validated in its constructor. One `MarketConfig` holds one curve; a market points at one.
- **Per-market config pointer on the IRM.** `AdaptiveCurveIrm` holds `mapping(Id => IMarketConfig) marketConfig` and reads a market's parameters by an external static call to its `MarketConfig` (`getConfig()`) when computing the rate. A market with no config set reverts (`config not set`). Immutables are `MORPHO` and `OWNER`; storage is `rateAtTarget` and `marketConfig`. The IRM does not reference the factory.
- **Permissionless factory + provenance.** `MarketConfigFactory` has no owner and no IRM reference: `createConfig(cfg)` deploys `new MarketConfig(cfg)` (which validates in its constructor) and records `isValidDeployment[config] = true`. Deploying a config grants no power — it is an inert data holder; the provenance record is for off-chain/periphery verification, not consumed on-chain.
- **Owner-gated activation.** `IRM.setConfig(id, config)` is `OWNER`-only; the IRM trusts the owner to point a market at a well-formed config (no on-chain provenance gate, matching Euler V2's core setter). `OWNER` is immutable — changing it is a proxy upgrade (see Proxiable below).
- **Reparametrization by re-pointing.** The owner deploys a fresh `MarketConfig` (via the factory) and calls `setConfig(id, newConfig)`, changing the market's curve while `rateAtTarget` persists. There is no parameter setter (each `MarketConfig` is immutable). See the "Reparametrization" section of SPECIFICATION.md for the timing/snap semantics.
- **Optional `maxBorrowRate` cap.** Hard ceiling on the charged rate (`0` disables it); clamps the returned rate without touching the adapting `rateAtTarget`, so the state machine is unchanged.
- **Proxiable, no initializer.** Both `MORPHO` and `OWNER` are immutable, so the constructor writes no storage and the only storage — `rateAtTarget` (slot 0, unchanged from upstream) and `marketConfig` (slot 1) — starts zero (the correct initial state). The implementation runs behind a proxy with **no initializer** (and no init front-run): immutables are read from impl bytecode under `delegatecall`, storage belongs to the proxy. Deployment is deploy-impl then deploy-proxy. Changing the owner or the logic is a proxy upgrade to a freshly-constructed impl; the configs and `rateAtTarget` persist. `OWNER` is thus immutable per-impl but replaceable by the proxy admin via upgrade — the proxy admin is the ultimate authority until the proxy is ossified. Any future storage field must be appended after `marketConfig`. The proxy lives in the product repo.

## Interfaces and libraries

- `IMarketConfig.sol` (new): the `Config` struct (relocated from `IAdaptiveCurveIrm`) and `getConfig()`.
- `IAdaptiveCurveIrm.sol`: drops the per-deployment curve getters and `getConfig()`; adds `OWNER()`, the `marketConfig(Id)` getter (returns `IMarketConfig`), and `setConfig(Id, IMarketConfig)`. `MORPHO()`, `rateAtTarget(Id)`, and the `IIrm` surface (`borrowRate`/`borrowRateView`) are unchanged.
- `IMarketConfigFactory.sol` (new): `isValidDeployment(address)`, `createConfig(Config)` (returns `IMarketConfig`).
- `ErrorsLib.sol`: keeps `ZERO_ADDRESS`/`NOT_MORPHO` and the per-parameter validation errors (now thrown by `MarketConfig`); adds `NOT_OWNER`, `CONFIG_NOT_SET`.
- `AdaptiveCurveIrmLib.sol` (periphery): resolves the market's config from the IRM registry (`marketConfig(id)`) and reads it live (tracks the currently-registered config) instead of `ConstantsLib`, applying the same clamp; reverts `config not set` when none is registered. Public surface unchanged, but behavior is now market-specific per the registered `Config` — consumers that assumed the upstream constants must re-check.
- `ConstantsLib.sol`: moved from `src/` to `test/`, where it is the canonical default config the tests build on.

## Compatibility

- **Drop-in at the call site:** the `IIrm` surface keeps upstream signatures and semantics; Morpho and integrators are unaffected (a market must have a config registered before it is used).
- **Not drop-in at deployment:** the IRM constructor is `(address morpho, address owner)`; curve params live in factory-deployed `MarketConfig`s, and behavior is per-market.
- **Reparametrization is a re-pointing, not a setter:** the owner points a market at a new `MarketConfig` via `setConfig`, which can move the charged rate discontinuously on the next interaction (see the "Reparametrization" section in SPECIFICATION.md). Changing the owner itself is a proxy upgrade.
- **Bumped:** `pragma 0.8.35` (was `0.8.19`). **Unchanged:** MIT, `evm_version = "paris"`.

## Tests and verification

- Foundry: upstream tests are retained and adapted to the per-market-config model (the IRM is deployed with a factory and owner, and a default config from `test/ConstantsLib.sol` is set per market); `testConstants` is dropped (now covered by `MarketConfig` validation). Fork tests add config validation (`MarketConfigTest`), the permissionless factory + provenance record (`MarketConfigFactoryTest`), `setConfig` access control, the cap, config-space fuzzing, a config-parametrized curve oracle, curve edge cases, reparametrization-by-re-pointing dynamics (`AdaptiveCurveIrmReparamTest`), and the proxy suite (immutables read through the proxy, config + `rateAtTarget` persist across upgrade, owner changed by upgrade, slot non-collision) against a minimal test-only ERC-1967 proxy (`AdaptiveCurveIrmProxyTest`).
- Certora: `certora/confs/{BorrowRateView,ExpectedMarketBalances}.conf` prove the periphery equivalent to the contract (values and reverts); `MaxBorrowRate.conf` proves the cap bounds both `borrowRate` and `borrowRateView` when enabled; `RateAtTargetBand.conf` proves `borrowRate` keeps `rateAtTarget[id]` within `[minRateAtTarget, maxRateAtTarget]`. Specs/harness read the curve params from a linked `MarketConfig`; confs pin `solc-0.8.35`.
