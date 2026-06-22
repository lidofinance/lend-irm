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

Footprint: `AdaptiveCurveIrm.sol`, `interfaces/IAdaptiveCurveIrm.sol`, `libraries/ErrorsLib.sol`, `libraries/periphery/AdaptiveCurveIrmLib.sol` differ; `libraries/ConstantsLib.sol` is relocated to `test/` (upstream-only here); everything else is identical.

## Core changes (`AdaptiveCurveIrm.sol`)

- **Per-deployment immutable params.** The six `ConstantsLib` curve constants are lifted to constructor immutables via a `Config` struct, so each deployment fixes its own curve. The curve math is byte-identical to upstream.
- **Constructor validation.** Curve values are now inputs (upstream's constructor took/validated none), so `_validateConfig` checks each parameter against a valid range: `curveSteepness` in `[WAD, 100*WAD]`, `adjustmentSpeed` in `[0, ~10000/year]`, `targetUtilization` in `(0, WAD)`, `minRateAtTarget > 0`, `maxRateAtTarget` in `[minRateAtTarget, ~1e6%/year]`, `initialRateAtTarget` in `[min, max]`, `maxBorrowRate >= 0`. These bounds, upper limits included, keep the curve math within its non-overflowing range so `borrowRate` returns a non-negative rate; values outside them revert at construction. They enforce well-formedness only, not economic soundness — within the bounds the deployer owns the curve (see docs/specification.md).
- **Optional `MAX_BORROW_RATE` cap.** Hard ceiling on the charged rate (`0` disables it); clamps the returned rate without touching the adapting `rateAtTarget`, so the state machine is unchanged.
- **`getConfig()`** returns the full `Config` (integrator convenience; on the contract, not `IAdaptiveCurveIrm`; unused by the core path or periphery).
- **Proxy-compatible.** Immutables live in impl bytecode (read during `delegatecall`); the only storage is `rateAtTarget` (slot 0, unchanged from upstream). So one impl can run behind an upgradeable proxy and be reparametrized by upgrading while `rateAtTarget` persists. ERC-1967 impl/admin pointers sit in dedicated slots that never collide with slot 0, and any future storage field must be appended after it. The proxy lives in the product repo.

## Interfaces and libraries

- `IAdaptiveCurveIrm.sol`: adds getters for the six curve params and `MAX_BORROW_RATE`; `MORPHO()`, `rateAtTarget(Id)`, and the `IIrm` surface (`borrowRate`/`borrowRateView`) are unchanged.
- `ErrorsLib.sol`: keeps `ZERO_ADDRESS`/`NOT_MORPHO`, adds the per-parameter validation errors.
- `AdaptiveCurveIrmLib.sol` (periphery): reads params from the IRM instance instead of `ConstantsLib` (tracks the live, possibly-proxied impl) and applies the same clamp. Public surface unchanged, but behavior is now instance-specific per the deployed `Config` — consumers that assumed the upstream constants must re-check.
- `ConstantsLib.sol`: moved from `src/` to `test/`, where it is the canonical default config the tests build on.

## Compatibility

- **Drop-in at the call site:** the `IIrm` surface keeps upstream signatures and semantics; Morpho and integrators are unaffected.
- **Not drop-in at deployment:** the constructor is `(address morpho, Config cfg)`, and curve behavior is per-deployment, not the upstream constants.
- **Reparametrization is an upgrade, not a setter:** the only way to change a live deployment's params is upgrading the impl behind the proxy, which can move the charged rate discontinuously on the next interaction (see the "Upgradable" section in docs/specification.md).
- **Unchanged:** MIT, `pragma 0.8.19`, `evm_version = "paris"`.

## Tests and verification

- Foundry: upstream tests are retained and adapted to the `Config` constructor (default from `test/ConstantsLib.sol`); `testConstants` is dropped (now covered by constructor validation). Fork tests add deployment/validation, the cap, config-space fuzzing, a config-parametrized curve oracle, curve edge cases, and the proxy/upgrade suite (against a minimal test-only ERC-1967 proxy).
- Certora: `certora/confs/{BorrowRateView,ExpectedMarketBalances}.conf` prove the periphery equivalent to the contract (values and reverts); specs/harness updated for instance-read params; confs pin `solc-0.8.19`.
