//! Mirrors `release_revenue_distributor::distribute` and `bps::apply`,
//! SPEC §1.
//!
//! ### DISCREPANCY (see `../../DISCREPANCIES.md`)
//!
//! SPEC A3 states the per-track loop sends funds "including when `amount_i
//! == 0` (no zero-skip in the loop)". The actual Move source
//! (`release_revenue_distributor.move:95-97`) reads:
//!
//! ```move
//! if (amount > 0) {
//!     revenue.split(amount).send_funds(track.recording_id().to_address());
//! };
//! ```
//!
//! There *is* a zero-skip. `send_funds(0)` is therefore never called on this
//! path, and SPEC F6 ("confirm behavior... if `send_funds` of zero aborts,
//! a large release with a 1-bps track could be un-distributable") does not
//! apply to `release_revenue_distributor`: a zero-floor track simply isn't
//! sent, every round, forever (A-D4), and the event is still emitted with
//! `amount: 0`. Move wins per the task rules; the model below skips zero
//! sends and keeps `zero_send_aborts` only as a config flag for the
//! `send_funds`-family entry points elsewhere that a future scenario might
//! exercise directly (currently unreachable from any op in `scenario.rs`).

use serde::{Deserialize, Serialize};

use super::abort::{Abort, ReleaseAbort};

/// `bps::apply` (`bps.move:153-156`, via the `mul_bps!<u64, u128>` macro):
/// `⌊(amount * rate) / 10_000⌋`, widened to u128 before multiplying so a
/// u64 amount can never overflow (`amount < 2^64`, `rate <= 10_000 < 2^14`,
/// product `< 2^78`, fits comfortably in u128).
pub fn bps_apply(amount: u64, rate_bps: u64) -> Result<u64, Abort> {
    let product = (amount as u128)
        .checked_mul(rate_bps as u128)
        .ok_or(Abort::Arithmetic)?;
    u64::try_from(product / 10_000).map_err(|_| Abort::Arithmetic)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Distribution {
    pub amounts: Vec<u64>,
    pub remainder: u64,
}

/// Config knob for SPEC F6 (`send_funds(0)`), kept per TASKS-SONNET §1.4.
/// See the module doc: the one real call site we model
/// (`release_revenue_distributor::distribute`) already skips zero sends, so
/// this flag currently has no observable effect in the simulator; it is
/// wired through so a future `send_funds`-modeling op can consult it.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct DistributorConfig {
    pub zero_send_aborts: bool,
}

/// `distribute` (`release_revenue_distributor.move:86-120`). `splits` are
/// each track's `split_bps` (SPEC A1 requires `Σ splits == 10_000`, enforced
/// at Release construction, not re-checked here — matching Move, which does
/// not re-validate the sum in `distribute`).
pub fn distribute(total: u64, splits: &[u64]) -> Result<Distribution, Abort> {
    let mut amounts = Vec::with_capacity(splits.len());
    let mut total_distributed: u64 = 0;
    for &split in splits {
        let amount = bps_apply(total, split)?; // release_revenue_distributor.move:93
        total_distributed = total_distributed
            .checked_add(amount)
            .ok_or(Abort::Arithmetic)?;
        amounts.push(amount);
    }
    // remainder = revenue.value() after every split is taken out
    // (release_revenue_distributor.move:107); floor(a/b) sums never exceed
    // total, so this cannot underflow, but we check anyway per the rules.
    let remainder = total
        .checked_sub(total_distributed)
        .ok_or(Abort::Arithmetic)?;
    Ok(Distribution { amounts, remainder })
}

/// Construction-time check for a Release's tracklist (`release.move:233`,
/// `EInvalidTrackSplitsSum = 20`). Not part of the distributor itself, but
/// the scenario language's `release_new` op needs it to reject invalid
/// fixtures the way Move would reject an invalid Release.
pub fn validate_splits_sum(splits: &[u64]) -> Result<(), Abort> {
    let sum: u128 = splits.iter().map(|&s| s as u128).sum();
    if sum != 10_000 {
        return Err(Abort::Release(ReleaseAbort::InvalidTrackSplitsSum));
    }
    Ok(())
}

