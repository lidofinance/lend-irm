# Morpho Blue IRM Fork Notes

A fork of [Morpho Blue IRM](https://github.com/morpho-org/morpho-blue-irm) (Morpho Labs), extended for Lido lending and imported by the product repository as a subrepository. Only `AdaptiveCurveIrm` and its directly-coupled files change; `FixedRateIrm`, `ExpLib`, `MathLib`, `UtilsLib` keep upstream behavior.

## Fork point

- Upstream `morpho-org/morpho-blue-irm` @ `2bce6da3ebe910ceeec963781aa3f4b4322c296e` (PR #139, feat/balances-lib-2).
- Sources are vendored (this repo starts at its own `forge init`), so there is no shared git ancestor: the change record is this document plus the per-file diff against that commit. Inherited files are edited in place under their upstream names; the untouched ones (`ExpLib`, `MathLib`, `UtilsLib`, `FixedRateIrm`, `IFixedRateIrm`) are byte-identical to it.
- The Morpho core interfaces/libraries the IRM imports resolve to the `lib/lido-lend` submodule (Lido's Morpho-core fork), not upstream `morpho-blue`.
- Upstream `AdaptiveCurveIrm` is the contract deployed [on Ethereum](https://etherscan.io/address/0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC); this fork's bytecode no longer matches it.

Reproduce the diff:

```sh
git clone https://github.com/morpho-org/morpho-blue-irm /tmp/mbi
git -C /tmp/mbi checkout 2bce6da3ebe910ceeec963781aa3f4b4322c296e
diff -rq src /tmp/mbi/src
```

Footprint:

- **Modified** in place: `AdaptiveCurveIrm.sol`, `interfaces/IAdaptiveCurveIrm.sol`, `libraries/ErrorsLib.sol`, `libraries/periphery/AdaptiveCurveIrmLib.sol`.
- **New** (fork-only): `AdaptiveCurveConfig.sol`, `interfaces/IAdaptiveCurveConfig.sol`, `interfaces/IAdaptiveCurveTypes.sol`.
- **Relocated**: `libraries/ConstantsLib.sol` moved to `test/` (the canonical default config the tests build on; upstream-only here).
- Everything else is identical.

## Core changes

The curve math and its adaptation are **byte-identical to upstream**. The fork only changes where the curve parameters come from, who may set them, and adds an optional output cap.

- **Per-market config in its own immutable contract.** Upstream's six `ConstantsLib` curve constants (plus the new `maxBorrowRate`) become an `AdaptiveCurveParams` struct frozen into an `AdaptiveCurveConfig` contract, validated in its constructor. One `AdaptiveCurveConfig` holds one curve; a market points at one.
- **Per-market config pointer + dedup cache on the IRM.** `AdaptiveCurveIrm` holds `mapping(Id => IAdaptiveCurveConfig) marketCurveConfig` and reads a market's parameters by an external static call to its `AdaptiveCurveConfig` (`getCurveParams()`) when computing the rate. A market with no config set reverts (`config not set`). It also holds `mapping(bytes32 => IAdaptiveCurveConfig) deployedCurveConfigs`, a cache keyed by `keccak256(abi.encode(params))` so identical parameters resolve to one shared, immutable config across markets. The only immutable is `MORPHO`.
- **Single privileged setter that deploys inline.** There is no separate factory. `setMarketCurveParams(marketParams, curveParams)` derives the market id, deploys `new AdaptiveCurveConfig(curveParams)` (which validates in its constructor) unless the dedup cache already holds one for those exact params, then points the market at the resolved config. It emits `ConfigDeployed` on a fresh deploy and `MarketCurveParamsSet` on every set. Callable by `owner` **or** `manager` only (`not authorized` otherwise); the IRM trusts the caller to choose well-formed params (no economic gate), matching Euler V2's core setter.
- **Owner and manager in storage.** `owner` rotates itself (`transferOwnership`) and the `manager` (`setManager`) — both owner-only, both rejecting the zero address — and may set market curves. `manager` is a scoped operational address that may only call `setMarketCurveParams`. Both are set once via `initialize(owner, manager)`. See Proxiable below.
- **Reparametrization by re-pointing.** The owner or manager calls `setMarketCurveParams(marketParams, newParams)` again; the IRM resolves (deploys or reuses) the config and re-points the market while `rateAtTarget` persists. There is no in-place parameter setter (each `AdaptiveCurveConfig` is immutable). See the "Reparametrization" section of SPECIFICATION.md for the timing/snap semantics.
- **Optional `maxBorrowRate` cap.** Hard ceiling on the charged rate (`0` disables it); clamps the returned rate without touching the adapting `rateAtTarget`, so the state machine is unchanged.
- **Proxiable, owner/manager set by `initialize`.** `MORPHO` is immutable (read from impl bytecode under `delegatecall`); storage is `rateAtTarget` (slot 0, unchanged from upstream), `marketCurveConfig` (slot 1), `deployedCurveConfigs` (slot 2), `owner` (slot 3), and `manager` packed with `isInitialized` (slot 4). The constructor takes only `morpho` and marks the *implementation itself* initialized (`isInitialized = true`) so a raw impl can never be `initialize`d — only a freshly-deployed proxy (zeroed storage) can be, exactly once, via `initialize(owner, manager)` (guarded on `isInitialized`, rejects zero addresses). Behind a proxy, deploy and `initialize` must be executed atomically so the owner/manager slots cannot be front-run. Upgrading the logic is a proxy upgrade to a freshly-constructed impl; storage — configs, dedup cache, `rateAtTarget`, and both addresses — persists. The proxy admin remains the ultimate authority (it can overwrite any slot via upgrade) until the proxy is ossified. Any future storage field must be appended after `manager`/`isInitialized`. The proxy lives in the product repo.

## Interfaces and libraries

- `IAdaptiveCurveTypes.sol` (new): the shared top-level `AdaptiveCurveParams` struct (the seven curve fields), decoupled from any contract.
- `IAdaptiveCurveConfig.sol` (new): the per-market config surface — `getCurveParams()` and the per-field getters (`CURVE_STEEPNESS()` … `MAX_BORROW_RATE()`); inherits the `AdaptiveCurveParams` type from `IAdaptiveCurveTypes`.
- `IAdaptiveCurveIrm.sol`: drops the per-deployment curve getters and `getCurveParams()`; adds `owner()`/`manager()`/`isInitialized()`, `initialize(address,address)`, `transferOwnership(address)`, `setManager(address)` (with `OwnershipTransferred`/`ManagerSet` events), the `marketCurveConfig(Id)` and `deployedCurveConfigs(bytes32)` getters (return `IAdaptiveCurveConfig`), and `setMarketCurveParams(MarketParams, AdaptiveCurveParams)` (with `ConfigDeployed`/`MarketCurveParamsSet` events). `MORPHO()`, `rateAtTarget(Id)`, and the `IIrm` surface (`borrowRate`/`borrowRateView`) are unchanged.
- `ErrorsLib.sol`: keeps `ZERO_ADDRESS`/`NOT_MORPHO` and the per-parameter validation errors (now thrown by `AdaptiveCurveConfig`); adds `NOT_OWNER`, `NOT_AUTHORIZED`, `CONFIG_NOT_SET`, `ALREADY_INITIALIZED`.
- `AdaptiveCurveIrmLib.sol` (periphery): resolves the market's config from the IRM (`marketCurveConfig(id)`) and reads it live (tracks the currently-registered config) instead of `ConstantsLib`, applying the same clamp; reverts `config not set` when none is registered. Public surface unchanged, but behavior is now market-specific per the registered params — consumers that assumed the upstream constants must re-check.
- `ConstantsLib.sol`: moved from `src/` to `test/`, where it is the canonical default config the tests build on.

## Compatibility

- **Drop-in at the call site:** the `IIrm` surface keeps upstream signatures and semantics; Morpho and integrators are unaffected (a market must have a curve set before it is used).
- **Not drop-in at deployment:** the IRM constructor is `(address morpho)` and the `owner`/`manager` are set post-deployment via `initialize(owner, manager)` (atomically with deployment behind a proxy); curve params live in IRM-deployed `AdaptiveCurveConfig`s, and behavior is per-market.
- **Reparametrization is a re-pointing, not a setter:** the owner or manager sets new parameters via `setMarketCurveParams`, which can move the charged rate discontinuously on the next interaction (see the "Reparametrization" section in SPECIFICATION.md). Rotating `owner` or `manager` is a `transferOwnership` / `setManager` call.
- **Bumped:** `pragma 0.8.35` (was `0.8.19`); Morpho core imports resolve to `lib/lido-lend`. **Unchanged:** MIT, `evm_version = "paris"`.

## Tests and verification

- Foundry: upstream tests are retained and adapted to the per-market-config model (the IRM is `initialize`d with an owner and manager, and a default config from `test/ConstantsLib.sol` is set per market via `setMarketCurveParams`); `testConstants` is dropped (now covered by `AdaptiveCurveConfig` validation). Fork tests add config validation (`AdaptiveCurveConfigTest`), `setMarketCurveParams` deploy/dedup + authorization (`testSetConfigDeploysAndPrices`, `testSetConfigOnlyOwner`), ownership (`testTransferOwnership*`, `testDeployment`), the cap, config-space fuzzing, a config-parametrized curve oracle, curve edge cases, reparametrization-by-re-pointing dynamics (`AdaptiveCurveIrmReparamTest`), and the proxy suite (`MORPHO`/`owner` read through the proxy, ownership rotated via `transferOwnership`, config + `rateAtTarget` persist across upgrade, slot non-collision) against a minimal test-only ERC-1967 proxy (`AdaptiveCurveIrmProxyTest`). See `TEST_PLAN.md` for the full mapping.
- Deep fuzz runs: the inherited `vm.assume`-heavy market filters are reworked into `bound`-based domain squeezing (`_boundMarket`), so the whole suite passes deep campaigns at Foundry's default rejection cap (verified at `FOUNDRY_FUZZ_RUNS=65536 FOUNDRY_INVARIANT_RUNS=4096`).
- Certora: `certora/confs/{BorrowRateView,ExpectedMarketBalances}.conf` prove the periphery equivalent to the contract (values and reverts); `MaxBorrowRate.conf` proves the cap bounds both `borrowRate` and `borrowRateView` when enabled; `RateAtTargetBand.conf` proves `borrowRate` keeps `rateAtTarget[id]` within `[minRateAtTarget, maxRateAtTarget]`. Specs/harness read the curve params from a linked `AdaptiveCurveConfig`; confs pin `solc-0.8.35`; `ExpectedMarketBalances.conf` additionally maps `lib/morpho-blue/src/Morpho.sol` to `solc-0.8.19` via `solc_map` (upstream Morpho pins that pragma).
