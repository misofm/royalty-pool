// HAND-WRITTEN by the Fable verification pass (VERIFICATION.md §5).
// Stage A (`release_revenue_distributor::distribute`) differential coverage
// against the real Move VM. Expected numbers were computed by hand /
// pure-Python integer arithmetic from bps.move's `mul_bps!<u64,u128>` and
// cross-checked against the Rust model's `distribute`.
#[test_only]
module release_revenue_distributor::fable_stage_a_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_revenue_distributor::release_revenue_distributor as action;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;

public struct CURRENCY() has drop;

const MAX_U64: u64 = 18446744073709551615;

fun fixture(splits: vector<u16>, ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let composition_id = test_helpers::fake_id(ctx);
    let target_release_id = test_helpers::fake_id(ctx);
    let tracks = splits.map!(|s| track::new_for_testing(
        composition_id,
        test_helpers::fake_id(ctx),
        target_release_id,
        s,
    ));
    release::new_for_testing(b"Release".to_string(), tracks, ctx)
}

/// Distribute exactly `t` through the redeem path (the unit VM honours
/// `send_funds` + `hikida::redeem_balance` for an exact value, see the
/// package's own `settled_value_helper_distributes_full_amount_and_later_remainder`).
/// Returns (per-track amounts from the events, total_distributed, remainder).
fun distribute_exact(
    release: &mut Release,
    cap: &ReleaseAdminCap,
    t: u64,
): (vector<u64>, u64, u64) {
    let release_address = object::id(release).to_address();
    balance::create_for_testing<CURRENCY>(t).send_funds(release_address);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(release, cap, t);
    let track_events = event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    let amounts = track_events.map_ref!(|e| {
        let (_, _, _, amount) = action::track_event_fields(e);
        amount
    });
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    let (_, input, distributed, remainder) = action::distribution_event_fields(&summaries[0]);
    assert_eq!(input, t);
    (amounts, distributed, remainder)
}

/// Same, but funding the release with a single `Coin` object of value `t` and
/// distributing through `receive_and_distribute`. Needed for `t = u64::MAX`:
/// the unit VM's address-balance accumulator overflows if u64::MAX is sent to
/// an address and then anything more is sent before settlement (see
/// `accumulator_probe_*` below), so the remainder's `send_funds` back to the
/// release would trip an arithmetic error unrelated to the distributor.
fun distribute_exact_via_coin(
    release: &mut Release,
    cap: &ReleaseAdminCap,
    t: u64,
    sc: &mut test_scenario::Scenario,
): (vector<u64>, u64, u64) {
    let c = coin::from_balance(balance::create_for_testing<CURRENCY>(t), sc.ctx());
    let c_id = object::id(&c);
    transfer::public_transfer(c, object::id(release).to_address());
    sc.next_tx(@0xB);
    action::receive_and_distribute<CURRENCY>(release, cap, vector[test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(c_id)]);
    let track_events = event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    let amounts = track_events.map_ref!(|e| {
        let (_, _, _, amount) = action::track_event_fields(e);
        amount
    });
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    let (_, input, distributed, remainder) = action::distribution_event_fields(&summaries[0]);
    assert_eq!(input, t);
    (amounts, distributed, remainder)
}

// --- unit-VM accumulator probes (harness boundary, not Stage A) ------------
// P1: two `send_funds` to one address whose values sum past u64::MAX *within
// a single transaction* is an arithmetic error in the test VM's
// `add_to_accumulator_address` native (pending per-tx merges are u64). This is
// how the first draft of the u64::MAX tests failed: the test minted u64::MAX
// to the release in the same tx as the distributor sent the remainder back.
#[test, expected_failure(arithmetic_error, location = sui::funds_accumulator)]
fun accumulator_probe_p1_same_tx_sends_past_u64_max_overflow() {
    let mut sc = test_scenario::begin(@0xA);
    let (release, cap) = fixture(vector[10_000], sc.ctx());
    let addr = object::id(&release).to_address();
    balance::create_for_testing<CURRENCY>(MAX_U64).send_funds(addr);
    balance::create_for_testing<CURRENCY>(1).send_funds(addr);
    destroy(release); destroy(cap); sc.end();
}

