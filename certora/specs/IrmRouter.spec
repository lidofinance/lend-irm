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
// `borrowRate` probe is summarized to NONDET as well -- it is a liveness filter on the implementation, not part of
// the routing state -- while the `borrowRateView` forward is dispatched to real scene code, which is exactly what
// the forwarding rule is about.

using LinearKinkIrm as Kink;

// Unconstrained Market struct standing in for Morpho's `market(id)` view.
function nondetMarket() returns IrmRouter.Market {
    IrmRouter.Market m;
    return m;
}

methods {
    function MORPHO() external returns (address) envfree;
    function isInitialized() external returns (bool) envfree;
    function owner() external returns (address) envfree;
    function manager() external returns (address) envfree;

    // Morpho lives outside the scene. Its two calls inside `setMarketIrm` are summarized: `market(id)` returns an
    // unconstrained Market struct and `accrueInterest` has no effect the router observes.
    function _.market(IrmRouter.Id) external => nondetMarket() expect IrmRouter.Market;
    function _.accrueInterest(IrmRouter.MarketParams) external => NONDET;

    // The setter's probe and the `borrowRate` forward return an arbitrary rate without reverting or touching state.
    // The `borrowRateView` forward is dispatched to the scene so `forwardingEquivalence` runs Kink's real code.
    function _.borrowRate(IrmRouter.MarketParams, IrmRouter.Market) external => NONDET;
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
