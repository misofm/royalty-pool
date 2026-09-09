// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_revenue_distributor::release_revenue_distributor_tests;

use hikida::hikida;
use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_revenue_distributor::release_revenue_distributor as action;
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;
use vault::vault;

const EUnauthorized: u64 = 0;
const ENoCoinsToReceive: u64 = 0;
const ENoValueToRedeem: u64 = 1;

public struct CURRENCY() has drop;

fun fixture(ctx: &mut TxContext): (Release, ReleaseAdminCap, ID, ID) {
    let composition_id = test_helpers::fake_id(ctx);
    let recording_a = test_helpers::fake_id(ctx);
    let recording_b = test_helpers::fake_id(ctx);
    let target_release_id = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(composition_id, recording_a, target_release_id, 6_000),
        track::new_for_testing(composition_id, recording_b, target_release_id, 4_000),
    ];
    let (release, admin_cap) = release::new_for_testing("Release", tracks, ctx);
    (release, admin_cap, recording_a, recording_b)
}

#[test]
fun received_coins_are_combined_split_and_fully_reported() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut release, admin_cap, recording_a, recording_b) = fixture(scenario.ctx());
    let release_id = object::id(&release);
    let coin_a = coin::from_balance(balance::create_for_testing<CURRENCY>(6_000), scenario.ctx());
    let coin_b = coin::from_balance(balance::create_for_testing<CURRENCY>(4_001), scenario.ctx());
    let coin_a_id = object::id(&coin_a);
    let coin_b_id = object::id(&coin_b);
    transfer::public_transfer(coin_a, release_id.to_address());
    transfer::public_transfer(coin_b, release_id.to_address());

    scenario.next_tx(@0xB);
    action::receive_and_distribute(
        &mut release,
        &admin_cap,
        vector[
            test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(coin_a_id),
            test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(coin_b_id),
        ],
    );

    let track_events =
        event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(track_events.length(), 2);
    let (event_release_a, index_a, event_recording_a, amount_a) =
        action::track_event_fields(&track_events[0]);
    let (event_release_b, index_b, event_recording_b, amount_b) =
        action::track_event_fields(&track_events[1]);
    assert_eq!(event_release_a, release_id);
    assert_eq!(event_release_b, release_id);
    assert_eq!(index_a, 0);
    assert_eq!(index_b, 1);
    assert_eq!(event_recording_a, recording_a);
    assert_eq!(event_recording_b, recording_b);
    assert_eq!(amount_a, 6_000);
    assert_eq!(amount_b, 4_000);

    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    let (event_release, input, distributed, remainder) =
        action::distribution_event_fields(&summaries[0]);
    assert_eq!(event_release, release_id);
    assert_eq!(input, 10_001);
    assert_eq!(distributed, 10_000);
    assert_eq!(remainder, 1);

    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun zero_value_coin_emits_zero_track_and_summary_events() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut release, admin_cap, recording_a, recording_b) = fixture(scenario.ctx());
    let release_id = object::id(&release);
    let coin = coin::zero<CURRENCY>(scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, release_id.to_address());

    scenario.next_tx(@0xB);
    action::receive_and_distribute(
        &mut release,
        &admin_cap,
        vector[test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(coin_id)],
    );
    let tracks = event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(tracks.length(), 2);
    let (release_a, index_a, target_a, amount_a) = action::track_event_fields(&tracks[0]);
    let (release_b, index_b, target_b, amount_b) = action::track_event_fields(&tracks[1]);
    assert_eq!(release_a, release_id);
    assert_eq!(release_b, release_id);
    assert_eq!(index_a, 0);
    assert_eq!(index_b, 1);
    assert_eq!(target_a, recording_a);
    assert_eq!(target_b, recording_b);
    assert_eq!(amount_a, 0);
    assert_eq!(amount_b, 0);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    let (summary_release, input, distributed, remainder) =
        action::distribution_event_fields(&summaries[0]);
    assert_eq!(summary_release, release_id);
    assert_eq!(input, 0);
    assert_eq!(distributed, 0);
    assert_eq!(remainder, 0);

    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun vault_admin_borrow_action_put_back_and_borrow_again() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut release, admin_cap, _recording_a, _recording_b) = fixture(scenario.ctx());
    let mut registry = vault::new_registry_for_testing(scenario.ctx());
    let (mut vault, vault_admin_cap) = vault::new(&mut registry, admin_cap, scenario.ctx());
    let coin = coin::from_balance(balance::create_for_testing<CURRENCY>(10_000), scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, object::id(&release).to_address());

    scenario.next_tx(@0xB);
    let (borrowed_cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    action::receive_and_distribute(
        &mut release,
        &borrowed_cap,
        vector[test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(coin_id)],
    );
    vault.put_back(borrowed_cap, receipt);
    let (borrowed_again, second_receipt) = vault.borrow_as_admin(&vault_admin_cap);
    assert_eq!(borrowed_again.release_id(), object::id(&release));
    vault.put_back(borrowed_again, second_receipt);

    let admin_cap = vault.withdraw_cap(&vault_admin_cap);
    destroy(admin_cap);
    destroy(vault_admin_cap);
    destroy(vault);
    destroy(registry);
    destroy(release);
    scenario.end();
}

