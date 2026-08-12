// SPDX-License-Identifier: MIT

// Verification of the fork-added IrmRouter: the stable IRM address behind which the owner or manager routes each
// market to a per-market implementation.
//
// The scene is the router plus one real implementation, LinearKinkIrm. Rules never recompute the market id from
// `marketParams`: where a rule must relate the routing table to a forwarded call, it routes `marketParams` through
// the real `setMarketIrm`; where it must quantify over the table, it reads `currentContract.marketIrm[id]` directly.
// Morpho is outside the scene, so `market(id)` and `accrueInterest` are summarized. Every outbound implementation
// `borrowRate` call is also summarized to an arbitrary successful return. That summary covers both the router's
// normal state-changing forward and the live-market probe. Only the `borrowRateView` forward is dispatched to linked
// implementation code, which is the forwarding equivalence proved below.

using LinearKinkIrm as Kink;

// Ghost observers over the summarized outside world: `ghostLastUpdate` steers what Morpho's `market(id)` reports,
// while the two counters record calls to core accrual and implementation `borrowRate`. They exist for the
// call-occurrence rules (h) and (i) -- the router must not call the implementation of a not-yet-created market
// (a pre-creation probe once decayed a stateful model's seeded rate over the whole epoch).
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

    // Every implementation `borrowRate` call -- including the setter's live probe and the router's normal
    // state-changing forward -- returns an arbitrary rate without reverting or touching implementation state and
    // bumps the call counter. `borrowRateView` is dispatched so `forwardingEquivalence` executes Kink's real code.
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

// (a1) unroutedBorrowRateReverts: after the Morpho caller passes the gate, the state-changing path still reverts for
//      an unrouted market. Together with (a0) and borrowRateGate, this covers both pricing entry points and callers.
rule unroutedBorrowRateReverts(env e, IrmRouter.MarketParams marketParams, IrmRouter.Market market) {
    require forall IrmRouter.Id id. currentContract.marketIrm[id] == 0;
    require e.msg.sender == MORPHO();

    borrowRate@withrevert(e, marketParams, market);
    assert lastReverted;
}

// (a) borrowRateGate: the state-changing entry point is Morpho-only -- any other caller reverts, whatever the market
//     or the routing state.
rule borrowRateGate(env e, IrmRouter.MarketParams marketParams, IrmRouter.Market market) {
    require e.msg.sender != MORPHO();

    borrowRate@withrevert(e, marketParams, market);
    assert lastReverted;
}

// (b) marketIrmAccessControl: the routing table moves only through `setMarketIrm` called by the owner or manager.
//     A changed value is never zero, and a non-zero route is never cleared. Direct storage access covers every id.
//
//     The pre-state assumption excludes self-routing (`marketIrm[id]` holding the router itself) to prevent recursive
//     `borrowRateView` dispatch from inlining the router into itself. Self-routing is not generally unreachable:
//     pre-creation `setMarketIrm` can store it because that branch performs no implementation probe.
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

// (c) initOneShot: `initialize` reverts from any state whose initialized flag is already set, while a successful
//     call sets the flag and installs exactly the given roles. Constructor locking is covered separately by Foundry.
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

// (h) uncreatedMarketRoutesUntouched: after querying Morpho for a market whose lastUpdate is zero, routing makes no
//     accrual or implementation `borrowRate` call -- nothing to accrue, nothing to probe, and no premature write of
//     a stateful model's per-market state. Regression guard for the pre-creation probe decay.
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
