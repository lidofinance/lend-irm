// SPDX-License-Identifier: MIT

// Verification of the fork-added IrmRouter: the single eternal IRM address behind which the owner routes each
// market to a per-market implementation.
//
// The scene is the router plus one real implementation, LinearKinkIrm (stateless, which makes the forwarding
// equivalence a clean same-inputs comparison). As in LinearKinkIrm.spec, rules never recompute the market id from
// `marketParams`: where a rule must relate the routing table to the forwarded call, it routes `marketParams` through
// the real `setMarketIrm` (the mapping slot the setter writes is exactly the slot `borrowRateView` reads back, both
// on the contract's own id-derivation path). Where it must talk about the table across all markets, it reads storage
// directly (`currentContract.marketIrm[id]`). Morpho is not in the scene, so the router's outbound Morpho calls are
// summarized: `market(id)` returns an unconstrained Market struct and `accrueInterest` is NONDET. The setter's
// `borrowRate` probe (live markets only) is summarized to NONDET as well -- it is a liveness filter, not part of
// the routing state -- while the `borrowRateView` forward is dispatched to real scene code, which is exactly what
// the forwarding rule is about.

using LinearKinkIrm as Kink;

// Ghost observers over the summarized outside world: `ghostLastUpdate` steers what Morpho's `market(id)` reports,
// and the two counters record every outbound call the router makes into Morpho and the implementation. They exist
// for the call-occurrence rules (h) and (i) -- the router must not touch the implementation of a not-yet-created
// market (a pre-creation probe once decayed a stateful model's seeded rate over the whole epoch).
ghost uint128 ghostLastUpdate;
ghost mathint accrueCalls;
ghost mathint probeCalls;

// Market struct standing in for Morpho's `market(id)` view: unconstrained except for `lastUpdate`, which the rules
// pin through the ghost to choose the created / not-yet-created branch.
function nondetMarket() returns IrmRouter.Market {
    IrmRouter.Market m;
    require m.lastUpdate == ghostLastUpdate;
    return m;
}

function countedAccrue() {
    accrueCalls = accrueCalls + 1;
}

function countedBorrowRate() returns uint256 {
    probeCalls = probeCalls + 1;
    uint256 rate;
    return rate;
}

methods {
    function MORPHO() external returns (address) envfree;
    function isInitialized() external returns (bool) envfree;
    function owner() external returns (address) envfree;
    function manager() external returns (address) envfree;

    // Morpho lives outside the scene. Its two calls inside `setMarketIrm` are summarized: `market(id)` returns a
    // ghost-steered Market struct and `accrueInterest` only bumps its call counter.
    function _.market(IrmRouter.Id) external => nondetMarket() expect IrmRouter.Market;
    function _.accrueInterest(IrmRouter.MarketParams) external => countedAccrue() expect void;

    // The setter's probe (live markets only) and the `borrowRate` forward return an arbitrary rate without
    // reverting or touching state, and bump the probe counter. The `borrowRateView` forward is dispatched to the
    // scene so `forwardingEquivalence` runs Kink's real code.
    function _.borrowRate(IrmRouter.MarketParams, IrmRouter.Market) external => countedBorrowRate() expect uint256;
    function _.borrowRateView(IrmRouter.MarketParams, IrmRouter.Market) external => DISPATCHER(true);
}

// (a0) unroutedReverts: on a routing table with no entry for any market (e.g. a freshly initialized proxy),
//      pricing reverts for every market (`irm not set`) -- an unrouted market can never return a rate.
rule unroutedReverts(env e, IrmRouter.MarketParams marketParams, IrmRouter.Market market) {
    require forall IrmRouter.Id id. currentContract.marketIrm[id] == 0;

    borrowRateView@withrevert(e, marketParams, market);
    assert lastReverted;
}

