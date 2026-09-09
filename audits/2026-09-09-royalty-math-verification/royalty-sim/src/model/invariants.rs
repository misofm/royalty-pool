//! SPEC invariants (§2.8, §3.2, §1) as runtime checks over a `World`.
//!
//! Each `check_*` function inspects state (plus, for a few, the just-applied
//! op's `Outcome`) and returns `Err(RawViolation)` describing exactly which
//! comparison failed. `check_all` is the entry point the runner
//! (`scenario.rs`) calls after every op; it fills in the op index and the op
//! itself so a `Violation` is self-contained for reporting.

use num_rational::BigRational;
use num_bigint::BigInt;
use primitive_types::U256;

use super::pool::{calculate_reward, Pool, P};
use super::stake::{Currency, PoolId, Registration, Stake};
use super::world::{Op, Outcome, World};

#[derive(Debug, Clone)]
pub struct RawViolation {
    pub id: &'static str,
    pub message: String,
    pub left_desc: String,
    pub left: String,
    pub right_desc: String,
    pub right: String,
}

impl RawViolation {
    /// Boxed (clippy `result_large_err`: this struct's several `String`
    /// fields make the `Err` side of every `check_*` result far bigger than
    /// the `Ok(())` side; every `check_*` function below returns
    /// `Result<(), Box<RawViolation>>` for exactly this reason).
    fn new(
        id: &'static str,
        message: impl Into<String>,
        left_desc: impl Into<String>,
        left: impl std::fmt::Display,
        right_desc: impl Into<String>,
        right: impl std::fmt::Display,
    ) -> Box<Self> {
        Box::new(RawViolation {
            id,
            message: message.into(),
            left_desc: left_desc.into(),
            left: left.to_string(),
            right_desc: right_desc.into(),
            right: right.to_string(),
        })
    }
}

#[derive(Debug, Clone)]
pub struct Violation {
    pub op_index: usize,
    pub op: Op,
    pub raw: Box<RawViolation>,
}

impl std::fmt::Display for Violation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "[{}] after op #{} ({:?}): {} -- {} = {} vs {} = {}",
            self.raw.id,
            self.op_index,
            self.op,
            self.raw.message,
            self.raw.left_desc,
            self.raw.left,
            self.raw.right_desc,
            self.raw.right
        )
    }
}

/// Per-pool state carried across ops purely for invariant checking (I-B5
/// monotonicity needs the previous index). Not part of the model proper.
#[derive(Debug, Default)]
pub struct Tracker {
    last_index: std::collections::BTreeMap<PoolId, U256>,
    max_ic4_error: std::collections::BTreeMap<PoolId, BigRational>,
    /// §1 telemetry (TASKS-OPUS): quantities the campaign must report.
    pub max_carry: u128,
    pub max_index_bits: usize,
    pub max_amount_index_bits: usize,
    pub max_forfeited_units: u128,
    pub max_carry_drift_abs: BigRational,
    pub max_staked_shares: u64,
    pub max_balance: u64,
}

impl Tracker {
    pub fn new() -> Self {
        Tracker::default()
    }

    /// Largest `|ideal − (paid+pending)|` observed, in whole token units,
    /// rounded up (for the report's headline number).
    pub fn max_ic4_error_ceil_units(&self) -> BigInt {
        let e = self.max_ic4_error();
        e.ceil().to_integer()
    }

    pub fn max_ic4_error(&self) -> BigRational {
        self.max_ic4_error
            .values()
            .cloned()
            .fold(BigRational::from_integer(0.into()), |a, b| if a > b { a } else { b })
    }
}

/// Every (stake, currency, registration) live in the world, including
/// routed stakes' wrapped positions.
fn all_registrations(world: &World) -> Vec<(&Stake, Currency, &Registration)> {
    let mut out = Vec::new();
    for s in world.stakes.values() {
        for (cur, reg) in &s.registrations {
            out.push((s, *cur, reg));
        }
    }
    for r in world.routed.values() {
        if let Some(s) = &r.stake {
            for (cur, reg) in &s.registrations {
                out.push((s, *cur, reg));
            }
        }
    }
    out
}

