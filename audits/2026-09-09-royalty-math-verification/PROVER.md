# PROVER.md: sui-prover feasibility for the royalty packages

## Verdict: GO. The prover runs locally and already proves three functions of the real `royalty_pool` package.

Evidence (all reproducible from this directory; see "Reproduce"):

| Step | Result |
|---|---|
| `cargo build --release -p sui-prover` (repo clone at `sui-prover/`, v1.5.3) | built in 1m42s, binary `sui-prover/target/release/sui-prover` |
| Boogie 2.15.8 (the version `scripts/prover_setup.sh` installs) | **incompatible**: `unknown switch: -inferModifies`. The setup script is stale. |
| Boogie 3.5.7 (latest on NuGet, what the repo's `lambda-boogie-handler/Dockerfile` installs), .NET 8, Z3 4.15.3 | works. Installed user-locally under `toolchain/` (no sudo, no brew). |
| `prover-smoke/` (standalone copy of the deposit fold) | `Verification successful`, 4.4 s |
| `prover-pool-specs/` against the **real** `github-root/misofm/royalty-pool` (local dep, hikida git dep resolved) | `Verification successful`, 11.5 s, 3 specs × 3 checks |

Specs proven so far (`prover-pool-specs/sources/`):

- `pool_specs::deposit_spec` targets `royalty_pool::pool::deposit`: carry' < staked_shares
  (I-B4), balance' = balance + v, cumulative_deposits' = cumulative_deposits + v, index
  monotone (I-B5), and the exact fold identity
  `(index' − index)·staked_shares + carry' == v·P + carry` (the per-deposit step of I-B2).
- `register_specs::register_stake_spec` targets `register_stake`: staked_shares' =
  staked_shares + amount, index unchanged, registration present with pool_id = pool and
  `debt == amount·index` exactly, and `pending_rewards == 0` right after registering (I-B10).
- `claim_specs::claim_rewards_spec` targets `claim_rewards`: reward = floor((amount·index −
  debt)/P), balance' = balance − reward, debt' = debt + reward·P, residue after claim < P,
  and `pending_rewards == 0` after the claim (I-B3 no-underflow as precondition, I-B9
  idempotence as postcondition).

Each spec carries the reachability preconditions from SPEC I-B7 (`balance + v ≤ u64::MAX`,
`cumulative_deposits + v ≤ u128::MAX`, `index + v·P ≤ u256::MAX`, `amount·index ≤ u256::MAX`,
`staked_shares + amount ≤ u64::MAX`). Without them the prover produces counterexamples at
the type maxima, which is Move aborting on overflow (correct behaviour), not a math defect.
That is itself a useful result: the prover confirms the *only* ways these functions abort
under valid state are the explicit asserts and integer overflow at the type limits.

## What the prover can and cannot do for us

Provable at function level (unbounded inputs, all u64/u128/u256 values): every row in SPEC
tagged "provable": I-A1, I-A2, I-A3 (distributor loop; needs a loop invariant or the
`prover::vector_iter::sum` idiom), I-B3, I-B4, I-B5, I-B7 (as reachability), I-B8, I-B9,
I-B10, I-B11 (unregister precondition), I-C1 (sweep branches).

Provable as a *state invariant* with more work: I-B1 (solvency) and I-B2 (exact conservation)
quantify over all live registrations, which live on Stake objects, not in the pool. A
function-level proof needs a ghost sum (`prover::ghost`) of `Σ(amount·index − debt)` over
registrations, maintained by every op, and an `inv_target` datatype invariant on the pool
relating `balance·P` to that ghost. This is a 1-3 day task for someone who has written
prover specs before; budget it as a stretch goal after the simulation campaign, because the
simulation + differential oracle already checks I-B1/I-B2 on every step of every scenario.

Not provable / out of reach: anything about address-balance settlement timing, PTB
composition, gas, or the crank. The prover models `sui::balance` and events; hikida's
`withdraw_funds_from_object` / `send_funds` natives were not exercised yet (the three specs
avoid `sweep_and_deposit` and `routed_stake::sweep`). Expect `sweep_and_deposit` to need a
spec-only stub or `#[ext(pure)]` abstraction.

## Known gotchas (learned while getting to green)

1. Set `BOOGIE_EXE` and `Z3_EXE`; the prover does not search PATH for them.
2. Use the NuGet-latest Boogie (3.x), not 2.15.8. `.NET 8` runtime is required for it.
3. Do not list `Sui`/`Prover` explicitly in the spec package's `Move.toml`; the prover
   injects its own forks (`asymptotic-code/sui` branch `next`) and warns otherwise. A spec
   package needs only the `local` dependency on the implementation package.
4. Postconditions must be written in `Integer` arithmetic (`x.to_int().mul(...)`): a
   postcondition written with native u128 ops is itself checked for overflow and fails the
   `SpecNoAbortCheck` pass.
5. In `SpecNoAbortCheck` the target is abstracted by its own ensures, so any post-state fact a
   later ensures relies on (e.g. "the registration still exists", "index unchanged") must be
   stated explicitly and *before* the ensures that read it.
6. Registrations are keyed by `Currency` type name (`stake.move:36-42`), not pool id; specs
   use `has_registration(&type_name::with_defining_ids<Currency>())`. SPEC.md §2.3 was
   corrected accordingly.
7. Runtime is seconds per spec at this size; the default 3000 s timeout is never approached.
8. The Move package cache is `~/.move` (the prover cloned its Sui fork there). That is the
   only write outside this directory.

## Recommended prover scope for the campaign

Phase P1 (during Sonnet's simulator work, 0.5 day): extend `prover-pool-specs/` with
`unregister_stake` (I-B11, I-B8: residue forfeited < P), `pending_rewards` (pure formula),
and a `routed_stake::sweep` spec for I-C1 with `deposit` abstracted by its proven spec
(`_Assume` already exists for that). Add a distributor spec package for I-A1/I-A2 once the
`release_revenue_distributor` package resolves locally.

Phase P2 (stretch, after the simulation results): ghost-sum state invariant for I-B1/I-B2.

Publishing: the spec packages are small, self-contained sibling packages; if the results are
published they belong next to the Move packages (`royalty-pool/specs/`, `routed-stake/specs/`)
with a CI job that installs Boogie 3.x + Z3 and runs `sui-prover -p specs`.

## Reproduce

```sh
cd <this directory>
source prover-env.sh
sui-prover -p prover-smoke        # standalone fold, ~4 s
sui-prover -p prover-pool-specs   # real royalty_pool package, ~12 s
```

Toolchain layout: `toolchain/bin/z3` (4.15.3), `toolchain/dotnet` (SDK 8.0.425; 6.0.428 also
present, unused), `toolchain/tools/boogie` (3.5.7). Logs: `prover-build.log`,
`prover-smoke/run.log`, `prover-pool-specs/run-all.log`.
