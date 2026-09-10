// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Accumulator-based royalty distribution pool for the protocol's share
/// tokens.
///
/// A `RoyaltyPool<Share, Currency>` is a derived object of any UID-bearing
/// parent. Its address is deterministically derived from
/// `(parent_id, Share, Currency)` — at most one pool per triple, and the pool
/// at that address is necessarily typed `RoyaltyPool<Share, Currency>` (the
/// same type parameters produce the address and the object) and necessarily
/// shared (the pool is key-only; `share` is its only consumer). The `Share`
/// phantom identifies which share-token type can stake against the pool.
///
/// Holders create a `Stake<Share>` (see `royalty_pool::stake`) and register
/// it. Callers fund the pool by handing it a `Balance<Currency>` via
/// `deposit`; the accumulator advances and claims pay out the per-stake
/// proportional share since each stake's last claim.
///
/// The pool is funded two ways, both committing the funds to share holders:
/// - `deposit(balance)` from any caller holding `&mut` on the pool — e.g.
///   `routed_stake::sweep`, which deposits a wrapped stake's claimed rewards
///   into its parent's pool.
/// - Delivery to the pool's derived address — pending `Coin<Currency>`
///   transfers or address-balance credits (e.g.
///   `release_revenue_distributor` settles each track's split there). The
///   address is a pure function of `(parent_id, Share, Currency)`, so senders
///   need the pool neither shared nor even created yet; a later `new` claims
///   exactly that ID — and can only be the correctly-typed, shared pool.
///   `recover_coins` and `settle` fold such funds into the accumulator,
///   permissionlessly: anyone can complete the delivery. Both are total —
///   a crank-facing call never aborts for having nothing to do. `settle`
///   folds in what is settled at the pool's own address once stakers exist;
///   while `staked_shares == 0` it returns 0 and reads nothing, so funds at
///   the pool's address wait, unredeemed, until a stake registers.
///   `recover_coins` never deposits — it only converts coin objects into
///   funds at the same address for a later `settle` to redeem.
///
/// ### No activation delay (deliberate)
///
/// Registration earns from the next deposit onward; there is no bonding or
/// unbonding period (contrast Sui native staking's next-epoch activation).
/// With the protocol's fixed-supply share token this is safe: a stake's
/// take of any deposit is `v · s / S` with `S` (total registered) bounded
/// by the share supply, so a continuously registered stake is guaranteed at
/// least its pro-rata share of total supply on every deposit. Short-lived
/// or just-in-time registrations can only compete for the *unregistered*
/// supply's drift — the designed incentive for being registered — never
/// below any registered stake's floor.
///
/// ### Exact accounting
///
/// Every base unit deposited is accounted for, to the last index unit:
///
/// - A deposit of `v` across `S` staked shares advances the index by
///   `⌊(v · PRECISION + carry) / S⌋` and keeps the remainder in `carry`
///   (in `value · PRECISION` units, independent of `S`), so deposit rounding
///   never loses value — it is folded into the next deposit. This also means
///   a share supply larger than `PRECISION` cannot lock deposits: they
///   accumulate in `carry` until they fold.
/// - A registration records its debt in `shares · index` units at full
///   precision and pays `⌊(shares · index − debt) / PRECISION⌋`; the payout is
///   added back to the debt as `reward · PRECISION`. A registration's lifetime
///   payout is therefore exactly `⌊shares · Δindex / PRECISION⌋`: sub-unit
///   credit carries across claims and is never inflated. At most one base
///   unit of sub-unit residue is forfeited per registration, at unregister.
///
/// Consequently `balance · PRECISION == Σ (shares · index − debt) + carry +
/// forfeited` at all times — the pool can never owe more than it holds — and
/// `PRECISION` is only a granularity/overflow choice: `shares · index` fits
/// `u256` for any `u64` share supply and lifetime deposits.
module royalty_pool::pool;

use hikida::hikida;
use royalty_pool::stake::{Self, Stake};
use std::type_name;
use sui::accumulator::AccumulatorRoot;
use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::derived_object::{claim, derive_address};
use sui::event::emit;
use sui::transfer::Receiving;

// === Errors ===

const EPoolNotDerivedFromParent: u64 = 0;
const ENoStakedShares: u64 = 1;
const EAlreadyRegistered: u64 = 2;
const ENotRegistered: u64 = 3;
const EPoolIdMismatch: u64 = 4;
const ELastClaimIndexMismatch: u64 = 5;
const EInvalidValue: u64 = 6;

// === Constants ===

const PRECISION: u128 = 1_000_000_000_000_000_000;

// === Structs ===

