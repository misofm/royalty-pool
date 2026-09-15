// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module royalty_pool::royalty_pool_tests;

use royalty_pool::pool::{
    Self,
    RoyaltyPool,
    RoyaltyPoolCreatedEvent,
    RoyaltyDepositedEvent,
    RoyaltyPoolFundsSettledEvent,
    RoyaltyPoolCoinsRecoveredEvent,
    StakeRegisteredEvent,
    StakeUnregisteredEvent,
    RoyaltyClaimedEvent,
};
use royalty_pool::stake::{Self, Stake, StakeCreatedEvent, StakeDestroyedEvent};
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario::{Self, Scenario};

// === Test types ===

// ALICE performs the cap-independent setup (standing in for the parent's own
// cap-gated extension) and holds the stakes claimed against; STRANGER owns
// nothing and proves the pool's directly unit-testable permissionless funding
// paths (`deposit` and `recover_coins`) by sender, not just by signature.
// The empty-settle test below is also executed by STRANGER.
const ALICE: address = @0xA1;
const STRANGER: address = @0x51;

public struct TEST_SHARE() has drop;
public struct OTHER_SHARE() has drop;
public struct TEST_CURRENCY() has drop;
public struct OTHER_CURRENCY() has drop;

// === Helpers ===

/// Create a `RoyaltyPool<TEST_SHARE, TEST_CURRENCY>` derived from a fresh
/// parent UID, share it, dispose the parent. Returns the pool's ID for
/// later lookup via `take_shared_by_id`.
fun create_pool(scenario: &mut Scenario): ID {
    scenario.next_tx(ALICE);
    let mut parent = object::new(scenario.ctx());
    let pool = pool::new<TEST_SHARE, TEST_CURRENCY>(&mut parent);
    let pool_id = object::id(&pool);
    pool.share();
    destroy(parent);
    pool_id
}

/// Deposit `amount` base units of `Currency` into the pool.
fun send_to_pool<S, C>(scenario: &mut Scenario, pool_id: ID, amount: u64) {
    scenario.next_tx(ALICE);
    let mut pool = scenario.take_shared_by_id<RoyaltyPool<S, C>>(pool_id);
    pool.deposit(balance::create_for_testing<C>(amount));
    test_scenario::return_shared(pool);
}

fun new_stake(scenario: &mut Scenario, amount: u64): Stake<TEST_SHARE> {
    stake::new(balance::create_for_testing<TEST_SHARE>(amount), scenario.ctx())
}

fun take_pool(scenario: &Scenario, pool_id: ID): RoyaltyPool<TEST_SHARE, TEST_CURRENCY> {
    scenario.take_shared_by_id(pool_id)
}

// === Stake CRUD ===
//
// `test_stake_round_trip`/`test_stake_rejects_zero_balance` create and
// destroy a `Stake` within one function, never sharing, taking, or
// transferring it — no ownership mechanic for `test_scenario` to exercise,
// so plain `tx_context::dummy()` construction is used. Every other test in
// this file runs under `test_scenario`.

#[test]
fun test_stake_round_trip() {
    let mut ctx = tx_context::dummy();
    let stake = stake::new(balance::create_for_testing<TEST_SHARE>(100), &mut ctx);
    let stake_id = object::id(&stake);
    let created = event::events_by_type<StakeCreatedEvent<TEST_SHARE>>();
    assert_eq!(created.length(), 1);
    let (created_id, sender, amount, count) = stake::created_event_fields(&created[0]);
    assert_eq!(created_id, stake_id.to_address());
    assert_eq!(sender, @0x0);
    assert_eq!(amount, 100);
    assert_eq!(count, 0);
    assert!(stake.value() == 100);
    assert!(stake.registration_count() == 0);
    let balance = stake::destroy(stake);
    let destroyed = event::events_by_type<StakeDestroyedEvent<TEST_SHARE>>();
    assert_eq!(destroyed.length(), 1);
    let (destroyed_id, destroyed_amount, destroyed_count) =
        stake::destroyed_event_fields(&destroyed[0]);
    assert_eq!(destroyed_id, stake_id.to_address());
    assert_eq!(destroyed_amount, 100);
    assert_eq!(destroyed_count, 0);
    balance::destroy_for_testing(balance);
}

#[test, expected_failure(abort_code = stake::EZeroBalance)]
fun test_stake_rejects_zero_balance() {
    let mut ctx = tx_context::dummy();
    let stake = stake::new(balance::create_for_testing<TEST_SHARE>(0), &mut ctx);
    let balance = stake::destroy(stake);
    balance::destroy_for_testing(balance);
}

// === Core register → deposit → claim → unregister flow ===

#[test]
fun test_single_staker_claims_full_deposit() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    assert!(pool.staked_shares() == 100);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 1_000);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    assert!(pool.balance().value() == 1_000);
    let reward = pool.claim_rewards(&mut s);
    assert!(reward.value() == 1_000);
    assert!(pool.balance().value() == 0);

    pool.unregister_stake(&mut s);
    assert!(pool.staked_shares() == 0);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    balance::destroy_for_testing(reward);
    test_scenario::end(scenario);
}

#[test]
fun test_two_stakes_proportional_split() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut a = new_stake(&mut scenario, 100);
    let mut b = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut a);
    pool.register_stake(&mut b);
    assert!(pool.staked_shares() == 200);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 1_000);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let r_a = pool.claim_rewards(&mut a);
    let r_b = pool.claim_rewards(&mut b);
    assert!(r_a.value() == 500);
    assert!(r_b.value() == 500);
    assert!(pool.balance().value() == 0);
    pool.unregister_stake(&mut a);
    pool.unregister_stake(&mut b);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(a));
    balance::destroy_for_testing(stake::destroy(b));
    balance::destroy_for_testing(r_a);
    balance::destroy_for_testing(r_b);
    test_scenario::end(scenario);
}

