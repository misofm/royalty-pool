//! `World`: a small in-memory chain state addressed by integer ids (SPEC
//! §1.5). Holds pools, stakes, routed stakes, and releases; `apply` performs
//! exactly one op and returns its observable `Outcome` (or the `Abort` Move
//! would raise).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::abort::Abort;
use super::distributor::{self, Distribution};
use super::pool::Pool;
use super::routed::{RoutedStake, Swept};
use super::stake::{Currency, PoolId, Stake, StakeId};

pub type RoutedId = u64;
pub type ReleaseId = u64;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Release {
    pub id: ReleaseId,
    pub splits: Vec<u64>,
    /// Address balance available to redeem (out of scope §7: settlement
    /// timing modeled as immediate — `release_fund` credits this directly).
    pub balance: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct World {
    pub pools: BTreeMap<PoolId, Pool>,
    pub stakes: BTreeMap<StakeId, Stake>,
    pub routed: BTreeMap<RoutedId, RoutedStake>,
    pub releases: BTreeMap<ReleaseId, Release>,
}

/// One scenario operation. Field names mirror `scenario.rs`'s JSON op set
/// (TASKS-SONNET §2). `parent_override` on routed ops lets a scenario drive
/// the `NotDerivedFromParent` negative case (SPEC §3, out of scope §7 note).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Op {
    Register { pool: PoolId, stake: StakeId },
    Unregister { pool: PoolId, stake: StakeId },
    Deposit { pool: PoolId, value: u64 },
    Settle { pool: PoolId },
    Claim { pool: PoolId, stake: StakeId },
    Pending { pool: PoolId, stake: StakeId },
    NewStake { stake: StakeId, amount: u64 },
    DestroyStake { stake: StakeId },
    RoutedNew { routed: RoutedId, parent: u64, amount: u64, routed_pool: PoolId },
    RoutedRegister { routed: RoutedId, stake_pool: PoolId, parent_override: Option<u64> },
    RoutedUnregister { routed: RoutedId, stake_pool: PoolId, parent_override: Option<u64> },
    RoutedUnstake { routed: RoutedId, parent_override: Option<u64> },
    RoutedRestake { routed: RoutedId, amount: u64, parent_override: Option<u64> },
    RoutedSweep { routed: RoutedId, stake_pool: PoolId },
    ReleaseNew { release: ReleaseId, splits: Vec<u64> },
    ReleaseFund { release: ReleaseId, value: u64 },
    ReleaseDistribute { release: ReleaseId },
}

/// Observable result of one op, used both for `expect` comparisons and for
/// the A1/A2/C1 op-scoped invariant checks in `invariants.rs`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Outcome {
    Unit,
    Reward(u64),
    Pending(u64),
    Amount(u64),
    Distribution(Option<Distribution>),
    Swept(Swept),
}

/// Errors that stop `apply` before it could even look up the referenced
/// object — a malformed scenario, not a Move abort.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorldError {
    UnknownPool(PoolId),
    UnknownStake(StakeId),
    UnknownRouted(RoutedId),
    UnknownRelease(ReleaseId),
    DuplicateId(&'static str, u64),
}

impl std::fmt::Display for WorldError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for WorldError {}

/// Either a scenario-structure error or a genuine Move abort.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApplyError {
    World(WorldError),
    Abort(Abort),
}

impl From<WorldError> for ApplyError {
    fn from(e: WorldError) -> Self {
        ApplyError::World(e)
    }
}
impl From<Abort> for ApplyError {
    fn from(e: Abort) -> Self {
        ApplyError::Abort(e)
    }
}

impl std::fmt::Display for ApplyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ApplyError {}

impl World {
    pub fn new() -> Self {
        World::default()
    }

    pub fn add_pool(&mut self, id: PoolId, currency: Currency) -> Result<(), WorldError> {
        if self.pools.contains_key(&id) {
            return Err(WorldError::DuplicateId("pool", id));
        }
        self.pools.insert(id, Pool::new(id, currency));
        Ok(())
    }

