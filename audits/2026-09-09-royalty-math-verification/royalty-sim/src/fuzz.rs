//! Random single-pool scenario generation and shrinking (TASKS-SONNET §3).
//!
//! Fuzz-generated scenarios are model-only (per TASKS-SONNET §4: "longer
//! fuzz scenarios are model-only") -- they exercise `World`/`invariants`
//! directly rather than round-tripping through JSON + `movegen`, though the
//! op list is still representable as a `ScenarioFile` for `--out` dumps.
//!
//! The profile's "sweep" weight is realized as an extra `deposit` with a
//! random value: the old `receive_and_deposit` recovery path reduced to the
//! identical `pool::deposit` call (SPEC §2.7) and has been folded into it
//! directly now that the op is gone; `settle`'s realistic trigger
//! (`routed_stake` parking, SPEC §3.1) is exercised by the routed-stake
//! handwritten scenarios instead of the single-pool fuzz profiles. See
//! NOTES.md.

use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha8Rng;

use crate::model::invariants::{self, Tracker, Violation};
use crate::model::world::{ApplyError, Op, World};
use crate::scenario::{PoolSetup, RawOp, ScenarioFile, Setup};

#[derive(Debug, Clone, Copy)]
pub enum ProfileName {
    Realistic,
    Stress,
    Churn,
    Dust,
    Hugeshares,
}

impl std::str::FromStr for ProfileName {
    type Err = anyhow::Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "realistic" => ProfileName::Realistic,
            "stress" => ProfileName::Stress,
            "churn" => ProfileName::Churn,
            "dust" => ProfileName::Dust,
            "hugeshares" => ProfileName::Hugeshares,
            other => anyhow::bail!("unknown profile `{other}` (want realistic|stress|churn|dust|hugeshares)"),
        })
    }
}

struct Profile {
    /// (weight, kind) for the weighted op choice, kinds: 0=deposit
    /// 1=claim 2=register 3=unregister 4=deposit (second bucket, doubles as
    /// the always-available fallback -- see `run_one`).
    weights: [u32; 5],
    amount_buckets: Vec<(u64, u64)>,
    deposit_buckets: Vec<(u64, u64)>,
    max_live: usize,
    /// Cap on total registered amount (SPEC §5 magnitudes); `u64::MAX` for
    /// profiles that intentionally probe the overflow boundary.
    supply: u128,
}

fn profile(name: ProfileName) -> Profile {
    match name {
        ProfileName::Realistic => Profile {
            weights: [40, 30, 15, 10, 5],
            amount_buckets: vec![(1, 100), (1, 1_000_000), (1, 1_000_000_000), (1, 10_000_000_000_000)],
            deposit_buckets: vec![(1, 1_000), (1, 1_000_000), (1, 1_000_000_000_000)],
            max_live: 20,
            supply: 10_000_000_000_000, // 1e13, matches SPEC §5 "realistic" stake magnitude
        },
        ProfileName::Stress => Profile {
            weights: [40, 25, 20, 10, 5],
            amount_buckets: vec![(1, 1_000), (1, u64::MAX / 4), (u64::MAX / 2, u64::MAX)],
            deposit_buckets: vec![(1, 1_000), (1, u64::MAX / 4), (u64::MAX / 2, u64::MAX)],
            max_live: 12,
            supply: u64::MAX as u128, // deliberately lets staked_shares approach u64::MAX
        },
        ProfileName::Churn => Profile {
            weights: [15, 30, 25, 30, 2],
            amount_buckets: vec![(1, 100), (1, 1_000_000)],
            deposit_buckets: vec![(1, 1_000)],
            max_live: 16,
            supply: 1_000_000_000,
        },
        ProfileName::Dust => Profile {
            weights: [45, 30, 15, 10, 2],
            amount_buckets: vec![(1, 50), (1, 500)],
            // TASKS-OPUS §1 wants `dust` to exercise *value = 1* deposits
            // specifically. A single uniform (1, 10_000) bucket draws
            // value == 1 once in 10 000; the two degenerate buckets below
            // make a third of all deposits exactly 1 unit, which is what
            // actually drives `carry` through a full fold cycle.
            deposit_buckets: vec![(1, 1), (1, 1), (1, 10), (1, 10_000)],
            max_live: 40,
            supply: 100_000,
        },
        ProfileName::Hugeshares => Profile {
            weights: [40, 30, 20, 5, 5],
            // staked_shares > P (1e18): a few huge stakers, summing well past
            // PRECISION, so the index increment can be zero and carry
            // accumulates (SPEC §2.8 corner case).
            amount_buckets: vec![(1_000_000_000_000_000_000, u64::MAX)],
            deposit_buckets: vec![(1, 1_000)],
            max_live: 6,
            supply: u64::MAX as u128,
        },
    }
}