#[test]
fun test_unequal_stakes_proportional_split() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut a = new_stake(&mut scenario, 300);
    let mut b = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut a);
    pool.register_stake(&mut b);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 1_000);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let r_a = pool.claim_rewards(&mut a);
    let r_b = pool.claim_rewards(&mut b);
    assert!(r_a.value() == 750);
    assert!(r_b.value() == 250);
    pool.unregister_stake(&mut a);
    pool.unregister_stake(&mut b);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(a));
    balance::destroy_for_testing(stake::destroy(b));
    balance::destroy_for_testing(r_a);
    balance::destroy_for_testing(r_b);
    test_scenario::end(scenario);
}

#[test]
fun test_claim_twice_second_yields_zero() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 500);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let r1 = pool.claim_rewards(&mut s);
    let r2 = pool.claim_rewards(&mut s);
    assert!(r1.value() == 500);
    assert!(r2.value() == 0);
    assert_eq!(event::events_by_type<RoyaltyClaimedEvent<TEST_SHARE, TEST_CURRENCY>>().length(), 1);
    pool.unregister_stake(&mut s);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    balance::destroy_for_testing(r1);
    balance::destroy_for_testing(r2);
    test_scenario::end(scenario);
}

#[test]
fun test_claim_pays_only_delta_since_last_claim() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 500);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let r1 = pool.claim_rewards(&mut s);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 200);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let r2 = pool.claim_rewards(&mut s);
    assert!(r1.value() == 500);
    assert!(r2.value() == 200);
    pool.unregister_stake(&mut s);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    balance::destroy_for_testing(r1);
    balance::destroy_for_testing(r2);
    test_scenario::end(scenario);
}

#[test]
fun test_re_register_after_destroy_no_retroactive_earnings() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut a = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut a);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 500);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let r1 = pool.claim_rewards(&mut a);
    assert!(r1.value() == 500);
    pool.unregister_stake(&mut a);
    test_scenario::return_shared(pool);

    let recovered = stake::destroy(a);
    let mut b = stake::new(recovered, scenario.ctx());

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut b);
    let r2 = pool.claim_rewards(&mut b);
    assert!(r2.value() == 0);
    pool.unregister_stake(&mut b);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(b));
    balance::destroy_for_testing(r1);
    balance::destroy_for_testing(r2);
    test_scenario::end(scenario);
}

// === Abort paths ===

#[test, expected_failure(abort_code = pool::ENoStakedShares)]
fun test_deposit_aborts_with_zero_staked_shares() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);
    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 100);
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = pool::EInvalidValue)]
fun test_deposit_aborts_with_zero_value() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 0);

    // Cleanup never reached — included to satisfy the type checker.
    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = pool::EAlreadyRegistered)]
fun test_register_aborts_if_already_registered() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = pool::ENotRegistered)]
fun test_claim_aborts_if_unregistered() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    let r = pool.claim_rewards(&mut s);
    balance::destroy_for_testing(r);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = pool::ENotRegistered)]
fun test_unregister_aborts_if_unregistered() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.unregister_stake(&mut s);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = pool::ELastClaimIndexMismatch)]
fun test_unregister_aborts_if_unclaimed_rewards_pending() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 500);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    pool.unregister_stake(&mut s); // aborts: didn't claim first
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = stake::EPoolsRegistered)]
fun test_destroy_aborts_with_active_registrations() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    let b = stake::destroy(s); // aborts
    balance::destroy_for_testing(b);
    test_scenario::end(scenario);
}

// === Multi-currency on a single stake ===

#[test]
/// A single stake registers with two pools of different currencies and
/// claims independently from each.
fun test_two_currencies_same_stake() {
    let mut scenario = test_scenario::begin(ALICE);

    scenario.next_tx(ALICE);
    let mut parent = object::new(scenario.ctx());
    let pool_a = pool::new<TEST_SHARE, TEST_CURRENCY>(&mut parent);
    let pool_b = pool::new<TEST_SHARE, OTHER_CURRENCY>(&mut parent);
    let id_a = object::id(&pool_a);
    let id_b = object::id(&pool_b);
    pool_a.share();
    pool_b.share();
    destroy(parent);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool_a = scenario.take_shared_by_id<RoyaltyPool<TEST_SHARE, TEST_CURRENCY>>(id_a);
    let mut pool_b = scenario.take_shared_by_id<RoyaltyPool<TEST_SHARE, OTHER_CURRENCY>>(id_b);
    pool_a.register_stake(&mut s);
    pool_b.register_stake(&mut s);
    assert!(s.registration_count() == 2);
    let registered = event::events_by_type<StakeRegisteredEvent<TEST_SHARE, TEST_CURRENCY>>();
    let b =
        event::events_by_type<StakeRegisteredEvent<TEST_SHARE, OTHER_CURRENCY>>();
    assert_eq!(registered.length(), 1);
    assert_eq!(b.length(), 1);
    {
        let (_, _, _, debt, count, _, _, _, _, _) =
            pool::stake_registered_event_fields(&registered[0]);
        assert_eq!(debt, 0);
        assert_eq!(count, 1);
    };
    {
        let (_, _, _, debt, count, _, _, _, _, _) =
            pool::stake_registered_event_fields(&b[0]);
        assert_eq!(debt, 0);
        assert_eq!(count, 2);
    };
    test_scenario::return_shared(pool_a);
    test_scenario::return_shared(pool_b);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, id_a, 500);
    send_to_pool<TEST_SHARE, OTHER_CURRENCY>(&mut scenario, id_b, 700);

    scenario.next_tx(ALICE);
    let mut pool_a = scenario.take_shared_by_id<RoyaltyPool<TEST_SHARE, TEST_CURRENCY>>(id_a);
    let mut pool_b = scenario.take_shared_by_id<RoyaltyPool<TEST_SHARE, OTHER_CURRENCY>>(id_b);
    let r_a = pool_a.claim_rewards(&mut s);
    let r_b = pool_b.claim_rewards(&mut s);
    assert!(r_a.value() == 500);
    assert!(r_b.value() == 700);
    pool_a.unregister_stake(&mut s);
    pool_b.unregister_stake(&mut s);
    assert!(s.registration_count() == 0);
    test_scenario::return_shared(pool_a);
    test_scenario::return_shared(pool_b);

    balance::destroy_for_testing(stake::destroy(s));
    balance::destroy_for_testing(r_a);
    balance::destroy_for_testing(r_b);
    test_scenario::end(scenario);
}

