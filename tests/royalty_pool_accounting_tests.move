// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact-accounting properties of `royalty_pool::pool`, checked against the
/// real shared pool and `Stake` objects after every operation of randomized
/// register / deposit / claim / unregister sequences:
///
/// - conservation: `balance · P == Σ_live (shares · index − debt) + carry + forfeited`
///   (no phantom credit, no leaked value — every index unit is accounted for)
/// - fairness: `paid + pending == ⌊shares · (index − index_at_register) / P⌋`
///   for every live registration (lifetime payout is the exact floor)
/// - residue: sub-unit residue `< P` at all times; `carry < staked_shares` as
///   of the last deposit
/// - `pending_rewards` equals the next claim; a repeated claim pays 0
///
/// Each operation runs in its own simulated transaction to reset event state.
/// The unit-test gas meter remains cumulative across the whole test.
#[test_only]
module royalty_pool::royalty_pool_accounting_tests;

use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::test_scenario::{Self, Scenario};

const ALICE: address = @0xA1;
const P: u256 = 1_000_000_000_000_000_000;
const SUPPLY: u64 = 10_000_000_000_000; // miso_share fixed supply
const OPS: u64 = 250;
const MAX_LIVE: u64 = 12;

public struct TEST_SHARE() has drop;
public struct TEST_CURRENCY() has drop;

public struct Model {
    pool_id: ID,
    stakes: vector<Stake<TEST_SHARE>>,
    idx_reg: vector<u256>,
    paid: vector<u64>,
    forfeited: u256,
    staked_at_fold: u64,
    registered: u64,
}

fun debt_of(s: &Stake<TEST_SHARE>): u256 {
    stake::registration_debt(s.get_registration(&type_name::with_defining_ids<TEST_CURRENCY>()))
}

fun check(m: &Model, pool: &RoyaltyPool<TEST_SHARE, TEST_CURRENCY>) {
    let idx = pool.cumulative_reward_per_share();
    let mut owed: u256 = 0;
    let mut i = 0u64;
    while (i < m.stakes.length()) {
        let s = &m.stakes[i];
        let shares = s.value() as u256;
        let pend = pool.pending_rewards(s) as u256;
        let raw = shares * idx - debt_of(s);
        assert_eq!((m.paid[i] as u256) + pend, shares * (idx - m.idx_reg[i]) / P);
        assert!(raw - pend * P < P, 100);
        owed = owed + raw;
        i = i + 1;
    };
    assert_eq!((pool.balance().value() as u256) * P, owed + (pool.carry() as u256) + m.forfeited);
    if (m.staked_at_fold > 0) assert!(pool.carry() < (m.staked_at_fold as u128), 101);
}

fun op_deposit(sc: &mut Scenario, m: &mut Model, v: u64) {
    sc.next_tx(ALICE);
    let mut pool = sc.take_shared_by_id<RoyaltyPool<TEST_SHARE, TEST_CURRENCY>>(m.pool_id);
    pool.deposit(balance::create_for_testing<TEST_CURRENCY>(v));
    m.staked_at_fold = pool.staked_shares();
    check(m, &pool);
    test_scenario::return_shared(pool);
}

fun op_register(sc: &mut Scenario, m: &mut Model, amount: u64) {
    sc.next_tx(ALICE);
    let mut pool = sc.take_shared_by_id<RoyaltyPool<TEST_SHARE, TEST_CURRENCY>>(m.pool_id);
    let mut s = stake::new(balance::create_for_testing<TEST_SHARE>(amount), sc.ctx());
    let idx = pool.cumulative_reward_per_share();
    pool.register_stake(&mut s);
    assert_eq!(pool.pending_rewards(&s), 0);
    m.stakes.push_back(s);
    m.idx_reg.push_back(idx);
    m.paid.push_back(0);
    m.registered = m.registered + amount;
    check(m, &pool);
    test_scenario::return_shared(pool);
}

fun claim_in(pool: &mut RoyaltyPool<TEST_SHARE, TEST_CURRENCY>, m: &mut Model, i: u64): u64 {
    let expected = pool.pending_rewards(&m.stakes[i]);
    let reward = pool.claim_rewards(&mut m.stakes[i]);
    let got = reward.value();
    balance::destroy_for_testing(reward);
    assert_eq!(got, expected);
    assert_eq!(pool.pending_rewards(&m.stakes[i]), 0);
    *&mut m.paid[i] = m.paid[i] + got;
    got
}

fun op_claim(sc: &mut Scenario, m: &mut Model, i: u64) {
    sc.next_tx(ALICE);
    let mut pool = sc.take_shared_by_id<RoyaltyPool<TEST_SHARE, TEST_CURRENCY>>(m.pool_id);
    claim_in(&mut pool, m, i);
    check(m, &pool);
    test_scenario::return_shared(pool);
}