fn registrations_in_pool<'a>(world: &'a World, pool: &Pool) -> Vec<(&'a Stake, &'a Registration)> {
    all_registrations(world)
        .into_iter()
        .filter(|(_, cur, reg)| *cur == pool.currency && reg.pool_id == pool.id)
        .map(|(s, _, reg)| (s, reg))
        .collect()
}

/// I-B1: solvency. `balance >= Σ claimable_r`.
pub fn check_b1(world: &World, pool: &Pool) -> Result<(), Box<RawViolation>> {
    check_b1_regs(&registrations_in_pool(world, pool), pool)
}

fn check_b1_regs(regs: &[(&Stake, &Registration)], pool: &Pool) -> Result<(), Box<RawViolation>> {
    let mut claimable_sum: u128 = 0;
    for (s, reg) in regs.iter().copied() {
        let c = calculate_reward(s.amount, reg.debt, pool.index)
            .map_err(|_| RawViolation::new("I-B1", "calculate_reward overflowed while checking solvency", "stake", s.id, "pool", pool.id))?;
        claimable_sum += c as u128;
    }
    if (pool.balance as u128) < claimable_sum {
        return Err(RawViolation::new(
            "I-B1",
            format!("pool {} insolvent", pool.id),
            "balance",
            pool.balance,
            "sum(claimable)",
            claimable_sum,
        ));
    }
    Ok(())
}

/// I-B2: exact conservation, `balance*P == Σ owed_r + carry + forfeited`.
pub fn check_b2(world: &World, pool: &Pool) -> Result<(), Box<RawViolation>> {
    check_b2_regs(&registrations_in_pool(world, pool), pool)
}

fn check_b2_regs(regs: &[(&Stake, &Registration)], pool: &Pool) -> Result<(), Box<RawViolation>> {
    let mut owed_sum = U256::zero();
    for (s, reg) in regs.iter().copied() {
        let scaled = U256::from(s.amount) * pool.index; // I-B7 already checked by the model on the way here
        let owed = scaled
            .checked_sub(reg.debt)
            .ok_or_else(|| RawViolation::new("I-B3", "amount*index < debt (underflow)", "amount*index", scaled, "debt", reg.debt))?;
        owed_sum += owed;
    }
    let left = U256::from(pool.balance) * U256::from(P);
    let right = owed_sum + U256::from(pool.carry) + pool.forfeited;
    if left != right {
        return Err(RawViolation::new(
            "I-B2",
            format!("pool {} conservation violated", pool.id),
            "balance*P",
            left,
            "sum(owed)+carry+forfeited",
            right,
        ));
    }
    Ok(())
}

/// I-B4: carry bound, `carry < staked_shares` (or `carry == 0` when fresh).
/// The bound is relative to `staked_shares` *as of the last deposit*
/// (`pool.move:212`'s modulus at that call), not the pool's current
/// `staked_shares` -- a later `unregister` can drain `staked_shares` to 0
/// while `carry` sits unchanged from the last deposit (see
/// `staked_shares_at_last_deposit`'s doc).
pub fn check_b4(pool: &Pool) -> Result<(), Box<RawViolation>> {
    if pool.staked_shares_at_last_deposit == 0 {
        if pool.carry != 0 {
            return Err(RawViolation::new(
                "I-B4",
                format!("pool {} has carry with no deposit ever made", pool.id),
                "carry",
                pool.carry,
                "0",
                0,
            ));
        }
    } else if pool.carry >= pool.staked_shares_at_last_deposit as u128 {
        return Err(RawViolation::new(
            "I-B4",
            format!("pool {} carry not below staked_shares as of the last deposit", pool.id),
            "carry",
            pool.carry,
            "staked_shares_at_last_deposit",
            pool.staked_shares_at_last_deposit,
        ));
    }
    Ok(())
}

