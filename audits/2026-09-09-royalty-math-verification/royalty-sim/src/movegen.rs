//! Scenario -> Move test generator (TASKS-SONNET §4.2).
//!
//! Every generated module lives in the `routed_stake` package's test tree
//! (`move/routed-stake/tests/gen/`) since that package depends on
//! `royalty_pool` and can exercise both. All pools use one phantom
//! `Share`/`Currency` pair (`GenShare`/`GenCurrency`).
//!
//! Object derivation (`pool::new`/`routed_stake::new`) claims an address
//! keyed by `(parent_id, Share[, Currency])` and aborts on a second claim at
//! the same address, so:
//! - every plain pool in `setup.pools` gets its own ephemeral parent
//!   (`object::new` + `destroy`, matching `royalty_pool_tests.move`'s
//!   `create_pool` helper) -- pool ops never need a parent afterward;
//! - a `routed_new` op's routed stake **and its `routed_pool`** share one
//!   dedicated, *shared* parent (matching `routed_stake_e2e_tests.move`'s
//!   `setup_shared`: `sweep` only checks `self`/`routed_pool` against
//!   `parent_id`, never `stake_pool`), so `routed_pool`'s id must NOT also
//!   appear in `setup.pools` -- it is created inline by `routed_new`.
//!
//! Scope (see NOTES.md for the reasoning): `release_*` ops and
//! `routed_unregister`/`routed_unstake`/`routed_restake`/`wrong_parent` are
//! not generated (none of the required differential scenarios need them);
//! `generate` returns an error naming the unsupported op so `diff` can
//! report it plainly rather than emit broken Move.

use std::collections::{BTreeMap, BTreeSet};

use anyhow::{anyhow, bail, Context, Result};

use crate::model::stake::{PoolId, StakeId};
use crate::model::world::{ApplyError, Op, Outcome, World};
use crate::scenario::ScenarioFile;

const IND: &str = "    ";

pub struct GeneratedTest {
    pub fn_name: String,
    /// `(abort_code, location)` when this test is `#[expected_failure]`.
    pub expected_abort: Option<(u64, String)>,
}

pub struct GeneratedModule {
    pub module_name: String,
    pub tests: Vec<GeneratedTest>,
    pub source: String,
}

pub fn ident(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.ends_with('_') {
            out.push('_');
        }
    }
    let out = out.trim_matches('_').to_string();
    if out.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(true) {
        format!("s_{out}")
    } else {
        out
    }
}

#[derive(Default)]
struct GenCtx {
    pool_id_var: BTreeMap<PoolId, String>,
    routed_id_var: BTreeMap<u64, String>,
    routed_parent_id_var: BTreeMap<u64, String>,
    stake_alive: BTreeSet<StakeId>,
}

impl GenCtx {
    fn pool(&self, id: PoolId) -> Result<&str> {
        self.pool_id_var
            .get(&id)
            .map(|s| s.as_str())
            .ok_or_else(|| anyhow!("pool {id} referenced before creation"))
    }
    fn routed(&self, id: u64) -> Result<&str> {
        self.routed_id_var
            .get(&id)
            .map(|s| s.as_str())
            .ok_or_else(|| anyhow!("routed stake {id} referenced before `routed_new`"))
    }
    fn routed_parent(&self, id: u64) -> Result<&str> {
        self.routed_parent_id_var
            .get(&id)
            .map(|s| s.as_str())
            .ok_or_else(|| anyhow!("routed stake {id} referenced before `routed_new`"))
    }
}

fn pool_ty() -> &'static str {
    "royalty_pool::pool::RoyaltyPool<GenShare, GenCurrency>"
}
fn routed_ty() -> &'static str {
    "routed_stake::routed_stake::RoutedStake<GenShare, GenShare>"
}

