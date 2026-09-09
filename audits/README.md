# Audits and verification of `royalty_pool`

| Date | What | Where |
| --- | --- | --- |
| 2026-08-23 | Security audit of `pool.move` and `stake.move` (threat model, solvency proof, custody findings), plus the 2026-09-07 localnet check of the funded `sweep_and_deposit` path | [`../AUDIT.md`](../AUDIT.md) |
| 2026-09-09 | Royalty math verification campaign against `18c55f62` (and routed-stake `950daa98`): bit-exact Rust model, independent Python oracle, 88 M-operation fuzz campaign run twice (second run with the strengthened accumulator identity enforced, byte-identical results), 239 generated scenarios executed on the Move VM with zero disagreements, 15 hand-written Move tests, function-level prover specs, and an adversarial verification pass | [`2026-09-09-royalty-math-verification/`](2026-09-09-royalty-math-verification/) |

## 2026-09-09 royalty math verification

Start with `REPORT.md` (the campaign report, revised after verification) and
`VERIFICATION.md` (the independent pass that replayed the campaign from
`CORPUS.json`, re-derived every headline finding, and corrected the report in
four places). `SPEC.md` is the mathematical model the campaign tested against,
with the discrepancies found between the spec and the Move source recorded in
`royalty-sim/DISCREPANCIES.md`.

Verdict in one paragraph: the accumulator arithmetic in `pool`, `stake`,
`routed_stake`, and the release distributor conserves value exactly
(`balance·P == Σ owed + carry + forfeited` at every step), never under-pays a
registered stake below `⌊amount·Δindex/P⌋`, and never lost, minted, or wedged
funds in anything tried. No Move defect was found. The findings are spec
corrections, tooling defects in the first handoff, and design properties that
operators should know about: rewards parked on a routed stake are split by the
composition pool's share set at sweep time, so sweeping promptly matters; a
pool whose total stake exceeds 10¹⁸ shares can redistribute carry when the
share set changes; sub-unit residue is forfeited on unregister. The one link
not executed in the unit VM is the funded address-balance redemption path
(`redeem_all_and_distribute`, `sweep_and_deposit`); see `REPORT.md` §Scope and
`../AUDIT.md` for the localnet observation of it.

### Contents

- `royalty-sim/` — the Rust model, scenario runner, Move test generator, and
  fuzzer, with pinned copies of `royalty-pool` and `routed-stake` under
  `move/` at the revisions recorded in `CORPUS.json` (build directories
  stripped). `royalty-sim/README.md` documents the CLI.
- `royalty-sim/scenarios/` — the full corpus: ported, hand-written,
  adversarial, verifier, and 200 fuzz-derived scenarios. Each file's sha256 is
  in `CORPUS.json`.
- `manual-move-tests/` — hand-written Move tests that cover what the generator
  cannot (the release distributor at `MAX_TRACKS`, the sweep derivation
  assert, and one differential SKIP).
- `oracle/` — the independent Python oracle used for expected values.
- `prover-pool-specs/` — the sui-prover specs (see `PROVER.md` for the
  toolchain and what each spec does and does not prove).
- `fuzz-logs/`, `fuzz-logs-run1/` — per-shard fuzz logs for the final run and
  the first run; `fuzz-jobs.txt` and `run-campaign.sh` reproduce them.
- `TASKS-SONNET.md`, `TASKS-OPUS.md` — the plans the build and campaign
  followed, kept for provenance.

### Replaying

Requirements: Rust stable, a `sui` binary matching `CORPUS.json`
(`toolchain.sui`), and about 30 cores for the full fuzz campaign.

```sh
cd audits/2026-09-09-royalty-math-verification/royalty-sim
cargo build --release
cargo test --release
cargo run --release -- run scenarios/*/*.json
cargo run --release -- diff scenarios/*/*.json --move-root move --sui sui
cd .. && ./run-campaign.sh        # the full 88 M-operation campaign; ~95 min at 30-way
```

Every scenario must report `AGREE` (248 scenarios: 239 differential, 8
model-only, 1 covered by a hand-written Move test); every fuzz shard must end
with `failures=0`. `CORPUS.json` lists the exact commands, seeds, and expected
sha256s the verifier matched byte for byte.