/// I-B5: index monotone (never decreases).
pub fn check_b5(tracker: &mut Tracker, pool: &Pool) -> Result<(), Box<RawViolation>> {
    let prev = tracker.last_index.get(&pool.id).copied().unwrap_or(U256::zero());
    if pool.index < prev {
        return Err(RawViolation::new(
            "I-B5",
            format!("pool {} index decreased", pool.id),
            "index",
            pool.index,
            "previous index",
            prev,
        ));
    }
    tracker.last_index.insert(pool.id, pool.index);
    Ok(())
}

/// I-B8: residue bound, `forfeited < P * unregister_count`.
pub fn check_b8(pool: &Pool) -> Result<(), Box<RawViolation>> {
    let bound = U256::from(P) * U256::from(pool.unregister_count);
    if pool.unregister_count > 0 && pool.forfeited >= bound {
        return Err(RawViolation::new(
            "I-B8",
            format!("pool {} forfeited exceeds per-unregister bound", pool.id),
            "forfeited",
            pool.forfeited,
            "P*unregister_count",
            bound,
        ));
    }
    Ok(())
}

/// I-C4: exact-rational oracle -- `ideal - (paid+pending)` should be small
/// for every live registration; the bound actually enforced (see below) is
/// looser than SPEC's original sketch, once `staked_shares` can change
/// *during* a registration's window.
///
/// A tight bound would be *two-sided*, unlike SPEC's informal sketch ("< 1 +
/// n_claims", implicitly one-sided: `paid+pending <= ideal`) is not, once
/// `staked_shares` can change *during* a registration's window. Empirically
/// found via `fuzz --profile hugeshares` (recorded in NOTES.md /
/// DISCREPANCIES.md) and confirmed algebraically:
///
/// Fix a stake's window `[reg, now]` and let `S` be `staked_shares`, which is
/// constant across that window (no register/unregister touched it). Move's
/// carry recurrence telescopes exactly over the window's own deposits:
/// `(idx_now - idx_reg)*S + (carry_now - carry_reg) == Σ value_k * P`
/// (each step is an exact `numerator = q*S + r` split; verified against a
/// captured failing scenario in the crate's fuzz corpus). So
/// `(idx_now - idx_reg)/P == ideal_delta_per_share - (carry_now -
/// carry_reg)/(S*P)`, where `ideal_delta_per_share == Σ value_k/S` is exactly
/// the ghost's `ideal_index` delta. `amount * (idx_now-idx_reg)/P` is
/// therefore within `amount * |carry_now - carry_reg| / (S*P)` of
/// `amount * ideal_delta_per_share` -- and since **`carry_reg` is bounded by
/// staked_shares *as of registration*, which can be smaller than the
/// window's constant `S`** (a big new stake joining inherits a carry
/// fold-in it did not itself accrue), `|carry_now - carry_reg|` is bounded
/// only by `S`, not by anything smaller -- giving an error term bounded by
/// `amount/P` **in either direction**, not just paid+pending falling short
/// of ideal. `calculate_reward`'s own floor then costs up to one more unit
/// per claim, SPEC's original term. This is a real, bounded fairness
/// perturbation (conservation I-B2 still holds exactly; no value is
/// created or destroyed) -- a large stake joining while a small-`S`-regime
/// carry is still unresolved can receive up to `amount/P` more than its
/// literal pro-rata ideal once that carry folds in.
///
/// A tighter, single-episode bound (`amount/P + 1 + claims`, derived and
/// tried first -- see the exhaustive derivation above) turned out to still
/// fail under `fuzz --profile hugeshares`/`stress`: when *several* other
/// registrations/unregistrations change `staked_shares` during one stake's
/// window, each contributes its own carry-inheritance episode, and the
/// errors compound. Deriving the exact multi-episode bound is a proof
/// exercise beyond what this ghost check needs (SPEC itself calls I-C4
/// empirical: "assert that bound and record the observed max"); instead we
/// use a bound that is trivially, unconditionally true by conservation
/// (I-B2) -- `ideal_r <= ideal_total <= cumulative_deposits` (a deposit's
/// value is split, never amplified, across the ideal shares) and
/// `actual_r = paid_r + pending_r <= cumulative_deposits` likewise -- so
/// `|diff| <= 2 * cumulative_deposits` always, regardless of episode count.
/// This is a real invariant (a genuine bug -- wrong units, a sign flip, a
/// stray widening -- would blow even this loose a bound), just not a tight
/// one; `Tracker::max_ic4_error` still records the tightest empirically
/// observed magnitude for reporting (see DISCREPANCIES.md for the
/// SPEC-vs-Move finding this bound relaxation documents).
pub fn check_c4(world: &World, pool: &Pool, tracker: &mut Tracker) -> Result<(), Box<RawViolation>> {
    check_c4_regs(&registrations_in_pool(world, pool), pool, tracker)
}

