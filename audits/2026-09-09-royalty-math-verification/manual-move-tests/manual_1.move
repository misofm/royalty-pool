// HAND-WRITTEN by the Opus verification campaign (TASKS-OPUS §3).
//
// MASTER COPY. `diff` clears `move/routed-stake/tests/gen/*.move` between
// batches, so copy this file back in before running it:
//   cp manual-move-tests/manual_1.move royalty-sim/move/routed-stake/tests/gen/
//   (cd royalty-sim/move/routed-stake && $SUI move test royalty_sim_gen_manual)
//
// Covers `scenarios/adversarial/10-u64-balance-limit.json`, which `movegen`
// SKIPs: its last step is a Move *arithmetic* abort (`balance::join`
// overflowing u64), which the VM reports without a module location, so it
// cannot be written as `#[expected_failure(abort_code = N, location = ...)]`
// the way the generator emits every other expected abort.
//
// What it pins down:
//   1. A pool can hold exactly `u64::MAX`, and a *single* share can claim all
//      of it: `calculate_reward`'s unchecked `as u64` cast (SPEC F4) is
//      exercised at its exact maximum, `owed/P == u64::MAX`, and does not
//      truncate.
//   2. The next deposit of even 1 unit aborts rather than wrapping (SPEC
//      I-B7 / "never silent wrap").
//   3. Solvency (I-B1) holds at the boundary: balance == claimable.
#[test_only, allow(unused_use)]
module routed_stake::royalty_sim_gen_manual_1;

use std::unit_test::{assert_eq, destroy};

const ALICE: address = @0xA1;

public struct GenShare() has drop;
public struct GenCurrency() has drop;

const MAX_U64: u64 = 18446744073709551615;
const PRECISION: u256 = 1000000000000000000;

#[test]
fun manual_1_pool_balance_reaches_u64_max_and_stays_claimable() {
    let mut sc = sui::test_scenario::begin(ALICE);
    let mut ep = object::new(sc.ctx());
    let gp = royalty_pool::pool::new<GenShare, GenCurrency>(&mut ep);
    let pool_id = object::id(&gp);
    gp.share();
    destroy(ep);

    // A single share, so index moves by exactly `value * PRECISION`.
    let mut s = royalty_pool::stake::new(sui::balance::create_for_testing<GenShare>(1), sc.ctx());

    sc.next_tx(ALICE);
    let mut p = sc.take_shared_by_id<royalty_pool::pool::RoyaltyPool<GenShare, GenCurrency>>(pool_id);
    p.register_stake(&mut s);
    assert_eq!(p.staked_shares(), 1);
    sui::test_scenario::return_shared(p);

    // Fill the pool to u64::MAX - 1, then to exactly u64::MAX.
    sc.next_tx(ALICE);
    let mut p = sc.take_shared_by_id<royalty_pool::pool::RoyaltyPool<GenShare, GenCurrency>>(pool_id);
    p.deposit(sui::balance::create_for_testing<GenCurrency>(MAX_U64 - 1));
    assert_eq!(p.balance().value(), MAX_U64 - 1);
    sui::test_scenario::return_shared(p);

    sc.next_tx(ALICE);
    let mut p = sc.take_shared_by_id<royalty_pool::pool::RoyaltyPool<GenShare, GenCurrency>>(pool_id);
    p.deposit(sui::balance::create_for_testing<GenCurrency>(1));
    assert_eq!(p.balance().value(), MAX_U64);
    // index == u64::MAX * PRECISION exactly (one share, no carry).
    assert_eq!(p.cumulative_reward_per_share(), (MAX_U64 as u256) * PRECISION);
    // The `as u64` cast in `calculate_reward` at its exact maximum.
    assert_eq!(p.pending_rewards(&s), MAX_U64);
    sui::test_scenario::return_shared(p);

    // Solvency at the boundary: the whole balance is claimable, and is paid.
    sc.next_tx(ALICE);
    let mut p = sc.take_shared_by_id<royalty_pool::pool::RoyaltyPool<GenShare, GenCurrency>>(pool_id);
    let reward = p.claim_rewards(&mut s);
    assert_eq!(reward.value(), MAX_U64);
    assert_eq!(p.balance().value(), 0);
    assert_eq!(p.pending_rewards(&s), 0);
    sui::balance::destroy_for_testing(reward);
    sui::test_scenario::return_shared(p);

    destroy(s);
    sc.end();
}

/// The deposit that would take the balance past `u64::MAX` aborts inside
/// `sui::balance::join` rather than wrapping. This is a VM arithmetic abort,
/// so `expected_failure` is matched without an abort code.
#[test]
#[expected_failure]
fun manual_1_deposit_past_u64_max_aborts() {
    let mut sc = sui::test_scenario::begin(ALICE);
    let mut ep = object::new(sc.ctx());
    let gp = royalty_pool::pool::new<GenShare, GenCurrency>(&mut ep);
    let pool_id = object::id(&gp);
    gp.share();
    destroy(ep);

    let mut s = royalty_pool::stake::new(sui::balance::create_for_testing<GenShare>(1), sc.ctx());

    sc.next_tx(ALICE);
    let mut p = sc.take_shared_by_id<royalty_pool::pool::RoyaltyPool<GenShare, GenCurrency>>(pool_id);
    p.register_stake(&mut s);
    p.deposit(sui::balance::create_for_testing<GenCurrency>(MAX_U64));
    assert_eq!(p.balance().value(), MAX_U64);
    // Aborts: balance would exceed u64::MAX.
    p.deposit(sui::balance::create_for_testing<GenCurrency>(1));

    sui::test_scenario::return_shared(p);
    destroy(s);
    sc.end();
}