public struct RoyaltyPool<phantom Share, phantom Currency> has key {
    id: UID,
    balance: Balance<Currency>,
    staked_shares: u64,
    cumulative_reward_per_share: u256,
    /// Deposit remainder not yet folded into the index, in
    /// `value · PRECISION` units. Smaller than `staked_shares` as of the last
    /// deposit.
    carry: u128,
    /// Lifetime sum of every deposited value, in currency base units.
    /// Read-only analytics — never decremented; not used by any on-chain logic.
    cumulative_deposits: u128,
}

/// Key used to derive a pool's object ID from its parent UID.
///
/// Phantom-typed: both `Share` and `Currency` are encoded in the BCS type
/// tag, so the struct itself is empty and zero-cost. Encoding `Share` makes
/// the derived address honest by construction — `new`'s type parameters
/// determine both the claimed address and the pool's own type, so the pool
/// at `(parent, Share, Currency)` is necessarily a `RoyaltyPool<Share,
/// Currency>`, and (the pool being key-only) necessarily shared. A pool
/// created with a wrong `Share` claims a different, unpaid address; it can
/// neither block nor impersonate the canonical one. Payers therefore need no
/// trust in the pool's creator — only the standard care that the `Share`
/// they derive with is the parent's true share type (pin it with a typed
/// reference to the parent when the caller supplies it).
public struct RoyaltyPoolKey<phantom Share, phantom Currency>() has copy, drop, store;

// === Events ===

public struct RoyaltyPoolCreatedEvent<phantom Share, phantom Currency> has copy, drop {
    pool_id: ID,
    parent_id: ID,
}

public struct RoyaltyDepositedEvent<phantom Share, phantom Currency> has copy, drop {
    pool_id: ID,
    value: u64,
}

/// Emitted by `recover_coins` when it converts a positive value. Not
/// emitted for an empty vector — nothing happened.
public struct CoinsRecoveredEvent<phantom Share, phantom Currency> has copy, drop {
    pool_id: ID,
    value: u64,
}

public struct StakeRegisteredEvent<phantom Share, phantom Currency> has copy, drop {
    pool_id: ID,
    stake_id: ID,
    staked_amount: u64,
}

public struct StakeUnregisteredEvent<phantom Share, phantom Currency> has copy, drop {
    pool_id: ID,
    stake_id: ID,
    unstaked_amount: u64,
}

public struct RoyaltyClaimedEvent<phantom Share, phantom Currency> has copy, drop {
    pool_id: ID,
    stake_id: ID,
    reward_amount: u64,
}

// === Public Functions ===

/// Construct a pool as a derived object of `parent`. The derivation key
/// encodes both type parameters, so the pool's address is determined
/// entirely by `(parent_id, Share, Currency)` — and therefore always names
/// a pool of exactly this type (see `RoyaltyPoolKey`).
///
/// Cap-gating happens at the parent: callers must obtain `&mut UID` via
/// whatever cap-gated accessor the parent exposes.
public fun new<Share, Currency>(parent: &mut UID): RoyaltyPool<Share, Currency> {
    let parent_id = parent.to_inner();
    let pool = RoyaltyPool<Share, Currency> {
        id: claim(parent, RoyaltyPoolKey<Share, Currency>()),
        balance: balance::zero(),
        staked_shares: 0,
        cumulative_reward_per_share: 0,
        carry: 0,
        cumulative_deposits: 0,
    };

    emit(RoyaltyPoolCreatedEvent<Share, Currency> {
        pool_id: object::id(&pool),
        parent_id,
    });

    pool
}

/// Share the pool object so holders can register and claim against it.
public fun share<Share, Currency>(self: RoyaltyPool<Share, Currency>) {
    transfer::share_object(self);
}

/// Fold a balance into the accumulator. Aborts on zero staked shares (the
/// deposit would be unattributable) or zero value (no-op deposits are
/// rejected to keep events meaningful).
///
/// Callers obtain the `Balance<Currency>` however they like — typically by
/// pulling from a parent's pending coins or funds accumulator (see e.g.
/// `composition_royalty_distributor`).
public fun deposit<Share, Currency>(
    self: &mut RoyaltyPool<Share, Currency>,
    balance: Balance<Currency>,
) {
    assert!(self.staked_shares > 0, ENoStakedShares);

    let value = balance.value();
    assert!(value > 0, EInvalidValue);

    // value · PRECISION + carry < 2^64 · 10^18 + 2^64: fits u128.
    let numerator = (value as u128) * PRECISION + self.carry;
    let staked_shares = self.staked_shares as u128;
    self.cumulative_reward_per_share =
        self.cumulative_reward_per_share + ((numerator / staked_shares) as u256);
    self.carry = numerator % staked_shares;
    self.cumulative_deposits = self.cumulative_deposits + (value as u128);
    self.balance.join(balance);

    emit(RoyaltyDepositedEvent<Share, Currency> {
        pool_id: object::id(self),
        value,
    });
}