fun op_unregister(sc: &mut Scenario, m: &mut Model, i: u64) {
    sc.next_tx(ALICE);
    let mut pool = sc.take_shared_by_id<RoyaltyPool<TEST_SHARE, TEST_CURRENCY>>(m.pool_id);
    if (pool.pending_rewards(&m.stakes[i]) > 0) { claim_in(&mut pool, m, i); };
    let mut s = m.stakes.swap_remove(i);
    let idx_reg = m.idx_reg.swap_remove(i);
    let paid = m.paid.swap_remove(i);
    let idx = pool.cumulative_reward_per_share();
    let shares = s.value() as u256;
    assert_eq!(paid as u256, shares * (idx - idx_reg) / P);
    let residue = shares * idx - debt_of(&s);
    assert!(residue < P, 102);
    pool.unregister_stake(&mut s);
    m.forfeited = m.forfeited + residue;
    m.registered = m.registered - s.value();
    balance::destroy_for_testing(stake::destroy(s));
    check(m, &pool);
    test_scenario::return_shared(pool);
}

fun rnd(s: &mut u64): u64 {
    let mut x = *s; x = x ^ (x << 13); x = x ^ (x >> 7); x = x ^ (x << 17); *s = x; x
}

fun fuzz(seed: u64) {
    let mut sc = test_scenario::begin(ALICE);
    let mut parent = object::new(sc.ctx());
    let pool = pool::new<TEST_SHARE, TEST_CURRENCY>(&mut parent);
    let pool_id = object::id(&pool);
    pool.share();
    destroy(parent);
    let mut m = Model { pool_id, stakes: vector[], idx_reg: vector[], paid: vector[],
        forfeited: 0, staked_at_fold: 0, registered: 0 };
    let mut s = seed;
    let mut i = 0u64;
    while (i < OPS) {
        let r = rnd(&mut s) % 100;
        if (r < 40) {
            if (m.registered > 0) {
                let k = rnd(&mut s) % 5;
                let v = if (k == 0) 1
                    else if (k == 1) rnd(&mut s) % 100 + 1
                    else if (k == 2) rnd(&mut s) % 1_000_000 + 1
                    else if (k == 3) rnd(&mut s) % 1_000_000_000 + 1
                    else rnd(&mut s) % 1_000_000_000_000 + 1;
                op_deposit(&mut sc, &mut m, v);
            }
        } else if (r < 60) {
            let room = SUPPLY - m.registered;
            if (room > 0 && m.stakes.length() < MAX_LIVE) {
                let k = rnd(&mut s) % 8;
                let want = if (k == 0) 1 else if (k == 1) 3 else if (k == 2) 7
                    else if (k == 3) rnd(&mut s) % 1000 + 1
                    else if (k == 4) rnd(&mut s) % 1_000_000_000 + 1
                    else if (k == 5) rnd(&mut s) % 1_000_000_000_000 + 1
                    else if (k == 6) room / 2 + 1
                    else room;
                op_register(&mut sc, &mut m, want.min(room));
            }
        } else if (r < 85) {
            if (m.stakes.length() > 0) {
                let j = rnd(&mut s) % m.stakes.length();
                op_claim(&mut sc, &mut m, j);
            }
        } else if (m.stakes.length() > 0) {
            let j = rnd(&mut s) % m.stakes.length();
            op_unregister(&mut sc, &mut m, j);
        };
        i = i + 1;
    };
    while (m.stakes.length() > 0) {
        let j = m.stakes.length() - 1;
        op_unregister(&mut sc, &mut m, j);
    };
    // Drained pool holds only forfeited dust + carry.
    sc.next_tx(ALICE);
    let pool = sc.take_shared_by_id<RoyaltyPool<TEST_SHARE, TEST_CURRENCY>>(pool_id);
    assert_eq!((pool.balance().value() as u256) * P, (pool.carry() as u256) + m.forfeited);
    test_scenario::return_shared(pool);
    let Model { pool_id: _, stakes, idx_reg: _, paid: _, forfeited: _, staked_at_fold: _, registered: _ } = m;
    stakes.destroy_empty();
    sc.end();
}

#[test] fun accounting_is_exact_seed_1() { fuzz(0x9E3779B97F4A7C15) }
#[test] fun accounting_is_exact_seed_2() { fuzz(0xD1B54A32D192ED03) }
#[test] fun accounting_is_exact_seed_3() { fuzz(0x2545F4914F6CDD1D) }

// === Targeted scenarios ===

fun setup<Share, Currency>(sc: &mut Scenario): ID {
    let mut parent = object::new(sc.ctx());
    let pool = pool::new<Share, Currency>(&mut parent);
    let id = object::id(&pool);
    pool.share();
    destroy(parent);
    id
}

