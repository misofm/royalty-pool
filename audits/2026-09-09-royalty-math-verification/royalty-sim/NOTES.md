# Notes: choices not pinned by SPEC, deviations, and dev-time findings

## Dependency not on TASKS-SONNET §0's list: `rand` + `rand_chacha`

TASKS-SONNET §0 names `primitive-types`/`ruint`, `serde`, `serde_json`,
`clap`, `proptest`, `num-rational` + `num-bigint`, and `anyhow` as the
allowed dependencies, "nothing else without writing the reason in
NOTES.md." `fuzz.rs` additionally uses `rand` + `rand_chacha`
(`ChaCha8Rng::seed_from_u64`) for its own weighted random-walk scenario
generator (deposit/claim/register/unregister/sweep, per profile). Reason:
`proptest`'s own `Strategy`/`TestRunner` machinery is built around
generating one value per property-test *case* from a description, not
around driving a long, stateful, adaptively-branching sequence of
interdependent operations (each "next op" choice needs to see the model's
current live-stake set, remaining room under the profile's supply cap,
etc.) -- forcing that through `proptest::Strategy` would mean hand-rolling
an RNG facade or a `TestRunner`-driving loop anyway, with no real benefit
over a plain seeded `Rng`. `proptest` is still used directly (via the
`proptest!` macro) for the two genuinely case-shaped properties in
`model::distributor`'s tests (`distribute` conservation over random split
vectors). `rand_chacha` was chosen over `rand`'s default RNG for
reproducibility across Rust/`rand` versions (`ChaCha8Rng` is an explicit,
version-stable algorithm rather than "whatever the default happens to be");
`rand` itself is pulled in only for the `Rng` trait these calls need.

See `DISCREPANCIES.md` for the two places SPEC and actual Move source
disagreed. This file is everything else: simplifications, scope cuts, and
bugs found and fixed during development.

## Choices SPEC left open

- **Currency representation.** SPEC keys registrations by `TypeName`
  (`std::type_name`). The model uses a small `u32` id (`model::stake::Currency`)
  instead -- the simulator never needs real Move type names, only
  distinctness, and every scenario in this crate uses currency `0`
  throughout (SPEC itself: "Realistic flows use one currency (SUI)").
- **`zero_send_aborts` config flag** (TASKS-SONNET §1.4): kept as specified
  (`model::distributor::DistributorConfig`), but currently has no
  observable effect -- see DISCREPANCIES.md #1. It's wired through so a
  future op that actually models a raw `send_funds` call (not currently in
  the op set) could consult it.
- **2026-09-10: `receive_and_deposit` op removed.** The Move-side
  `receive_and_deposit` (coin-object recovery that deposited directly) was
  removed when the API moved to `settle`/`recover_coins` (task A5); since
  its accounting always reduced to a plain `pool::deposit(value)` call (see
  the note this replaces, below), every scenario that used it now calls
  `deposit` directly with the same value -- no economic content changed.
- **`settle`'s "parked funds" queue** (renamed from `sweep_and_deposit`,
  2026-09-10; the model's semantics were already total before the rename --
  see the next bullet). Out of scope §7 says address-balance settlement
  timing is modeled as immediate. The model represents "funds sent to a
  pool's address, awaiting `settle`" as a single ghost counter
  (`Pool::parked_at_address`), populated only by `routed_stake::sweep`'s
  park branch (SPEC §3.1) and drained in full by `settle`. There is no
  direct "send funds to a pool address" op in the scenario language other
  than through a routed sweep; this was sufficient for every required
  scenario.
- **2026-09-10: `sweep_and_deposit` became `settle`, total.** The old
  `sweep_and_deposit` aborted (`ENoSettledFunds`) when nothing was parked;
  `settle` returns `Ok(0)` instead in both no-op cases (nothing parked, and
  `staked_shares == 0`, checked first and before any redemption -- matching
  the new `pool.move` guard order). `Pool::settle`'s own unit test
  (`model::pool::tests::settle_is_total_with_no_stakers_or_nothing_parked`)
  pins all four cases (empty/empty, staked/empty, unstaked/parked,
  staked/parked).