// === pending_rewards view ===

#[test]
fun test_pending_rewards_returns_zero_for_unregistered_stake() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let s = new_stake(&mut scenario, 100);
    let pool = take_pool(&scenario, pool_id);
    assert!(pool.pending_rewards(&s) == 0);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

#[test]
fun test_pending_rewards_matches_subsequent_claim() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 1_234);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let pending = pool.pending_rewards(&s);
    let claimed = pool.claim_rewards(&mut s);
    assert!(pending == claimed.value());
    assert!(pending == 1_234);
    pool.unregister_stake(&mut s);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    balance::destroy_for_testing(claimed);
    test_scenario::end(scenario);
}

// === Address derivation ===

#[test]
fun test_derived_address_matches_pool_address() {
    let mut scenario = test_scenario::begin(ALICE);

    scenario.next_tx(ALICE);
    let mut parent = object::new(scenario.ctx());
    let parent_id = parent.to_inner();
    let pool = pool::new<TEST_SHARE, TEST_CURRENCY>(&mut parent);
    let derived = pool::derived_address<TEST_SHARE, TEST_CURRENCY>(parent_id);
    assert!(derived == object::id_to_address(&object::id(&pool)));
    pool.assert_derived_from(parent_id);
    pool.share();
    destroy(parent);

    test_scenario::end(scenario);
}

#[test]
/// Sharing is silent and preserves an owned pool registered and funded before sharing.
fun test_sharing_is_silent_and_preserves_pre_share_state() {
    let mut scenario = test_scenario::begin(ALICE);
    scenario.next_tx(ALICE);
    let mut parent = object::new(scenario.ctx());
    let mut pool = pool::new<TEST_SHARE, TEST_CURRENCY>(&mut parent);
    let pool_id = object::id(&pool);
    let mut s = new_stake(&mut scenario, 100);
    pool.register_stake(&mut s);
    pool.deposit(balance::create_for_testing<TEST_CURRENCY>(250));
    let event_count = event::num_events();
    pool.share();
    assert_eq!(event::num_events(), event_count);
    let created = event::events_by_type<RoyaltyPoolCreatedEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(created.length(), 1);
    destroy(parent);
    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let reward = pool.claim_rewards(&mut s);
    assert_eq!(reward.value(), 250);
    pool.unregister_stake(&mut s);
    test_scenario::return_shared(pool);
    balance::destroy_for_testing(stake::destroy(s));
    balance::destroy_for_testing(reward);
    test_scenario::end(scenario);
}

#[test]
/// Event type identity is carried by both phantom parameters: pools with a
/// different Share type do not collapse into the same event stream.
fun test_event_type_separates_phantom_share_and_currency() {
    let mut scenario = test_scenario::begin(ALICE);
    scenario.next_tx(ALICE);
    let mut parent = object::new(scenario.ctx());
    let pool_a = pool::new<TEST_SHARE, TEST_CURRENCY>(&mut parent);
    let pool_b = pool::new<OTHER_SHARE, TEST_CURRENCY>(&mut parent);
    let a = event::events_by_type<RoyaltyPoolCreatedEvent<TEST_SHARE, TEST_CURRENCY>>();
    let b = event::events_by_type<RoyaltyPoolCreatedEvent<OTHER_SHARE, TEST_CURRENCY>>();
    assert_eq!(a.length(), 1);
    assert_eq!(b.length(), 1);
    pool_a.share();
    pool_b.share();
    destroy(parent);
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = pool::EPoolNotDerivedFromParent)]
fun test_assert_derived_from_aborts_for_wrong_parent() {
    let mut scenario = test_scenario::begin(ALICE);

    scenario.next_tx(ALICE);
    let mut parent = object::new(scenario.ctx());
    let other = object::new(scenario.ctx());
    let pool = pool::new<TEST_SHARE, TEST_CURRENCY>(&mut parent);
    pool.assert_derived_from(other.to_inner()); // aborts
    pool.share();
    destroy(parent);
    destroy(other);

    test_scenario::end(scenario);
}

// === Late register: no retroactive earnings ===

#[test]
fun test_late_register_no_retroactive_share() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut a = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut a);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 1_000);

    scenario.next_tx(ALICE);
    let mut b = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut b);
    let registered = event::events_by_type<StakeRegisteredEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(registered.length(), 1);
    let (_, _, _, debt, count, _, _, _, _, _) =
        pool::stake_registered_event_fields(&registered[0]);
    assert_eq!(debt, 1_000_000_000_000_000_000_000);
    assert_eq!(count, 1);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 200);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let r_a = pool.claim_rewards(&mut a);
    let r_b = pool.claim_rewards(&mut b);
    assert!(r_a.value() == 1_100);
    assert!(r_b.value() == 100);
    pool.unregister_stake(&mut a);
    pool.unregister_stake(&mut b);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(a));
    balance::destroy_for_testing(stake::destroy(b));
    balance::destroy_for_testing(r_a);
    balance::destroy_for_testing(r_b);
    test_scenario::end(scenario);
}

// === Consumed-index advance: fractional holders preserve credit ===

