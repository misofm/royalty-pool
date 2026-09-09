# TASKS-OPUS: drive the verification campaign

You take over after Sonnet hands off `royalty-sim` with all acceptance gates in
`TASKS-SONNET.md` §6 green. Read `SPEC.md` first. Your job is to try to break the royalty
math, not to confirm it works. Budget: wall-clock, not tokens; the fuzzers are cheap.

Working directory: `<this directory>/royalty-sim/`. Write only under `<this directory>`.
Do not modify `github-root/` or the copied Move packages except to add generated tests under
`move/routed-stake/tests/gen/`.

## 0. Re-verify the handoff (30 min)

1. Re-run every gate in `TASKS-SONNET.md` §6 yourself. Anything red: stop, write it in
   `REPORT.md` §"Handoff defects", and message the orchestrator rather than fixing it.
2. Read `NOTES.md`. Every "choice not pinned by SPEC" is a candidate for a differential test:
   write one JSON scenario per choice and run `diff` on it. The Move VM is the arbiter.
3. Read the model's `deposit`, `calculate_reward`, `claim`, `unregister`, `distribute` and
   compare them line by line to `pool.move:198-220, 416-418, 313-339, 282-309` and
   `release_revenue_distributor.move`. Any deviation, even one that "cannot matter", goes in
   `REPORT.md` and gets a differential scenario.

## 1. Fuzz budgets (run all; record seeds and violation counts in `REPORT.md`)

| Profile | `--ops` | `--count` | seeds | Purpose |
|---|---|---|---|---|
| realistic | 2 000 | 2 000 | 1..=8 | baseline |
| churn | 5 000 | 500 | 1..=8 | forfeited accumulation, registration churn |
| dust | 5 000 | 500 | 1..=8 | value=1 deposits, carry exercise, 1-bps tracks |
| hugeshares | 2 000 | 500 | 1..=8 | `staked_shares > 1e18`, zero index increments |
| stress | 500 | 2 000 | 1..=8 | u64/u128/u256 boundaries; expected aborts, never silent wrap |

For each run also record: max observed `ideal − (paid+pending)` (I-C4 error), total
`forfeited` per pool, max `carry`, max `index` bit-length, max `amount·index` bit-length.

## 2. Adversarial families (hand-written, at least the ones listed; add your own)

Write each as a JSON scenario in `scenarios/adversarial/` and run `run` then `diff`.

1. **Sandwich**: A registered; deposit D; B registers with huge amount; deposit D2; A
   claims; B claims. Expect A gets all of D and its share of D2; B gets only its share of
   D2. (I-B10)
2. **Whale dilution to zero increment**: register `2^63` shares; deposit 1 repeatedly 1e6
   times (model-only), then claim. Confirm index stayed 0 while carry grew to 1e6·1e18
   mod 2^63… actually confirm `carry < staked_shares` and total claimable equals
   `floor(1e6 · 1e18 / 2^63)`… no: with a single staker of amount `2^63`, claimable equals
   `floor(2^63 · index / P)`; verify against the exact rational `1e6 · 2^63/2^63 = 1e6` minus
   floors. Do the arithmetic in the report; do not hand-wave.
3. **Claim-then-unregister-then-reregister** loop 1 000 times with deposits of 1 between.
   Measure `forfeited`. Confirm `forfeited ≤ 1 000 · P` (I-B8) and that balance keeps
   `balance·P == owed + carry + forfeited` (I-B2).
4. **Two identical stakers registered in different orders** across a sequence of deposits:
   their `paid + pending` must be equal at every step (I-B6 symmetry).
5. **Split then merge**: one staker with amount 2a vs two stakers with amount a each
   (registered at the same index), same deposits: the singleton's payout must be ≥ the sum
   of the pair's payouts and differ by < 2 units per deposit… derive the exact bound from
   the floor formula and assert it.
6. **Routed late sweep vs eager sweep**: identical recording deposits, child pool with 3
   stakers; scenario E sweeps after every deposit, scenario L sweeps once at the end.
   Report per-staker difference; assert `|E − L| ≤ number_of_sweeps_in_E` units per staker
   and total conservation in both (I-C2).