/// Redeem everything settled at this pool's own address and fold it into the
/// accumulator. Recovery path for funds a routed sweep parked here while the
/// pool had no stakers. Returns the value deposited. Returns 0 and changes
/// nothing when nothing is settled or when `staked_shares == 0` (the funds
/// stay at the pool's address until a stake registers). Permissionless.
public fun settle<Share, Currency>(self: &mut RoyaltyPool<Share, Currency>, root: &AccumulatorRoot): u64 {
    if (self.staked_shares == 0) return 0;

    let balance = hikida::redeem_settled_balance<Currency>(&mut self.id, root);
    if (balance.value() == 0) {
        balance.destroy_zero();
        return 0
    };

    let value = balance.value();
    self.deposit(balance);
    value
}

/// Convert `Coin` objects sent to this pool's address into funds at the same
/// address, so `settle` can fold them in next commit. Deposits nothing.
/// Returns the value converted; 0 for an empty vector. Permissionless.
public fun recover_coins<Share, Currency>(
    self: &mut RoyaltyPool<Share, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
): u64 {
    let pool_address = self.id.to_address();
    let value = hikida::receive_coins_and_send_funds(&mut self.id, coins, pool_address);
    if (value > 0) {
        emit(CoinsRecoveredEvent<Share, Currency> {
            pool_id: object::id(self),
            value,
        });
    };
    value
}

/// Register a stake with the pool. Records the stake's entry index so future
/// deposits accrue to it proportionally.
///
/// Aborts if the stake is already registered with a pool of the same Currency.
public fun register_stake<Share, Currency>(
    self: &mut RoyaltyPool<Share, Currency>,
    stake: &mut Stake<Share>,
) {
    let currency = type_name::with_defining_ids<Currency>();
    assert!(!stake.has_registration(&currency), EAlreadyRegistered);

    let pool_id = object::id(self);
    let stake_id = object::id(stake);
    let staked_amount = stake.value();
    let debt = (staked_amount as u256) * self.cumulative_reward_per_share;

    stake.add_registration(currency, stake::new_registration(pool_id, debt));
    self.staked_shares = self.staked_shares + staked_amount;

    emit(StakeRegisteredEvent<Share, Currency> {
        pool_id,
        stake_id,
        staked_amount,
    });
}

/// Unregister a stake from the pool. All claimable rewards must be drained
/// first — i.e., a final `claim_rewards` call must yield 0. Sub-base-unit
/// residue (`shares · index − debt < PRECISION`) does NOT block unregister,
/// since it could never be claimed as a whole base unit anyway. Forfeiting
/// it on exit is the deliberate semantics.
public fun unregister_stake<Share, Currency>(
    self: &mut RoyaltyPool<Share, Currency>,
    stake: &mut Stake<Share>,
) {
    let currency = type_name::with_defining_ids<Currency>();
    assert!(stake.has_registration(&currency), ENotRegistered);

    let pool_id = object::id(self);
    let stake_id = object::id(stake);
    let staked_amount = stake.value();
    let cumulative = self.cumulative_reward_per_share;

    let registration = stake.get_registration(&currency);
    assert!(stake::registration_pool_id(registration) == pool_id, EPoolIdMismatch);
    assert!(
        calculate_reward(staked_amount, stake::registration_debt(registration), cumulative) == 0,
        ELastClaimIndexMismatch,
    );

    stake.remove_registration(&currency);
    self.staked_shares = self.staked_shares - staked_amount;

    emit(StakeUnregisteredEvent<Share, Currency> {
        pool_id,
        stake_id,
        unstaked_amount: staked_amount,
    });
}

/// Claim accrued rewards for a registered stake. Adds the payout to the
/// registration's debt, so sub-unit credit carries over to the next claim.
public fun claim_rewards<Share, Currency>(
    self: &mut RoyaltyPool<Share, Currency>,
    stake: &mut Stake<Share>,
): Balance<Currency> {
    let currency = type_name::with_defining_ids<Currency>();
    assert!(stake.has_registration(&currency), ENotRegistered);

    let pool_id = object::id(self);
    let stake_id = object::id(stake);
    let staked_amount = stake.value();
    let cumulative = self.cumulative_reward_per_share;

    let registration = stake.registration_mut(&currency);
    assert!(stake::registration_pool_id(registration) == pool_id, EPoolIdMismatch);

    let reward_amount =
        calculate_reward(staked_amount, stake::registration_debt(registration), cumulative);
    stake::add_debt(registration, (reward_amount as u256) * (PRECISION as u256));

    emit(RoyaltyClaimedEvent<Share, Currency> {
        pool_id,
        stake_id,
        reward_amount,
    });

    self.balance.split(reward_amount)
}