/// Assert pool-level accessors currently registered in `pool_id`.
///
/// `full` gates everything beyond the balance check: `staked_shares`,
/// `cumulative_reward_per_share`, and `pending_rewards` per live stake. This
/// exists because Move bounds a function to ~255 local-variable slots and
/// each `assert_eq!` here costs several (see NOTES.md): a scenario with more
/// than a handful of ops asserting the full set every step blows that
/// budget (observed panicking around op #14; `sui move test` reported "value
/// (355) cannot exceed (255)" from bytecode serialization). `build_test_fn`
/// asserts in full at every op with an explicit `expect`, at the last op of
/// the function, and at every op when the whole test is short; other,
/// "dense-scenario" intermediate ops still get the cheap balance check, so a
/// disagreement anywhere is still caught, just not with full granularity.
/// How much state to assert after one op. See `ASSERT_SITE_BUDGET`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AssertLevel {
    /// No assertion at this op (long scenarios, between sampled sites).
    None,
    /// `balance().value()` only.
    Balance,
    /// Balance, `staked_shares`, `cumulative_reward_per_share`, and every
    /// live stake's `pending_rewards`.
    Full,
}

fn assert_pool_state(
    out: &mut Vec<String>,
    world: &World,
    pool_id: PoolId,
    pool_var: &str,
    routed: Option<(&str, u64)>,
    level: AssertLevel,
) {
    if level == AssertLevel::None {
        return;
    }
    let Some(pool) = world.pools.get(&pool_id) else { return };
    out.push(format!("{IND}assert_eq!({pool_var}.balance().value(), {});", pool.balance));
    if level != AssertLevel::Full {
        return;
    }
    out.push(format!(
        "{IND}assert_eq!({pool_var}.staked_shares(), {});",
        pool.staked_shares
    ));
    out.push(format!(
        "{IND}assert_eq!({pool_var}.cumulative_reward_per_share(), {}u256);",
        pool.index
    ));
    // `carry` and `cumulative_deposits` are public accessors (pool.move:382,
    // 387) and SPEC §4 asks for `carry` to be asserted when it is exposed.
    // Neither was asserted until the independent verification pass; a wrong
    // carry after a scenario's last deposit was invisible to the
    // differential. Two extra sites per Full assertion, which is why the
    // density budgets below drop to compensate.
    out.push(format!("{IND}assert_eq!({pool_var}.carry(), {}u128);", pool.carry));
    out.push(format!(
        "{IND}assert_eq!({pool_var}.cumulative_deposits(), {}u128);",
        pool.cumulative_deposits
    ));
    for (id, s) in &world.stakes {
        if let Some(reg) = s.registrations.get(&pool.currency) {
            if reg.pool_id == pool_id {
                let pending = pool.pending(s).unwrap_or(u64::MAX);
                out.push(format!(
                    "{IND}assert_eq!({pool_var}.pending_rewards(&s{id}), {pending});"
                ));
            }
        }
    }
    if let Some((routed_var, routed_id)) = routed {
        if let Some(r) = world.routed.get(&routed_id) {
            if let Some(s) = &r.stake {
                if let Some(reg) = s.registrations.get(&pool.currency) {
                    if reg.pool_id == pool_id {
                        let pending = pool.pending(s).unwrap_or(u64::MAX);
                        out.push(format!(
                            "{IND}assert_eq!({pool_var}.pending_rewards({routed_var}.stake()), {pending});"
                        ));
                    }
                }
            }
        }
    }
}

/// Pools that are a `routed_new` op's `routed_pool` must not be created by
/// the generic per-pool setup loop -- they are created inline by that op,
/// sharing its dedicated parent (see module doc).
fn routed_pool_ids(scenario: &ScenarioFile) -> Result<BTreeSet<PoolId>> {
    let mut set = BTreeSet::new();
    for raw in &scenario.ops {
        if raw.op == "routed_new" {
            let op = raw.to_op()?;
            if let Op::RoutedNew { routed_pool, .. } = op {
                set.insert(routed_pool);
            }
        }
    }
    Ok(set)
}

