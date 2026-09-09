# TASKS-SONNET: implement `royalty-sim`

You are implementing a bit-exact simulator of the misofm royalty distribution math and a
differential oracle against the real Move packages. Read `SPEC.md` in this directory first;
it is the contract. Every formula in the model must cite the SPEC section it implements.

Working directory (create it): `<this directory>/royalty-sim/`. Do not touch anything
outside `<this directory>`. Do not modify the Move packages under `github-root/`; copy them.

Toolchain available: `cargo 1.97`, `sui` 1.78.1 at
`sui`
(`sui move test` verified working on `github-root/misofm/royalty-pool`: 38 tests pass).

## 0. Ground rules

- Rust 2021, single binary crate `royalty-sim` with a `lib` + `main`. Dependencies allowed:
  `primitive-types` (U256/U512) or `ruint`, `serde`, `serde_json`, `clap`, `proptest`,
  `num-rational` + `num-bigint` (for the exact oracle), `anyhow`. Nothing else without
  writing the reason in `NOTES.md`.
- **No floating point anywhere in the model.** Rational comparisons use `BigRational`.
- Every arithmetic step that Move performs on a fixed-width type must be performed on the
  same width in Rust with `checked_*`, and a checked failure must map to a Move abort
  (`Abort::Arithmetic`). Do not "helpfully" widen. The only widening allowed is where Move
  widens (`(x as u128)`, `(x as u256)`), and narrowing (`as u64`) must be `try_from` that
  maps failure to `Abort::Arithmetic`.
- Abort codes are part of the model. Use the exact constants from SPEC §2 (pool),
  `stake.move`, `routed_stake.move`, `hikida` (`ENoValueToRedeem = 1`), and the distributor.
- Deterministic: every run is reproducible from `(seed, config)`; print the seed on every
  failure.

## 1. Model (`src/model/`)

### 1.1 `pool.rs` (SPEC §2)

```rust
pub struct Pool { pub id: PoolId, pub index: U256, pub carry: u128, pub staked_shares: u64,
                  pub cumulative_deposits: u128, pub balance: u64,
                  // ghosts (not on chain):
                  pub forfeited: U256 /* in P-units */, pub parked_at_address: u64 }
pub const P: u128 = 1_000_000_000_000_000_000;
impl Pool {
  pub fn deposit(&mut self, value: u64) -> Result<(), Abort>;          // pool.move:198-220
  pub fn register(&mut self, stake: &mut Stake) -> Result<(), Abort>;   // pool.move:255-275
  pub fn unregister(&mut self, stake: &mut Stake) -> Result<(), Abort>; // pool.move:282-309, bumps forfeited
  pub fn claim(&mut self, stake: &mut Stake) -> Result<u64, Abort>;     // pool.move:313-339
  pub fn pending(&self, stake: &Stake) -> Result<u64, Abort>;           // pool.move:345-365
  pub fn sweep_and_deposit(&mut self) -> Result<(), Abort>;             // pool.move:241-249 (uses parked_at_address)
  pub fn receive_and_deposit(&mut self, value: u64) -> Result<(), Abort>; // pool.move:225-231
}
fn calculate_reward(amount: u64, debt: U256, index: U256) -> Result<u64, Abort>; // pool.move:416-418
```

### 1.2 `stake.rs` (SPEC §2.3, `stake.move`)

`Stake { id, amount: u64, registrations: BTreeMap<Currency, Registration{pool_id, debt: U256}> }`
where `Currency` is a small enum/id (SPEC §2.3: registrations are keyed by currency type, so
a stake is in at most one pool per currency; `unregister`/`claim` abort `EPoolIdMismatch = 4`
when the stored pool id differs from the pool called, `pending` returns 0). Every pool has a
`currency`; scenarios default all pools to one currency. `new` aborts on `amount == 0`.
`destroy` aborts when registrations non-empty.

### 1.3 `routed.rs` (SPEC §3)

`RoutedStake { id, parent, stake: Option<Stake>, routed_pool: PoolId }` with
`register/unregister/unstake/restake/sweep` exactly as `routed_stake.move:94-236`. `sweep`
must implement the three branches (zero reward → return; child has no stakers → park at
child address; else deposit). Emit a `Swept{claimed, deposited, parked}` record.

### 1.4 `distributor.rs` (SPEC §1)