#[test]
/// A small holder claiming after every sub-threshold deposit recovers their
/// full proportional share over time. Without the consumed-index advance
/// they'd lose all credit each round.
///
/// Setup: total staked = 1_000_000 (one whole share at d=6); holder A has
/// 100 base units (1/10_000th of a whole share); holder B has the rest. Each
/// 100-base-unit deposit advances cum by 1e14, yielding A a per-round reward
/// of `100 * 1e14 / 1e18 = 0.01 → 0` (truncated). Across 100 rounds, A's
/// fair share is exactly 1 base unit; with the fix, that's what they collect.
fun test_fractional_holder_credit_preserved_across_zero_claims() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut a = new_stake(&mut scenario, 100);
    let mut b = new_stake(&mut scenario, 999_900);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut a);
    pool.register_stake(&mut b);
    test_scenario::return_shared(pool);

    let mut acc_a = balance::zero<TEST_CURRENCY>();
    100u64.do!(|_| {
        send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 100);
        scenario.next_tx(ALICE);
        let mut pool = take_pool(&scenario, pool_id);
        acc_a.join(pool.claim_rewards(&mut a));
        test_scenario::return_shared(pool);
    });

    // A claimed 0 base units for 99 rounds, then 1 on round 100 — recovering
    // their full 1-base-unit fair share over the 100 small deposits.
    assert!(acc_a.value() == 1);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let r_b = pool.claim_rewards(&mut b);
    assert!(r_b.value() == 9_999);
    assert!(pool.balance().value() == 0);
    pool.unregister_stake(&mut a);
    pool.unregister_stake(&mut b);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(a));
    balance::destroy_for_testing(stake::destroy(b));
    balance::destroy_for_testing(acc_a);
    balance::destroy_for_testing(r_b);
    test_scenario::end(scenario);
}

#[test]
/// A sole staker (`staked_amount == staked_shares`) with a non-evenly
/// divisible deposit: the index advances by ⌊2 · 1e18 / 6⌋ and the 2 index
/// units of remainder stay in `carry`. The stake is owed exactly
/// ⌊6 · index / 1e18⌋ = 1 base unit (1.999… truncated) — the second unit is
/// sub-unit residue that no rounding may inflate into a payout. A second
/// claim yields 0, and unregister succeeds with the residue forfeited; the
/// leftover base unit remains in the pool, backed by carry + residue.
fun test_sole_staker_indivisible_deposit_pays_exact_floor() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 6);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 2);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    assert_eq!(pool.cumulative_reward_per_share(), 333_333_333_333_333_333);
    assert_eq!(pool.carry(), 2);
    let r1 = pool.claim_rewards(&mut s);
    let r2 = pool.claim_rewards(&mut s);
    assert_eq!(r1.value(), 1);
    assert_eq!(r2.value(), 0);
    assert_eq!(pool.balance().value(), 1);
    assert_eq!(pool.pending_rewards(&s), 0);

    let claims = event::events_by_type<RoyaltyClaimedEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(claims.length(), 1);
    let (_, _, _, amount, _, _, residue, count, bal, shares, index, carry, deposits) =
        pool::royalty_claimed_event_fields(&claims[0]);
    assert_eq!(amount, 1);
    assert_eq!(residue, 999_999_999_999_999_998);
    assert_eq!(count, 1);
    assert_eq!(bal, 1);
    assert_eq!(shares, 6);
    assert_eq!(index, 333_333_333_333_333_333);
    assert_eq!(carry, 2);
    assert_eq!(deposits, 2);

    pool.unregister_stake(&mut s);
    let unregistered = event::events_by_type<StakeUnregisteredEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(unregistered.length(), 1);
    let (_, _, _, debt, forfeited, count, bal, shares, index, carry, deposits) =
        pool::stake_unregistered_event_fields(&unregistered[0]);
    assert_eq!(debt, 1_000_000_000_000_000_000);
    assert_eq!(forfeited, 999_999_999_999_999_998);
    assert_eq!(count, 0);
    assert_eq!(bal, 1);
    assert_eq!(shares, 0);
    assert_eq!(index, 333_333_333_333_333_333);
    assert_eq!(carry, 2);
    assert_eq!(deposits, 2);
    // Exact accounting: balance · 1e18 == carry + forfeited residue.
    // residue = 6 · index − debt = 1_999_999_999_999_999_998 − 1e18.
    assert_eq!((pool.balance().value() as u256) * 1_000_000_000_000_000_000, 2 + 999_999_999_999_999_998);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    balance::destroy_for_testing(r1);
    balance::destroy_for_testing(r2);
    test_scenario::end(scenario);
}

#[test]
/// Repeated maximum deposits exercise the u128 lifetime total and u256 index
/// fields without overflowing a single u64 balance (each deposit is claimed
/// before the next one).
fun test_rich_event_widths_across_nineteen_max_deposits() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);
    let max = std::u64::max_value!();
    let precision = 1_000_000_000_000_000_000u256;

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, max);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    let mut i = 0u64;
    while (i < 19) {
        scenario.next_tx(ALICE);
        let mut pool = take_pool(&scenario, pool_id);
        pool.deposit(balance::create_for_testing<TEST_CURRENCY>(max));
        let deposits = event::events_by_type<RoyaltyDepositedEvent<TEST_SHARE, TEST_CURRENCY>>();
        assert_eq!(deposits.length(), 1);
        let (_, value, before, before_carry, balance, shares, index, carry, total) =
            pool::deposited_event_fields(&deposits[0]);
        let n = (i + 1) as u256;
        assert_eq!(value, max);
        assert_eq!(before, (i as u256) * precision);
        assert_eq!(before_carry, 0);
        assert_eq!(balance, max);
        assert_eq!(shares, max);
        assert_eq!(index, n * precision);
        assert_eq!(carry, 0);
        assert_eq!(total, (i + 1) as u128 * (max as u128));

        let reward = pool.claim_rewards(&mut s);
        assert_eq!(reward.value(), max);
        let claims = event::events_by_type<RoyaltyClaimedEvent<TEST_SHARE, TEST_CURRENCY>>();
        assert_eq!(claims.length(), 1);
        let (_, _, amount, value, debt_before, debt_after, residue, _, balance, shares, index, carry, total) =
            pool::royalty_claimed_event_fields(&claims[0]);
        assert_eq!(amount, max);
        assert_eq!(value, max);
        assert_eq!(debt_before, (i as u256) * (max as u256) * precision);
        assert_eq!(debt_after, n * (max as u256) * precision);
        assert_eq!(residue, 0);
        assert_eq!(balance, 0);
        assert_eq!(shares, max);
        assert_eq!(index, n * precision);
        assert_eq!(carry, 0);
        assert_eq!(total, (i + 1) as u128 * (max as u128));
        test_scenario::return_shared(pool);
        balance::destroy_for_testing(reward);
        i = i + 1;
    };

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    pool.unregister_stake(&mut s);
    test_scenario::return_shared(pool);
    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

