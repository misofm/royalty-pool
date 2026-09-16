#[test_only]
module royalty_pool::fresh_math_review;

use royalty_pool::{pool, stake};
use share::share::{Self, Share};
use std::unit_test::{assert_eq, destroy};
use sui::balance;

public struct Reward() has drop;

#[test]
/// Exercise the production admission path and actual fixed share balance.
/// Verify the repeated-cycle recurrence on Move without exceeding the event
/// memory limit. The companion independent oracle extends it to 10,002 cycles.
fun bounded_carry_accumulates_across_100_voluntary_exits() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap, metadata_cap) = share::new_share_currency_for_testing(6, ctx);
    currency.delete_metadata_cap(metadata_cap);
    let mut share_balance = share::initialize(&mut currency, treasury_cap);
    let mut parent = object::new(ctx);
    let mut pool = pool::new<Share, Reward>(&mut parent, &currency);
    let mut persistent = stake::new(share_balance.split(1), ctx);
    let mut transient = stake::new(share_balance.split(99_990_000_999_900), ctx);
    pool.register_stake(&mut persistent);
    let mut total_paid = 0;
    let mut i = 0u64;
    while (i < 100) {
        pool.register_stake(&mut transient);
        pool.deposit(balance::create_for_testing<Reward>(1));
        assert_eq!(pool.carry(), 99_990_000_990_000);
        assert_eq!(pool.pending_rewards(&transient), 0);
        pool.unregister_stake(&mut transient);
        pool.deposit(balance::create_for_testing<Reward>(1));
        let paid = pool.claim_rewards(&mut persistent);
        total_paid = total_paid + paid.value();
        destroy(paid);
        i = i + 1;
    };
    assert_eq!(total_paid, 100);
    assert_eq!(pool.balance().value(), 100);
    assert_eq!(pool.cumulative_deposits(), 200);
    assert_eq!(pool.cumulative_reward_per_share(), 100 * (1_000_000_000_000_000_000u256 + 99_990_000_990_000 + 10_000));
    assert_eq!(pool.carry(), 0);
    pool.unregister_stake(&mut persistent);
    destroy(persistent.destroy());
    destroy(transient.destroy());
    destroy(share_balance);
    destroy(currency);
    destroy(pool);
    destroy(parent);
}

#[test]
/// Share admission means no first-production-deposit can have a zero index
/// increment. Full supply is the worst denominator and divides precision.
fun full_supply_still_advances_by_10000_index_units_per_payout_unit() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap, metadata_cap) = share::new_share_currency_for_testing(6, ctx);
    currency.delete_metadata_cap(metadata_cap);
    let share_balance = share::initialize(&mut currency, treasury_cap);
    let mut parent = object::new(ctx);
    let mut pool = pool::new<Share, Reward>(&mut parent, &currency);
    let mut position = stake::new(share_balance, ctx);
    pool.register_stake(&mut position);
    pool.deposit(balance::create_for_testing<Reward>(1));
    assert_eq!(pool.cumulative_reward_per_share(), 10_000);
    assert_eq!(pool.carry(), 0);
    let reward = pool.claim_rewards(&mut position);
    assert_eq!(reward.value(), 1);
    destroy(reward);
    pool.unregister_stake(&mut position);
    destroy(position.destroy());
    destroy(currency);
    destroy(pool);
    destroy(parent);
}