fn pick_bucket(rng: &mut ChaCha8Rng, buckets: &[(u64, u64)]) -> u64 {
    let (lo, hi) = buckets[rng.gen_range(0..buckets.len())];
    if lo >= hi {
        lo
    } else {
        rng.gen_range(lo..=hi)
    }
}

pub struct FuzzRunResult {
    pub ops: Vec<RawOp>,
    pub violation: Option<Box<Violation>>,
    pub max_ic4_error: num_rational::BigRational,
    /// TASKS-OPUS §1 telemetry, aggregated by `run_fuzz`.
    pub telemetry: Telemetry,
}

/// The per-run quantities TASKS-OPUS §1 requires the campaign to report.
#[derive(Debug, Clone, Default)]
pub struct Telemetry {
    pub max_carry: u128,
    pub max_index_bits: usize,
    pub max_amount_index_bits: usize,
    pub max_forfeited_units: u128,
    pub max_carry_drift_abs: String,
    pub max_staked_shares: u64,
    pub max_balance: u64,
    /// Total ops actually applied (successfully or not) across the run.
    pub ops_applied: usize,
    pub aborts: usize,
}

impl Telemetry {
    fn merge(&mut self, o: &Telemetry) {
        self.max_carry = self.max_carry.max(o.max_carry);
        self.max_index_bits = self.max_index_bits.max(o.max_index_bits);
        self.max_amount_index_bits = self.max_amount_index_bits.max(o.max_amount_index_bits);
        self.max_forfeited_units = self.max_forfeited_units.max(o.max_forfeited_units);
        self.max_staked_shares = self.max_staked_shares.max(o.max_staked_shares);
        self.max_balance = self.max_balance.max(o.max_balance);
        self.ops_applied += o.ops_applied;
        self.aborts += o.aborts;
        // string-compare-free: parse both as rationals and keep the larger
        let a: num_rational::BigRational = parse_rat(&self.max_carry_drift_abs);
        let b: num_rational::BigRational = parse_rat(&o.max_carry_drift_abs);
        if b > a {
            self.max_carry_drift_abs = o.max_carry_drift_abs.clone();
        }
    }
}

fn parse_rat(s: &str) -> num_rational::BigRational {
    use std::str::FromStr;
    if s.is_empty() {
        return num_rational::BigRational::from_integer(0.into());
    }
    num_rational::BigRational::from_str(s).unwrap_or_else(|_| num_rational::BigRational::from_integer(0.into()))
}

