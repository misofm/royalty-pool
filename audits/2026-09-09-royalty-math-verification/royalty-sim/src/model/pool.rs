//! Mirrors `royalty_pool::pool` (`pool.move`), SPEC §2.
//!
//! Every arithmetic step below cites the Move line(s) it reproduces. Widths
//! and operation order follow Move exactly: `u64` inputs, `u128` carry
//! arithmetic, `u256` index/debt, and the single unchecked-in-Move `as u64`
//! narrowing in `calculate_reward` (guarded here by `try_from`, mapped to
//! `Abort::Arithmetic` on failure — Move would simply abort the transaction
//! with a VM arithmetic error at that point, never mint out-of-thin-air
//! value).

use primitive_types::U256;
use serde::{Deserialize, Serialize};

use super::abort::{Abort, PoolAbort};
use super::stake::{Currency, PoolId, Registration, Stake};

/// `PRECISION` (`pool.move:95`).
pub const P: u128 = 1_000_000_000_000_000_000;

fn trace(what: &str) {
    if std::env::var_os("FUZZ_ABORT_TRACE").is_some() {
        eprintln!("TRACE {what}");
    }
}

fn zero_rational() -> num_rational::BigRational {
    num_rational::BigRational::from_integer(0.into())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pool {
    pub id: PoolId,
    pub currency: Currency,
    /// `cumulative_reward_per_share` (`pool.move:103`).
    pub index: U256,
    /// `carry` (`pool.move:107`).
    pub carry: u128,
    /// `staked_shares` (`pool.move:102`).
    pub staked_shares: u64,
    /// `cumulative_deposits` (`pool.move:110`).
    pub cumulative_deposits: u128,
    /// `balance` (`pool.move:101`).
    pub balance: u64,

    // --- ghosts (not on chain) ---
    /// Sum of sub-unit residues forfeited by `unregister` (SPEC §2.6), in
    /// P-units. Used by I-B2/I-B8.
    #[serde(skip)]
    pub forfeited: U256,
    /// Funds "parked" at the pool's own address by `routed_stake::sweep`
    /// when this pool had no stakers (SPEC §3.1, `routed_stake.move:223-227`)
    /// or otherwise sent to the pool address, waiting for `settle`. Out of
    /// scope §7 says address-balance settlement timing is modeled as
    /// immediate, so this is simply a queue `settle` drains in full.
    #[serde(skip)]
    pub parked_at_address: u64,
    /// Exact (unfloored) accumulator index, `Σ value/staked_shares` over
    /// every deposit, for the I-C4 exact-rational oracle.
    #[serde(skip, default = "zero_rational")]
    pub ideal_index: num_rational::BigRational,
    /// Count of `unregister` calls ever made against this pool (I-B8 bound:
    /// `forfeited < P * unregister_count`).
    #[serde(skip)]
    pub unregister_count: u64,
    /// Running sum `Σ_k (carry_k − carry_{k−1}) / S_k` over every deposit
    /// `k` this pool has ever folded, where `S_k` is `staked_shares` at
    /// deposit `k`. Exact rational, in P-units-per-share. This is the ghost
    /// that makes I-C4 an *exact identity* rather than an inequality: see
    /// the derivation on `invariants::check_c4_exact`.
    #[serde(skip, default = "zero_rational")]
    pub carry_drift: num_rational::BigRational,
    /// `staked_shares` as of the *last deposit* (I-B4: `carry <
    /// staked_shares` holds relative to the shares in effect when carry was
    /// last set, not necessarily the pool's current `staked_shares` -- a
    /// later `unregister` can drop `staked_shares` to 0 while `carry` sits
    /// unchanged, exactly matching `royalty_pool_accounting_tests.move`'s
    /// `staked_at_fold` ghost).
    #[serde(skip)]
    pub staked_shares_at_last_deposit: u64,
}

impl Pool {
    pub fn new(id: PoolId, currency: Currency) -> Self {
        Pool {
            id,
            currency,
            index: U256::zero(),
            carry: 0,
            staked_shares: 0,
            cumulative_deposits: 0,
            balance: 0,
            forfeited: U256::zero(),
            parked_at_address: 0,
            ideal_index: num_rational::BigRational::from_integer(0.into()),
            unregister_count: 0,
            carry_drift: num_rational::BigRational::from_integer(0.into()),
            staked_shares_at_last_deposit: 0,
        }
    }

    /// `deposit` (`pool.move:198-220`).
    pub fn deposit(&mut self, value: u64) -> Result<(), Abort> {
        if self.staked_shares == 0 {
            return Err(Abort::Pool(PoolAbort::NoStakedShares)); // pool.move:202
        }
        if value == 0 {
            return Err(Abort::Pool(PoolAbort::InvalidValue)); // pool.move:205
        }

        // numerator = value * PRECISION + carry (pool.move:208). Comment at
        // pool.move:207 proves this never overflows u128 for any u64 value;
        // we still use checked ops rather than "helpfully" trusting the
        // proof. Every fallible value is computed before any field is
        // mutated, so a `checked_*` miss here leaves `self` untouched —
        // mirroring Move's whole-transaction rollback on abort.
        let numerator = (value as u128)
            .checked_mul(P)
            .and_then(|v| v.checked_add(self.carry))
            .ok_or_else(|| { trace("deposit:numerator"); Abort::Arithmetic })?;
        let staked_shares = self.staked_shares as u128;

        // index += (numerator / staked_shares) as u256 (pool.move:210-211).
        let increment = numerator / staked_shares;
        let new_index = self
            .index
            .checked_add(U256::from(increment))
            .ok_or_else(|| { trace("deposit:index"); Abort::Arithmetic })?;
        // carry = numerator % staked_shares (pool.move:212).
        let new_carry = numerator % staked_shares;
        let new_cumulative_deposits = self
            .cumulative_deposits
            .checked_add(value as u128)
            .ok_or_else(|| { trace("deposit:cumulative_deposits"); Abort::Arithmetic })?; // pool.move:213
        let new_balance = self
            .balance
            .checked_add(value)
            .ok_or_else(|| { trace("deposit:balance_u64_overflow"); Abort::Arithmetic })?; // pool.move:214 (balance.join)

        let old_carry = self.carry;
        self.index = new_index;
        self.carry = new_carry;
        self.cumulative_deposits = new_cumulative_deposits;
        self.balance = new_balance;
        // Ghost: exact (unfloored) index for the I-C4 oracle.
        self.ideal_index += num_rational::BigRational::new(value.into(), self.staked_shares.into());
        // Ghost for the exact I-C4 identity: (carry_k − carry_{k−1}) / S_k.
        self.carry_drift += num_rational::BigRational::new(
            num_bigint::BigInt::from(new_carry) - num_bigint::BigInt::from(old_carry),
            self.staked_shares.into(),
        );
        // Ghost for I-B4 (see the field doc): `carry`'s bound is relative to
        // `staked_shares` as of *this* deposit, not whatever it is later.
        self.staked_shares_at_last_deposit = self.staked_shares;

        Ok(())
    }

    /// `settle` (`pool.move`, replaces `sweep_and_deposit`). Total: returns
    /// `Ok(0)` and changes nothing when `staked_shares == 0` (read nothing,
    /// redeem nothing — the guard runs before any accumulator read) or when
    /// nothing is parked at the pool's address. Otherwise redeems the parked
    /// value and folds it into the accumulator via `deposit`, returning the
    /// value deposited.
    pub fn settle(&mut self) -> Result<u64, Abort> {
        if self.staked_shares == 0 {
            return Ok(0);
        }
        let value = self.parked_at_address;
        if value == 0 {
            return Ok(0);
        }
        self.parked_at_address = 0;
        self.deposit(value)?;
        Ok(value)
    }

    /// `register_stake` (`pool.move:255-275`).
    pub fn register(&mut self, stake: &mut Stake) -> Result<(), Abort> {
        if stake.has_registration(self.currency) {
            return Err(Abort::Pool(PoolAbort::AlreadyRegistered)); // pool.move:260
        }
        let amount = stake.amount;
        // debt = amount * index (u256, full precision) (pool.move:265).
        let debt = U256::from(amount)
            .checked_mul(self.index)
            .ok_or(Abort::Arithmetic)?; // I-B7
        // pool.move:268 -- computed before any mutation (see `deposit`'s
        // comment on atomicity).
        let new_staked_shares = self.staked_shares.checked_add(amount).ok_or(Abort::Arithmetic)?;

        stake.registrations.insert(
            self.currency,
            Registration {
                pool_id: self.id,
                debt,
                idx_at_registration: self.index,
                paid: 0,
                carry_drift_at_registration: self.carry_drift.clone(),
                ideal_index_at_registration: self.ideal_index.clone(),
                claims_since_registration: 0,
            },
        );
        self.staked_shares = new_staked_shares;
        Ok(())
    }

    /// `unregister_stake` (`pool.move:282-309`). Forfeits the sub-unit
    /// residue into the `forfeited` ghost (SPEC §2.6/§2.8, I-B8).
    pub fn unregister(&mut self, stake: &mut Stake) -> Result<(), Abort> {
        if !stake.has_registration(self.currency) {
            return Err(Abort::Pool(PoolAbort::NotRegistered)); // pool.move:287
        }
        let amount = stake.amount;
        let index = self.index;
        let reg = stake.registration(self.currency).unwrap();
        if reg.pool_id != self.id {
            return Err(Abort::Pool(PoolAbort::PoolIdMismatch)); // pool.move:295
        }
        let reward = calculate_reward(amount, reg.debt, index)?;
        if reward != 0 {
            return Err(Abort::Pool(PoolAbort::LastClaimIndexMismatch)); // pool.move:296-299
        }

        // Residue forfeited (< PRECISION, since reward == 0 means
        // amount*index - debt < PRECISION). I-B3 guarantees no underflow.
        let raw = U256::from(amount)
            .checked_mul(index)
            .and_then(|v| v.checked_sub(reg.debt))
            .ok_or(Abort::Arithmetic)?;
        let new_forfeited = self.forfeited.checked_add(raw).ok_or(Abort::Arithmetic)?;
        // pool.move:302 -- computed before any mutation.
        let new_staked_shares = self.staked_shares.checked_sub(amount).ok_or(Abort::Arithmetic)?;

        self.forfeited = new_forfeited;
        self.unregister_count += 1;
        stake.registrations.remove(&self.currency);
        self.staked_shares = new_staked_shares;
        Ok(())
    }

    /// `claim_rewards` (`pool.move:313-339`).
    pub fn claim(&mut self, stake: &mut Stake) -> Result<u64, Abort> {
        if !stake.has_registration(self.currency) {
            return Err(Abort::Pool(PoolAbort::NotRegistered)); // pool.move:318
        }
        let amount = stake.amount;
        let index = self.index;
        let pool_id = self.id;
        let reg = stake.registration_mut(self.currency).unwrap();
        if reg.pool_id != pool_id {
            return Err(Abort::Pool(PoolAbort::PoolIdMismatch)); // pool.move:326
        }

        let reward = calculate_reward(amount, reg.debt, index).inspect_err(|_| trace("claim:calculate_reward"))?;
        // debt += reward * PRECISION (pool.move:330). Computed before any
        // mutation (see `deposit`'s comment on atomicity): if any checked op
        // below fails, `reg` and `self.balance` stay untouched.
        let new_debt = U256::from(reward)
            .checked_mul(U256::from(P))
            .and_then(|add| reg.debt.checked_add(add))
            .ok_or_else(|| { trace("claim:debt_overflow"); Abort::Arithmetic })?;
        let new_paid = reg
            .paid
            .checked_add(reward as u128)
            .ok_or_else(|| { trace("claim:paid_ghost_overflow"); Abort::Arithmetic })?;
        // balance.split(reward) (pool.move:338): aborts if balance < reward.
        // Guaranteed not to by I-B1 (solvency); checked anyway per the rules.
        let new_balance = self.balance.checked_sub(reward).ok_or_else(|| { trace("claim:INSOLVENT"); Abort::Arithmetic })?;

        reg.debt = new_debt;
        reg.paid = new_paid;
        reg.claims_since_registration += 1;
        self.balance = new_balance;
        Ok(reward)
    }

    /// `pending_rewards` (`pool.move:345-365`). Returns `0` instead of
    /// aborting when unregistered or registered with a different pool.
    pub fn pending(&self, stake: &Stake) -> Result<u64, Abort> {
        let Some(reg) = stake.registration(self.currency) else {
            return Ok(0); // pool.move:351-353
        };
        if reg.pool_id != self.id {
            return Ok(0); // pool.move:356-358
        }
        calculate_reward(stake.amount, reg.debt, self.index)
    }
}

/// `calculate_reward` (`pool.move:416-418`):
/// `⌊(amount·index − debt) / PRECISION⌋ as u64`.
pub fn calculate_reward(amount: u64, debt: U256, index: U256) -> Result<u64, Abort> {
    // amount * index < 2^256 (I-B7).
    let scaled = U256::from(amount).checked_mul(index).ok_or(Abort::Arithmetic)?;
    // debt <= amount * index always (I-B3); checked anyway.
    let raw = scaled.checked_sub(debt).ok_or(Abort::Arithmetic)?;
    let reward = raw / U256::from(P);
    u64::try_from(reward).map_err(|_| Abort::Arithmetic) // pool.move:417 "as u64"
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::stake::Stake;

    fn pool() -> Pool {
        Pool::new(0, 0)
    }

    #[test]
    fn deposit_aborts_with_no_stakers() {
        let mut p = pool();
        assert_eq!(
            p.deposit(10).unwrap_err(),
            Abort::Pool(PoolAbort::NoStakedShares)
        );
    }

    #[test]
    fn settle_is_total_with_no_stakers_or_nothing_parked() {
        // No stakers, nothing parked: still a no-op returning 0.
        let mut p = pool();
        assert_eq!(p.settle().unwrap(), 0);
        assert_eq!(p.balance, 0);

        // Stakers, but nothing parked: also a no-op.
        let mut s = Stake::new(0, 100).unwrap();
        p.register(&mut s).unwrap();
        assert_eq!(p.settle().unwrap(), 0);
        assert_eq!(p.balance, 0);

        // Parked, but no stakers: returns 0 and leaves the parked value in
        // place (pins the guard order -- stakers checked before any
        // redemption) rather than draining it into an unattributable
        // deposit.
        let mut p2 = pool();
        p2.parked_at_address = 42;
        assert_eq!(p2.settle().unwrap(), 0);
        assert_eq!(p2.balance, 0);
        assert_eq!(p2.parked_at_address, 42);

        // Parked and staked: redeemed and folded in, returning the value.
        p.parked_at_address = 42;
        assert_eq!(p.settle().unwrap(), 42);
        assert_eq!(p.balance, 42);
        assert_eq!(p.parked_at_address, 0);
    }

    #[test]
    fn deposit_aborts_on_zero_value() {
        let mut p = pool();
        let mut s = Stake::new(0, 100).unwrap();
        p.register(&mut s).unwrap();
        assert_eq!(p.deposit(0).unwrap_err(), Abort::Pool(PoolAbort::InvalidValue));
    }

    #[test]
    fn single_staker_gets_full_deposit() {
        let mut p = pool();
        let mut s = Stake::new(0, 100).unwrap();
        p.register(&mut s).unwrap();
        p.deposit(1_000).unwrap();
        assert_eq!(p.pending(&s).unwrap(), 1_000);
        let reward = p.claim(&mut s).unwrap();
        assert_eq!(reward, 1_000);
        assert_eq!(p.balance, 0);
    }

    #[test]
    fn carry_accumulates_and_folds() {
        // From royalty_pool_accounting_tests.move's
        // carry_folds_when_staked_exceeds_precision: staked_shares = u64::MAX,
        // 19 deposits of 1 unit each. Index stays 0 for 18 deposits, then
        // becomes 1 (19e18 > u64::MAX) with pending == 18.
        let mut p = pool();
        let mut s = Stake::new(0, u64::MAX).unwrap();
        p.register(&mut s).unwrap();
        for _ in 0..18 {
            p.deposit(1).unwrap();
            assert_eq!(p.index, U256::zero());
        }
        p.deposit(1).unwrap();
        assert_eq!(p.index, U256::from(1u64));
        assert_eq!(p.pending(&s).unwrap(), 18);
        let reward = p.claim(&mut s).unwrap();
        assert_eq!(reward, 18);
    }

    #[test]
    fn late_small_registrant_gets_exact_floor() {
        // From royalty_pool_accounting_tests.move's
        // late_small_registrant_gets_exact_floor.
        let mut p = pool();
        let mut b = Stake::new(0, 10).unwrap();
        p.register(&mut b).unwrap();
        p.deposit(1).unwrap(); // index = 1e17
        let mut a = Stake::new(1, 1).unwrap();
        p.register(&mut a).unwrap(); // owed 0 so far
        p.deposit(20).unwrap(); // S = 11 -> a owed 1.818...
        assert_eq!(p.pending(&a).unwrap(), 1);
        assert_eq!(p.pending(&b).unwrap(), 19);
        let ra = p.claim(&mut a).unwrap();
        let rb = p.claim(&mut b).unwrap();
        assert_eq!(ra, 1);
        assert_eq!(rb, 19);
        assert_eq!(p.balance, 1);
    }

    #[test]
    fn unregister_requires_zero_pending() {
        let mut p = pool();
        let mut s = Stake::new(0, 100).unwrap();
        p.register(&mut s).unwrap();
        p.deposit(1_000).unwrap();
        assert_eq!(
            p.unregister(&mut s).unwrap_err(),
            Abort::Pool(PoolAbort::LastClaimIndexMismatch)
        );
        p.claim(&mut s).unwrap();
        p.unregister(&mut s).unwrap();
    }

    #[test]
    fn pool_id_mismatch_on_claim_from_wrong_pool() {
        let mut p1 = Pool::new(0, 0);
        let p2 = Pool::new(1, 0);
        let mut s = Stake::new(0, 100).unwrap();
        p1.register(&mut s).unwrap();
        assert_eq!(
            p2.pending(&s).unwrap(),
            0 // pending returns 0, doesn't abort
        );
    }
}