// === Recovery paths: recover_coins ===

#[test]
/// A `Coin<C>` transferred directly to the pool's address is converted into
/// funds at the same address by `recover_coins` — it deposits nothing.
/// The return value equals the coin's value, a `RoyaltyPoolCoinsRecoveredEvent` is
/// emitted, the pool's `balance` is unchanged, and the coin object no longer
/// exists (as a receivable) at the pool's address.
fun test_recover_coins_converts_without_depositing() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    // Royalty payer (or a confused user) transfers a coin straight to the
    // pool's address instead of going through the distributor.
    scenario.next_tx(ALICE);
    let coin = coin::from_balance(
        balance::create_for_testing<TEST_CURRENCY>(500),
        scenario.ctx(),
    );
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, pool_id.to_address());

    // Anyone can recover it by calling recover_coins on the pool.
    scenario.next_tx(ALICE);
    assert_eq!(
        test_scenario::receivable_object_ids_for_owner_id<Coin<TEST_CURRENCY>>(pool_id),
        vector[coin_id],
    );
    let mut pool = take_pool(&scenario, pool_id);
    let ticket = test_scenario::receiving_ticket_by_id<Coin<TEST_CURRENCY>>(coin_id);
    let value = pool.recover_coins(vector[ticket]);
    assert_eq!(value, 500);

    let recovered = event::events_by_type<RoyaltyPoolCoinsRecoveredEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(recovered.length(), 1);
    let (event_pool_id, event_count, event_recipient, event_value, event_balance, event_shares, event_index, event_carry, event_deposits) =
        pool::coins_recovered_event_fields(&recovered[0]);
    assert_eq!(event_pool_id, pool_id.to_address());
    assert_eq!(event_count, 1);
    assert_eq!(event_recipient, pool_id.to_address());
    assert_eq!(event_value, 500);
    assert_eq!(event_balance, 0);
    assert_eq!(event_shares, 100);
    assert_eq!(event_index, 0);
    assert_eq!(event_carry, 0);
    assert_eq!(event_deposits, 0);

    // Converted, not deposited: the balance is untouched.
    assert_eq!(pool.balance().value(), 0);
    pool.unregister_stake(&mut s);
    test_scenario::return_shared(pool);

    // The coin no longer exists as a receivable at the pool's address —
    // visible once this transaction's effects land.
    scenario.next_tx(ALICE);
    assert_eq!(
        test_scenario::receivable_object_ids_for_owner_id<Coin<TEST_CURRENCY>>(pool_id),
        vector[],
    );

    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

#[test]
/// An empty `coins` vector is a no-op: returns 0 and emits nothing.
fun test_recover_coins_empty_vector_is_noop() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let value = pool.recover_coins(vector[]);
    assert_eq!(value, 0);
    assert_eq!(
        event::events_by_type<RoyaltyPoolCoinsRecoveredEvent<TEST_SHARE, TEST_CURRENCY>>().length(),
        0,
    );
    assert_eq!(pool.balance().value(), 0);
    test_scenario::return_shared(pool);

    test_scenario::end(scenario);
}

#[test]
/// A nonempty vector still emits a recovery event when all received coins
/// have zero value.
fun test_recover_coins_nonempty_zero_value_emits_event() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let coin = coin::from_balance(
        balance::create_for_testing<TEST_CURRENCY>(0),
        scenario.ctx(),
    );
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, pool_id.to_address());

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let ticket = test_scenario::receiving_ticket_by_id<Coin<TEST_CURRENCY>>(coin_id);
    assert_eq!(pool.recover_coins(vector[ticket]), 0);
    let recovered = event::events_by_type<RoyaltyPoolCoinsRecoveredEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(recovered.length(), 1);
    let (event_pool_id, count, recipient, value, balance, shares, index, carry, deposits) =
        pool::coins_recovered_event_fields(&recovered[0]);
    assert_eq!(event_pool_id, pool_id.to_address());
    assert_eq!(count, 1);
    assert_eq!(recipient, pool_id.to_address());
    assert_eq!(value, 0);
    assert_eq!(balance, 0);
    assert_eq!(shares, 0);
    assert_eq!(index, 0);
    assert_eq!(carry, 0);
    assert_eq!(deposits, 0);
    test_scenario::return_shared(pool);
    test_scenario::end(scenario);
}

#[test]
/// Batch recovery preserves receiving-ticket order and consumes every input
/// coin while reporting the aggregate value.
fun test_recover_coins_batch_preserves_ids_and_consumes_coins() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let coin_a = coin::from_balance(
        balance::create_for_testing<TEST_CURRENCY>(100),
        scenario.ctx(),
    );
    let coin_b = coin::from_balance(
        balance::create_for_testing<TEST_CURRENCY>(200),
        scenario.ctx(),
    );
    let id_a = object::id(&coin_a);
    let id_b = object::id(&coin_b);
    transfer::public_transfer(coin_a, pool_id.to_address());
    transfer::public_transfer(coin_b, pool_id.to_address());

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let ticket_a = test_scenario::receiving_ticket_by_id<Coin<TEST_CURRENCY>>(id_a);
    let ticket_b = test_scenario::receiving_ticket_by_id<Coin<TEST_CURRENCY>>(id_b);
    assert_eq!(pool.recover_coins(vector[ticket_a, ticket_b]), 300);
    let recovered = event::events_by_type<RoyaltyPoolCoinsRecoveredEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(recovered.length(), 1);
    let (_, count, _, value, _, _, _, _, _) =
        pool::coins_recovered_event_fields(&recovered[0]);
    assert_eq!(count, 2);
    assert_eq!(value, 300);
    test_scenario::return_shared(pool);

    scenario.next_tx(ALICE);
    assert_eq!(
        test_scenario::receivable_object_ids_for_owner_id<Coin<TEST_CURRENCY>>(pool_id),
        vector[],
    );
    test_scenario::end(scenario);
}

