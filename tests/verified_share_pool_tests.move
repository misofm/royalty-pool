// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production constructor and real native-share split coverage.
#[test_only]
module royalty_pool::verified_share_pool_tests;

use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use share::share;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::test_scenario;

public struct TEST_PAYOUT() has drop;

#[test]
fun production_pool_uses_subject_issuance_and_split_shares() {
    let ctx = &mut tx_context::dummy();
    let mut subject = object::new(ctx);
    let subject_id = subject.to_inner();
    let mut registry = share::registry_for_testing(ctx);
    let (issuance, mut supply) = share::initialize_for_testing(&mut registry, &mut subject);
    let issuance_id = object::id(&issuance);
    assert_eq!(supply.value(), share::max_supply!());

    let mut pool = pool::new<TEST_PAYOUT>(&mut subject, &issuance);
    assert_eq!(pool.issuance_id(), issuance_id);
    assert_eq!(object::id(&pool).to_address(), pool::derived_address<TEST_PAYOUT>(subject_id, issuance_id));
    let mut first = stake::new(supply.split(60), ctx);
    let mut second = stake::new(supply.split(40), ctx);
    assert_eq!(first.issuance_id(), issuance_id);
    assert_eq!(second.issuance_id(), issuance_id);
    pool.register_stake(&mut first);
    pool.register_stake(&mut second);
    pool.deposit(balance::create_for_testing<TEST_PAYOUT>(1_000));
    assert_eq!(pool.pending_rewards(&first), 600);
    assert_eq!(pool.pending_rewards(&second), 400);
    let first_reward = pool.claim_rewards(&mut first);
    let second_reward = pool.claim_rewards(&mut second);
    pool.unregister_stake(&mut first);
    pool.unregister_stake(&mut second);
    assert_eq!(first_reward.value(), 600);
    assert_eq!(second_reward.value(), 400);
    assert_eq!(pool.balance().value(), 0);
    destroy(first_reward); destroy(second_reward);
    destroy(stake::destroy(first)); destroy(stake::destroy(second));
    destroy(pool); destroy(supply); destroy(issuance); destroy(registry); destroy(subject);
}

#[test, expected_failure(abort_code = pool::EIssuanceSubjectMismatch)]
fun production_new_rejects_issuance_for_different_parent() {
    let ctx = &mut tx_context::dummy();
    let mut subject = object::new(ctx);
    let mut wrong_parent = object::new(ctx);
    let mut registry = share::registry_for_testing(ctx);
    let (issuance, supply) = share::initialize_for_testing(&mut registry, &mut subject);
    let pool = pool::new<TEST_PAYOUT>(&mut wrong_parent, &issuance);
    destroy(pool); destroy(supply); destroy(issuance); destroy(registry);
    destroy(subject); destroy(wrong_parent);
}

public struct Subject has key { id: UID }

#[test]
fun published_issuance_supports_pool_and_stake_across_transactions() {
    let admin = @0xA1;
    let mut scenario = test_scenario::begin(admin);
    let mut subject = Subject { id: object::new(scenario.ctx()) };
    let subject_id = object::id(&subject);
    let mut registry = share::registry_for_testing(scenario.ctx());
    let mut supply = share::initialize(&mut registry, &mut subject.id);
    let mut position = stake::new(supply.split(100), scenario.ctx());
    let stake_id = object::id(&position);
    transfer::public_transfer(position, admin);
    transfer::share_object(subject);
    destroy(supply); destroy(registry);

    scenario.next_tx(admin);
    let mut subject = scenario.take_shared<Subject>();
    let issuance = scenario.take_shared<share::Issuance>();
    assert_eq!(issuance.subject_id(), subject_id);
    let pool = pool::new<TEST_PAYOUT>(&mut subject.id, &issuance);
    let pool_id = object::id(&pool);
    pool.share();
    test_scenario::return_shared(subject);
    test_scenario::return_shared(issuance);

    scenario.next_tx(admin);
    let mut position = test_scenario::take_from_sender_by_id<stake::Stake>(&scenario, stake_id);
    let mut pool = scenario.take_shared_by_id<RoyaltyPool<TEST_PAYOUT>>(pool_id);
    pool.register_stake(&mut position);
    pool.deposit(balance::create_for_testing<TEST_PAYOUT>(25));
    let reward = pool.claim_rewards(&mut position);
    assert_eq!(reward.value(), 25);
    pool.unregister_stake(&mut position);
    test_scenario::return_shared(pool);
    destroy(reward); destroy(stake::destroy(position));
    scenario.end();
}
