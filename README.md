# Morpho Blue IRMs

Some interest rate models for Morpho Blue:

- [AdaptiveCurveIRM](src/adaptive-curve-irm/AdaptiveCurveIrm.sol)
  - _Lido fork_: this `AdaptiveCurveIRM` diverges from upstream Morpho's. The curve constants (`ConstantsLib`)
    move into a per-market, immutable [`AdaptiveCurveConfig`](src/adaptive-curve-irm/AdaptiveCurveConfig.sol) (validated at
    construction) that a permissionless [factory](src/adaptive-curve-irm/AdaptiveCurveConfigFactory.sol) deploys; the IRM
    keeps a per-market pointer to one and reads its parameters through an external static call. An optional
    `maxBorrowRate` hard cap clips the charged rate without touching the adapting `rateAtTarget` (0 disables it). The
    IRM `owner` reparametrizes a market by pointing it at a new config via `setConfig`. The owner lives in storage
    (set once via `initialize`, transferred via `transferOwnership`) and the IRM is proxy-compatible — upgrading the
    logic is a proxy upgrade, while every market's config, `rateAtTarget`, and the owner persist.
  - _Important_: upstream Morpho's `AdaptiveCurveIRM` was deployed [on Ethereum](https://etherscan.io/address/0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC)
    without the `via_ir` solc compilation option. That reference predates the changes above, so this contract's
    bytecode no longer matches that address.
- [FixedRateIRM](src/fixed-rate-irm/FixedRateIrm.sol)

## Resources

- AdaptiveCurveIRM: [documentation](https://docs.morpho.org/concepts/morpho-blue/core-concepts/irm#the-adaptivecurveirm), [announcement article](https://morpho.mirror.xyz/aaUjIF85aIi5RT6-pLhVWBzuiCpOb4BV03OYNts2BHQ).

## Audits

All audits are stored in the [audits](audits)' folder.

## Getting started

Compilation, testing and formatting with [forge](https://book.getfoundry.sh/getting-started/installation).

## Licenses

The primary license is MIT, see [LICENSE](LICENSE).
