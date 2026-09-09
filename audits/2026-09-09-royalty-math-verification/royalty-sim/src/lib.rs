//! `royalty-sim`: a bit-exact Rust model of the misofm royalty distribution
//! math, plus a differential oracle against the real Move packages.
//!
//! See `SPEC.md` (repo root) for the model this crate implements, and
//! `TASKS-SONNET.md` for the crate layout this file follows.

pub mod fuzz;
pub mod model;
pub mod movegen;
pub mod scenario;
