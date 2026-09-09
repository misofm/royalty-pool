//! Mirrors `royalty_pool::stake` (`stake.move`).
//!
//! A `Stake` holds an immutable `amount` and a small map of registrations,
//! one per `Currency`. Real registrations are keyed by `TypeName`
//! (`stake.move:39-41`); we key by a small `Currency` id instead (SPEC
//! §2.3) since the simulator never needs real Move type names, only
//! distinctness.

use std::collections::BTreeMap;

use num_rational::BigRational;
use primitive_types::U256;
use serde::{Deserialize, Serialize};

use super::abort::{Abort, StakeAbort};

pub type PoolId = u64;
pub type StakeId = u64;
/// Stand-in for `TypeName` (SPEC §2.3): pools of the same `Currency` collide
/// on a stake's registration slot.
pub type Currency = u32;

/// Per-stake registration record (`stake.move:46-54`), extended with
/// simulator-only ghost fields used by the invariant checks in
/// `invariants.rs` (I-B6 fairness, I-C4 exact-oracle bound). The ghosts are
/// never read by any function that determines a real (on-chain-observable)
/// outcome — only by `invariants.rs`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Registration {
    pub pool_id: PoolId,
    /// `debt` in `shares · index` units, full precision (`stake.move:48-53`).
    pub debt: U256,

    // --- ghosts (not on chain) ---
    /// `index` at the moment this registration was created, used to state
    /// I-B6 (`paid + pending == floor(amount * (index - idx_at_reg) / P)`).
    #[serde(skip, default)]
    pub idx_at_registration: U256,
    /// Cumulative reward this registration has claimed while live. `u128`,
    /// not `u64`: this is a ghost with no on-chain counterpart, and a
    /// registration's lifetime payout is bounded by the pool's `u128`
    /// `cumulative_deposits`, not by `u64`. (It was `u64` originally, which
    /// made the model abort `Arithmetic` on a `claim` that Move executes
    /// happily -- see REPORT.md finding F3.)
    #[serde(skip, default)]
    pub paid: u128,
    /// Exact rational index (no floors) at registration time, for I-C4.
    #[serde(skip, default = "zero_rational")]
    pub ideal_index_at_registration: BigRational,
    /// Number of `claim` calls made against this registration while live,
    /// used to bound the accumulated floor error in I-C4.
    #[serde(skip, default)]
    pub claims_since_registration: u64,
    /// `Pool::carry_drift` at registration time. See `Pool::carry_drift` and
    /// `invariants::check_c4_exact` for the identity this makes checkable.
    #[serde(skip, default = "zero_rational")]
    pub carry_drift_at_registration: BigRational,
}

fn zero_rational() -> BigRational {
    BigRational::from_integer(0.into())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Stake {
    pub id: StakeId,
    pub amount: u64,
    #[serde(skip)]
    pub registrations: BTreeMap<Currency, Registration>,
}

impl Stake {
    /// `stake::new` (`stake.move:73-88`). Aborts `EZeroBalance = 0` on a
    /// zero balance.
    pub fn new(id: StakeId, amount: u64) -> Result<Self, Abort> {
        if amount == 0 {
            return Err(Abort::Stake(StakeAbort::ZeroBalance));
        }
        Ok(Stake {
            id,
            amount,
            registrations: BTreeMap::new(),
        })
    }

    /// `stake::destroy` (`stake.move:93-106`). Aborts `EPoolsRegistered = 1`
    /// while any registration remains. Returns the reclaimed amount.
    pub fn destroy(self) -> Result<u64, Abort> {
        if !self.registrations.is_empty() {
            return Err(Abort::Stake(StakeAbort::PoolsRegistered));
        }
        Ok(self.amount)
    }

    pub fn has_registration(&self, currency: Currency) -> bool {
        self.registrations.contains_key(&currency)
    }

    pub fn registration(&self, currency: Currency) -> Option<&Registration> {
        self.registrations.get(&currency)
    }

    pub fn registration_mut(&mut self, currency: Currency) -> Option<&mut Registration> {
        self.registrations.get_mut(&currency)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_aborts_on_zero_amount() {
        assert_eq!(
            Stake::new(0, 0).unwrap_err(),
            Abort::Stake(StakeAbort::ZeroBalance)
        );
    }

    #[test]
    fn destroy_aborts_with_live_registration() {
        let mut s = Stake::new(0, 10).unwrap();
        s.registrations.insert(
            0,
            Registration {
                pool_id: 0,
                debt: U256::zero(),
                idx_at_registration: U256::zero(),
                paid: 0,
                ideal_index_at_registration: zero_rational(),
                claims_since_registration: 0,
                carry_drift_at_registration: zero_rational(),
            },
        );
        assert_eq!(
            s.destroy().unwrap_err(),
            Abort::Stake(StakeAbort::PoolsRegistered)
        );
    }

    #[test]
    fn destroy_returns_amount_when_empty() {
        let s = Stake::new(0, 42).unwrap();
        assert_eq!(s.destroy().unwrap(), 42);
    }
}