// === Recovery paths: settle ===

#[test]
/// `settle` with nothing settled at the pool's address returns 0 and
/// changes nothing: balance and index are unchanged, and no
/// `RoyaltyDepositedEvent` is emitted. Executed by STRANGER to pin that the
/// entry is permissionless.
fun settle_with_nothing_settled_is_a_noop() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    scenario.next_tx(STRANGER);
    let mut pool = take_pool(&scenario, pool_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let value = pool.settle(&root);
    assert_eq!(value, 0);
    assert_eq!(pool.balance().value(), 0);
    assert_eq!(pool.cumulative_reward_per_share(), 0);
    assert_eq!(
        event::events_by_type<RoyaltyDepositedEvent<TEST_SHARE, TEST_CURRENCY>>().length(),
        0,
    );
    assert_eq!(
        event::events_by_type<RoyaltyPoolFundsSettledEvent<TEST_SHARE, TEST_CURRENCY>>().length(),
        0,
    );
    pool.unregister_stake(&mut s);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(root);

    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

#[test]
/// `settle` on a pool with `staked_shares == 0` returns 0 without ever
/// reading the accumulator — the unit VM cannot seed settled funds, so this
/// test only pins the guard order (stakers checked before any accumulator
/// read): no `RoyaltyDepositedEvent` is emitted and the balance is
/// unchanged, exactly as the empty-settled case above.
fun settle_with_no_stakers_is_a_noop() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(STRANGER);
    let mut pool = take_pool(&scenario, pool_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    let value = pool.settle(&root);
    assert_eq!(value, 0);
    assert_eq!(pool.balance().value(), 0);
    assert_eq!(
        event::events_by_type<RoyaltyDepositedEvent<TEST_SHARE, TEST_CURRENCY>>().length(),
        0,
    );
    assert_eq!(
        event::events_by_type<RoyaltyPoolFundsSettledEvent<TEST_SHARE, TEST_CURRENCY>>().length(),
        0,
    );
    test_scenario::return_shared(pool);
    test_scenario::return_shared(root);

    test_scenario::end(scenario);
}

#[test]
/// `settled_value` reads 0 for a pool with nothing settled at its address —
/// the only value the unit VM can ever populate this view with.
fun settled_value_reads_zero() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let pool = take_pool(&scenario, pool_id);
    let root = scenario.take_shared<AccumulatorRoot>();
    assert_eq!(pool.settled_value(&root), 0);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(root);

    test_scenario::end(scenario);
}

// === View accessors ===

#[test]
/// The remaining view accessors: stake identity and balance access, direct
/// registration reads, the raw accumulator index, and `pending_rewards`
/// against a pool the stake is registered with — but not this one.
fun test_view_accessors_track_registration_lifecycle() {
    let mut scenario = test_scenario::begin(ALICE);
    let (id_a, id_b) = create_two_pools_same_currency(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let stake_id = object::id(&s);
    assert!(s.balance().value() == 100);

    let currency = type_name::with_defining_ids<TEST_CURRENCY>();
    assert!(!s.has_registration(&currency));

    let mut pool_a = take_pool(&scenario, id_a);
    assert!(pool_a.cumulative_reward_per_share() == 0);
    pool_a.register_stake(&mut s);
    assert!(s.has_registration(&currency));
    let registration = s.get_registration(&currency);
    assert!(stake::registration_pool_id(registration) == id_a);
    assert!(stake::registration_debt(registration) == 0);
    test_scenario::return_shared(pool_a);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, id_a, 1_000);

    scenario.next_tx(ALICE);
    let mut pool_a = take_pool(&scenario, id_a);
    let pool_b = take_pool(&scenario, id_b);
    // The accumulator advanced by 1_000 * PRECISION / 100.
    assert!(pool_a.cumulative_reward_per_share() == 10_000_000_000_000_000_000);
    // Registered with pool A, not pool B: B reports zero pending.
    assert!(pool_a.pending_rewards(&s) == 1_000);
    assert!(pool_b.pending_rewards(&s) == 0);

    let reward = pool_a.claim_rewards(&mut s);
    assert!(reward.value() == 1_000);
    // The claim consumed the full entitlement: debt == shares · index.
    let registration = s.get_registration(&currency);
    assert!(
        stake::registration_debt(registration) == 100 * pool_a.cumulative_reward_per_share(),
    );

    pool_a.unregister_stake(&mut s);
    assert!(object::id(&s) == stake_id);
    test_scenario::return_shared(pool_a);
    test_scenario::return_shared(pool_b);

    balance::destroy_for_testing(stake::destroy(s));
    balance::destroy_for_testing(reward);
    test_scenario::end(scenario);
}

// === cumulative_deposits ===

#[test]
fun test_cumulative_deposits_tracks_lifetime_inflows() {
    let mut scenario = test_scenario::begin(ALICE);
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    assert!(pool.cumulative_deposits() == 0);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 100);

    scenario.next_tx(ALICE);
    let pool = take_pool(&scenario, pool_id);
    assert!(pool.cumulative_deposits() == 100);
    test_scenario::return_shared(pool);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, pool_id, 250);

    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    assert!(pool.cumulative_deposits() == 350);

    // Claims do not affect cumulative_deposits.
    let r = pool.claim_rewards(&mut s);
    assert!(pool.cumulative_deposits() == 350);
    pool.unregister_stake(&mut s);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    balance::destroy_for_testing(r);
    test_scenario::end(scenario);
}