// P2: the production shape -- u64::MAX already at the address from an earlier
// transaction, then redeem u64::MAX and send the remainder back in one tx --
// is fine (settled values are u128; the redeem is a split, not a merge).
#[test]
fun accumulator_probe_p2_prior_max_then_redeem_and_send_back_is_fine() {
    let mut sc = test_scenario::begin(@0xA);
    let (mut release, cap) = fixture(vector[10_000], sc.ctx());
    let addr = object::id(&release).to_address();
    balance::create_for_testing<CURRENCY>(MAX_U64).send_funds(addr);
    sc.next_tx(@0xB);
    let mut b = hikida::hikida::redeem_balance<CURRENCY>(release.uid_mut(&cap), MAX_U64);
    assert_eq!(b.value(), MAX_U64);
    b.split(42).send_funds(addr);
    destroy(b);
    balance::create_for_testing<CURRENCY>(1).send_funds(addr);
    destroy(release); destroy(cap); sc.end();
}

// --- 1-bps track: T below / at / above 10 000 -------------------------------

#[test]
fun one_bps_track_t_1() {
    let mut sc = test_scenario::begin(@0xA);
    let (mut release, cap) = fixture(vector[9_999, 1], sc.ctx());
    sc.next_tx(@0xB);
    let (amounts, distributed, remainder) = distribute_exact(&mut release, &cap, 1);
    assert_eq!(amounts, vector[0, 0]);
    assert_eq!(distributed, 0);
    assert_eq!(remainder, 1); // no send at all; the whole unit returns to the release
    destroy(release); destroy(cap); sc.end();
}

#[test]
fun one_bps_track_t_9999_starves() {
    let mut sc = test_scenario::begin(@0xA);
    let (mut release, cap) = fixture(vector[9_999, 1], sc.ctx());
    sc.next_tx(@0xB);
    let (amounts, distributed, remainder) = distribute_exact(&mut release, &cap, 9_999);
    assert_eq!(amounts, vector[9_998, 0]);
    assert_eq!(distributed, 9_998);
    assert_eq!(remainder, 1);
    destroy(release); destroy(cap); sc.end();
}

#[test]
fun one_bps_track_t_10000_first_unit() {
    let mut sc = test_scenario::begin(@0xA);
    let (mut release, cap) = fixture(vector[9_999, 1], sc.ctx());
    sc.next_tx(@0xB);
    let (amounts, distributed, remainder) = distribute_exact(&mut release, &cap, 10_000);
    assert_eq!(amounts, vector[9_999, 1]);
    assert_eq!(distributed, 10_000);
    assert_eq!(remainder, 0);
    destroy(release); destroy(cap); sc.end();
}

#[test]
fun one_bps_track_t_10001() {
    let mut sc = test_scenario::begin(@0xA);
    let (mut release, cap) = fixture(vector[9_999, 1], sc.ctx());
    sc.next_tx(@0xB);
    let (amounts, distributed, remainder) = distribute_exact(&mut release, &cap, 10_001);
    assert_eq!(amounts, vector[9_999, 1]);
    assert_eq!(distributed, 10_000);
    assert_eq!(remainder, 1);
    destroy(release); destroy(cap); sc.end();
}

// --- widest on-chain-representable split vector: MAX_TRACKS = 255 ---------
// (SPEC §5 / TASKS-OPUS §2.9's 1024-track vector cannot exist on chain:
// `release::new` asserts `tracks.length() <= 255`, EMaxTracksExceeded = 31.)

fun wide_splits(): vector<u16> {
    // [9746, 1 x 254]  -> sum 9746 + 254 = 10 000, n = 255
    let mut v = vector[9_746u16];
    254u64.do!(|_| v.push_back(1));
    v
}

#[test]
fun two_fifty_five_tracks_t_10000() {
    let mut sc = test_scenario::begin(@0xA);
    let (mut release, cap) = fixture(wide_splits(), sc.ctx());
    assert_eq!(release.tracks().length(), 255);
    sc.next_tx(@0xB);
    let (amounts, distributed, remainder) = distribute_exact(&mut release, &cap, 10_000);
    assert_eq!(amounts.length(), 255);
    assert_eq!(amounts[0], 9_746);
    let mut i = 1; while (i < 255) { assert_eq!(amounts[i], 1); i = i + 1; };
    assert_eq!(distributed, 10_000);
    assert_eq!(remainder, 0);
    destroy(release); destroy(cap); sc.end();
}