/// Generate and run one fuzz scenario of `op_count` ops under `profile`,
/// stopping at the first invariant violation (if any).
fn run_one(profile_name: ProfileName, seed: u64, op_count: usize) -> FuzzRunResult {
    let prof = profile(profile_name);
    let mut rng = ChaCha8Rng::seed_from_u64(seed);
    let mut world = World::new();
    world.add_pool(0, 0).expect("fresh world");
    let mut tracker = Tracker::new();
    let mut ops: Vec<RawOp> = vec![];
    let mut live: Vec<u64> = vec![];
    let mut next_stake_id: u64 = 0;
    let mut total_registered: u128 = 0;
    let mut violation = None;
    let mut aborts = 0usize;
    let mut ops_applied = 0usize;

    let total_weight: u32 = prof.weights.iter().sum();
    let mut op_index = 0usize;

    'outer: while ops.len() < op_count {
        let room = prof.supply.saturating_sub(total_registered);
        let mut choice = rng.gen_range(0..total_weight);
        let mut kind = 0;
        for (k, w) in prof.weights.iter().enumerate() {
            if choice < *w {
                kind = k;
                break;
            }
            choice -= w;
        }
        // Fall back to a no-op-safe choice (4: the second deposit bucket,
        // always available) when the chosen kind's precondition can't be
        // met right now.
        let register_unavailable = room == 0 || live.len() >= prof.max_live;
        let unavailable = match kind {
            0 | 1 | 3 => live.is_empty(),
            2 => register_unavailable,
            // A deposit of any kind aborts ENoStakedShares with no live
            // registration (pool.move:202), so the fallback for an
            // unavailable op has to be `register` when the pool is empty.
            _ => live.is_empty(),
        };
        let kind = if !unavailable {
            kind
        } else if live.is_empty() && !register_unavailable {
            2
        } else if live.is_empty() {
            // Genuinely nothing useful to do: still emit the deposit so the
            // expected ENoStakedShares abort path stays covered (I-B12).
            4
        } else {
            4
        };
        // `kind == 2` reached via the fallback must run the same
        // new_stake+register pair as a directly chosen 2.

        let mut step_ops: Vec<RawOp> = Vec::new();
        match kind {
            0 => {
                let value = pick_bucket(&mut rng, &prof.deposit_buckets);
                step_ops.push(RawOp {
                    op: "deposit".into(),
                    pool: Some(0),
                    value: Some(value),
                    ..Default::default()
                });
            }
            1 => {
                let stake = live[rng.gen_range(0..live.len())];
                step_ops.push(RawOp { op: "claim".into(), pool: Some(0), stake: Some(stake), ..Default::default() });
            }
            2 => {
                let amount = pick_bucket(&mut rng, &prof.amount_buckets).min(room.max(1) as u64);
                let amount = amount.max(1);
                let id = next_stake_id;
                next_stake_id += 1;
                step_ops.push(RawOp { op: "new_stake".into(), stake: Some(id), amount: Some(amount), ..Default::default() });
                step_ops.push(RawOp { op: "register".into(), pool: Some(0), stake: Some(id), ..Default::default() });
                // Only commit to bookkeeping if the register actually
                // succeeds below; tentatively assume success, corrected
                // after applying.
                live.push(id);
                total_registered += amount as u128;
            }
            3 => {
                let idx = rng.gen_range(0..live.len());
                let stake = live.remove(idx);
                // Releasing a registration frees its shares back under the
                // profile's supply cap. Without this the cap is consumed
                // monotonically and, once exhausted, `register` is
                // permanently unavailable -- which pinned `live` at empty
                // and turned every subsequent op into an aborting `deposit`
                // (ENoStakedShares). Measured at ~80% wasted ops on
                // `realistic` before this fix; see REPORT.md "Handoff
                // defects".
                if let Some(w) = world.stakes.get(&stake) {
                    total_registered = total_registered.saturating_sub(w.amount as u128);
                }
                // Claim first (idempotent even if pending is already 0, I-B9)
                // so `unregister` never fails on ELastClaimIndexMismatch.
                step_ops.push(RawOp { op: "claim".into(), pool: Some(0), stake: Some(stake), ..Default::default() });
                step_ops.push(RawOp { op: "unregister".into(), pool: Some(0), stake: Some(stake), ..Default::default() });
            }
            _ => {
                let value = pick_bucket(&mut rng, &prof.deposit_buckets);
                step_ops.push(RawOp {
                    op: "deposit".into(),
                    pool: Some(0),
                    value: Some(value),
                    ..Default::default()
                });
            }
        }

        for raw in step_ops {
            if ops.len() >= op_count {
                break 'outer;
            }
            let op = raw.to_op().expect("fuzz-generated op is always well-formed");
            let result = world.apply(&op);
            ops_applied += 1;
            if let Err(e) = &result {
                aborts += 1;
                if std::env::var_os("FUZZ_ABORT_TRACE").is_some() {
                    eprintln!("ABORT {} {:?}", raw.op, e);
                }
            }
            ops.push(raw);
            if let Ok(outcome) = &result {
                if let Err(v) = invariants::check_all(&world, &mut tracker, op_index, &op, outcome) {
                    violation = Some(v);
                    break 'outer;
                }
            }
            // If `register` aborted (e.g. stress profile intentionally
            // overflowing staked_shares), correct our tentative bookkeeping.
            if let Op::Register { stake, .. } = &op {
                if result.is_err() {
                    live.retain(|s| s != stake);
                    if let Some(w) = world.stakes.get(stake) {
                        total_registered -= w.amount as u128;
                    }
                }
            }
            op_index += 1;
        }
    }

    let telemetry = Telemetry {
        max_carry: tracker.max_carry,
        max_index_bits: tracker.max_index_bits,
        max_amount_index_bits: tracker.max_amount_index_bits,
        max_forfeited_units: tracker.max_forfeited_units,
        max_carry_drift_abs: tracker.max_carry_drift_abs.to_string(),
        max_staked_shares: tracker.max_staked_shares,
        max_balance: tracker.max_balance,
        ops_applied,
        aborts,
    };
    FuzzRunResult { ops, violation, max_ic4_error: tracker.max_ic4_error(), telemetry }
}