// (a) borrowRateGate: the state-changing entry point is Morpho-only -- any other caller reverts, whatever the market
//     or the routing state.
rule borrowRateGate(env e, IrmRouter.MarketParams marketParams, IrmRouter.Market market) {
    require e.msg.sender != MORPHO();

    borrowRate@withrevert(e, marketParams, market);
    assert lastReverted;
}

// (b) marketIrmAccessControl: the routing table moves only through `setMarketIrm` called by the owner or the
//     manager, the value
//     written is never zero, and a market once routed is never routed back to zero. Direct storage access covers
//     every id at once. The pre-state assumption excludes self-routing (`marketIrm[id]` holding the router itself),
//     which is unreachable in a real deployment -- the setter's probe would call `borrowRate` on the router with
//     `msg.sender == router != MORPHO`, so the gate rejects it -- and keeps the `borrowRateView` dispatch from
//     inlining the router into itself.
rule marketIrmAccessControl(env e, method f, calldataarg args, IrmRouter.Id id) {
    require forall IrmRouter.Id anyId. currentContract.marketIrm[anyId] != currentContract;

    address ownerBefore = owner();
    address managerBefore = manager();
    address irmBefore = currentContract.marketIrm[id];

    f(e, args);

    address irmAfter = currentContract.marketIrm[id];

    assert irmAfter != irmBefore
        => f.selector == sig:setMarketIrm(IrmRouter.MarketParams, address).selector
            && (e.msg.sender == ownerBefore || e.msg.sender == managerBefore) && irmAfter != 0;
    assert irmBefore != 0 => irmAfter != 0;
}

// (c) initOneShot: `initialize` reverts once the contract is initialized -- covering both the implementation, locked
//     by its constructor, and an already-initialized proxy -- and a successful call sets the flag and installs
//     exactly the given roles.
rule initOneShot(env e, address owner_, address manager_) {
    bool initializedBefore = isInitialized();

    initialize@withrevert(e, owner_, manager_);
    bool reverted = lastReverted;

    assert initializedBefore => reverted;
    assert !reverted => isInitialized() && owner() == owner_ && manager() == manager_;
}

// (d) forwardingEquivalence: after routing a market to the linked LinearKinkIrm, the rate the router reports is
//     exactly the rate the implementation reports for the same inputs. The setter is the id-oracle (the slot it
//     writes is the slot the view reads), so the dispatched forward runs Kink's real code on Kink's real storage,
//     and the direct call runs the same code on the same storage. Reachable because the prover picks a storage
//     where Kink has the market configured (the plain calls prune the reverting paths).
rule forwardingEquivalence(
    env eSet,
    env e,
    IrmRouter.MarketParams marketParams,
    IrmRouter.Market market
) {
    setMarketIrm(eSet, marketParams, Kink);

    uint256 routed = borrowRateView(e, marketParams, market);
    uint256 direct = Kink.borrowRateView(e, marketParams, market);

    assert routed == direct;
}

// (h) uncreatedMarketRoutesUntouched: routing a market Morpho reports as not yet created (lastUpdate == 0) makes no
//     call into Morpho or the implementation -- nothing to accrue, nothing to probe, and no premature write of a
//     stateful model's per-market state. Regression guard for the pre-creation probe decay.
rule uncreatedMarketRoutesUntouched(env e, IrmRouter.MarketParams marketParams, address irm) {
    require ghostLastUpdate == 0;
    require accrueCalls == 0 && probeCalls == 0;

    setMarketIrm(e, marketParams, irm);

    assert accrueCalls == 0 && probeCalls == 0;
}

// (i) liveMarketRoutesAccruedAndProbed: a successful switch of a live market (lastUpdate != 0) accrues exactly once
//     and probes the new implementation exactly once.
rule liveMarketRoutesAccruedAndProbed(env e, IrmRouter.MarketParams marketParams, address irm) {
    require ghostLastUpdate != 0;
    require accrueCalls == 0 && probeCalls == 0;

    setMarketIrm(e, marketParams, irm);

    assert accrueCalls == 1 && probeCalls == 1;
}