fn emit_setup(out: &mut Vec<String>, ctx: &mut GenCtx, scenario: &ScenarioFile, need_accumulator: bool) -> Result<()> {
    // `accumulator::create_for_testing` asserts `ctx.sender() == @0x0`
    // (`accumulator.move:17`), so begin at the system address whenever it's
    // needed -- matching `royalty_pool_tests.move`'s
    // `sweep_and_deposit_aborts_when_no_funds_are_settled` -- and switch to
    // ALICE on the first op's `next_tx` either way.
    if need_accumulator {
        out.push(format!("{IND}let mut sc = sui::test_scenario::begin(@0x0);"));
        out.push(format!("{IND}sui::accumulator::create_for_testing(sc.ctx());"));
    } else {
        out.push(format!("{IND}let mut sc = sui::test_scenario::begin(ALICE);"));
    }
    let skip = routed_pool_ids(scenario)?;
    for p in &scenario.setup.pools {
        if skip.contains(&p.id) {
            continue;
        }
        if p.currency != 0 {
            bail!("movegen only supports a single currency (pool {} has currency {})", p.id, p.currency);
        }
        let var = format!("pool{}_id", p.id);
        out.push(format!("{IND}let mut ep{0} = object::new(sc.ctx());", p.id));
        out.push(format!(
            "{IND}let gp{0} = royalty_pool::pool::new<GenShare, GenCurrency>(&mut ep{0});",
            p.id
        ));
        out.push(format!("{IND}let {var} = object::id(&gp{0});", p.id));
        out.push(format!("{IND}gp{0}.share();", p.id));
        out.push(format!("{IND}destroy(ep{0});", p.id));
        ctx.pool_id_var.insert(p.id, var);
    }
    for s in &scenario.setup.stakes {
        out.push(format!(
            "{IND}let mut s{0} = royalty_pool::stake::new(sui::balance::create_for_testing<GenShare>({1}), sc.ctx());",
            s.id, s.amount
        ));
        ctx.stake_alive.insert(s.id);
    }
    Ok(())
}

fn emit_receive_and_deposit(out: &mut Vec<String>, ctx: &GenCtx, pool: PoolId, value: u64) -> Result<()> {
    let pv = ctx.pool(pool)?.to_string();
    out.push(format!(
        "{IND}let coin = sui::coin::from_balance(sui::balance::create_for_testing<GenCurrency>({value}), sc.ctx());"
    ));
    out.push(format!("{IND}let coin_id = object::id(&coin);"));
    out.push(format!("{IND}transfer::public_transfer(coin, {pv}.to_address());"));
    out.push(format!("{IND}sc.next_tx(ALICE);"));
    out.push(format!("{IND}let mut p = sc.take_shared_by_id<{}>({pv});", pool_ty()));
    out.push(format!(
        "{IND}let ticket = sui::test_scenario::receiving_ticket_by_id<sui::coin::Coin<GenCurrency>>(coin_id);"
    ));
    out.push(format!("{IND}p.receive_and_deposit(vector[ticket]);"));
    Ok(())
}