// === Cross-pool, same Currency ===

/// Create two `RoyaltyPool<TEST_SHARE, TEST_CURRENCY>` pools derived from two
/// different parents (one parent cannot host two pools of the same Currency).
fun create_two_pools_same_currency(scenario: &mut Scenario): (ID, ID) {
    scenario.next_tx(ALICE);
    let mut parent_a = object::new(scenario.ctx());
    let mut parent_b = object::new(scenario.ctx());
    let pool_a = pool::new<TEST_SHARE, TEST_CURRENCY>(&mut parent_a);
    let pool_b = pool::new<TEST_SHARE, TEST_CURRENCY>(&mut parent_b);
    let id_a = object::id(&pool_a);
    let id_b = object::id(&pool_b);
    pool_a.share();
    pool_b.share();
    destroy(parent_a);
    destroy(parent_b);
    (id_a, id_b)
}

#[test, expected_failure(abort_code = pool::EAlreadyRegistered)]
/// Registrations are keyed by `Currency`, not by pool: a stake registered
/// with one pool cannot also register with another pool of the same
/// Currency — this is what blocks double-counting the same shares.
fun test_register_aborts_at_second_pool_same_currency() {
    let mut scenario = test_scenario::begin(ALICE);
    let (id_a, id_b) = create_two_pools_same_currency(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool_a = take_pool(&scenario, id_a);
    pool_a.register_stake(&mut s);
    test_scenario::return_shared(pool_a);

    scenario.next_tx(ALICE);
    let mut pool_b = take_pool(&scenario, id_b);
    pool_b.register_stake(&mut s); // aborts
    test_scenario::return_shared(pool_b);

    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = pool::EPoolIdMismatch)]
