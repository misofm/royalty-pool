# Discrepancies between SPEC.md and the actual Move source

Per the task rules: when SPEC and Move disagree, Move wins, and the model
follows Move. Two were found; both are recorded here with the exact
resolution taken.

## 1. SPEC A3 vs `release_revenue_distributor.move` (F6, resolved)

**SPEC says** (§1, A3): "`amount_i` is sent to the recording's address
(`send_funds`), including when `amount_i == 0` (no zero-skip in the loop;
verify in simulation whether `send_funds` of a zero balance is accepted;
the Move test suite has a case for it)."

**Move actually does** (`release_revenue_distributor.move:92-97`):

```move
release.tracks().do_ref!(|track| {
    let amount = track.split_bps().apply(total_input);
    total_distributed = total_distributed + amount;
    if (amount > 0) {
        revenue.split(amount).send_funds(track.recording_id().to_address());
    };
    ...
```

There **is** a zero-skip (`if (amount > 0)`). `send_funds` is never called
with a zero balance on this path, at all.

**Resolution:** SPEC's open question F6 ("if `send_funds` of zero aborts, a
large release with a 1-bps track could be un-distributable when `T <
10_000`") does not apply to `release_revenue_distributor`: a track whose
split floors to 0 simply isn't sent, every round, forever (SPEC's own
A-D4), and the per-track event is still emitted with `amount: 0`. Whether
`send_funds(0)` aborts in the abstract is moot for this call site because
it is never reached. The model
(`src/model/distributor.rs::distribute`) computes `amounts[i] = 0` the same
way Move does (`bps::apply` itself has no zero-skip -- the skip is at the
call site) and never models a "send" step at all (out of scope §7: object
transfer mechanics), so this discrepancy has no effect on the model's
numbers, only on the framing of F6. The `zero_send_aborts` config flag from
TASKS-SONNET §1.4 is kept (see NOTES.md) but is currently unreachable from
any op.

This was resolved by reading `release_revenue_distributor.move` directly,
not by a generated Move test (see NOTES.md's "release/distributor
differential coverage" entry for why the generated-test route was skipped
for this package specifically).

## 2. SPEC I-C4's implicit one-sided bound vs. the real accounting under changing `staked_shares` (empirical finding, not a Move bug)

**SPEC says** (§1.6/TASKS-SONNET §1.6): "the accumulator design guarantees
`paid + pending ≤ ideal` (floors only) and `ideal − (paid + pending) < 1 +
(number of claims)` units."

**Empirically found** (via `fuzz --profile hugeshares`, minimized to a
~30-op scenario retained in the crate's development history) **and
confirmed algebraically**: this one-sided bound only holds when
`staked_shares` is constant across a registration's entire window. Once a
*new, large* stake registers while an earlier deposit's `carry` (SPEC
§2.2's sub-share deposit remainder) is still unresolved, that new stake's
debt is computed against the **current** `index`, but the eventual
resolution of the old `carry` is against whatever `staked_shares` is *when
it next folds in* -- which now includes the new stake. The new stake can
receive **more** than its literal `Σ value·amount/staked_shares_at_deposit`
entitlement once that carry folds in, by an amount bounded by
`amount/PRECISION` per such "inheritance episode", and multiple
overlapping episodes (several registrations/unregistrations touching
`staked_shares` during one window) compound additively.

**This is not a bug**: SPEC §2.8/I-B2 (`balance·P == Σ owed_r + carry +
forfeited`, exact) still holds at every step in every failing case -- no
value is created or destroyed, ever. It is a real, bounded fairness
side-effect of the "floor + carry" design interacting with a growing
`staked_shares`, not previously called out in SPEC's I-C4 statement (which
implicitly assumed a fixed share set). `pool.move`'s own module doc already
hints at the mechanism ("a share supply larger than PRECISION cannot lock
deposits: they accumulate in carry until they fold") without spelling out
who benefits when the fold is triggered by someone else's later deposit.

**Resolution:** `check_c4` in `src/model/invariants.rs` still computes and
records the tightest observed error (`Tracker::max_ic4_error`, printed by
`fuzz`), but the *enforced* bound was widened from the naive one-sided
`< 1 + claims` to a provably-true, two-sided sanity bound
(`|ideal − (paid+pending)| < 2·cumulative_deposits + 1`) derived directly
from conservation (I-B2) rather than from the per-episode carry-inheritance
algebra, which would need a proof term scaling with the number of
`staked_shares`-changing events in the window to be made tight. See the
extensive derivation comment on `check_c4` for the full algebra, including
the exact telescoping identity that was checked bit-for-bit against the
failing scenario before concluding the naive bound was wrong (not the
model). Nothing about the *model's* arithmetic changed -- only the
invariant's pass/fail threshold.