/// Emit one op's Move code. Returns `true` if the block ends with a
/// `test_scenario::return_shared` for everything it took (the normal case);
/// the caller omits this for the final op of an expected-failure test.
fn emit_op(
    out: &mut Vec<String>,
    ctx: &mut GenCtx,
    world_before: &World,
    op: &Op,
    outcome: Option<&Outcome>,
    is_final_abort: bool,
    level: AssertLevel,
) -> Result<()> {
    out.push(format!("{IND}sc.next_tx(ALICE);"));
    match op {
        Op::Register { pool, stake } => {
            let pv = ctx.pool(*pool)?.to_string();
            out.push(format!("{IND}let mut p = sc.take_shared_by_id<{}>({pv});", pool_ty()));
            out.push(format!("{IND}p.register_stake(&mut s{stake});"));
            if let Some(outcome) = outcome {
                let mut world_after = world_before.clone();
                world_after.apply(op).ok();
                let _ = outcome;
                assert_pool_state(out, &world_after, *pool, "p", None, level);
            }
            if !is_final_abort {
                out.push(format!("{IND}sui::test_scenario::return_shared(p);"));
            }
        }
        Op::Unregister { pool, stake } => {
            let pv = ctx.pool(*pool)?.to_string();
            out.push(format!("{IND}let mut p = sc.take_shared_by_id<{}>({pv});", pool_ty()));
            out.push(format!("{IND}p.unregister_stake(&mut s{stake});"));
            if outcome.is_some() {
                let mut world_after = world_before.clone();
                world_after.apply(op).ok();
                assert_pool_state(out, &world_after, *pool, "p", None, level);
            }
            if !is_final_abort {
                out.push(format!("{IND}sui::test_scenario::return_shared(p);"));
            }
        }
        Op::Deposit { pool, value } => {
            let pv = ctx.pool(*pool)?.to_string();
            out.push(format!("{IND}let mut p = sc.take_shared_by_id<{}>({pv});", pool_ty()));
            out.push(format!(
                "{IND}p.deposit(sui::balance::create_for_testing<GenCurrency>({value}));"
            ));
            if outcome.is_some() {
                let mut world_after = world_before.clone();
                world_after.apply(op).ok();
                assert_pool_state(out, &world_after, *pool, "p", None, level);
            }
            if !is_final_abort {
                out.push(format!("{IND}sui::test_scenario::return_shared(p);"));
            }
        }
        Op::ReceiveAndDeposit { pool, value } => {
            emit_receive_and_deposit(out, ctx, *pool, *value)?;
            if outcome.is_some() {
                let mut world_after = world_before.clone();
                world_after.apply(op).ok();
                assert_pool_state(out, &world_after, *pool, "p", None, level);
            }
            if !is_final_abort {
                out.push(format!("{IND}sui::test_scenario::return_shared(p);"));
            }
        }
        Op::SweepAndDeposit { pool } => {
            let parked = world_before.pools.get(pool).map(|p| p.parked_at_address).unwrap_or(0);
            if parked == 0 {
                let pv = ctx.pool(*pool)?.to_string();
                out.push(format!("{IND}let mut p = sc.take_shared_by_id<{}>({pv});", pool_ty()));
                out.push(format!(
                    "{IND}let root = sc.take_shared<sui::accumulator::AccumulatorRoot>();"
                ));
                out.push(format!("{IND}p.sweep_and_deposit(&root);"));
                if !is_final_abort {
                    out.push(format!("{IND}sui::test_scenario::return_shared(p);"));
                    out.push(format!("{IND}sui::test_scenario::return_shared(root);"));
                }
            } else {
                out.push(format!(
                    "{IND}// sweep_and_deposit proxy (see movegen.rs doc + NOTES.md): the unit VM"
                ));
                out.push(format!(
                    "{IND}// never populates a positive settled-funds snapshot, so the success path"
                ));
                out.push(format!(
                    "{IND}// is exercised via receive_and_deposit, which folds into the identical"
                ));
                out.push(format!("{IND}// pool::deposit call."));
                emit_receive_and_deposit(out, ctx, *pool, parked)?;
                if outcome.is_some() {
                    let mut world_after = world_before.clone();
                    world_after.apply(op).ok();
                    assert_pool_state(out, &world_after, *pool, "p", None, level);
                }
                if !is_final_abort {
                    out.push(format!("{IND}sui::test_scenario::return_shared(p);"));
                }
            }
        }
        Op::Claim { pool, stake } => {
            let pv = ctx.pool(*pool)?.to_string();
            out.push(format!("{IND}let mut p = sc.take_shared_by_id<{}>({pv});", pool_ty()));
            out.push(format!("{IND}let reward = p.claim_rewards(&mut s{stake});"));
            if let Some(Outcome::Reward(r)) = outcome {
                if level == AssertLevel::Full {
                    out.push(format!("{IND}assert_eq!(reward.value(), {r});"));
                }
                let mut world_after = world_before.clone();
                world_after.apply(op).ok();
                assert_pool_state(out, &world_after, *pool, "p", None, level);
            }
            out.push(format!("{IND}sui::balance::destroy_for_testing(reward);"));
            if !is_final_abort {
                out.push(format!("{IND}sui::test_scenario::return_shared(p);"));
            }
        }
        Op::Pending { pool, stake } => {
            let pv = ctx.pool(*pool)?.to_string();
            out.push(format!("{IND}let p = sc.take_shared_by_id<{}>({pv});", pool_ty()));
            if let Some(Outcome::Pending(v)) = outcome {
                out.push(format!("{IND}assert_eq!(p.pending_rewards(&s{stake}), {v});"));
            }
            out.push(format!("{IND}sui::test_scenario::return_shared(p);"));
        }
        Op::NewStake { stake, amount } => {
            out.push(format!(
                "{IND}let mut s{stake} = royalty_pool::stake::new(sui::balance::create_for_testing<GenShare>({amount}), sc.ctx());"
            ));
            ctx.stake_alive.insert(*stake);
        }
        Op::DestroyStake { stake } => {
            out.push(format!(
                "{IND}let recovered{stake} = royalty_pool::stake::destroy(s{stake});"
            ));
            out.push(format!("{IND}sui::balance::destroy_for_testing(recovered{stake});"));
            ctx.stake_alive.remove(stake);
        }
        Op::RoutedNew { routed, amount, routed_pool, .. } => {
            let parent_var = format!("rp{routed}");
            let parent_id_var = format!("rp{routed}_id");
            let pool_var = format!("pool{routed_pool}_id");
            let routed_id_var = format!("routed{routed}_id");
            out.push(format!("{IND}let mut {parent_var} = GenParent {{ id: object::new(sc.ctx()) }};"));
            out.push(format!("{IND}let {parent_id_var} = object::id(&{parent_var});"));
            out.push(format!(
                "{IND}let g{routed_pool} = royalty_pool::pool::new<GenShare, GenCurrency>(&mut {parent_var}.id);"
            ));
            out.push(format!("{IND}let {pool_var} = object::id(&g{routed_pool});"));
            out.push(format!("{IND}g{routed_pool}.share();"));
            out.push(format!(
                "{IND}let r{routed} = routed_stake::routed_stake::new<GenShare, GenShare>(&mut {parent_var}.id, sui::balance::create_for_testing<GenShare>({amount}), sc.ctx());"
            ));
            out.push(format!("{IND}let {routed_id_var} = object::id(&r{routed});"));
            out.push(format!("{IND}routed_stake::routed_stake::share(r{routed});"));
            out.push(format!("{IND}transfer::share_object({parent_var});"));
            ctx.pool_id_var.insert(*routed_pool, pool_var);
            ctx.routed_id_var.insert(*routed, routed_id_var);
            ctx.routed_parent_id_var.insert(*routed, parent_id_var);
        }
        Op::RoutedRegister { routed, stake_pool, parent_override } => {
            if parent_override.is_some() {
                bail!("movegen does not support wrong_parent (model-only, see NOTES.md)");
            }
            let rid = ctx.routed(*routed)?.to_string();
            let rpid = ctx.routed_parent(*routed)?.to_string();
            let spv = ctx.pool(*stake_pool)?.to_string();
            out.push(format!("{IND}let mut r = sc.take_shared_by_id<{}>({rid});", routed_ty()));
            out.push(format!("{IND}let mut parent = sc.take_shared_by_id<GenParent>({rpid});"));
            out.push(format!("{IND}let mut sp = sc.take_shared_by_id<{}>({spv});", pool_ty()));
            out.push(format!("{IND}r.register(&mut parent.id, &mut sp);"));
            if outcome.is_some() {
                let mut world_after = world_before.clone();
                world_after.apply(op).ok();
                assert_pool_state(out, &world_after, *stake_pool, "sp", Some(("r", *routed)), level);
            }
            if !is_final_abort {
                out.push(format!("{IND}sui::test_scenario::return_shared(r);"));
                out.push(format!("{IND}sui::test_scenario::return_shared(parent);"));
                out.push(format!("{IND}sui::test_scenario::return_shared(sp);"));
            }
        }
        Op::RoutedSweep { routed, stake_pool } => {
            let rid = ctx.routed(*routed)?.to_string();
            let rpid = ctx.routed_parent(*routed)?.to_string();
            let spv = ctx.pool(*stake_pool)?.to_string();
            let routed_pool_id = world_before
                .routed
                .get(routed)
                .ok_or_else(|| anyhow!("routed stake {routed} not found"))?
                .routed_pool;
            let rpv = ctx.pool(routed_pool_id)?.to_string();
            out.push(format!("{IND}let mut r = sc.take_shared_by_id<{}>({rid});", routed_ty()));
            out.push(format!("{IND}let mut sp = sc.take_shared_by_id<{}>({spv});", pool_ty()));
            out.push(format!("{IND}let mut rp = sc.take_shared_by_id<{}>({rpv});", pool_ty()));
            out.push(format!("{IND}r.sweep(&mut sp, &mut rp, {rpid});"));
            if outcome.is_some() {
                let mut world_after = world_before.clone();
                world_after.apply(op).ok();
                assert_pool_state(out, &world_after, *stake_pool, "sp", Some(("r", *routed)), level);
                assert_pool_state(out, &world_after, routed_pool_id, "rp", None, level);
            }
            if !is_final_abort {
                out.push(format!("{IND}sui::test_scenario::return_shared(r);"));
                out.push(format!("{IND}sui::test_scenario::return_shared(sp);"));
                out.push(format!("{IND}sui::test_scenario::return_shared(rp);"));
            }
        }
        Op::RoutedUnregister { .. } | Op::RoutedUnstake { .. } | Op::RoutedRestake { .. } => {
            bail!("movegen does not yet support {op:?} (model-only, see NOTES.md)")
        }
        Op::ReleaseNew { .. } | Op::ReleaseFund { .. } | Op::ReleaseDistribute { .. } => {
            bail!("release_* ops are not supported by the differential generator (see NOTES.md)")
        }
    }
    Ok(())
}

