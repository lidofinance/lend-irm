# Morpho Blue IRMs

Some interest rate models for Morpho Blue:

- [AdaptiveCurveIRM](src/adaptive-curve-irm/AdaptiveCurveIrm.sol)
  - _Lido fork_: this `AdaptiveCurveIRM` diverges from upstream Morpho's. The curve constants (`ConstantsLib`)
    are lifted to constructor `Config` immutables (validated at construction), an optional `MAX_BORROW_RATE`
    hard cap clips the charged rate without touching the adapting `rateAtTarget` (0 disables it), and the
    immutable design is proxy-compatible — a single implementation can be deployed behind an upgradeable proxy
    and reparametrized by upgrading, while the stored `rateAtTarget` persists.
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