`distribute(total: u64, splits: &[u64]) -> Result<Distribution{amounts: Vec<u64>, remainder: u64}, Abort>`
using `bps::apply` semantics (`floor(total * split / 10_000)` computed in u128). Also
`redeem_all_and_distribute(release_balance: &mut u64, ...)` that is a no-op on zero.
Whether `send_funds(0)` aborts is a SPEC F6 unknown: implement as a config flag
`zero_send_aborts: bool` and have the differential test determine the truth (see §4).

### 1.5 `world.rs`

A `World` holds releases (with split vectors and address balance), recording pools, routed
stakes, composition pools, and plain stakes, addressed by small integer ids. It exposes a
single `apply(&mut self, op: &Op) -> Result<Outcome, Abort>`.

### 1.6 `invariants.rs`

Implement each SPEC invariant as a function `check_<id>(&World) -> Result<(), Violation>`
and a `check_all` that runs every applicable invariant after every op. Required:
I-A1, I-A2, I-B1, I-B2, I-B3, I-B4, I-B5, I-B7, I-B8, I-C1. Fairness (I-B6) is checked via
per-stake ghost counters: `paid` and `idx_at_registration`; assert
`paid + pending == floor(amount * (index - idx_at_registration) / P)` while the stake stays
registered with constant amount. `Violation` must carry the op index, the op, and the two
sides of the failed comparison.

I-B2 exact form to implement (both must hold):

```
balance * P == Σ_live (amount·index − debt) + carry + forfeited          // P-units
cumulative_deposits * P == Σ_all_ever (paid·P + owed_now_or_at_unregister) + carry + forfeited
```

Also implement `check_exact_oracle` (I-C4): maintain a `BigRational` "ideal" payout per
stake (`Σ over deposits of value · amount / staked_shares_at_deposit`) and report
`ideal − (paid + pending)` as a signed rational; assert it is in `[0, 1 + n_deposits_since_registration·0)`.
Precisely: the accumulator design guarantees `paid + pending ≤ ideal` (floors only) and
`ideal − (paid + pending) < 1 + (number of claims)` units. Assert that bound and record the
observed max.

## 2. Scenario language (`src/scenario.rs`)

JSON, one file per scenario:

```json
{ "name": "two-stakers-one-deposit",
  "setup": { "pools": [{"id": 0}], "stakes": [{"id": 0, "amount": 100}, {"id": 1, "amount": 300}] },
  "ops": [
    {"op": "register", "pool": 0, "stake": 0},
    {"op": "register", "pool": 0, "stake": 1},
    {"op": "deposit",  "pool": 0, "value": 1000},
    {"op": "claim",    "pool": 0, "stake": 0, "expect": {"reward": 250}},
    {"op": "unregister", "pool": 0, "stake": 1, "expect": {"abort": 5}}
  ] }
```

Op set (all must exist): `register`, `unregister`, `deposit`, `receive_and_deposit`,
`sweep_and_deposit`, `claim`, `pending`, `new_stake`, `destroy_stake`,
`routed_new`, `routed_register`, `routed_unregister`, `routed_unstake`, `routed_restake`,
`routed_sweep`, `release_new {splits}`, `release_fund {value}`, `release_distribute`.
Each op takes an optional `expect` with `reward`, `abort`, `amounts`, `remainder`.

## 3. CLI (`src/main.rs`)

```
royalty-sim run <scenario.json>...            # run scenarios, check invariants each step, print JSON result per scenario
royalty-sim fuzz --seed N --ops K --profile realistic|stress|churn|dust|hugeshares --count M [--out DIR]
                                              # proptest/own RNG; on failure write the minimized scenario to DIR
royalty-sim diff <scenario.json>... --move-root PATH --out DIR
                                              # emit Move tests (see §4) and run `sui move test`; report agreement
royalty-sim gen-move <scenario.json> --out FILE   # just emit the Move test
```

`fuzz` must implement shrinking (proptest's, or a simple delta-debugging pass over the op
list) so failures are reported as the smallest scenario that still violates.

Profiles (see SPEC §5 for magnitudes):

- `realistic`: amounts 1..1e13, deposits 1..1e12, ≤ 20 stakers, ops weighted deposit 40%,
  claim 30%, register 15%, unregister 10%, sweep 5%.
- `stress`: amounts up to u64::MAX with `staked_shares` allowed to approach u64::MAX (the
  generator must keep the sum ≤ u64::MAX or expect abort), deposits up to u64::MAX (expect
  balance overflow abort past u64::MAX total; the generator must model this).