#[test]
fun settled_value_helper_distributes_full_amount_and_later_remainder() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut release, admin_cap, _recording_a, _recording_b) = fixture(scenario.ctx());
    let release_address = object::id(&release).to_address();
    balance::create_for_testing<CURRENCY>(10_001).send_funds(release_address);

    scenario.next_tx(@0xB);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release,
        &admin_cap,
        10_001,
    );
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    let (_, first_input, first_distributed, first_remainder) =
        action::distribution_event_fields(&summaries[0]);
    assert_eq!(first_input, 10_001);
    assert_eq!(first_distributed, 10_000);
    assert_eq!(first_remainder, 1);

    // The first call requeues its one-unit flooring remainder. Batch it with
    // later revenue so the next settled redemption has no rounding dust.
    balance::create_for_testing<CURRENCY>(9_999).send_funds(release_address);
    scenario.next_tx(@0xC);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release,
        &admin_cap,
        10_000,
    );
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    let (_, second_input, second_distributed, second_remainder) =
        action::distribution_event_fields(&summaries[0]);
    assert_eq!(second_input, 10_000);
    assert_eq!(second_distributed, 10_000);
    assert_eq!(second_remainder, 0);

    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

/// The unit VM does not populate a positive consensus `AccumulatorRoot`
/// snapshot after `send_funds`. This pins the honest local boundary; a funded
/// `redeem_all_and_distribute` success remains a network E2E requirement.
#[test]
fun funded_accumulator_snapshot_documents_zero_vm_result() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    let (release, admin_cap, _, _) = fixture(scenario.ctx());
    let release_address = object::id(&release).to_address();

    scenario.next_tx(@0xA);
    balance::create_for_testing<CURRENCY>(10_001).send_funds(release_address);
    scenario.next_tx(@0xB);
    let root = scenario.take_shared<AccumulatorRoot>();
    assert_eq!(balance::settled_funds_value<CURRENCY>(&root, release_address), 0);
    test_scenario::return_shared(root);

    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = EUnauthorized, location = release)]
fun another_releases_cap_is_rejected() {
    let ctx = &mut tx_context::dummy();
    let (mut release, _cap, _, _) = fixture(ctx);
    let (_other_release, other_cap, _, _) = fixture(ctx);
    action::redeem_and_distribute<CURRENCY>(&mut release, &other_cap, 1);
    abort
}

#[test, expected_failure(abort_code = EUnauthorized, location = release)]
fun redeem_all_rejects_foreign_cap_on_empty_settled_snapshot() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut release, _admin_cap, _, _) = fixture(scenario.ctx());
    let (_other_release, other_admin_cap, _, _) = fixture(scenario.ctx());
    let root = scenario.take_shared<AccumulatorRoot>();
    action::redeem_all_and_distribute<CURRENCY>(&mut release, &other_admin_cap, &root);
    abort
}

#[test, expected_failure(abort_code = ENoCoinsToReceive, location = hikida)]
fun empty_receive_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut release, admin_cap, _, _) = fixture(ctx);
    action::receive_and_distribute<CURRENCY>(&mut release, &admin_cap, vector[]);
    abort
}

#[test, expected_failure(abort_code = ENoValueToRedeem, location = hikida)]
fun zero_redeem_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut release, admin_cap, _, _) = fixture(ctx);
    action::redeem_and_distribute<CURRENCY>(&mut release, &admin_cap, 0);
    abort
}

#[test]
fun redeem_all_is_an_idempotent_no_op_without_settled_funds() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut release, admin_cap, _, _) = fixture(scenario.ctx());
    let root = scenario.take_shared<AccumulatorRoot>();
    action::redeem_all_and_distribute<CURRENCY>(&mut release, &admin_cap, &root);
    assert_eq!(
        event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>().length(),
        0,
    );
    assert_eq!(
        event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>().length(),
        0,
    );
    test_scenario::return_shared(root);
    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure]
fun overdraw_redeem_aborts_on_empty_accumulator() {
    let ctx = &mut tx_context::dummy();
    let (mut release, admin_cap, _, _) = fixture(ctx);
    action::redeem_and_distribute<CURRENCY>(&mut release, &admin_cap, 1);
    abort
}