    pub fn add_stake(&mut self, id: StakeId, amount: u64) -> Result<(), ApplyError> {
        if self.stakes.contains_key(&id) {
            return Err(WorldError::DuplicateId("stake", id).into());
        }
        let stake = Stake::new(id, amount)?;
        self.stakes.insert(id, stake);
        Ok(())
    }

    fn pool_mut(&mut self, id: PoolId) -> Result<&mut Pool, WorldError> {
        self.pools.get_mut(&id).ok_or(WorldError::UnknownPool(id))
    }
    fn pool(&self, id: PoolId) -> Result<&Pool, WorldError> {
        self.pools.get(&id).ok_or(WorldError::UnknownPool(id))
    }
    fn stake_mut(&mut self, id: StakeId) -> Result<&mut Stake, WorldError> {
        self.stakes.get_mut(&id).ok_or(WorldError::UnknownStake(id))
    }
    fn routed_mut(&mut self, id: RoutedId) -> Result<&mut RoutedStake, WorldError> {
        self.routed.get_mut(&id).ok_or(WorldError::UnknownRouted(id))
    }
    fn release_mut(&mut self, id: ReleaseId) -> Result<&mut Release, WorldError> {
        self.releases.get_mut(&id).ok_or(WorldError::UnknownRelease(id))
    }

    /// Apply exactly one op, atomically: on any error the world is restored
    /// to its pre-op state, matching Move's whole-transaction rollback on
    /// abort. Individual op implementations additionally order their own
    /// fallible arithmetic before their mutations (see e.g. `Pool::deposit`)
    /// as documented practice, but this snapshot/restore is the actual
    /// correctness guarantee — it is what makes multi-object ops like
    /// `RoutedSweep` (claim from one pool, deposit into another) atomic too.
    pub fn apply(&mut self, op: &Op) -> Result<Outcome, ApplyError> {
        let snapshot = self.clone();
        let result = self.apply_inner(op);
        if result.is_err() {
            *self = snapshot;
        }
        result
    }