/// A stake registered with pool A cannot claim from pool B (same Currency):
/// the registration records the pool it belongs to.
fun test_claim_aborts_at_wrong_pool() {
    let mut scenario = test_scenario::begin(ALICE);
    let (id_a, id_b) = create_two_pools_same_currency(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool_a = take_pool(&scenario, id_a);
    pool_a.register_stake(&mut s);
    test_scenario::return_shared(pool_a);

    send_to_pool<TEST_SHARE, TEST_CURRENCY>(&mut scenario, id_a, 500);

    scenario.next_tx(ALICE);
    let mut pool_b = take_pool(&scenario, id_b);
    let r = pool_b.claim_rewards(&mut s); // aborts
    balance::destroy_for_testing(r);
    test_scenario::return_shared(pool_b);

    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}

// === Event payloads ===

fun assert_created_payload(
    event: &RoyaltyPoolCreatedEvent<TEST_SHARE, TEST_CURRENCY>,
    pool_id: address,
    parent_id: address,
) {
    let (
        event_pool_id,
        event_parent_id,
        precision,
        balance,
        shares,
        index,
        carry,
        deposits,
    ) = pool::created_event_fields(event);
    assert_eq!(event_pool_id, pool_id);
    assert_eq!(event_parent_id, parent_id);
    assert_eq!(precision, 1_000_000_000_000_000_000);
    assert_eq!(balance, 0);
    assert_eq!(shares, 0);
    assert_eq!(index, 0);
    assert_eq!(carry, 0);
    assert_eq!(deposits, 0);
}

fun assert_stake_created_payload(event: &StakeCreatedEvent<TEST_SHARE>, stake_id: address) {
    let (event_stake_id, sender, amount, count) = stake::created_event_fields(event);
    assert_eq!(event_stake_id, stake_id);
    assert_eq!(sender, ALICE);
    assert_eq!(amount, 100);
    assert_eq!(count, 0);
}

fun assert_registered_payload(
    event: &StakeRegisteredEvent<TEST_SHARE, TEST_CURRENCY>,
    pool_id: address,
    stake_id: address,
) {
    let (
        event_pool_id,
        event_stake_id,
        amount,
        debt,
        count,
        balance,
        shares,
        index,
        carry,
        deposits,
    ) = pool::stake_registered_event_fields(event);
    assert_eq!(event_pool_id, pool_id);
    assert_eq!(event_stake_id, stake_id);
    assert_eq!(amount, 100);
    assert_eq!(debt, 0);
    assert_eq!(count, 1);
    assert_eq!(balance, 0);
    assert_eq!(shares, 100);
    assert_eq!(index, 0);
    assert_eq!(carry, 0);
    assert_eq!(deposits, 0);
}

#[test]
/// Every event this package emits, across the full create → register →
/// deposit → claim → unregister → destroy lifecycle, with the exact payload
/// pinned. Read back in the same transaction as each emitting call —
/// `test_scenario` clears the recorded event log across a `next_tx`
/// boundary.
fun test_full_lifecycle_emits_expected_events_with_exact_payloads() {
    let mut scenario = test_scenario::begin(ALICE);

    // --- Tx 1: pool creation ---
    let mut parent = object::new(scenario.ctx());
    let _parent_id = parent.to_inner();
    let pool = pool::new<TEST_SHARE, TEST_CURRENCY>(&mut parent);
    let pool_id = object::id(&pool);
    let created = event::events_by_type<RoyaltyPoolCreatedEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(created.length(), 1);
    assert_created_payload(&created[0], pool_id.to_address(), _parent_id.to_address());
    pool.share();
    destroy(parent);

    // --- Tx 2: stake creation ---
    scenario.next_tx(ALICE);
    let mut s = stake::new(balance::create_for_testing<TEST_SHARE>(100), scenario.ctx());
    let _stake_id = object::id(&s);
    let stake_created = event::events_by_type<StakeCreatedEvent<TEST_SHARE>>();
    assert_eq!(stake_created.length(), 1);
    assert_stake_created_payload(&stake_created[0], _stake_id.to_address());

    // --- Tx 3: register ---
    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    let registered = event::events_by_type<StakeRegisteredEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(registered.length(), 1);
    assert_registered_payload(&registered[0], pool_id.to_address(), _stake_id.to_address());
    test_scenario::return_shared(pool);

    // --- Tx 4: deposit ---
    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    pool.deposit(balance::create_for_testing<TEST_CURRENCY>(1_000));
    let deposited = event::events_by_type<RoyaltyDepositedEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(deposited.length(), 1);
    let (d_pool_id, d_value, _, _, _, _, _, _, _) =
        pool::deposited_event_fields(&deposited[0]);
    assert_eq!(d_pool_id, pool_id.to_address());
    assert_eq!(d_value, 1_000);
    test_scenario::return_shared(pool);

    // --- Tx 5: claim + unregister ---
    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let reward = pool.claim_rewards(&mut s);
    let claimed = event::events_by_type<RoyaltyClaimedEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(claimed.length(), 1);
    let (c_pool_id, c_stake_id, _, c_amount, _, _, _, _, _, _, _, _, _) =
        pool::royalty_claimed_event_fields(&claimed[0]);
    assert_eq!(c_pool_id, pool_id.to_address());
    assert_eq!(c_stake_id, _stake_id.to_address());
    assert_eq!(c_amount, 1_000);

    pool.unregister_stake(&mut s);
    let unregistered = event::events_by_type<StakeUnregisteredEvent<TEST_SHARE, TEST_CURRENCY>>();
    assert_eq!(unregistered.length(), 1);
    let (u_pool_id, u_stake_id, u_amount, _, _, _, _, _, _, _, _) =
        pool::stake_unregistered_event_fields(&unregistered[0]);
    assert_eq!(u_pool_id, pool_id.to_address());
    assert_eq!(u_stake_id, _stake_id.to_address());
    assert_eq!(u_amount, 100);
    test_scenario::return_shared(pool);

    // --- Tx 6: destroy ---
    scenario.next_tx(ALICE);
    let recovered = stake::destroy(s);
    let destroyed = event::events_by_type<StakeDestroyedEvent<TEST_SHARE>>();
    assert_eq!(destroyed.length(), 1);
    let (x_stake_id, x_amount, _) = stake::destroyed_event_fields(&destroyed[0]);
    assert_eq!(x_stake_id, _stake_id.to_address());
    assert_eq!(x_amount, 100);

    balance::destroy_for_testing(recovered);
    balance::destroy_for_testing(reward);
    test_scenario::end(scenario);
}

// === Permissionless funding, proven by sender ===

#[test]
/// The pool's directly testable funding paths — `deposit` and
/// `recover_coins` — are permissionless by construction: they take
/// `&mut RoyaltyPool` (shared) and need no capability. Proven here by a
/// STRANGER sender who owns nothing (no cap, no stake, nothing from ALICE's
/// setup), with ALICE's registered stake as the sole beneficiary of the
/// `deposit`. `recover_coins` only converts a payer's stray coin into funds
/// at the pool's own address — it does not deposit — so it contributes
/// nothing further to ALICE's claim; the Move unit VM does not populate
/// funded `AccumulatorRoot` reads, so folding that converted value in via
/// `settle` requires localnet coverage for a funded success case.
fun stranger_funds_pool_without_capability() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    let pool_id = create_pool(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool = take_pool(&scenario, pool_id);
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);

    // --- STRANGER, tx: direct `deposit` ---
    scenario.next_tx(STRANGER);
    let mut pool = take_pool(&scenario, pool_id);
    pool.deposit(balance::create_for_testing<TEST_CURRENCY>(300));
    test_scenario::return_shared(pool);

    // --- STRANGER, tx: `recover_coins` converts a coin sent to the pool's
    // address by yet another party (the payer) into settled funds there ---
    scenario.next_tx(ALICE);
    let coin = coin::from_balance(balance::create_for_testing<TEST_CURRENCY>(500), scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, pool_id.to_address());

    scenario.next_tx(STRANGER);
    let mut pool = take_pool(&scenario, pool_id);
    let ticket = test_scenario::receiving_ticket_by_id<Coin<TEST_CURRENCY>>(coin_id);
    let recovered_value = pool.recover_coins(vector[ticket]);
    assert_eq!(recovered_value, 500);
    // Nothing deposited: recover_coins only converts, never applies.
    assert_eq!(pool.balance().value(), 300);
    test_scenario::return_shared(pool);

    // --- ALICE, tx: the registered stake collects only what was actually
    // deposited; the recovered coin awaits a later `settle` ---
    scenario.next_tx(ALICE);
    let mut pool = take_pool(&scenario, pool_id);
    let reward = pool.claim_rewards(&mut s);
    assert_eq!(reward.value(), 300);
    assert_eq!(pool.balance().value(), 0);
    pool.unregister_stake(&mut s);
    test_scenario::return_shared(pool);

    balance::destroy_for_testing(stake::destroy(s));
    balance::destroy_for_testing(reward);
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = pool::EPoolIdMismatch)]
/// A stake registered with pool A cannot unregister from pool B (same
/// Currency).
fun test_unregister_aborts_at_wrong_pool() {
    let mut scenario = test_scenario::begin(ALICE);
    let (id_a, id_b) = create_two_pools_same_currency(&mut scenario);

    scenario.next_tx(ALICE);
    let mut s = new_stake(&mut scenario, 100);
    let mut pool_a = take_pool(&scenario, id_a);
    pool_a.register_stake(&mut s);
    test_scenario::return_shared(pool_a);

    scenario.next_tx(ALICE);
    let mut pool_b = take_pool(&scenario, id_b);
    pool_b.unregister_stake(&mut s); // aborts
    test_scenario::return_shared(pool_b);

    balance::destroy_for_testing(stake::destroy(s));
    test_scenario::end(scenario);
}
