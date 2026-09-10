//! JSON scenario language (TASKS-SONNET §2) and the runner used by both the
//! `run` CLI command and `diff`/`fuzz`'s model-side execution.

use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::model::invariants::{self, Tracker, Violation};
use crate::model::world::{Op, Outcome, World};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScenarioFile {
    pub name: String,
    #[serde(default)]
    pub setup: Setup,
    pub ops: Vec<RawOp>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Setup {
    #[serde(default)]
    pub pools: Vec<PoolSetup>,
    #[serde(default)]
    pub stakes: Vec<StakeSetup>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PoolSetup {
    pub id: u64,
    #[serde(default)]
    pub currency: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StakeSetup {
    pub id: u64,
    pub amount: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Expect {
    pub reward: Option<u64>,
    pub abort: Option<u64>,
    pub amounts: Option<Vec<u64>>,
    pub remainder: Option<u64>,
}

/// One JSON op object. All op-specific parameters are optional fields on a
/// single struct (rather than a tagged enum) so a scenario file stays close
/// to the example in TASKS-SONNET §2 without fighting serde's flatten/tag
/// interaction; `to_op` validates the fields required by `op`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RawOp {
    pub op: String,
    #[serde(default)]
    pub pool: Option<u64>,
    #[serde(default)]
    pub stake: Option<u64>,
    #[serde(default)]
    pub value: Option<u64>,
    #[serde(default)]
    pub amount: Option<u64>,
    #[serde(default)]
    pub routed: Option<u64>,
    #[serde(default)]
    pub parent: Option<u64>,
    #[serde(default)]
    pub routed_pool: Option<u64>,
    #[serde(default)]
    pub stake_pool: Option<u64>,
    #[serde(default)]
    pub release: Option<u64>,
    #[serde(default)]
    pub splits: Option<Vec<u64>>,
    /// Drives the `NotDerivedFromParent` negative scenario on routed ops.
    #[serde(default)]
    pub wrong_parent: Option<bool>,
    #[serde(default)]
    pub expect: Option<Expect>,
}

impl RawOp {
    fn req_pool(&self) -> Result<u64> {
        self.pool.ok_or_else(|| anyhow!("op `{}` requires `pool`", self.op))
    }
    fn req_stake(&self) -> Result<u64> {
        self.stake.ok_or_else(|| anyhow!("op `{}` requires `stake`", self.op))
    }
    fn req_value(&self) -> Result<u64> {
        self.value.ok_or_else(|| anyhow!("op `{}` requires `value`", self.op))
    }
    fn req_amount(&self) -> Result<u64> {
        self.amount.ok_or_else(|| anyhow!("op `{}` requires `amount`", self.op))
    }
    fn req_routed(&self) -> Result<u64> {
        self.routed.ok_or_else(|| anyhow!("op `{}` requires `routed`", self.op))
    }
    fn req_release(&self) -> Result<u64> {
        self.release.ok_or_else(|| anyhow!("op `{}` requires `release`", self.op))
    }
    fn req_stake_pool(&self) -> Result<u64> {
        self.stake_pool.ok_or_else(|| anyhow!("op `{}` requires `stake_pool`", self.op))
    }

    /// A `parent_override` that is wrong-on-purpose when `wrong_parent` is
    /// set (SPEC out of scope §7: `assert_derived_from` is modeled as
    /// always-true except for this one negative scenario shape). The exact
    /// wrong value doesn't matter, only that it differs from the real
    /// parent; `u64::MAX` can never be a real parent id a scenario assigns.
    fn parent_override(&self) -> Option<u64> {
        if self.wrong_parent == Some(true) {
            Some(u64::MAX)
        } else {
            None
        }
    }

    pub fn to_op(&self) -> Result<Op> {
        Ok(match self.op.as_str() {
            "register" => Op::Register { pool: self.req_pool()?, stake: self.req_stake()? },
            "unregister" => Op::Unregister { pool: self.req_pool()?, stake: self.req_stake()? },
            "deposit" => Op::Deposit { pool: self.req_pool()?, value: self.req_value()? },
            "settle" => Op::Settle { pool: self.req_pool()? },
            "claim" => Op::Claim { pool: self.req_pool()?, stake: self.req_stake()? },
            "pending" => Op::Pending { pool: self.req_pool()?, stake: self.req_stake()? },
            "new_stake" => Op::NewStake { stake: self.req_stake()?, amount: self.req_amount()? },
            "destroy_stake" => Op::DestroyStake { stake: self.req_stake()? },
            "routed_new" => Op::RoutedNew {
                routed: self.req_routed()?,
                parent: self.parent.unwrap_or(0),
                amount: self.req_amount()?,
                routed_pool: self.routed_pool.ok_or_else(|| anyhow!("routed_new requires `routed_pool`"))?,
            },
            "routed_register" => Op::RoutedRegister {
                routed: self.req_routed()?,
                stake_pool: self.req_stake_pool()?,
                parent_override: self.parent_override(),
            },
            "routed_unregister" => Op::RoutedUnregister {
                routed: self.req_routed()?,
                stake_pool: self.req_stake_pool()?,
                parent_override: self.parent_override(),
            },
            "routed_unstake" => Op::RoutedUnstake {
                routed: self.req_routed()?,
                parent_override: self.parent_override(),
            },
            "routed_restake" => Op::RoutedRestake {
                routed: self.req_routed()?,
                amount: self.req_amount()?,
                parent_override: self.parent_override(),
            },
            "routed_sweep" => {
                Op::RoutedSweep { routed: self.req_routed()?, stake_pool: self.req_stake_pool()? }
            }
            "release_new" => Op::ReleaseNew {
                release: self.req_release()?,
                splits: self.splits.clone().ok_or_else(|| anyhow!("release_new requires `splits`"))?,
            },
            "release_fund" => Op::ReleaseFund { release: self.req_release()?, value: self.req_value()? },
            "release_distribute" => Op::ReleaseDistribute { release: self.req_release()? },
            other => bail!("unknown op `{other}`"),
        })
    }
}

pub fn load_scenario(path: &Path) -> Result<ScenarioFile> {
    let text = std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let file: ScenarioFile =
        serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;
    Ok(file)
}

pub fn build_world(setup: &Setup) -> Result<World> {
    let mut world = World::new();
    for p in &setup.pools {
        world.add_pool(p.id, p.currency).map_err(|e| anyhow!("{e}"))?;
    }
    for s in &setup.stakes {
        world.add_stake(s.id, s.amount).map_err(|e| anyhow!("{e:?}"))?;
    }
    Ok(world)
}

#[derive(Debug, Clone, Serialize)]
pub struct OpReport {
    pub index: usize,
    pub op: RawOp,
    /// `Ok` result as a human-readable tag ("unit", "reward=5", ...), or the
    /// abort's numeric code and location if the op aborted.
    pub result: String,
    pub expect_ok: bool,
    pub expect_message: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScenarioReport {
    pub name: String,
    pub passed: bool,
    pub ops: Vec<OpReport>,
    pub violations: Vec<String>,
    pub max_ic4_error: String,
}

fn outcome_tag(outcome: &Outcome) -> String {
    match outcome {
        Outcome::Unit => "unit".to_string(),
        Outcome::Reward(r) => format!("reward={r}"),
        Outcome::Pending(p) => format!("pending={p}"),
        Outcome::Amount(a) => format!("amount={a}"),
        Outcome::Distribution(Some(d)) => {
            format!("amounts={:?} remainder={}", d.amounts, d.remainder)
        }
        Outcome::Distribution(None) => "no-op (zero balance)".to_string(),
        Outcome::Swept(s) => format!("claimed={} deposited={} parked={}", s.claimed, s.deposited, s.parked),
    }
}

/// Check a completed op's outcome against its `expect` block, returning a
/// human-readable mismatch description on failure.
fn check_expect(expect: &Expect, outcome: &Outcome) -> Option<String> {
    if let Some(want) = expect.reward {
        // `reward` doubles as the expectation field for both `claim`
        // (`Outcome::Reward`) and `pending`/`routed_unstake`/`destroy_stake`
        // (`Outcome::Pending`/`Outcome::Amount`) -- all "the one u64 this op
        // is about" -- to keep the scenario JSON schema small.
        let got = match outcome {
            Outcome::Reward(r) => *r,
            Outcome::Pending(p) => *p,
            Outcome::Amount(a) => *a,
            _ => return Some(format!("expected reward={want}, op did not return a reward")),
        };
        if got != want {
            return Some(format!("expected reward={want}, got {got}"));
        }
    }
    if let Some(want) = &expect.amounts {
        match outcome {
            Outcome::Distribution(Some(d)) if &d.amounts == want => {}
            Outcome::Distribution(Some(d)) => {
                return Some(format!("expected amounts={want:?}, got {:?}", d.amounts))
            }
            _ => return Some("expected a distribution outcome".to_string()),
        }
    }
    if let Some(want) = expect.remainder {
        match outcome {
            Outcome::Distribution(Some(d)) if d.remainder == want => {}
            Outcome::Distribution(Some(d)) => {
                return Some(format!("expected remainder={want}, got {}", d.remainder))
            }
            _ => return Some("expected a distribution outcome".to_string()),
        }
    }
    None
}

/// Run every op in `file` against a fresh `World`, checking `expect` blocks
/// and every applicable SPEC invariant after each op. Stops at the first op
/// whose actual result (success or abort) doesn't match its `expect` (if
/// any); subsequent ops after a *correctly expected* abort are still
/// attempted only if the scenario lists them (Move would need a fresh
/// transaction/tx boundary after an abort, but nothing in our model
/// prevents continuing against the rolled-back state, which is exactly what
/// `World::apply`'s snapshot/restore leaves us with).
pub fn run_scenario(file: &ScenarioFile) -> Result<ScenarioReport> {
    let mut world = build_world(&file.setup)?;
    let mut tracker = Tracker::new();
    let mut reports = Vec::with_capacity(file.ops.len());
    let mut violations: Vec<String> = Vec::new();
    let mut passed = true;

    for (index, raw) in file.ops.iter().enumerate() {
        let op = raw.to_op().with_context(|| format!("op #{index} in scenario `{}`", file.name))?;
        let result = world.apply(&op);
        let (result_tag, expect_ok, expect_message) = match &result {
            Ok(outcome) => {
                let tag = outcome_tag(outcome);
                if let Some(want_abort) = raw.expect.as_ref().and_then(|e| e.abort) {
                    (tag, false, Some(format!("expected abort {want_abort}, op succeeded")))
                } else {
                    match raw.expect.as_ref().and_then(|e| check_expect(e, outcome)) {
                        Some(msg) => (tag, false, Some(msg)),
                        None => (tag, true, None),
                    }
                }
            }
            Err(e) => {
                let code = match e {
                    crate::model::world::ApplyError::Abort(a) => Some(a.code()),
                    crate::model::world::ApplyError::World(_) => None,
                };
                let tag = format!("abort {e:?}");
                match (raw.expect.as_ref().and_then(|ex| ex.abort), code) {
                    (Some(want), Some(got)) if want == got => (tag, true, None),
                    (Some(want), Some(got)) => {
                        (tag, false, Some(format!("expected abort {want}, got abort {got}")))
                    }
                    (Some(want), None) => {
                        (tag, false, Some(format!("expected abort {want}, got structural error {e}")))
                    }
                    (None, _) => (tag, false, Some(format!("unexpected error: {e}"))),
                }
            }
        };

        if !expect_ok {
            passed = false;
        }

        // Only check invariants after a successful, non-aborting op: an
        // aborted op leaves world state exactly as `World::apply`'s
        // snapshot/restore found it (matching Move's tx rollback), so the
        // invariants trivially still hold from the prior op.
        if let Ok(outcome) = &result {
            if let Err(v) = invariants::check_all(&world, &mut tracker, index, &op, outcome) {
                passed = false;
                violations.push(v.to_string());
            }
        }

        reports.push(OpReport {
            index,
            op: raw.clone(),
            result: result_tag,
            expect_ok,
            expect_message,
        });
    }

    Ok(ScenarioReport {
        name: file.name.clone(),
        passed,
        ops: reports,
        violations,
        max_ic4_error: tracker.max_ic4_error().to_string(),
    })
}

/// Convenience used by `invariants::Violation` display in reports/tests.
pub fn violation_to_string(v: &Violation) -> String {
    v.to_string()
}
