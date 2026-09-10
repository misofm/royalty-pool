# royalty-sim

A bit-exact Rust model of the misofm royalty distribution math (`royalty_pool`,
`routed_stake`, and the `release_revenue_distributor` split), plus a differential
oracle that generates and runs real Move tests against copies of the actual
packages. See `../SPEC.md` for the model this crate implements and
`../TASKS-SONNET.md` for the plan it follows.

## Layout

```
royalty-sim/
  Cargo.toml
  src/
    lib.rs            -- crate root (pub mod fuzz, model, movegen, scenario)
    main.rs            -- CLI (run / fuzz / diff / gen-move)
    model/
      abort.rs         -- Move abort codes, namespaced by module
      pool.rs           -- royalty_pool::pool (SPEC §2)
      stake.rs          -- royalty_pool::stake (SPEC §2.3)
      routed.rs         -- routed_stake::routed_stake (SPEC §3)
      distributor.rs     -- release_revenue_distributor::distribute (SPEC §1)
      world.rs           -- World/Op/Outcome: the scenario-executable state machine
      invariants.rs       -- SPEC invariant checks (I-A*, I-B*, I-C*)
    scenario.rs          -- JSON scenario schema, parsing, the `run` runner
    movegen.rs            -- scenario -> generated Move test module
    fuzz.rs                -- random scenario generation + shrinking
  scenarios/
    ported/               -- 4 scenarios reproducing royalty_pool_accounting_tests.move cases
    handwritten/           -- 12 scenarios covering the §6 gate-3 required categories
  move/
    royalty-pool/          -- copy of github-root/misofm/royalty-pool
    routed-stake/           -- copy of github-root/misofm/routed-stake, patched to
                               depend on the local royalty-pool copy
    routed-stake/tests/gen/ -- `diff`/`gen-move` write generated Move tests here
  tests/
    scenarios.rs            -- cargo test: runs every ported/handwritten scenario through the model
    differential.rs          -- cargo test: one scenario's real `sui move test` run (see below)
```

## Commands

All commands assume `cwd` is this directory (`royalty-sim/`).

### `run` -- execute scenarios against the model only

```sh
cargo run --release -- run scenarios/ported/*.json scenarios/handwritten/*.json
```

Prints one pretty-printed JSON report per scenario (per-op result, whether
every `expect` was met, any invariant violations, and the max I-C4 error
observed) and exits non-zero if anything failed.

### `fuzz` -- random-walk the model and check invariants

```sh
cargo run --release -- fuzz --profile realistic  --seed 1 --ops 500 --count 200
cargo run --release -- fuzz --profile churn      --seed 1 --ops 500 --count 100
cargo run --release -- fuzz --profile dust       --seed 1 --ops 500 --count 100
cargo run --release -- fuzz --profile hugeshares --seed 1 --ops 500 --count 100
cargo run --release -- fuzz --profile stress     --seed 1 --ops 500 --count 100
```

`--out DIR` additionally writes the first (delta-debugging-shrunk) failing
scenario as JSON to `DIR/<profile>-seed<seed>.json`. All five commands above
currently report `failures=0`.

### `diff` -- generate Move tests and run them for real

```sh
cargo run --release -- diff scenarios/ported/*.json scenarios/handwritten/*.json \
  --move-root move --sui /path/to/sui
```

(`--sui` defaults to `sui` on `$PATH`; in this environment it is
`../bin/sui` relative to `royalty-verification/`.) This:

1. Clears every `*.move` file out of `move/routed-stake/tests/gen/`, then
   generates a Move test module (see `movegen.rs`) for each scenario into
   `move/routed-stake/tests/gen/<name>.move`. Any hand-installed reproducer
   (see `CORPUS.json`'s `hand_written_move_tests`) is cleared along with
   everything else — reinstall it (`cp` it back in) after a `diff` run that
   needs it present for a subsequent `sui move test`.
2. Runs `sui move test royalty_sim_gen` once in `move/routed-stake/`.
3. Parses the pass/fail lines and prints `AGREE <name>` or
   `DISAGREE <name> -- <detail>` per scenario.
4. `--out DIR` also saves the raw `sui move test` stdout/stderr to
   `DIR/sui-move-test.{stdout,stderr}.txt`.

Currently reports `AGREE` for all 16 scenarios under `scenarios/ported/` and
`scenarios/handwritten/` (§6 gate 3).

**The full corpus is run as seven separate `diff` invocations, not one
`scenarios/**/*.json` glob** (see `CORPUS.json`'s `differential_batches`):
`ported`+`handwritten`, `adversarial` (non-`modelonly`), `fuzzgen/realistic`,
`fuzzgen/churn`, `fuzzgen/dust`, `fuzzgen/hugeshares`, and `verifier`
(non-`modelonly`). Two independent reasons force the split: a single
`scenarios/**/*.json` invocation generates a Move package whose largest
function needs more local-variable slots than `LOCAL_INDEX_MAX` allows (the
model-only scenarios alone overrun it), and even the non-model-only corpus
run as one batch accumulates enough generated modules across a long-lived
`tests/gen/` directory to exhaust the VM's `PACKAGE_ARENA_LIMIT_REACHED` —
which step 1 above now prevents *within* one `diff` invocation, but each of
the seven batches is still its own separate invocation for exactly that
reason.

### `gen-move` -- just emit one scenario's generated Move test

```sh
cargo run --release -- gen-move scenarios/handwritten/01-single-staker.json --out /tmp/single_staker.move
```

## Tests

```sh
cargo build --release
cargo test --release
cargo clippy --all-targets -- -D warnings
```

`cargo test` includes:
- Unit tests next to each model module (`calculate_reward`, `deposit`
  carry arithmetic, `distribute` remainder, `Stake`/`RoutedStake` abort
  paths).
- A proptest that `distribute` conserves the total and `R < n` for random
  split vectors (`n` in 1..=64) summing to 10 000.
- A proptest-style seeded sweep of the `realistic` profile for 200 ops x 256
  cases (`fuzz::tests::realistic_profile_200_ops_256_cases_has_no_violations`).
- `tests/scenarios.rs`: every `scenarios/ported/*.json` and
  `scenarios/handwritten/*.json` file passes through the model with every
  `expect` met and no invariant violated.
- `tests/differential.rs`: `single-staker`'s real `sui move test` run
  (finishes in ~5s here) -- see that file's doc comment for how it locates
  `sui`, and note that it prints a message and passes trivially rather than
  failing if no `sui` binary is found (e.g. a CI image without the
  framework deps cached).

## Regenerating the Move copies

`move/royalty-pool` and `move/routed-stake` are plain copies of
`github-root/misofm/{royalty-pool,routed-stake}` with `routed-stake/Move.toml`'s
`royalty_pool` dependency repointed at `{ local = "../royalty-pool" }`. To
refresh them from an updated `github-root` checkout:

```sh
rm -rf move/royalty-pool move/routed-stake
cp -r ../github-root/misofm/royalty-pool move/royalty-pool
cp -r ../github-root/misofm/routed-stake move/routed-stake
rm -rf move/royalty-pool/build move/routed-stake/build
rm -f move/royalty-pool/Move.lock move/routed-stake/Move.lock
sed -i 's#git = ".*", rev = ".*"#local = "../royalty-pool"#' move/routed-stake/Move.toml
(cd move/royalty-pool && sui move test)   # should be 38/38 (or whatever the upstream suite has grown to)
(cd move/routed-stake && sui move test)   # should be 18/18
```

See `NOTES.md` for every place the model had to make a choice not pinned by
SPEC, and `DISCREPANCIES.md` for the one place SPEC and the actual Move
source disagreed.