#[test]
/// A small holder registering at a fractional index gets the exact floor
/// of its entitlement — nothing rounds against it at registration.
fun late_small_registrant_gets_exact_floor() {
    let mut sc = test_scenario::begin(ALICE);
    let id = setup<TEST_SHARE, TEST_CURRENCY>(&mut sc);
    sc.next_tx(ALICE);
    let mut pool = sc.take_shared_by_id<RoyaltyPool<TEST_SHARE, TEST_CURRENCY>>(id);
    let mut b = stake::new(balance::create_for_testing<TEST_SHARE>(10), sc.ctx());
    pool.register_stake(&mut b);
    pool.deposit(balance::create_for_testing<TEST_CURRENCY>(1));   // index = 1e17
    let mut a = stake::new(balance::create_for_testing<TEST_SHARE>(1), sc.ctx());
    pool.register_stake(&mut a);                                     // owed 0 so far
    pool.deposit(balance::create_for_testing<TEST_CURRENCY>(20));  // S = 11 → a owed 1.818…
    assert_eq!(pool.pending_rewards(&a), 1);
    assert_eq!(pool.pending_rewards(&b), 19);                        // 1 + 18.18…
    let ra = pool.claim_rewards(&mut a);
    let rb = pool.claim_rewards(&mut b);
    assert_eq!(ra.value(), 1);
    assert_eq!(rb.value(), 19);
    assert_eq!(pool.balance().value(), 1);                           // 0.818 + 0.18 residue + carry
    pool.unregister_stake(&mut a);
    pool.unregister_stake(&mut b);
    test_scenario::return_shared(pool);
    destroy(ra); destroy(rb); destroy(a); destroy(b);
    sc.end();
}

#[test]
/// A share supply larger than PRECISION cannot lock deposits: they gather in
/// `carry` until they fold into a whole index unit.
fun carry_folds_when_staked_exceeds_precision() {
    let mut sc = test_scenario::begin(ALICE);
    let id = setup<TEST_SHARE, TEST_CURRENCY>(&mut sc);
    sc.next_tx(ALICE);
    let mut pool = sc.take_shared_by_id<RoyaltyPool<TEST_SHARE, TEST_CURRENCY>>(id);
    let mut s = stake::new(balance::create_for_testing<TEST_SHARE>(std::u64::max_value!()), sc.ctx());
    pool.register_stake(&mut s);
    let mut i = 0u64;
    while (i < 18) {
        pool.deposit(balance::create_for_testing<TEST_CURRENCY>(1));
        assert_eq!(pool.cumulative_reward_per_share(), 0);
        i = i + 1;
    };
    pool.deposit(balance::create_for_testing<TEST_CURRENCY>(1));     // 19e18 > u64::MAX
    assert_eq!(pool.cumulative_reward_per_share(), 1);
    assert_eq!(pool.pending_rewards(&s), 18);
    let r = pool.claim_rewards(&mut s);
    assert_eq!(r.value(), 18);
    test_scenario::return_shared(pool);
    destroy(r); destroy(s);
    sc.end();
}

#[test]
/// The whale replay: a near-full-supply staker running 1-unit deposit +
/// claim cycles while a dust stake claims whenever a whole unit is owed.
/// Under exact accounting every claim is ⌊shares · Δ / P⌋ and the pool stays
/// solvent — the dust stake's exit is always reachable.
fun whale_claim_cycles_stay_solvent() {
    // Distinct primitive phantom tags bound event/type-name gas in this long
    // test. All 1,000 accounting cycles and assertions remain unchanged.
    let mut sc = test_scenario::begin(ALICE);
    let id = setup<u8, u64>(&mut sc);
    sc.next_tx(ALICE);
    let mut whale = stake::new(balance::create_for_testing<u8>(SUPPLY - 99_999_000), sc.ctx());
    let mut dust = stake::new(balance::create_for_testing<u8>(99_999_000), sc.ctx());
    let mut pool = sc.take_shared_by_id<RoyaltyPool<u8, u64>>(id);
    pool.register_stake(&mut whale);
    pool.register_stake(&mut dust);
    test_scenario::return_shared(pool);
    let mut paid_whale = 0u64;
    let mut paid_dust = 0u64;
    let mut tx = 0u64;
    while (tx < 10) {
        sc.next_tx(ALICE);
        let mut pool = sc.take_shared_by_id<RoyaltyPool<u8, u64>>(id);
        let mut i = 0u64;
        while (i < 100) {                     // 200 events per tx
            pool.deposit(balance::create_for_testing<u64>(1));
            paid_whale = paid_whale + balance::destroy_for_testing(pool.claim_rewards(&mut whale));
            if (pool.pending_rewards(&dust) > 0) {
                paid_dust = paid_dust + balance::destroy_for_testing(pool.claim_rewards(&mut dust));
            };
            i = i + 1;
        };
        let idx = pool.cumulative_reward_per_share();
        assert_eq!(paid_whale as u256, ((SUPPLY - 99_999_000) as u256) * idx / P);
        assert_eq!((paid_dust as u256) + (pool.pending_rewards(&dust) as u256), (99_999_000u64 as u256) * idx / P);
        test_scenario::return_shared(pool);
        tx = tx + 1;
    };
    sc.next_tx(ALICE);
    let mut pool = sc.take_shared_by_id<RoyaltyPool<u8, u64>>(id);
    destroy(pool.claim_rewards(&mut dust));
    pool.unregister_stake(&mut dust);
    destroy(pool.claim_rewards(&mut whale));
    pool.unregister_stake(&mut whale);
    assert!(pool.balance().value() <= 2, 0);   // at most the two forfeited residues
    test_scenario::return_shared(pool);
    destroy(whale); destroy(dust);
    sc.end();
}
