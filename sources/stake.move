// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A position holding share tokens registered against a `RoyaltyPool`.
///
/// Stakes are owned objects with an immutable balance — to increase a holder's
/// total staked amount, mint additional Stake objects rather than modify an
/// existing one. This mirrors Sui's native staking model.
///
/// Each stake tracks the royalty pools it is currently registered with via an
/// inline `VecMap<TypeName, Registration>`, keyed by the pool's `Currency`
/// `TypeName`. The stake cannot be destroyed while any registrations remain.
/// Pool registrations are mutated by `royalty_pool::pool` through the
/// package-private accessors below.
///
/// Custody warning: `pool::claim_rewards` pays accrued rewards to the
/// *caller*, and `Stake` is `key + store` — a bare shared stake (or one
/// wrapped in a shared object that hands out `&mut`) is drainable by anyone.
/// Stakes must stay address-owned, or wrapped by a contract that pins the
/// reward route (e.g. `routed_stake`); the pool cannot enforce this itself.
module royalty_pool::stake;

use std::type_name::TypeName;
use sui::balance::Balance;
use sui::event::emit;
use sui::vec_map::{Self, VecMap};

// === Errors ===

const EZeroBalance: u64 = 0;
const EPoolsRegistered: u64 = 1;

// === Structs ===

public struct Stake<phantom Share> has key, store {
    id: UID,
    /// The staked balance. Immutable after creation.
    balance: Balance<Share>,
    /// Active royalty-pool registrations, keyed by `Currency` `TypeName`.
    /// Must be empty to destroy.
    registrations: VecMap<TypeName, Registration>,
}

/// Per-stake registration record. One entry per pool the stake is registered
/// with, stored inline on the stake.
public struct Registration has copy, drop, store {
    pool_id: ID,
    /// Reward debt in `shares · index` units: `shares · index` as of
    /// registration, plus `reward · PRECISION` for every payout since. The
    /// pending reward is `(shares · index − debt) / PRECISION`, computed by
    /// `royalty_pool::pool`. Kept at full precision so no rounding is ever
    /// stored: `debt ≤ shares · index` always holds.
    debt: u256,
}

// === Events ===

public struct StakeCreatedEvent<phantom Share> has copy, drop {
    stake_id: address,
    transaction_sender: address,
    amount: u64,
    registration_count_after: u64,
}

public struct StakeDestroyedEvent<phantom Share> has copy, drop {
    stake_id: address,
    amount: u64,
    registration_count_before: u64,
}

// === Public Functions ===

/// Create a new stake with the given balance.
///
/// Aborts if `balance` is zero.
public fun new<Share>(balance: Balance<Share>, ctx: &mut TxContext): Stake<Share> {
    assert!(balance.value() > 0, EZeroBalance);

    let stake = Stake<Share> {
        id: object::new(ctx),
        balance,
        registrations: vec_map::empty(),
    };

    emit(StakeCreatedEvent<Share> {
        stake_id: object::id(&stake).to_address(),
        transaction_sender: tx_context::sender(ctx),
        amount: stake.value(),
        registration_count_after: stake.registration_count(),
    });

    stake
}

/// Destroy a stake and reclaim its balance.
///
/// Aborts if the stake is still registered with any royalty pools.
public fun destroy<Share>(stake: Stake<Share>): Balance<Share> {
    let Stake { id, balance, registrations } = stake;

    assert!(registrations.is_empty(), EPoolsRegistered);
    let stake_id = id.to_inner().to_address();
    let amount = balance.value();
    let registration_count_before = registrations.length();
    registrations.destroy_empty();

    id.delete();

    emit(StakeDestroyedEvent<Share> {
        stake_id,
        amount,
        registration_count_before,
    });

    balance
}

// === View Functions ===

public fun balance<Share>(self: &Stake<Share>): &Balance<Share> {
    &self.balance
}

public fun value<Share>(self: &Stake<Share>): u64 {
    self.balance.value()
}

/// Number of royalty pools this stake is currently registered with.
public fun registration_count<Share>(self: &Stake<Share>): u64 {
    self.registrations.length()
}

public fun has_registration<Share>(self: &Stake<Share>, currency: &TypeName): bool {
    self.registrations.contains(currency)
}

public fun get_registration<Share>(self: &Stake<Share>, currency: &TypeName): &Registration {
    self.registrations.get(currency)
}

public fun registration_pool_id(r: &Registration): ID {
    r.pool_id
}

public fun registration_debt(r: &Registration): u256 {
    r.debt
}

// === Package Functions ===

/// Construct a fresh `Registration` value. Package-private so only the pool
/// module can mint registrations (always paired with `add_registration`).
public(package) fun new_registration(pool_id: ID, debt: u256): Registration {
    Registration {
        pool_id,
        debt,
    }
}

/// Insert a registration for `currency`. The pool module is expected to check
/// `has_registration` first; this function will abort on duplicate insert via
/// `VecMap::insert`.
public(package) fun add_registration<Share>(
    self: &mut Stake<Share>,
    currency: TypeName,
    registration: Registration,
) {
    self.registrations.insert(currency, registration);
}

/// Remove and return the registration for `currency`. Aborts if absent.
public(package) fun remove_registration<Share>(
    self: &mut Stake<Share>,
    currency: &TypeName,
): Registration {
    let (_, registration) = self.registrations.remove(currency);
    registration
}

/// Mutable access to a registration. Aborts if absent.
public(package) fun registration_mut<Share>(
    self: &mut Stake<Share>,
    currency: &TypeName,
): &mut Registration {
    self.registrations.get_mut(currency)
}

public(package) fun add_debt(r: &mut Registration, amount: u256) {
    r.debt = r.debt + amount;
}

// === Test Functions ===
//
// Accessors for this module's event payloads — the event structs' fields are
// module-private and carry no other public reader.

#[test_only]
public fun created_event_fields<Share>(
    event: &StakeCreatedEvent<Share>,
): (address, address, u64, u64) {
    (event.stake_id, event.transaction_sender, event.amount, event.registration_count_after)
}

#[test_only]
public fun destroyed_event_fields<Share>(
    event: &StakeDestroyedEvent<Share>,
): (address, u64, u64) {
    (event.stake_id, event.amount, event.registration_count_before)
}