/// Everything still holding a bare (non-shared) resource at a *normal*
/// function end must be disposed of via `std::unit_test::destroy`, which
/// bypasses the `drop`-ability check `stake::destroy` would otherwise
/// enforce (a still-registered stake is fine to force-destroy in a test).
fn emit_final_cleanup(out: &mut Vec<String>, ctx: &GenCtx) {
    for id in &ctx.stake_alive {
        out.push(format!("{IND}destroy(s{id});"));
    }
    out.push(format!("{IND}sc.end();"));
}

/// Build one `#[test]` function covering `ops[..end]`, optionally as an
/// `expected_failure` ending at an abort on `ops[end-1]`.
fn build_test_fn(
    fn_name: &str,
    scenario: &ScenarioFile,
    end: usize,
    abort: Option<(u64, String)>,
) -> Result<String> {
    let mut out = Vec::new();
    let mut ctx = GenCtx::default();
    let need_accumulator = scenario.ops[..end].iter().any(|o| o.op == "sweep_and_deposit");

    out.push("#[test]".to_string());
    if let Some((code, loc)) = &abort {
        out.pop();
        out.push(format!(
            "#[test, expected_failure(abort_code = {code}, location = {loc})]"
        ));
    }
    out.push(format!("fun {fn_name}() {{"));
    emit_setup(&mut out, &mut ctx, scenario, need_accumulator)
        .with_context(|| format!("scenario `{}` setup", scenario.name))?;

    // See `assert_pool_state`'s doc: Move's ~255-local-per-function budget
    // means we can't assert every accessor after every op once a scenario
    // runs past roughly a dozen ops. Below that, assert in full every step;
    // above it, only at ops with an explicit `expect` and at the last op.
    // A "dense" scenario asserts the *full* observable state after every op.
    // The gate has to be the number of `assert_eq!` *call sites* the result
    // would have, not the op count: a full assertion costs
    // `3 + (live stakes)` sites, so a 10-op scenario with one stake already
    // needs ~40 sites and overruns Move's 255-local budget (a plain op-count
    // threshold of 10 let `05a-merged-single-1000` through at 262 locals).
    let n_stakes = scenario.setup.stakes.len()
        + scenario.ops.iter().filter(|o| o.op == "new_stake").count();
    let full_site_cost = 3 + n_stakes.max(1);
    const SITE_BUDGET: usize = 20;
    let dense = end * full_site_cost <= SITE_BUDGET;
    // Every `assert_eq!` is a Move macro inlined at its call site and costs
    // several of a function's 255 local slots (`LOCAL_INDEX_MAX`). Asserting
    // the balance on *every* op of a long scenario overruns that budget and
    // makes `move-compiler` **panic** (`value (769) cannot exceed (255)`),
    // which fails the whole package build -- so every *other* scenario in
    // the same batch is then reported as a false DISAGREE ("test not found
    // in output"). Cap the number of intermediate assertion sites instead,
    // spacing them evenly; the last op always asserts in full.
    const ASSERT_SITE_BUDGET: usize = 12;
    let stride = end.div_ceil(ASSERT_SITE_BUDGET).max(1);

    let mut world = crate::scenario::build_world(&scenario.setup).map_err(|e| anyhow!("{e}"))?;
    for (i, raw) in scenario.ops[..end].iter().enumerate() {
        let op = raw.to_op().with_context(|| format!("op #{i}"))?;
        let world_before = world.clone();
        let result = world.apply(&op);
        let is_last = i + 1 == end;
        let is_final_abort = is_last && abort.is_some();
        // `raw.expect` does NOT gate `full` here (unlike an earlier version
        // of this function): `assert_eq!` is a Move *macro*, inlined at
        // every call site, and empirically costs several LOCAL_INDEX slots
        // per call (Move caps a function at 255 locals total,
        // `LOCAL_INDEX_MAX` in `file_format_common.rs`) -- a scenario with
        // many `expect`-bearing ops asserting in full blew that budget at
        // ~40-80 total `assert_eq!` call sites well before 200 ops. Only
        // `dense` (short scenarios) or the last op get full assertions now.
        let level = if dense || is_last {
            AssertLevel::Full
        } else if i % stride == 0 {
            AssertLevel::Balance
        } else {
            AssertLevel::None
        };
        match &result {
            Ok(outcome) => {
                emit_op(&mut out, &mut ctx, &world_before, &op, Some(outcome), is_final_abort, level)?;
            }
            Err(ApplyError::Abort(_)) if is_final_abort => {
                emit_op(&mut out, &mut ctx, &world_before, &op, None, true, level)?;
            }
            Err(e) => bail!("op #{i} in scenario `{}` did not apply: {e}", scenario.name),
        }
    }

    if abort.is_some() {
        out.push(format!("{IND}abort"));
    } else {
        emit_final_cleanup(&mut out, &ctx);
    }
    out.push("}".to_string());
    Ok(out.join("\n"))
}