/// `redeem_all_and_distribute` (`release_revenue_distributor.move:53-71`):
/// a no-op on a zero settled balance (SPEC A5), otherwise redeems the whole
/// balance and distributes it, with the remainder (SPEC A4) settling back
/// onto the release (out of scope §7: modeled as immediate).
pub fn redeem_all_and_distribute(
    release_balance: &mut u64,
    splits: &[u64],
) -> Result<Option<Distribution>, Abort> {
    let value = *release_balance;
    if value == 0 {
        return Ok(None); // release_revenue_distributor.move:69
    }
    let dist = distribute(value, splits)?;
    *release_balance = dist.remainder;
    Ok(Some(dist))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conserves_total() {
        let d = distribute(1_000, &[2_500, 2_500, 5_000]).unwrap();
        let sum: u64 = d.amounts.iter().sum::<u64>() + d.remainder;
        assert_eq!(sum, 1_000);
        assert_eq!(d.amounts, vec![250, 250, 500]);
        assert_eq!(d.remainder, 0);
    }

    #[test]
    fn remainder_bounded_by_track_count() {
        // 3 tracks of 3_334/3_333/3_333 bps against T=10 leaves floors of
        // 3/3/3 = 9, remainder 1 < 3.
        let d = distribute(10, &[3_334, 3_333, 3_333]).unwrap();
        assert!(d.remainder < 3);
    }

    #[test]
    fn dust_track_gets_zero_below_threshold() {
        // A-D5 / F6: a 1-bps track needs T >= 10_000 to receive anything.
        let d = distribute(9_999, &[1, 9_999]).unwrap();
        assert_eq!(d.amounts[0], 0);
        assert_eq!(d.amounts[0] + d.amounts[1] + d.remainder, 9_999);
    }

    #[test]
    fn redeem_all_is_noop_on_zero() {
        let mut balance = 0u64;
        let result = redeem_all_and_distribute(&mut balance, &[10_000]).unwrap();
        assert!(result.is_none());
        assert_eq!(balance, 0);
    }

    #[test]
    fn invalid_split_sum_rejected() {
        assert_eq!(
            validate_splits_sum(&[5_000, 4_000]).unwrap_err(),
            Abort::Release(ReleaseAbort::InvalidTrackSplitsSum)
        );
    }

    proptest::proptest! {
        /// TASKS-SONNET §5: `distribute` conserves and `R < n` for random
        /// split vectors summing to 10_000 with `n` in 1..=64 (I-A1, I-A2).
        #[test]
        fn distribute_conserves_and_bounds_remainder(
            (splits, total) in split_vector_and_total(),
        ) {
            let d = distribute(total, &splits).unwrap();
            let sum: u64 = d.amounts.iter().sum::<u64>() + d.remainder;
            proptest::prop_assert_eq!(sum, total);
            proptest::prop_assert!(d.remainder < splits.len() as u64);
        }
    }

    /// A random `n in 1..=64` split vector summing to exactly 10_000, paired
    /// with a random total `T`.
    fn split_vector_and_total() -> impl proptest::strategy::Strategy<Value = (Vec<u64>, u64)> {
        use proptest::prelude::*;
        (1usize..=64, any::<u64>()).prop_flat_map(|(n, total)| {
            // n-1 random cut points in [0, 10_000], sorted, turn the gaps
            // between them into the split vector -- guarantees sum == 10_000
            // for any n, including n == 1.
            prop::collection::vec(0u16..=10_000, n - 1).prop_map(move |mut cuts| {
                cuts.sort_unstable();
                cuts.push(10_000);
                let mut splits = Vec::with_capacity(n);
                let mut prev = 0u16;
                for c in cuts {
                    splits.push((c - prev) as u64);
                    prev = c;
                }
                (splits, total)
            })
        })
    }
}