- `churn`: register/unregister/claim dominate; deposits of 1..1000; measure `forfeited`.
- `dust`: deposits of 1..10_000 with many stakers; releases with a 1-bps track and `T` in
  `[1, 10_000)`.
- `hugeshares`: `staked_shares > P` (register stakes summing to > 1e18) with small deposits
  so the index increment can be zero; confirm carry accumulates and conservation holds.

## 4. Differential oracle (`src/movegen.rs`, `move/`)

1. Copy `github-root/misofm/royalty-pool` and `github-root/misofm/routed-stake` into
   `royalty-sim/move/` and point `routed_stake`'s `royalty_pool` dependency at the local
   copy (`local = "../royalty-pool"`) so both compile from one tree. Confirm the existing
   suites still pass in the copies before generating anything.
2. `gen-move` turns a scenario into a Move test module `royalty_sim_gen::<name>` that
   replays the ops with the real APIs (use `royalty-pool/tests/royalty_pool_accounting_tests.move`
   as the template for how the existing tests construct pools/stakes and read state: it
   already has helpers for creating a pool, a stake, depositing a `Balance`, claiming, and
   reading `pending_rewards`). After every op, assert the observable state the model
   predicts: `balance().value()`, `staked_shares()`, `cumulative_reward_per_share()`, and
   `pending_rewards` for every registered stake. If `carry` is not readable through a public
   accessor, assert the *next* deposit's effect instead (it is fully determined by carry).
   Scenarios whose last op is expected to abort are emitted as
   `#[expected_failure(abort_code = N, location = <module>)]` tests; scenarios with an
   abort in the middle are split at the abort (prefix as a normal test, prefix+abort-op as
   an expected-failure test).
3. `diff` writes the generated modules into `move/routed-stake/tests/gen/` (routed-stake
   depends on royalty-pool so one package can exercise both), runs
   `sui move test --filter royalty_sim_gen`, parses the output, and prints
   `AGREE`/`DISAGREE` per scenario with the first failing assertion.
4. Resolve SPEC F6 (`send_funds` of zero) with a generated distributor test in a copy of
   `musicos-actions/release_revenue_distributor` if its dependencies resolve locally;
   otherwise document that it is left to Opus with the plugin package.

Keep the generated Move small: the test binary limit and gas meter in `sui move test` bound
scenario length. Cap `diff` scenarios at 200 ops; longer fuzz scenarios are model-only.

## 5. Tests inside the crate

- Unit tests for `calculate_reward`, `deposit` (carry arithmetic), `distribute` (remainder).
- Port the three targeted cases from `royalty_pool_accounting_tests.move` as JSON scenarios
  under `scenarios/ported/` and confirm the model reproduces their expected numbers.
- A proptest that `distribute` conserves and `R < n` for random split vectors summing to
  10 000 with `n` in 1..=64.
- A proptest that runs the `realistic` profile for 200 ops and 256 cases in `cargo test`.

## 6. Acceptance gates (all must be green before you hand off)

1. `cargo build --release` and `cargo test` pass with no warnings under `-D warnings`.
2. `royalty-sim run scenarios/ported/*.json` reports all expectations met.
3. `royalty-sim diff scenarios/ported/*.json scenarios/handwritten/*.json --move-root move`
   reports `AGREE` for every scenario (at least 12 handwritten scenarios covering: single
   staker, two stakers unequal, late joiner, claim-twice, unregister-with-pending (abort 5),
   unregister-after-claim, deposit-no-stakers (abort 1), deposit-zero (abort 6),
   routed sweep to empty child (parks), sweep_and_deposit recovery, sweep with zero reward,
   huge-shares carry behaviour).
4. `royalty-sim fuzz --profile realistic --seed 1 --ops 500 --count 200` completes with zero
   violations, and the same for `churn`, `dust`, `hugeshares` at `--count 100`.
5. `README.md` documents how to run each command; `NOTES.md` lists every place the model
   had to make a choice not pinned by SPEC, and any place where the model and Move disagreed
   during development (even if fixed).

## 7. Out of scope

- Gas, object ownership, transfer, and permission checks (`assert_derived_from` is modeled
  as always-true except for a single negative scenario).
- The crank service, PTB packing, and address-balance settlement timing (parked funds are
  modeled as immediately settled).
- Performance of the Move code.
- Any change to the Move packages. If you believe you found a Move bug, write it in
  `NOTES.md` under "Suspected Move findings" with the minimal scenario and stop; do not fix.