// === View Functions ===

/// Compute pending rewards for a stake without claiming. Returns 0 if the
/// stake is not registered with this pool.
public fun pending_rewards<Share, Currency>(
    self: &RoyaltyPool<Share, Currency>,
    stake: &Stake<Share>,
): u64 {
    let currency = type_name::with_defining_ids<Currency>();

    if (!stake.has_registration(&currency)) {
        return 0
    };

    let registration = stake.get_registration(&currency);
    if (stake::registration_pool_id(registration) != object::id(self)) {
        return 0
    };

    calculate_reward(
        stake.value(),
        stake::registration_debt(registration),
        self.cumulative_reward_per_share,
    )
}

public fun balance<Share, Currency>(self: &RoyaltyPool<Share, Currency>): &Balance<Currency> {
    &self.balance
}

public fun staked_shares<Share, Currency>(self: &RoyaltyPool<Share, Currency>): u64 {
    self.staked_shares
}

public fun cumulative_reward_per_share<Share, Currency>(
    self: &RoyaltyPool<Share, Currency>,
): u256 {
    self.cumulative_reward_per_share
}

/// Deposit remainder awaiting the next deposit, in `value · PRECISION` units.
public fun carry<Share, Currency>(self: &RoyaltyPool<Share, Currency>): u128 {
    self.carry
}

/// Lifetime sum of all deposits, in currency base units. Strictly monotonic.
public fun cumulative_deposits<Share, Currency>(
    self: &RoyaltyPool<Share, Currency>,
): u128 {
    self.cumulative_deposits
}

/// Funds of `Currency` settled at this pool's own address as of the start of
/// the current consensus commit — what `settle` would redeem right now.
public fun settled_value<Share, Currency>(
    self: &RoyaltyPool<Share, Currency>,
    root: &AccumulatorRoot,
): u64 {
    hikida::settled_balance_value<Currency>(&self.id, root)
}

/// Compute the deterministic address of a pool given its parent ID and
/// `Currency` type parameter. Useful for off-chain derivation and for
/// cross-module checks that the pool was minted from the expected parent.
public fun derived_address<Share, Currency>(parent_id: ID): address {
    derive_address(parent_id, RoyaltyPoolKey<Share, Currency>())
}

/// Read-only verification that the pool was derived from the given parent ID.
public fun assert_derived_from<Share, Currency>(
    self: &RoyaltyPool<Share, Currency>,
    parent_id: ID,
) {
    assert!(
        self.id.to_address() == derive_address(parent_id, RoyaltyPoolKey<Share, Currency>()),
        EPoolNotDerivedFromParent,
    );
}

// === Private Functions ===

/// `⌊(shares · index − debt) / PRECISION⌋`. The subtraction cannot underflow
/// (`debt ≤ shares · index` by construction) and the result is bounded by the
/// pool balance (see the module doc), so the `u64` cast cannot truncate.
fun calculate_reward(staked_amount: u64, debt: u256, index: u256): u64 {
    (((staked_amount as u256) * index - debt) / (PRECISION as u256)) as u64
}

// === Test Functions ===
//
// Accessors for this module's event payloads — the event structs' fields are
// module-private and carry no other public reader.

#[test_only]
public fun created_event_fields<Share, Currency>(
    event: &RoyaltyPoolCreatedEvent<Share, Currency>,
): (ID, ID) {
    (event.pool_id, event.parent_id)
}

#[test_only]
public fun deposited_event_fields<Share, Currency>(
    event: &RoyaltyDepositedEvent<Share, Currency>,
): (ID, u64) {
    (event.pool_id, event.value)
}

#[test_only]
public fun coins_recovered_event_fields<Share, Currency>(
    event: &CoinsRecoveredEvent<Share, Currency>,
): (ID, u64) {
    (event.pool_id, event.value)
}

#[test_only]
public fun stake_registered_event_fields<Share, Currency>(
    event: &StakeRegisteredEvent<Share, Currency>,
): (ID, ID, u64) {
    (event.pool_id, event.stake_id, event.staked_amount)
}

#[test_only]
public fun stake_unregistered_event_fields<Share, Currency>(
    event: &StakeUnregisteredEvent<Share, Currency>,
): (ID, ID, u64) {
    (event.pool_id, event.stake_id, event.unstaked_amount)
}

#[test_only]
public fun royalty_claimed_event_fields<Share, Currency>(
    event: &RoyaltyClaimedEvent<Share, Currency>,
): (ID, ID, u64) {
    (event.pool_id, event.stake_id, event.reward_amount)
}