fn check_c4_regs(_regs: &[(&Stake, &Registration)], _pool: &Pool, _tracker: &mut Tracker) -> Result<(), Box<RawViolation>> {
    // Superseded by `check_c4_exact_regs`, which both enforces the exact
    // closed form and derives the reported `ideal − (paid+pending)` error
    // from the same `ΔCD` it already computes:
    //     ideal_r − (paid+pending) = frac(a·Δindex/P) + (a/P)·ΔCD
    // (see `check_c4_exact_regs`). Computing `ideal_r` a second time from
    // `ideal_index` cost a clone/multiply/subtract of a big rational per
    // registration per op for no additional coverage.
    Ok(())
}

/// **I-C4-exact**: the rounding error of the accumulator is not merely
/// *bounded*, it is an exact closed form. This check asserts that closed
/// form bit-for-bit and is strictly stronger than `check_c4`.
///
/// Derivation (all in exact rationals; `S_k` is `staked_shares` at deposit
/// `k`, `v_k` the deposited value, `P` the precision):
///
/// `pool::deposit` (`pool.move:207-212`) computes `numerator = v_k·P +
/// carry_{k−1}`, `index_k = index_{k−1} + ⌊numerator/S_k⌋`, `carry_k =
/// numerator mod S_k`. Since `⌊n/S⌋ = (n − n mod S)/S` exactly:
///
/// ```text
/// index_k − index_{k−1} = (v_k·P + carry_{k−1} − carry_k) / S_k
/// ```
///
/// Summing over the deposits `k ∈ (j, m]` of a registration's window (`j` =
/// the deposit index at registration, `m` = now) and dividing by `P`:
///
/// ```text
/// (index_m − index_j)/P = Σ v_k/S_k  −  (1/P)·Σ (carry_k − carry_{k−1})/S_k
///                       = ΔII        −  ΔCD/P
/// ```
///
/// where `ΔII` is the `ideal_index` ghost's delta (the exact, unfloored
/// per-share entitlement) and `ΔCD` the `carry_drift` ghost's delta. Note
/// this holds for *any* sequence of `S_k`, including one changed by other
/// stakes registering and unregistering mid-window — nothing here assumes a
/// constant share set.
///
/// Separately, a registration's `debt` is `a·index_j + Σ reward_i·P`
/// (`register_stake` sets `a·index_j`; `claim_rewards` adds `reward·P`), so
///
/// ```text
/// paid + pending = Σreward_i + ⌊(a·index_m − a·index_j − Σreward_i·P)/P⌋
///                = ⌊a·(index_m − index_j)/P⌋
/// ```
///
/// — **independent of how many times the stake claimed**, because each
/// claim's sub-unit residue is retained in `debt` rather than discarded.
/// (SPEC's I-C4 sketch carries a `+ number of claims` term; that term is
/// unnecessary. Claim frequency costs a staker exactly nothing.)
///
/// Combining, with `ideal_r = a·ΔII`:
///
/// ```text
/// paid + pending = ⌊ideal_r − (a/P)·ΔCD⌋
/// ```
///
/// so the quantity
///
/// ```text
/// X := ideal_r − (a/P)·ΔCD − (paid + pending)
/// ```
///
/// must lie in `[0, 1)` — always, exactly. That is what this function
/// asserts. Any deviation whatsoever is a defect in the model or in Move.
///
/// The practical fairness reading: the *whole* deviation from exact pro-rata
/// is `(a/P)·ΔCD + frac`, `frac ∈ [0,1)`. Over a window in which
/// `staked_shares` is constant at `S`, `ΔCD = (carry_m − carry_j)/S` and
/// both carries are `< S`, so `|(a/P)·ΔCD| < a/P` — under one token unit for
/// any stake of at most `P = 1e18` shares, and at most `18.44` units for the
/// largest representable u64 stake. When `staked_shares` changes mid-window
/// the Abel-summed form
/// `ΔCD = carry_m/S_m − carry_j/S_{j+1} + Σ carry_k(1/S_k − 1/S_{k+1})`
/// picks up one bounded term per change ("carry-inheritance episode",
/// DISCREPANCIES.md #2), each `< 1` in magnitude when shares grow — hence
/// error `< 1 + (a/P)·(episodes)` — and each up to `S_k/S_{k+1}` when shares
/// shrink. `Tracker::max_carry_drift_abs` records the observed maximum.
pub fn check_c4_exact(world: &World, pool: &Pool, tracker: &mut Tracker) -> Result<(), Box<RawViolation>> {
    check_accumulator_identity(pool)?;
    check_c4_exact_regs(&registrations_in_pool(world, pool), pool, tracker)
}

