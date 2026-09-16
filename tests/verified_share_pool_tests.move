// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-constructor coverage. Generic accounting tests use the clearly
/// test-only `pool::new_for_testing`; these tests alone exercise the verified
/// `pool::new` admission boundary with real `coin_registry::Currency` state.
#[test_only]
module royalty_pool::verified_share_pool_tests;

use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use share::share::{Self, Share};
use std::unit_test::{assert_eq, destroy};
use sui::balance::{Self, Balance};
use sui::coin::TreasuryCap;
use sui::coin_registry::Currency;

const SHARE_SUPPLY: u64 = 100_000_000_000_000;
const PRECISION: u128 = 1_000_000_000_000_000_000;

public struct TEST_PAYOUT() has drop;

fun initialize_share(ctx: &mut TxContext): (Currency<Share>, Balance<Share>) {
    let (mut currency, treasury_cap, metadata_cap) =
        share::new_share_currency_for_testing(6, ctx);
    currency.delete_metadata_cap(metadata_cap);
    let balance = share::initialize(&mut currency, treasury_cap);
    (currency, balance)
}

fun fix_supply(
    currency: &mut Currency<Share>,
    mut treasury_cap: TreasuryCap<Share>,
    amount: u64,
): Balance<Share> {
    let balance = treasury_cap.mint_balance(amount);
    currency.make_supply_fixed(treasury_cap);
    balance
}

#[test]
/// A currency initialized by the share package admits a production pool with
/// an arbitrary payout type. The real fixed supply is 100 million whole
/// tokens at six decimals (100_000_000_000_000 base units).
fun production_new_accepts_verified_share_currency() {
    let ctx = &mut tx_context::dummy();
    let (currency, share_balance) = initialize_share(ctx);
    assert_eq!(share_balance.value(), SHARE_SUPPLY);

    let mut parent = object::new(ctx);
    let pool = pool::new<Share, TEST_PAYOUT>(&mut parent, &currency);
    assert_eq!(pool.staked_shares(), 0);

    destroy(pool);
    destroy(parent);
    destroy(share_balance);
    destroy(currency);
}

#[test, expected_failure(abort_code = pool::EInvalidShareCurrency)]
/// Correct name, decimals, metadata lock and fixed-supply mode are
/// insufficient when the immutable supply is not the protocol share supply.
fun production_new_rejects_wrong_fixed_supply() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap, metadata_cap) =
        share::new_share_currency_for_testing(6, ctx);
    currency.delete_metadata_cap(metadata_cap);
    let share_balance = fix_supply(&mut currency, treasury_cap, SHARE_SUPPLY - 1);
    let mut parent = object::new(ctx);

    let pool = pool::new<Share, TEST_PAYOUT>(&mut parent, &currency);

    destroy(pool);
    destroy(parent);
    destroy(share_balance);
    destroy(currency);
}

#[test, expected_failure(abort_code = pool::EInvalidShareCurrency)]
/// Even an exact fixed supply is rejected when the currency configuration is
/// wrong; here the registry records nine decimals instead of six.
fun production_new_rejects_wrong_share_configuration() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap, metadata_cap) =
        share::new_share_currency_for_testing(9, ctx);
    currency.delete_metadata_cap(metadata_cap);
    let share_balance = fix_supply(&mut currency, treasury_cap, SHARE_SUPPLY);
    let mut parent = object::new(ctx);

    let pool = pool::new<Share, TEST_PAYOUT>(&mut parent, &currency);

    destroy(pool);
    destroy(parent);
    destroy(share_balance);
    destroy(currency);
}

#[test]
/// Production admission binds staked supply to the verified 100 million-token
/// cap. Therefore `carry < staked_shares <= SHARE_SUPPLY`, which means the
/// pool-wide carry represents strictly less than 1e-4 payout base unit.
fun production_admission_bounds_deposit_carry_below_one_ten_thousandth_base_unit() {
    let ctx = &mut tx_context::dummy();
    let (currency, mut share_balance) = initialize_share(ctx);
    let staked = 99_990_000_999_901;
    let stake_balance = share_balance.split(staked);

    let mut parent = object::new(ctx);
    let mut pool = pool::new<Share, TEST_PAYOUT>(&mut parent, &currency);
    let mut share_stake = stake::new(stake_balance, ctx);
    pool.register_stake(&mut share_stake);
    pool.deposit(balance::create_for_testing<TEST_PAYOUT>(1));

    // This input leaves an almost-maximal remainder, making the strict bound
    // concrete rather than exercising the divisible full-supply case.
    assert_eq!(pool.carry(), 99_990_000_990_000);
    assert!(pool.carry() < (pool.staked_shares() as u128));
    assert!(pool.carry() < (SHARE_SUPPLY as u128));
    assert!(pool.carry() * 10_000 < PRECISION);

    pool.unregister_stake(&mut share_stake);
    destroy(share_stake);
    destroy(pool);
    destroy(parent);
    destroy(share_balance);
    destroy(currency);
}