#[test]
fun two_fifty_five_tracks_t_u64_max_conserves() {
    let mut sc = test_scenario::begin(@0xA);
    let (mut release, cap) = fixture(wide_splits(), sc.ctx());
    let (amounts, distributed, remainder) = distribute_exact_via_coin(&mut release, &cap, MAX_U64, &mut sc);
    // floor(u64::MAX * 9746 / 10000) and floor(u64::MAX / 10000), by hand:
    assert_eq!(amounts[0], 17_978_196_774_237_329_003);
    let mut i = 1; let mut sum = amounts[0];
    while (i < 255) { assert_eq!(amounts[i], 1_844_674_407_370_955); sum = sum + amounts[i]; i = i + 1; };
    assert_eq!(sum, distributed);
    assert_eq!(distributed + remainder, MAX_U64);     // I-A1 at the type limit
    assert_eq!(remainder, 42);                       // hand: 18446744073709551615 - distributed
    assert!(remainder < 255);                        // I-A2
    destroy(release); destroy(cap); sc.end();
}

// (A 1024-track fixture was tried via `new_for_testing`, which bypasses MAX_TRACKS: the
// unit VM aborts with MEMORY_LIMIT_EXCEEDED in sui::event on the 1024 per-track events.
// It cannot exist on chain in any case: `release::new` enforces MAX_TRACKS = 255.)

// --- remainder handling: dust returns to the release and re-enters ----------

#[test]
fun remainder_returns_to_release_and_recirculates() {
    let mut sc = test_scenario::begin(@0xA);
    let (mut release, cap) = fixture(vector[6_000, 4_000], sc.ctx());
    sc.next_tx(@0xB);
    let (amounts, distributed, remainder) = distribute_exact(&mut release, &cap, 10_001);
    assert_eq!(amounts, vector[6_000, 4_000]);
    assert_eq!(distributed, 10_000);
    assert_eq!(remainder, 1);

    // The 1-unit remainder was `send_funds` back to the release address. Redeem
    // exactly that unit again (nothing else was sent): it floors to 0 for both
    // tracks and comes straight back -- dust is never lost, never sent as 0.
    sc.next_tx(@0xC);
    let release_address = object::id(&release).to_address();
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(&mut release, &cap, 1);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    let (_, input, distributed2, remainder2) = action::distribution_event_fields(&summaries[0]);
    assert_eq!(input, 1);
    assert_eq!(distributed2, 0);
    assert_eq!(remainder2, 1);
    let _ = release_address;

    // Batched with 9_999 more it clears exactly (10_000 -> 6_000 + 4_000, 0).
    balance::create_for_testing<CURRENCY>(9_999).send_funds(object::id(&release).to_address());
    sc.next_tx(@0xD);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(&mut release, &cap, 10_000);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    let (_, input3, distributed3, remainder3) = action::distribution_event_fields(&summaries[0]);
    assert_eq!(input3, 10_000);
    assert_eq!(distributed3, 10_000);
    assert_eq!(remainder3, 0);
    destroy(release); destroy(cap); sc.end();
}

// --- three-way split at T = u64::MAX (remainder < n, exact conservation) ---
#[test]
fun three_way_split_t_u64_max() {
    let mut sc = test_scenario::begin(@0xA);
    let (mut release, cap) = fixture(vector[3_334, 3_333, 3_333], sc.ctx());
    let (amounts, distributed, remainder) = distribute_exact_via_coin(&mut release, &cap, MAX_U64, &mut sc);
    assert_eq!(amounts, vector[6_150_144_474_174_764_508, 6_148_299_799_767_393_553, 6_148_299_799_767_393_553]);
    assert_eq!(distributed + remainder, MAX_U64);
    assert_eq!(remainder, 1);
    destroy(release); destroy(cap); sc.end();
}