7. **Parked funds**: routed sweep into a child with zero stakers three times; then register
   a staker; `sweep_and_deposit`; confirm the staker can claim the full parked sum minus
   floor (I-C3). Also: register a second staker *between* parking and `sweep_and_deposit`
   and confirm pro-rata split of the parked sum (parked funds are distributed by the shares
   at sweep time, not at park time; document this as a design property).
8. **Release with a 1-bps track**: T from 1 to 20 000 step 1 (model), T ∈ {1, 9 999, 10 000,
   10 001} (diff). Confirm A-D1/A-D2 and resolve SPEC F6 with the Move result.
9. **1 024 tracks** with splits `[8_977, 1, 1, …, 1]` (sum 10 000): T = 10 000 and
   T = u64::MAX. Confirm conservation and `R < 1 024`.
10. **Deposit exactly at u64 balance limit**: pool balance `u64::MAX − 1`, deposit 1 (ok),
    deposit 1 again (abort). The model must abort, not wrap.
11. **Debt monotonicity under repeated zero claims**: 10 000 consecutive claims with no
    deposits; debt must not change after the first; balance unchanged.
12. **Unregister with sub-unit residue**: single staker amount 3, deposit 1 → claimable 0
    (1·P/3 per share ·3 = P − residue? compute exactly), unregister must succeed
    (ELastClaimIndexMismatch only if claimable > 0) and forfeit the residue; then a new
    staker registers and a deposit of 1 arrives: confirm the forfeited residue is *not*
    paid to the new staker (it is dead balance). Document the exact dead-balance number.

## 3. Differential campaign

- Run `diff` on: all `scenarios/ported`, `scenarios/handwritten`, `scenarios/adversarial`,
  and **200 fuzz-generated scenarios** (≤ 200 ops each: 50 from each of realistic, churn,
  dust, hugeshares; use `fuzz --out` to dump them, choosing seeds 100..=103 so they are
  reproducible).
- Every `DISAGREE` is a finding. Reproduce it by hand in a fresh Move test in
  `move/routed-stake/tests/gen/manual_<n>.move` before you write it up. Classify as
  *model bug* (fix the model, note it, re-run) or *Move finding* (do not fix; write the
  minimal reproducer and the affected SPEC invariant).
- Record the total `sui move test` runtime; if generated tests exceed the gas meter or the
  test binary limits, reduce ops per scenario and say so.

## 4. Corpus manifest

Write `CORPUS.json` listing every scenario file, its sha256, the command used, seeds, the
git revision of the Move packages (`git -C github-root/misofm/royalty-pool rev-parse HEAD`
and the same for `routed-stake`), the `sui` version, the `royalty-sim` commit/hash, and the
verdict per scenario. Fable will replay from this manifest; if it cannot, the campaign does
not count.

## 5. `REPORT.md` format

```
# Royalty math verification report — <date>
## Verdict            one paragraph: rock solid / solid with caveats / defects found
## Scope              packages, revisions, what was and was not modeled (copy SPEC §7 of TASKS-SONNET)
## Invariant table    one row per SPEC invariant: method (sim / diff / prover), runs, violations, notes
## Findings           numbered; each with: severity, SPEC ref, minimal scenario path, Move reproducer path,
                      observed vs expected, whether it is a Move bug, a model bug, or a design property
## Quantitative       max rounding error per staker (units), forfeited totals under churn, carry/index maxima,
                      dust starvation thresholds (min T for every track to receive ≥ 1 unit for the tested split vectors)
## Fuzz runs          the §1 table with actual numbers and seeds
## Differential runs  counts of AGREE/DISAGREE, runtime
## Prover             copy the status from PROVER.md plus any specs you ran
## Handoff defects    anything red at §0
## Reproduction       exact commands, from CORPUS.json
```

Severity scale: **S0** funds can be lost/minted or a claim can fail for a registered stake
(I-B1/I-B2 violation); **S1** unexpected abort that can wedge a pool or release (funds
stuck without a recovery path); **S2** rounding error beyond the SPEC bound; **S3** design
property worth documenting (e.g. parked-funds split by shares at sweep time); **S4** model
or tooling defect.

## 6. What you must not do

- Do not soften the model to make a run pass. If a bound in SPEC is wrong, say the bound
  is wrong and give the counterexample; the orchestrator decides.
- Do not extrapolate from the model to Move without a `diff` run or a hand-written Move
  test for the claim.
- Do not change any Move package.
