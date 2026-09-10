//! Mirrors `routed_stake::routed_stake` (`routed_stake.move`), SPEC §3.
//!
//! `assert_derived_from` (both here and in `pool.move`) is modeled as
//! always-true (out of scope §7: object derivation/ownership), except for
//! one explicit negative scenario driven by the `wrong_parent` flag on the
//! relevant ops (see `scenario.rs`).

use serde::{Deserialize, Serialize};

use super::abort::{Abort, RoutedAbort};
use super::pool::Pool;
use super::stake::{PoolId, Stake, StakeId};

pub type RoutedStakeId = u64;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoutedStake {
    pub id: RoutedStakeId,
    /// Ghost parent identity, used only by the `wrong_parent` negative
    /// scenario to make `assert_derived_from` fail on purpose.
    pub parent: u64,
    pub stake: Option<Stake>,
    pub routed_pool: PoolId,
    next_stake_id: StakeId,
}

/// Result of a `sweep` (`routed_stake.move:206-236`), for I-C1 conservation
/// checks (`claimed == deposited + parked`).
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct Swept {
    pub claimed: u64,
    pub deposited: u64,
    pub parked: u64,
}

impl RoutedStake {
    pub fn new(id: RoutedStakeId, parent: u64, routed_pool: PoolId, stake: Stake) -> Self {
        let next_stake_id = stake.id + 1;
        RoutedStake {
            id,
            parent,
            stake: Some(stake),
            routed_pool,
            next_stake_id,
        }
    }

    fn assert_derived(&self, parent: u64) -> Result<(), Abort> {
        if self.parent != parent {
            return Err(Abort::Routed(RoutedAbort::NotDerivedFromParent));
        }
        Ok(())
    }

    /// `register` (`routed_stake.move:125-133`).
    pub fn register(&mut self, parent: u64, stake_pool: &mut Pool) -> Result<(), Abort> {
        self.assert_derived(parent)?;
        let stake = self.stake.as_mut().ok_or(Abort::Routed(RoutedAbort::NoStake))?;
        stake_pool.register(stake)
    }

    /// `unregister` (`routed_stake.move:139-147`).
    pub fn unregister(&mut self, parent: u64, stake_pool: &mut Pool) -> Result<(), Abort> {
        self.assert_derived(parent)?;
        let stake = self.stake.as_mut().ok_or(Abort::Routed(RoutedAbort::NoStake))?;
        stake_pool.unregister(stake)
    }

    /// `unstake` (`routed_stake.move:154-169`). Returns the reclaimed
    /// principal.
    pub fn unstake(&mut self, parent: u64) -> Result<u64, Abort> {
        self.assert_derived(parent)?;
        if self.stake.is_none() {
            return Err(Abort::Routed(RoutedAbort::NoStake));
        }
        let stake = self.stake.take().unwrap();
        stake.destroy() // stake::destroy, stake.move:93-106
    }

    /// `restake` (`routed_stake.move:173-188`). Aborts `EStakeExists = 2` if
    /// a position is already present.
    pub fn restake(&mut self, parent: u64, amount: u64) -> Result<(), Abort> {
        self.assert_derived(parent)?;
        if self.stake.is_some() {
            return Err(Abort::Routed(RoutedAbort::StakeExists));
        }
        let id = self.next_stake_id;
        self.next_stake_id += 1;
        let stake = Stake::new(id, amount)?; // stake::new, stake.move:73-88
        self.stake = Some(stake);
        Ok(())
    }

    /// `sweep` (`routed_stake.move:206-236`).
    pub fn sweep(&mut self, stake_pool: &mut Pool, routed_pool: &mut Pool) -> Result<Swept, Abort> {
        let stake = self.stake.as_mut().ok_or(Abort::Routed(RoutedAbort::NoStake))?;
        let reward = stake_pool.claim(stake)?; // stake_pool.claim_rewards
        if reward == 0 {
            return Ok(Swept::default()); // reward.destroy_zero(); return (no event)
        }
        if routed_pool.staked_shares == 0 {
            // reward.send_funds(routed_pool address): parked, recoverable via
            // settle (SPEC §3.1, I-C3). Address-balance settlement timing is
            // out of scope §7 and modeled as immediate.
            routed_pool.parked_at_address = routed_pool
                .parked_at_address
                .checked_add(reward)
                .ok_or(Abort::Arithmetic)?;
            Ok(Swept {
                claimed: reward,
                deposited: 0,
                parked: reward,
            })
        } else {
            routed_pool.deposit(reward)?;
            Ok(Swept {
                claimed: reward,
                deposited: reward,
                parked: 0,
            })
        }
    }

    pub fn value(&self) -> u64 {
        self.stake.as_ref().map(|s| s.amount).unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::pool::Pool;

    #[test]
    fn sweep_with_zero_reward_is_a_no_op() {
        let mut stake_pool = Pool::new(0, 0);
        let mut routed_pool = Pool::new(1, 0);
        let s = Stake::new(0, 100).unwrap();
        let mut routed = RoutedStake::new(0, 0, 1, s);
        routed.register(0, &mut stake_pool).unwrap();
        let swept = routed.sweep(&mut stake_pool, &mut routed_pool).unwrap();
        assert_eq!(swept.claimed, 0);
        assert_eq!(swept.deposited, 0);
        assert_eq!(swept.parked, 0);
    }

    #[test]
    fn sweep_parks_when_child_has_no_stakers() {
        let mut stake_pool = Pool::new(0, 0);
        let mut routed_pool = Pool::new(1, 0);
        let s = Stake::new(0, 100).unwrap();
        let mut routed = RoutedStake::new(0, 0, 1, s);
        routed.register(0, &mut stake_pool).unwrap();
        stake_pool.deposit(500).unwrap();
        let swept = routed.sweep(&mut stake_pool, &mut routed_pool).unwrap();
        assert_eq!(swept.claimed, 500);
        assert_eq!(swept.parked, 500);
        assert_eq!(swept.deposited, 0);
        assert_eq!(routed_pool.balance, 0);
        assert_eq!(routed_pool.parked_at_address, 500);
    }

    #[test]
    fn settle_recovers_parked_funds() {
        let mut stake_pool = Pool::new(0, 0);
        let mut routed_pool = Pool::new(1, 0);
        let s = Stake::new(0, 100).unwrap();
        let mut routed = RoutedStake::new(0, 0, 1, s);
        routed.register(0, &mut stake_pool).unwrap();
        stake_pool.deposit(500).unwrap();
        routed.sweep(&mut stake_pool, &mut routed_pool).unwrap();

        let mut holder = Stake::new(1, 10).unwrap();
        routed_pool.register(&mut holder).unwrap();
        let settled = routed_pool.settle().unwrap();
        assert_eq!(settled, 500);
        assert_eq!(routed_pool.balance, 500);
        assert_eq!(routed_pool.pending(&holder).unwrap(), 500);
    }
}
