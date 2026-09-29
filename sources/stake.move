// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A position holding native shares registered against royalty pools.
///
/// A stake holds one immutable Share value and can register in one pool per
/// payout currency. It cannot be destroyed while registrations remain.
/// Custodians must control who may mutate a stake and claim its rewards.
module royalty_pool::stake;

use std::type_name::TypeName;
use share::share::{Self, Share};
use sui::event::emit;
use sui::vec_map::{Self, VecMap};

// === Errors ===

const EZeroBalance: u64 = 0;
const EPoolsRegistered: u64 = 1;

// === Structs ===

public struct Stake has key, store {
    id: UID,
    /// The staked balance. Immutable after creation.
    balance: Share,
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

public struct StakeCreatedEvent has copy, drop {
    stake_id: address,
    transaction_sender: address,
    amount: u64,
    registration_count_after: u64,
}

public struct StakeDestroyedEvent has copy, drop {
    stake_id: address,
    amount: u64,
    registration_count_before: u64,
}

// === Public Functions ===

/// Create a new stake with the given shares.
///
/// Aborts if `shares` are zero.
public fun new(balance: Share, ctx: &mut TxContext): Stake {
    assert!(balance.value() > 0, EZeroBalance);

    let stake = Stake {
        id: object::new(ctx),
        balance,
        registrations: vec_map::empty(),
    };

    emit(StakeCreatedEvent {
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
public fun destroy(stake: Stake): Share {
    let Stake { id, balance, registrations } = stake;

    assert!(registrations.is_empty(), EPoolsRegistered);
    let stake_id = id.to_inner().to_address();
    let amount = balance.value();
    let registration_count_before = registrations.length();
    registrations.destroy_empty();

    id.delete();

    emit(StakeDestroyedEvent {
        stake_id,
        amount,
        registration_count_before,
    });

    balance
}

// === View Functions ===

public fun balance(self: &Stake): &Share {
    &self.balance
}

public fun issuance_id(self: &Stake): ID { self.balance.issuance_id() }

public fun value(self: &Stake): u64 {
    self.balance.value()
}

/// Number of royalty pools this stake is currently registered with.
public fun registration_count(self: &Stake): u64 {
    self.registrations.length()
}

public fun has_registration(self: &Stake, currency: &TypeName): bool {
    self.registrations.contains(currency)
}

public fun get_registration(self: &Stake, currency: &TypeName): &Registration {
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
public(package) fun add_registration(
    self: &mut Stake,
    currency: TypeName,
    registration: Registration,
) {
    self.registrations.insert(currency, registration);
}

/// Remove and return the registration for `currency`. Aborts if absent.
public(package) fun remove_registration(
    self: &mut Stake,
    currency: &TypeName,
): Registration {
    let (_, registration) = self.registrations.remove(currency);
    registration
}

/// Mutable access to a registration. Aborts if absent.
public(package) fun registration_mut(
    self: &mut Stake,
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
public fun created_event_fields(
    event: &StakeCreatedEvent,
): (address, address, u64, u64) {
    (event.stake_id, event.transaction_sender, event.amount, event.registration_count_after)
}

#[test_only]
public fun destroyed_event_fields(
    event: &StakeDestroyedEvent,
): (address, u64, u64) {
    (event.stake_id, event.amount, event.registration_count_before)
}