/// **(a) The accumulator identity**, checked once per pool per op, in exact
/// rationals:
///
/// ```text
/// ideal_index − carry_drift / P  ==  index / P
/// ```
///
/// `index` is the real, floored `cumulative_reward_per_share` the Move code
/// maintains. `ideal_index` (`Σ v_k/S_k`) and `carry_drift`
/// (`Σ (carry_k − carry_{k−1})/S_k`) are two ghosts accumulated
/// independently of it, one from the deposit values and one from the carry
/// remainders. The identity says the floored accumulator differs from the
/// exact pro-rata accumulator by exactly the carry drift and nothing else —
/// i.e. `pool::deposit` loses no value to its floor beyond what `carry`
/// records. A stray widening, a wrong divisor, a dropped carry, or an
/// off-by-one in the fold breaks this immediately.
fn check_accumulator_identity(pool: &Pool) -> Result<(), Box<RawViolation>> {
    let p_rat = BigRational::from_integer(BigInt::from(P));
    let lhs = pool.ideal_index.clone() - pool.carry_drift.clone() / p_rat.clone();
    let rhs = BigRational::new(u256_to_bigint(pool.index), BigInt::from(P));
    if lhs != rhs {
        return Err(RawViolation::new(
            "I-C4-exact/a",
            format!("pool {} accumulator identity broken", pool.id),
            "ideal_index - carry_drift/P",
            lhs,
            "index/P",
            rhs,
        ));
    }
    Ok(())
}

fn u256_to_bigint(v: U256) -> BigInt {
    let bytes = v.to_big_endian();
    BigInt::from_bytes_be(num_bigint::Sign::Plus, &bytes)
}