    /// Two-pool-argument ops (e.g. `register`) borrow disjoint entries via a
    /// temporary removal-and-reinsert to keep the borrow checker happy
    /// without `unsafe` or `RefCell`.
    fn apply_inner(&mut self, op: &Op) -> Result<Outcome, ApplyError> {
        match op {
            Op::Register { pool, stake } => {
                let mut p = self.pools.remove(pool).ok_or(WorldError::UnknownPool(*pool))?;
                let result = (|| -> Result<(), ApplyError> {
                    let s = self.stake_mut(*stake)?;
                    p.register(s)?;
                    Ok(())
                })();
                self.pools.insert(*pool, p);
                result.map(|_| Outcome::Unit)
            }
            Op::Unregister { pool, stake } => {
                let mut p = self.pools.remove(pool).ok_or(WorldError::UnknownPool(*pool))?;
                let result = (|| -> Result<(), ApplyError> {
                    let s = self.stake_mut(*stake)?;
                    p.unregister(s)?;
                    Ok(())
                })();
                self.pools.insert(*pool, p);
                result.map(|_| Outcome::Unit)
            }
            Op::Deposit { pool, value } => {
                self.pool_mut(*pool)?.deposit(*value)?;
                Ok(Outcome::Unit)
            }
            Op::Settle { pool } => {
                let value = self.pool_mut(*pool)?.settle()?;
                Ok(Outcome::Amount(value))
            }
            Op::Claim { pool, stake } => {
                let mut p = self.pools.remove(pool).ok_or(WorldError::UnknownPool(*pool))?;
                let result = (|| -> Result<u64, ApplyError> {
                    let s = self.stake_mut(*stake)?;
                    Ok(p.claim(s)?)
                })();
                self.pools.insert(*pool, p);
                result.map(Outcome::Reward)
            }
            Op::Pending { pool, stake } => {
                let p = self.pool(*pool)?;
                let s = self.stakes.get(stake).ok_or(WorldError::UnknownStake(*stake))?;
                Ok(Outcome::Pending(p.pending(s)?))
            }
            Op::NewStake { stake, amount } => {
                self.add_stake(*stake, *amount)?;
                Ok(Outcome::Unit)
            }
            Op::DestroyStake { stake } => {
                // Peek before removing: Move rolls back the whole tx on
                // abort, so a failing `destroy` must leave the stake in
                // place (stake.move:93-106, `EPoolsRegistered`).
                let s = self.stakes.get(stake).ok_or(WorldError::UnknownStake(*stake))?;
                if !s.registrations.is_empty() {
                    return Err(Abort::Stake(super::abort::StakeAbort::PoolsRegistered).into());
                }
                let s = self.stakes.remove(stake).unwrap();
                let amount = s.destroy().expect("emptiness checked above");
                Ok(Outcome::Amount(amount))
            }
            Op::RoutedNew { routed, parent, amount, routed_pool } => {
                if self.routed.contains_key(routed) {
                    return Err(WorldError::DuplicateId("routed", *routed).into());
                }
                let stake = Stake::new(routed * ROUTED_STAKE_ID_BASE, *amount)?;
                self.routed.insert(*routed, RoutedStake::new(*routed, *parent, *routed_pool, stake));
                Ok(Outcome::Unit)
            }
            Op::RoutedRegister { routed, stake_pool, parent_override } => {
                let mut r = self.routed.remove(routed).ok_or(WorldError::UnknownRouted(*routed))?;
                let parent = parent_override.unwrap_or(r.parent);
                let result = (|| -> Result<(), ApplyError> {
                    let p = self.pool_mut(*stake_pool)?;
                    r.register(parent, p)?;
                    Ok(())
                })();
                self.routed.insert(*routed, r);
                result.map(|_| Outcome::Unit)
            }
            Op::RoutedUnregister { routed, stake_pool, parent_override } => {
                let mut r = self.routed.remove(routed).ok_or(WorldError::UnknownRouted(*routed))?;
                let parent = parent_override.unwrap_or(r.parent);
                let result = (|| -> Result<(), ApplyError> {
                    let p = self.pool_mut(*stake_pool)?;
                    r.unregister(parent, p)?;
                    Ok(())
                })();
                self.routed.insert(*routed, r);
                result.map(|_| Outcome::Unit)
            }
            Op::RoutedUnstake { routed, parent_override } => {
                let r = self.routed_mut(*routed)?;
                let parent = parent_override.unwrap_or(r.parent);
                Ok(Outcome::Amount(r.unstake(parent)?))
            }
            Op::RoutedRestake { routed, amount, parent_override } => {
                let r = self.routed_mut(*routed)?;
                let parent = parent_override.unwrap_or(r.parent);
                r.restake(parent, *amount)?;
                Ok(Outcome::Unit)
            }
            Op::RoutedSweep { routed, stake_pool } => {
                let mut r = self.routed.remove(routed).ok_or(WorldError::UnknownRouted(*routed))?;
                let routed_pool_id = r.routed_pool;
                let result = (|| -> Result<Swept, ApplyError> {
                    let mut sp = self.pools.remove(stake_pool).ok_or(WorldError::UnknownPool(*stake_pool))?;
                    let rp_result = (|| -> Result<Swept, ApplyError> {
                        let rp = self.pool_mut(routed_pool_id)?;
                        Ok(r.sweep(&mut sp, rp)?)
                    })();
                    self.pools.insert(*stake_pool, sp);
                    rp_result
                })();
                self.routed.insert(*routed, r);
                result.map(Outcome::Swept)
            }
            Op::ReleaseNew { release, splits } => {
                if self.releases.contains_key(release) {
                    return Err(WorldError::DuplicateId("release", *release).into());
                }
                distributor::validate_splits_sum(splits)?;
                self.releases.insert(*release, Release { id: *release, splits: splits.clone(), balance: 0 });
                Ok(Outcome::Unit)
            }
            Op::ReleaseFund { release, value } => {
                let r = self.release_mut(*release)?;
                r.balance = r.balance.checked_add(*value).ok_or(Abort::Arithmetic)?;
                Ok(Outcome::Unit)
            }
            Op::ReleaseDistribute { release } => {
                let r = self.release_mut(*release)?;
                let dist = distributor::redeem_all_and_distribute(&mut r.balance, &r.splits)?;
                Ok(Outcome::Distribution(dist))
            }
        }
    }
}

const ROUTED_STAKE_ID_BASE: u64 = 1_000_000_000;
