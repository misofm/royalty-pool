//! Abort codes mirroring the Move modules' error constants.
//!
//! Move abort codes are only unique *within a module*; the same numeric value
//! means different things in `pool`, `stake`, `routed_stake`, and `hikida`.
//! We keep them namespaced here so the model can't accidentally compare a
//! `stake::EPoolsRegistered = 1` against a `pool::ENoStakedShares = 1`, while
//! still exposing the bare numeric code for scenario `expect.abort` checks
//! and for matching `#[expected_failure(abort_code = N, location = ...)]` in
//! the generated Move tests.

use serde::{Deserialize, Serialize};

/// A single abort, tagged with the Move module that raises it so the
/// generated Move test can pick the right `location = <module>`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Abort {
    Pool(PoolAbort),
    Stake(StakeAbort),
    Routed(RoutedAbort),
    Hikida(HikidaAbort),
    Release(ReleaseAbort),
    /// A checked arithmetic op (`checked_add`/`checked_mul`/`checked_sub`/
    /// `try_from`) failed. Move has no named constant for this — an
    /// arithmetic error aborts the transaction with a VM-level "arithmetic
    /// error", not a module abort code. We use code `u64::MAX` as a sentinel
    /// so JSON scenarios can still assert on it if desired, but the
    /// differential harness never expects this in an `abort_code` position
    /// (Move would report a different location: `ARITHMETIC_ERROR`, not
    /// `abort_code`).
    Arithmetic,
}

impl Abort {
    /// The raw abort code as Move would report it (module-local).
    pub fn code(&self) -> u64 {
        match self {
            Abort::Pool(e) => *e as u64,
            Abort::Stake(e) => *e as u64,
            Abort::Routed(e) => *e as u64,
            Abort::Hikida(e) => *e as u64,
            Abort::Release(e) => *e as u64,
            Abort::Arithmetic => u64::MAX,
        }
    }

    /// The Move module name for `#[expected_failure(location = ...)]`.
    pub fn location(&self) -> &'static str {
        match self {
            Abort::Pool(_) => "royalty_pool::pool",
            Abort::Stake(_) => "royalty_pool::stake",
            Abort::Routed(_) => "routed_stake::routed_stake",
            Abort::Hikida(_) => "hikida::hikida",
            Abort::Release(_) => "musicos::release",
            Abort::Arithmetic => "ARITHMETIC_ERROR",
        }
    }
}

/// `royalty_pool::pool` — see `pool.move:84-91`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PoolAbort {
    NotDerivedFromParent = 0,
    NoStakedShares = 1,
    AlreadyRegistered = 2,
    NotRegistered = 3,
    PoolIdMismatch = 4,
    LastClaimIndexMismatch = 5,
    InvalidValue = 6,
    NoSettledFunds = 7,
}

/// `royalty_pool::stake` — see `stake.move:30-31`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum StakeAbort {
    ZeroBalance = 0,
    PoolsRegistered = 1,
}

/// `routed_stake::routed_stake` — see `routed_stake.move:42-44`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RoutedAbort {
    NotDerivedFromParent = 0,
    NoStake = 1,
    StakeExists = 2,
}

/// `hikida::hikida` — see `hikida.move:9-10`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HikidaAbort {
    NoCoinsToReceive = 0,
    NoValueToRedeem = 1,
}

/// `musicos::release` — only the one construction-time check we model
/// (`release.move:98,233`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReleaseAbort {
    InvalidTrackSplitsSum = 20,
}
