//! The bit-exact Rust model of the misofm royalty distribution math (SPEC
//! §1-3). See `../../SPEC.md` for the source of truth and
//! `../../DISCREPANCIES.md` for the one place Move and SPEC disagreed.

pub mod abort;
pub mod distributor;
pub mod invariants;
pub mod pool;
pub mod routed;
pub mod stake;
pub mod world;

pub use abort::Abort;
pub use world::{Op, Outcome, World};