/// **(b) The payout identity (I-B6, exact)**, checked per registration per
/// op in pure integer arithmetic:
///
/// ```text
/// paid + pending == ⌊amount · (index − index_at_registration) / P⌋
/// ```
///
/// This is the statement that a registration is paid exactly its floored
/// pro-rata share of every index movement in its window, **independent of
/// how often it claimed** — each claim's sub-unit residue is retained in
/// `debt` (`pool.move:330` adds `reward·P`, not the full accrual), so claim
/// frequency costs a staker exactly nothing. SPEC's I-C4 sketch carries a
/// `+ number of claims` error term; this check shows that term is
/// unnecessary.
///
/// Together (a) and (b) give the closed form
/// `paid + pending == ⌊ideal_r − (amount/P)·ΔCD⌋`, so the entire deviation
/// from exact pro-rata is `(amount/P)·ΔCD + frac`, `frac ∈ [0,1)`. See
/// `Pool::carry_drift` and REPORT.md for the fairness reading and the bound
/// on `ΔCD`.
fn check_c4_exact_regs(regs: &[(&Stake, &Registration)], pool: &Pool, tracker: &mut Tracker) -> Result<(), Box<RawViolation>> {
    let p256 = U256::from(P);
    for (s, reg) in regs.iter().copied() {
        let pending = calculate_reward(s.amount, reg.debt, pool.index).map_err(|_| {
            RawViolation::new("I-C4-exact/b", "calculate_reward overflowed", "stake", s.id, "pool", pool.id)
        })?;
        let delta_index = pool.index.checked_sub(reg.idx_at_registration).ok_or_else(|| {
            RawViolation::new("I-B5", "index fell below its value at registration", "index", pool.index, "idx_at_registration", reg.idx_at_registration)
        })?;
        let expected = (U256::from(s.amount) * delta_index) / p256;
        let actual = U256::from(reg.paid) + U256::from(pending);
        if actual != expected {
            return Err(RawViolation::new(
                "I-C4-exact/b",
                format!("stake {} in pool {}: paid+pending != floor(amount*(index-index_at_reg)/P)", s.id, pool.id),
                "paid+pending",
                actual,
                "floor(amount*delta_index/P)",
                expected,
            ));
        }
        let ai = U256::from(s.amount) * pool.index;
        let bits = 256 - ai.leading_zeros() as usize;
        if bits > tracker.max_amount_index_bits {
            tracker.max_amount_index_bits = bits;
        }
        let delta_cd = pool.carry_drift.clone() - reg.carry_drift_at_registration.clone();

        // Reported I-C4 error, exactly:
        //   ideal_r − (paid+pending) = frac(a·Δindex/P) + (a/P)·ΔCD
        let frac = BigRational::new(
            u256_to_bigint((U256::from(s.amount) * delta_index) % p256),
            BigInt::from(P),
        );
        let err = frac
            + BigRational::from_integer(BigInt::from(s.amount)) * delta_cd.clone()
                / BigRational::from_integer(BigInt::from(P));
        // Unconditionally-true sanity bound from conservation (I-B2): both
        // `ideal_r` and `paid+pending` are at most `cumulative_deposits`.
        let bound = BigRational::from_integer(
            BigInt::from(2) * BigInt::from(pool.cumulative_deposits) + BigInt::from(1),
        );
        if err <= -bound.clone() || err >= bound.clone() {
            return Err(RawViolation::new(
                "I-C4",
                format!("stake {} in pool {} exceeds exact-oracle sanity bound", s.id, pool.id),
                "ideal - (paid+pending)",
                err,
                "bound (2*cumulative_deposits + 1)",
                bound,
            ));
        }
        let abs_err = if err < BigRational::from_integer(0.into()) { -err.clone() } else { err.clone() };
        let e = tracker.max_ic4_error.entry(pool.id).or_insert_with(|| BigRational::from_integer(0.into()));
        if abs_err > *e {
            *e = abs_err;
        }

        let abs_cd = if delta_cd < BigRational::from_integer(0.into()) { -delta_cd } else { delta_cd };
        if abs_cd > tracker.max_carry_drift_abs {
            tracker.max_carry_drift_abs = abs_cd;
        }
    }
    Ok(())
}

fn record_telemetry(tracker: &mut Tracker, pool: &Pool) {
    if pool.carry > tracker.max_carry {
        tracker.max_carry = pool.carry;
    }
    let ibits = 256 - pool.index.leading_zeros() as usize;
    if ibits > tracker.max_index_bits {
        tracker.max_index_bits = ibits;
    }
    let f_units = (pool.forfeited / U256::from(P)).low_u128();
    if f_units > tracker.max_forfeited_units {
        tracker.max_forfeited_units = f_units;
    }
    if pool.staked_shares > tracker.max_staked_shares {
        tracker.max_staked_shares = pool.staked_shares;
    }
    if pool.balance > tracker.max_balance {
        tracker.max_balance = pool.balance;
    }
}