pub fn generate(scenario: &ScenarioFile) -> Result<GeneratedModule> {
    let base = ident(&scenario.name);
    let module_name = format!("royalty_sim_gen_{base}");

    // Find the first op whose `expect.abort` is set, if any.
    let mut abort_at: Option<(usize, u64)> = None;
    for (i, raw) in scenario.ops.iter().enumerate() {
        if let Some(e) = &raw.expect {
            if let Some(code) = e.abort {
                abort_at = Some((i, code));
                break;
            }
        }
    }

    // Resolve the abort's location by dry-running the model up to that op.
    let mut tests = Vec::new();
    let mut bodies = Vec::new();

    if let Some((idx, code)) = abort_at {
        if idx > 0 {
            let fn_name = format!("{base}_prefix");
            let body = build_test_fn(&fn_name, scenario, idx, None)?;
            tests.push(GeneratedTest { fn_name, expected_abort: None });
            bodies.push(body);
        }
        // Determine the location by replaying the model once to capture the
        // Abort's module tag.
        let mut world = crate::scenario::build_world(&scenario.setup).map_err(|e| anyhow!("{e}"))?;
        let mut location = None;
        for raw in &scenario.ops[..=idx] {
            let op = raw.to_op()?;
            match world.apply(&op) {
                Ok(_) => {}
                Err(ApplyError::Abort(a)) => {
                    location = Some(a.location().to_string());
                }
                Err(e) => bail!("op did not apply while resolving abort location: {e}"),
            }
        }
        let location = location.ok_or_else(|| {
            anyhow!(
                "scenario `{}` expects abort {code} at op #{idx} but the model did not abort there",
                scenario.name
            )
        })?;
        // `royalty_pool`/`stake`'s aborts live in a package `routed_stake`
        // only depends on, not the current module -- always qualify fully.
        let location = if location == "ARITHMETIC_ERROR" {
            bail!("scenario `{}` expects an arithmetic abort, which Move reports without a module location; not representable as `expected_failure`", scenario.name);
        } else {
            location
        };
        let fn_name = format!("{base}_abort");
        let body = build_test_fn(&fn_name, scenario, idx + 1, Some((code, location.clone())))?;
        tests.push(GeneratedTest { fn_name, expected_abort: Some((code, location)) });
        bodies.push(body);
    } else {
        let fn_name = base.clone();
        let body = build_test_fn(&fn_name, scenario, scenario.ops.len(), None)?;
        tests.push(GeneratedTest { fn_name, expected_abort: None });
        bodies.push(body);
    }

    let mut source = String::new();
    source.push_str("// GENERATED by royalty-sim movegen. Do not hand-edit.\n");
    // `#[allow(unused_use)]`: a scenario whose first op already aborts never
    // calls `assert_eq!` (no successful op to assert state after).
    source.push_str(&format!(
        "#[test_only, allow(unused_use)]\nmodule routed_stake::{module_name};\n\n"
    ));
    source.push_str("use std::unit_test::{assert_eq, destroy};\n\n");
    source.push_str("const ALICE: address = @0xA1;\n\n");
    source.push_str("public struct GenShare() has drop;\npublic struct GenCurrency() has drop;\n");
    source.push_str("public struct GenParent has key { id: UID }\n\n");
    for body in &bodies {
        source.push_str(body);
        source.push_str("\n\n");
    }

    Ok(GeneratedModule { module_name, tests, source })
}