/// Replay `ops` from scratch against a fresh `World`, returning the first
/// invariant violation (if any) or a structural error if the op list no
/// longer refers to valid ids (which shrinking must treat as "not
/// reproduced", not as a fix).
fn replay(ops: &[RawOp]) -> Result<Option<Box<Violation>>, ApplyError> {
    let mut world = World::new();
    world.add_pool(0, 0).map_err(ApplyError::World)?;
    let mut tracker = Tracker::new();
    for (i, raw) in ops.iter().enumerate() {
        let op = raw.to_op().expect("shrink candidates are always well-formed ops");
        let outcome = world.apply(&op)?;
        if let Err(v) = invariants::check_all(&world, &mut tracker, i, &op, &outcome) {
            return Ok(Some(v));
        }
    }
    Ok(None)
}

/// Simple delta-debugging: repeatedly try dropping one op at a time (last to
/// first, so earlier indices stay valid across removals within a pass);
/// keep the removal if the replay still violates the *same* invariant id.
/// Repeats passes until a full pass removes nothing.
fn shrink(ops: Vec<RawOp>, target_id: &str) -> Vec<RawOp> {
    let mut current = ops;
    loop {
        let mut removed_any = false;
        let mut i = current.len();
        while i > 0 {
            i -= 1;
            if current.len() <= 1 {
                break;
            }
            let mut candidate = current.clone();
            candidate.remove(i);
            match replay(&candidate) {
                Ok(Some(v)) if v.raw.id == target_id => {
                    current = candidate;
                    removed_any = true;
                }
                _ => {}
            }
        }
        if !removed_any {
            break;
        }
    }
    current
}

pub struct FuzzReport {
    pub profile: String,
    pub seed: u64,
    pub failures: usize,
    pub runs: usize,
    pub max_ic4_error: String,
    pub max_ic4_error_units: String,
    pub telemetry: Telemetry,
    pub minimized: Option<(u64, Vec<RawOp>, Box<Violation>)>,
}

