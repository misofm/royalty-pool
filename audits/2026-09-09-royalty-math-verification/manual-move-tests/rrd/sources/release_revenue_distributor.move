// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw-cap Release revenue actions.
///
/// Revenue is split from the immutable Release tracklist and sent to the
/// corresponding Recording addresses. Callers select only funds already held
/// by the Release; they cannot select recipients or alter split amounts.
module release_revenue_distributor::release_revenue_distributor;

use hikida::hikida;
use musicos::release::{Release, ReleaseAdminCap};
use sui::accumulator::AccumulatorRoot;
use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;

/// Emitted for every Release track, including a zero-value rounded split.
public struct ReleaseTrackRevenueDistributedEvent<phantom Currency> has copy, drop {
    release_id: ID,
    track_index: u64,
    recording_id: ID,
    amount: u64,
}

/// Emitted once after an entire Release distribution completes.
public struct ReleaseRevenueDistributedEvent<phantom Currency> has copy, drop {
    release_id: ID,
    total_input: u64,
    total_distributed: u64,
    remainder: u64,
}

/// Redeem `value` from the Release accumulator and distribute it according to
/// the immutable tracklist.
public fun redeem_and_distribute<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    value: u64,
) {
    let revenue = hikida::redeem_balance<Currency>(release.uid_mut(admin_cap), value);
    distribute(release, revenue)
}

/// Redeem all Release funds settled at the start of the current consensus
/// commit and distribute them according to the immutable tracklist.
///
/// The framework snapshot is capped at `u64::MAX`; excess funds, newly sent
/// funds, and per-track flooring remainder settle for a later call. This fixed
/// crank prevents permissionless adapters from selecting dust-sized fragments.
/// A zero settled snapshot is an idempotent no-op.
public fun redeem_all_and_distribute<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    root: &AccumulatorRoot,
) {
    let value = balance::settled_funds_value<Currency>(root, object::id(release).to_address());
    redeem_settled_value_and_distribute<Currency>(release, admin_cap, value)
}

/// Redeem a previously read settled snapshot when it is positive.
fun redeem_settled_value_and_distribute<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    value: u64,
) {
    release.authorize(admin_cap);
    if (value == 0) return;
    redeem_and_distribute<Currency>(release, admin_cap, value)
}

/// Receive selected coins sent to the Release and distribute their combined
/// value according to the immutable tracklist.
public fun receive_and_distribute<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    let revenue = hikida::receive_balance(release.uid_mut(admin_cap), coins);
    distribute(release, revenue)
}

/// Split a balance using only immutable Release data. Per-track flooring
/// remainder returns to the Release address for a later distribution.
fun distribute<Currency>(release: &Release, mut revenue: Balance<Currency>) {
    let release_id = object::id(release);
    let total_input = revenue.value();
    let mut total_distributed = 0;
    let mut track_index = 0;

    release.tracks().do_ref!(|track| {
        let amount = track.split_bps().apply(total_input);
        total_distributed = total_distributed + amount;
        if (amount > 0) {
            revenue.split(amount).send_funds(track.recording_id().to_address());
        };
        emit(ReleaseTrackRevenueDistributedEvent<Currency> {
            release_id,
            track_index,
            recording_id: track.recording_id(),
            amount,
        });
        track_index = track_index + 1;
    });

    let remainder = revenue.value();
    if (remainder > 0) {
        revenue.send_funds(release_id.to_address());
    } else {
        revenue.destroy_zero();
    };

    emit(ReleaseRevenueDistributedEvent<Currency> {
        release_id,
        total_input,
        total_distributed,
        remainder,
    })
}

#[test_only]
public fun track_event_fields<Currency>(
    event: &ReleaseTrackRevenueDistributedEvent<Currency>,
): (ID, u64, ID, u64) {
    (event.release_id, event.track_index, event.recording_id, event.amount)
}

#[test_only]
public fun distribution_event_fields<Currency>(
    event: &ReleaseRevenueDistributedEvent<Currency>,
): (ID, u64, u64, u64) {
    (event.release_id, event.total_input, event.total_distributed, event.remainder)
}

#[test_only]
public fun redeem_settled_value_and_distribute_for_testing<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    value: u64,
) {
    redeem_settled_value_and_distribute<Currency>(release, admin_cap, value)
}
