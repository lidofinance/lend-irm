# Lido Lend IRMs

Some interest rate models for Morpho Blue:

- [AdaptiveCurveIRM](src/adaptive-curve-irm/AdaptiveCurveIrm.sol)
  - _Lido fork_: this `AdaptiveCurveIRM` diverges from upstream Morpho's. The curve constants (`ConstantsLib`)
    move into a per-market, immutable [`AdaptiveCurveConfig`](src/adaptive-curve-irm/AdaptiveCurveConfig.sol) (validated at
    construction). The IRM's `owner` or `manager` sets a market's curve with a single `setMarketCurveParams` call, which
    deploys the config — or reuses the one already cached for identical params (deduped by params hash) — and points the
    market at it. The IRM reads the parameters through an external static call. An optional `maxBorrowRate` hard cap clips
    the charged rate without touching the adapting `rateAtTarget` (0 disables it). Re-calling `setMarketCurveParams`
    reparametrizes a live market. The `owner` and `manager` live in storage (set via `initialize`, rotated via
    `transferOwnership` / `setManager`) and the IRM is proxy-compatible — upgrading the logic is a proxy upgrade, while
    every market's config, `rateAtTarget`, and both addresses persist.
  - _Important_: upstream Morpho's `AdaptiveCurveIRM` was deployed [on Ethereum](https://etherscan.io/address/0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC)
    without the `via_ir` solc compilation option. That reference predates the changes above, so this contract's
    bytecode no longer matches that address.
- [LinearKinkIRM](src/linear-kink-irm/LinearKinkIrm.sol)
  - _Lido addition_ (replaces upstream's `FixedRateIRM`): a stateless kinked ("jump rate") model à la Aave/Compound —
    the per-second borrow rate is a piecewise-linear function of utilization that steepens past a kink
    (`optimalUtilization`). One IRM instance serves many markets keyed by `Id` (like the AdaptiveCurveIRM): each market's
    parameters (`baseRate`, `slope1`, `slope2`, `optimalUtilization`) are stored packed in a single slot (4×`uint64`,
    per-second WAD) in a `mapping(Id => LinearKinkParams)`, set and reparametrized in place by the `owner` or `manager`
    via `setMarketKinkParams(marketParams, params)`. A market with no params set reverts. Same owner/manager + proxy
    model as the AdaptiveCurveIRM.

## Resources

- AdaptiveCurveIRM: [documentation](https://docs.morpho.org/concepts/morpho-blue/core-concepts/irm#the-adaptivecurveirm), [announcement article](https://morpho.mirror.xyz/aaUjIF85aIi5RT6-pLhVWBzuiCpOb4BV03OYNts2BHQ).

## Audits

All audits are stored in the [audits](audits)' folder.

## Getting started

Compilation, testing and formatting with [forge](https://book.getfoundry.sh/getting-started/installation).

Formal verification with [Certora](https://docs.certora.com/): the specs in [certora/specs](certora/specs) cover both IRMs (`certoraRun certora/confs/<Name>.conf`) — see the "Tests and verification" section of [FORK_NOTES.md](FORK_NOTES.md).

## Licenses

The primary license is MIT, see [LICENSE](LICENSE).