pub fn run_fuzz(
    profile_name: ProfileName,
    profile_str: &str,
    base_seed: u64,
    op_count: usize,
    count: usize,
    skip: usize,
) -> FuzzReport {
    let mut failures = 0usize;
    let mut worst_ic4 = num_rational::BigRational::from_integer(0.into());
    let mut minimized = None;
    let mut telemetry = Telemetry::default();
    for i in skip..(skip + count) {
        let seed = base_seed.wrapping_add(i as u64).wrapping_mul(0x9E3779B97F4A7C15);
        let result = run_one(profile_name, seed, op_count);
        telemetry.merge(&result.telemetry);
        if result.max_ic4_error > worst_ic4 {
            worst_ic4 = result.max_ic4_error.clone();
        }
        if let Some(v) = result.violation {
            failures += 1;
            if minimized.is_none() {
                let shrunk = shrink(result.ops, v.raw.id);
                // Re-derive the violation on the shrunk scenario for an
                // accurate report (op index/message will differ from the
                // original, larger run).
                let v2 = replay(&shrunk).ok().flatten().unwrap_or(v);
                minimized = Some((seed, shrunk, v2));
            }
        }
    }
    FuzzReport {
        profile: profile_str.to_string(),
        seed: base_seed,
        failures,
        runs: count,
        max_ic4_error_units: worst_ic4.ceil().to_integer().to_string(),
        max_ic4_error: worst_ic4.to_string(),
        telemetry,
        minimized,
    }
}

/// Generate `count` scenarios under `profile` (seeded from `base_seed` the
/// same way `run_fuzz` seeds its cases) and write each to
/// `dir/<profile>-seed<base>-<i>.json`, regardless of whether it violated
/// anything. `run_fuzz`'s `--out` only ever dumps a *failing* minimized
/// case, so this is what TASKS-OPUS §3's "dump 200 fuzz-generated scenarios
/// and run `diff` on them" needs.
pub fn sample_scenarios(
    profile_name: ProfileName,
    profile_str: &str,
    base_seed: u64,
    op_count: usize,
    count: usize,
    dir: &std::path::Path,
) -> anyhow::Result<Vec<std::path::PathBuf>> {
    std::fs::create_dir_all(dir)?;
    let mut paths = Vec::new();
    for i in 0..count {
        let seed = base_seed.wrapping_add(i as u64).wrapping_mul(0x9E3779B97F4A7C15);
        let result = run_one(profile_name, seed, op_count);
        let name = format!("{profile_str}-seed{base_seed}-{i:03}");
        let file = dir.join(format!("{name}.json"));
        let scenario = ScenarioFile {
            name,
            setup: Setup { pools: vec![PoolSetup { id: 0, currency: 0 }], stakes: vec![] },
            ops: result.ops,
        };
        std::fs::write(&file, serde_json::to_string_pretty(&scenario)?)?;
        paths.push(file);
    }
    Ok(paths)
}

/// Write a minimized failing scenario to `dir/<profile>-seed<seed>.json`.
pub fn dump_scenario(dir: &std::path::Path, profile: &str, seed: u64, ops: Vec<RawOp>) -> anyhow::Result<std::path::PathBuf> {
    std::fs::create_dir_all(dir)?;
    let file = dir.join(format!("{profile}-seed{seed}.json"));
    let scenario = ScenarioFile {
        name: format!("{profile}-seed{seed}"),
        setup: Setup { pools: vec![PoolSetup { id: 0, currency: 0 }], stakes: vec![] },
        ops,
    };
    std::fs::write(&file, serde_json::to_string_pretty(&scenario)?)?;
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// TASKS-SONNET §5: "A proptest that runs the `realistic` profile for
    /// 200 ops and 256 cases in `cargo test`." (Plain seeded iteration
    /// rather than `proptest!` macro sugar -- `run_fuzz` already *is* the
    /// randomized-case loop `proptest!` would generate, with its own
    /// shrinking; wrapping it in `proptest!` would just add a second,
    /// redundant layer of seed selection.)
    #[test]
    fn realistic_profile_200_ops_256_cases_has_no_violations() {
        let report = run_fuzz(ProfileName::Realistic, "realistic", 0xC0FFEE, 200, 256, 0);
        assert_eq!(
            report.failures, 0,
            "realistic profile found {} violation(s) out of {} cases: {:?}",
            report.failures,
            report.runs,
            report.minimized.map(|(seed, _, v)| format!("seed {seed}: {v}"))
        );
    }
}