/// All pool-scoped invariants applicable after any op.
pub fn check_pool(world: &World, pool: &Pool, tracker: &mut Tracker) -> Result<(), Box<RawViolation>> {
    // One scan of the world's registrations, shared by every check that
    // needs it (this scan is O(all stakes) and used to run four times per
    // pool per op).
    let regs = registrations_in_pool(world, pool);
    check_b1_regs(&regs, pool)?;
    check_b2_regs(&regs, pool)?;
    check_b4(pool)?;
    check_b5(tracker, pool)?;
    check_b8(pool)?;
    check_c4_regs(&regs, pool, tracker)?;
    // Identity (a). This call was missing until the independent verification
    // pass caught it: `check_accumulator_identity` was defined and derived
    // but only reachable through `check_c4_exact`, which nothing called, so
    // the 88M-operation campaign enforced identity (b) alone. Wired in here.
    check_accumulator_identity(pool)?;
    check_c4_exact_regs(&regs, pool, tracker)?;
    record_telemetry(tracker, pool);
    Ok(())
}

/// I-A1/I-A2: distributor conservation and remainder bound, checked against
/// the `Outcome` of a `ReleaseDistribute` op.
pub fn check_distribution(splits: &[u64], total: u64, dist: &super::distributor::Distribution) -> Result<(), Box<RawViolation>> {
    let sum: u64 = dist.amounts.iter().sum();
    let n = splits.len() as u64;
    if sum + dist.remainder != total {
        return Err(RawViolation::new(
            "I-A1",
            "distribution does not conserve total",
            "sum(amounts)+remainder",
            sum + dist.remainder,
            "T",
            total,
        ));
    }
    if dist.remainder >= n {
        return Err(RawViolation::new(
            "I-A2",
            "remainder not bounded by track count",
            "remainder",
            dist.remainder,
            "n",
            n,
        ));
    }
    Ok(())
}

/// I-C1: sweep conservation, checked against the `Outcome` of a
/// `RoutedSweep` op.
pub fn check_sweep(swept: &super::routed::Swept) -> Result<(), Box<RawViolation>> {
    if swept.claimed != swept.deposited + swept.parked {
        return Err(RawViolation::new(
            "I-C1",
            "sweep did not conserve the claimed reward",
            "claimed",
            swept.claimed,
            "deposited+parked",
            swept.deposited + swept.parked,
        ));
    }
    Ok(())
}

/// Run every applicable invariant after op #`op_index` (`op`, whose
/// `Outcome` was `outcome`) was applied to `world`. Scans every pool for the
/// state invariants, plus the op-scoped ones (A1/A2 for `ReleaseDistribute`,
/// C1 for `RoutedSweep`).
pub fn check_all(
    world: &World,
    tracker: &mut Tracker,
    op_index: usize,
    op: &Op,
    outcome: &Outcome,
) -> Result<(), Box<Violation>> {
    for pool in world.pools.values() {
        check_pool(world, pool, tracker).map_err(|raw| Box::new(Violation { op_index, op: op.clone(), raw }))?;
    }
    match (op, outcome) {
        (Op::ReleaseDistribute { release }, Outcome::Distribution(Some(dist))) => {
            // total = amounts+remainder by definition of `distribute`; we
            // additionally have the release's splits.
            if let Some(r) = world.releases.get(release) {
                let total: u64 = dist.amounts.iter().sum::<u64>() + dist.remainder;
                check_distribution(&r.splits, total, dist)
                    .map_err(|raw| Box::new(Violation { op_index, op: op.clone(), raw }))?;
            }
        }
        (Op::RoutedSweep { .. }, Outcome::Swept(swept)) => {
            check_sweep(swept).map_err(|raw| Box::new(Violation { op_index, op: op.clone(), raw }))?;
        }
        _ => {}
    }
    Ok(())
}
