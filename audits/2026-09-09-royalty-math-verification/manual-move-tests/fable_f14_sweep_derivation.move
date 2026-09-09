// HAND-WRITTEN by the Fable verification pass (VERIFICATION.md §5, F14).
// `routed_stake::sweep` is permissionless; the only thing that keeps it safe
// is the pair of derivation asserts at routed_stake.move:212-213. These tests
// try to route parent A's rewards somewhere else by lying about `parent_id`.
#[test_only, allow(unused_use)]
module routed_stake::fable_f14_sweep_derivation;

use std::unit_test::{assert_eq, destroy};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use routed_stake::routed_stake::{Self, RoutedStake};
use sui::balance;
use sui::test_scenario;

const ADMIN: address = @0xAD;
const ATTACKER: address = @0xBAD;
const ENotDerivedFromParent: u64 = 0;   // routed_stake.move:42
const EPoolNotDerivedFromParent: u64 = 0; // pool.move:84

public struct SHARE() has drop;
public struct PSHARE() has drop;
public struct USD() has drop;
public struct Parent has key { id: UID }

/// Two independent parents, A and B. Each has its own routed pool derived
/// from itself. Only A has a routed stake, registered in a shared stake pool
/// with 1000 units of accrued reward. Returns (a_id, b_id, stake_pool_id,
/// a_pool_id, b_pool_id, routed_id).
fun setup(sc: &mut test_scenario::Scenario): (ID, ID, ID, ID, ID, ID) {
    let mut a = Parent { id: object::new(sc.ctx()) };
    let mut b = Parent { id: object::new(sc.ctx()) };
    let mut asset = Parent { id: object::new(sc.ctx()) };
    let a_id = a.id.to_inner();
    let b_id = b.id.to_inner();
    let mut stake_pool = pool::new<SHARE, USD>(&mut asset.id);
    let a_pool = pool::new<PSHARE, USD>(&mut a.id);
    let b_pool = pool::new<PSHARE, USD>(&mut b.id);
    let mut routed = routed_stake::new<SHARE, PSHARE>(&mut a.id, balance::create_for_testing<SHARE>(10), sc.ctx());
    routed.register(&mut a.id, &mut stake_pool);
    stake_pool.deposit(balance::create_for_testing<USD>(1000));
    let sp_id = object::id(&stake_pool);
    let ap_id = object::id(&a_pool);
    let bp_id = object::id(&b_pool);
    let r_id = object::id(&routed);
    stake_pool.share(); a_pool.share(); b_pool.share(); routed_stake::share(routed);
    transfer::share_object(a); transfer::share_object(b); transfer::share_object(asset);
    (a_id, b_id, sp_id, ap_id, bp_id, r_id)
}

/// Attacker passes B's id with A's routed stake and B's pool: the routed
/// stake's own derivation check fires first.
#[test, expected_failure(abort_code = ENotDerivedFromParent, location = routed_stake)]
fun sweep_with_foreign_parent_id_and_foreign_pool_aborts() {
    let mut sc = test_scenario::begin(ADMIN);
    let (_a, b_id, sp_id, _ap, bp_id, r_id) = setup(&mut sc);
    sc.next_tx(ATTACKER);
    let mut r = sc.take_shared_by_id<RoutedStake<SHARE, PSHARE>>(r_id);
    let mut sp = sc.take_shared_by_id<RoyaltyPool<SHARE, USD>>(sp_id);
    let mut bp = sc.take_shared_by_id<RoyaltyPool<PSHARE, USD>>(bp_id);
    r.sweep(&mut sp, &mut bp, b_id);
    abort
}

/// Attacker passes the *correct* parent id (A) but B's pool as the
/// destination: the pool derivation check fires.
#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = pool)]
fun sweep_with_correct_parent_but_foreign_pool_aborts() {
    let mut sc = test_scenario::begin(ADMIN);
    let (a_id, _b, sp_id, _ap, bp_id, r_id) = setup(&mut sc);
    sc.next_tx(ATTACKER);
    let mut r = sc.take_shared_by_id<RoutedStake<SHARE, PSHARE>>(r_id);
    let mut sp = sc.take_shared_by_id<RoyaltyPool<SHARE, USD>>(sp_id);
    let mut bp = sc.take_shared_by_id<RoyaltyPool<PSHARE, USD>>(bp_id);
    r.sweep(&mut sp, &mut bp, a_id);
    abort
}

/// Control: the honest call from the same attacker address succeeds and the
/// 1000 units land parked at A's pool address (A's pool has no stakers), so
/// nothing about the negative tests is an artefact of the fixture.
#[test]
fun honest_sweep_from_stranger_parks_at_a_pool() {
    let mut sc = test_scenario::begin(ADMIN);
    let (a_id, _b, sp_id, ap_id, _bp, r_id) = setup(&mut sc);
    sc.next_tx(ATTACKER);
    let mut r = sc.take_shared_by_id<RoutedStake<SHARE, PSHARE>>(r_id);
    let mut sp = sc.take_shared_by_id<RoyaltyPool<SHARE, USD>>(sp_id);
    let mut ap = sc.take_shared_by_id<RoyaltyPool<PSHARE, USD>>(ap_id);
    assert_eq!(sp.pending_rewards(r.stake()), 1000);
    r.sweep(&mut sp, &mut ap, a_id);
    assert_eq!(sp.pending_rewards(r.stake()), 0);
    assert_eq!(sp.balance().value(), 0);
    assert_eq!(ap.balance().value(), 0); // parked at the address, not in the accumulator
    test_scenario::return_shared(r); test_scenario::return_shared(sp); test_scenario::return_shared(ap);
    sc.end();
}