- **`RoutedStake`'s Rust shape carries `parent`/`routed_pool` fields
  directly** (per TASKS-SONNET §1.3's literal struct definition), even
  though the real Move `RoutedStake` struct stores neither (they're passed
  as parameters to each op). This is a simulator-level convenience matching
  how a routed stake is used in practice (one fixed parent, one fixed
  child pool) and is exactly mirrored by `movegen`'s per-routed-stake
  dedicated parent object (see below).
- **`assert_derived_from` is modeled as always-true** (out of scope §7),
  except for the one negative scenario shape (`wrong_parent: true` on a
  routed op, mapped to a bogus `u64::MAX` parent id) -- present in the
  model (`World`/`Op::Routed*::parent_override`) but **not supported by
  `movegen`** (see below); it is model-only.

## Scope cuts in `movegen` (the differential generator)

All of the following are things the *model* (`World`/`Op`) fully supports,
but the Move-test generator does not, because none of the required
differential scenarios (TASKS-SONNET §6 gate 3's 12 categories) need them,
and time was better spent elsewhere:

- **`release_new`/`release_fund`/`release_distribute`**: not generated at
  all (`movegen::generate` returns an error naming the op). Wiring up
  `musicos::release` + `ReleaseAdminCap` + `Recording` objects as local
  Move test fixtures is a substantial undertaking of its own, and SPEC F6
  (the one open question about this stage) was already resolved
  definitively by reading `release_revenue_distributor.move` directly (see
  DISCREPANCIES.md #1) -- stronger evidence than a generated test would
  have given anyway. Left for Opus per TASKS-SONNET §4.4's own allowance
  ("otherwise document that it is left to Opus with the plugin package").
- **`routed_unregister`/`routed_unstake`/`routed_restake`**: not generated
  (model-only). `routed_register` and `routed_sweep` (which cover every
  required routed-stake scenario) follow the identical take-shared/return-
  shared pattern, so extending to the other three is low-risk future work,
  just not needed here.
- **`wrong_parent` scenarios**: model-only, not generated. Exercising the
  real `EPoolNotDerivedFromParent`/`ENotDerivedFromParent` abort would need
  a second, unrelated parent object threaded through the Move test purely
  for this one negative case; skipped for time.
- **Multiple currencies per scenario**: `movegen` requires every pool in
  `setup.pools` to have `currency == 0` and maps it to one Move phantom
  type pair, `GenShare`/`GenCurrency`, shared by every pool, stake, and
  routed stake in the generated module. This is enough for every scenario
  here, including the ones that need *multiple pools* of the same currency
  (the `EAlreadyRegistered`/`EPoolIdMismatch` shape) -- those just need
  distinct pool ids, not distinct Move types.
- **`settle`'s parked-value path is proxied through a direct `deposit`**
  (2026-09-10; previously proxied through `receive_and_deposit`, which no
  longer exists -- see the doc comment on `movegen::emit_op`'s `Op::Settle`
  arm). The Move unit-test VM never populates a *positive* settled-funds
  snapshot after `send_funds` in the same transaction (confirmed directly:
  `royalty_pool_tests.move`'s own comment, "The Move unit VM does not
  populate funded `AccumulatorRoot` reads... requires localnet coverage for
  a funded success case"), so the only real, generatable `settle` behavior
  is the total 0-return case -- which the model correctly special-cases
  (a real `settle(&root)` call is emitted and asserted to return 0 and
  leave `balance` unchanged, whenever `parked_at_address == 0`). When the
  model has a positive `parked_at_address` (a routed sweep parked it
  earlier in the same scenario), a real `settle` call still can't observe
  it, so the generated Move reaches the identical post-state via
  `p.deposit(balance::create_for_testing(parked))` instead -- bit-identical
  to what `settle` would apply once it could observe the settlement, and
  not a substitution for the *routed sweep's park* step itself (that part
  -- `routed_pool.balance().value() == 0` after parking -- is asserted for
  real, via `routed_stake::sweep`).
- **`whale-claim-cycles-stay-solvent` ported at reduced scale.** The
  original `royalty_pool_accounting_tests.move` test runs 1000 deposit +
  claim cycles across 10 transactions. `scenarios/ported/whale-claim-cycles-stay-solvent.json`
  runs 6 (chosen to fit comfortably under Move's function-locals ceiling,
  see below) while keeping the same whale/dust proportions and the same
  "claim is always reachable" property. The full 1000-cycle-scale
  behavior is instead exercised by `fuzz --profile hugeshares`/`stress`
  (hundreds of ops per case, 100-200 cases), which is model-only and has
  no such ceiling.

## Move's per-function locals ceiling (`movegen` assertion density)

Early versions of `movegen` asserted the full observable state (`balance`,
`staked_shares`, `cumulative_reward_per_share`, and `pending_rewards` for
every live stake) after *every* op. This works for any scenario up to
roughly a dozen ops, then `sui move test` reliably panics during bytecode
serialization:

```
called `Result::unwrap()` on an `Err` value: value (551) cannot exceed (255)
```

`551` is a total across the whole function, and it scales with the number
of `assert_eq!` call sites (`LOCAL_INDEX_MAX = 255` in
`move-binary-format/src/file_format_common.rs`; `assert_eq!` is a `macro
fun`, inlined at every call site, and each inlined copy apparently costs
several local-variable slots -- confirmed empirically, not from reading the
macro's expansion). Fixed in `movegen::build_test_fn`/`assert_pool_state`
by asserting in full only when the whole scenario is short (`<= 10` ops)
or at the very last op; longer scenarios get a cheap `balance().value()`
check on every other op. This still catches any disagreement (a wrong
balance at any step is still caught), just not with full per-accessor
granularity at every intermediate step of a long scenario. See the doc
comment on `assert_pool_state` for the exact numbers this was calibrated
against.

## Bugs found and fixed during development (in the simulator, not Move)

- **I-B4's carry bound was checked against the wrong `staked_shares`.**
  First implementation compared `pool.carry` against the pool's *current*
  `staked_shares`, which can shrink to 0 after `unregister` while `carry`
  (set by the last *deposit*) sits unchanged -- a legitimate state, not a
  bug, that the first version of the invariant flagged as one. Fixed by
  adding a `staked_shares_at_last_deposit` ghost (mirroring
  `royalty_pool_accounting_tests.move`'s own `staked_at_fold` ghost) and
  checking against that instead. Found by `fuzz --profile realistic`.
- **I-C4's bound was one-sided and too tight** -- see DISCREPANCIES.md #2.
  Found by `fuzz --profile hugeshares`/`stress`.
- **Non-atomic mutation on a checked-arithmetic failure path.** Several
  `Pool`/model methods originally mutated some fields before checking a
  later `checked_*` call that could still fail (e.g. `register` inserted
  the new registration onto the stake *before* checking
  `staked_shares.checked_add`). Move's actual semantics roll back the
  *entire* transaction on any abort, so a partial mutation before an abort
  is wrong. Fixed two ways: (1) every model method now computes all
  fallible values before committing any mutation (see the comments in
  `pool.rs`), and (2) `World::apply` additionally snapshots and restores
  the whole `World` around every op as a second, simpler safety net --
  this is what actually makes multi-object ops like `RoutedSweep` (claim
  from one pool, deposit into another) atomic, since ordering the
  fallible-vs-mutating steps *within* `sweep` alone can't make a
  cross-object rollback atomic. Found by code review, not by a failing
  test (the specific overflow this guards was never hit by the profiles
  run here, since `stress`'s generator caps registrations at the modeled
  supply) -- kept as defense in depth.
- **`sui move test`'s CLI takes the test filter as a bare positional
  argument in this build (v1.78.1)**, not `--filter <name>` (which errors
  "unexpected argument"). `main.rs`'s `diff` command uses the positional
  form.
- **`sui::accumulator::create_for_testing` asserts `ctx.sender() == @0x0`**
  (`accumulator.move:17`, `ENotSystemAddress`). `movegen::emit_setup`
  begins the test scenario at `@0x0` (matching
  `royalty_pool_tests.move`'s own pattern) whenever any op in the scenario
  needs it, switching to `ALICE` on the first op's `next_tx`.

## Out of scope, per TASKS-SONNET §7 (confirmed, not re-litigated here)

Gas, object ownership/transfer, and permission checks; the crank service,
PTB packing, and real address-balance settlement timing (modeled as
immediate); prover-grade formal proofs (that's `PROVER.md`/Opus's remit).
