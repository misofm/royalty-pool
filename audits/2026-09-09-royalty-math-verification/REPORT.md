# Royalty math verification report — 2026-09-09

Campaign driver: Opus. Inputs: `SPEC.md`, `TASKS-OPUS.md`, Sonnet's `royalty-sim/`
handoff (`NOTES.md`, `DISCREPANCIES.md`, `README.md`), `PROVER.md`.
Reproduction manifest: `CORPUS.json`.

**This revision incorporates the independent verification pass (`VERIFICATION.md`).** That
pass replayed the campaign bit-for-bit and confirmed its findings, but it also corrected
this report in four places and refuted two of its claims. All are applied below and marked
inline: **V1** (the stake-size error bound is false without its fixed-share-set qualifier —
an 18-unit counterexample on a 1-share stake), **V2** (`MAX_TRACKS = 255`, so every
1024-track figure described an input the chain rejects; `R ≤ 254` on chain), **A1**
(accumulator identity (a) was never actually wired into the checker, so the 88M-operation
campaign enforced identity (b) alone), **A2** (`carry` and `cumulative_deposits` were never
asserted differentially), and a precision fix to the prover claims (§Prover). Both code
omissions are now closed and everything was re-run; the corrected numbers are the ones
reported throughout.

## Verdict

**Solid — no defect was found in the Move royalty math.** Across every method applied
(a bit-exact Rust model, an independently written Python oracle, **88 000 000 fuzz
operations** across 44 000 runs under five profiles, **231 differential scenarios** executed
on the real Move VM with **zero disagreements**, four function-level prover specs, and a
hand-written Move reproducer at the u64 boundary) the accumulator conserved
value **exactly** at every step: `balance·P == Σ owed + carry + forfeited` never
deviated by a single P-unit, solvency (`balance ≥ Σ claimable`) never failed, and no
claim ever failed for a registered stake. The one unchecked narrowing on the money path
(`calculate_reward`'s `as u64`, SPEC F4) was exercised at its exact maximum against real
Move and does not truncate. Every abort observed under stress was a genuine `u64`
`Balance::join` overflow — Move aborts, it never wraps.

All 14 findings below are therefore **SPEC defects, design properties, or tooling defects —
not Move bugs.** This conclusion survived an adversarial independent replay, which found no
result-affecting deviation between the model and Move and no counterexample to the
conservation identity — while correcting four of this report's own claims (see the note
above). Three findings matter: SPEC's I-C4 rounding bound is stated
wrongly in two independent ways (F1, F2), SPEC's I-C2 claim that split deposits are
*not* bit-identical to a single combined deposit is **false** (F4 — the carry makes
deposit folding exactly associative), and the timing of a routed sweep is economically
significant in a way SPEC understates (F5: delaying a sweep can transfer an unbounded
fraction of accrued rewards to stakers who join in the interim). None of these lose
funds; all of them affect what the system can be *claimed* to guarantee.

Two of the handoff's own artefacts were defective and were fixed before the campaign
ran (F9, F10): the fuzzer was wasting 80% of its operations on guaranteed-abort no-ops,
and the enforced I-C4 invariant was vacuous. Both are why this campaign's numbers are
not comparable to Sonnet's. Two further gaps — this time mine — were caught only by the
independent pass (A1, A2) and are now closed.

**One gap is not closed by any of this:** the funded address-balance redemption paths
(`redeem_all_and_distribute`, `sweep_and_deposit`) cannot execute in the Move unit VM and
are not covered by a scripted test anywhere. See "Residual gap" in Scope. Until that has a
localnet E2E, "rock solid" applies to the arithmetic, not to the end-to-end money path.

## Scope

| Package | Revision | Role |
|---|---|---|
| `royalty_pool` (`pool.move`, `stake.move`) | `18c55f623a9a709fea9d999cc995d29fd0266332` | accumulator pool — **fully modeled and differentially tested** |
| `routed_stake` (`routed_stake.move`) | `950daa98c1dc441cabbe2ed7dd772b02ba3d96df` | sweep/park/route — **modeled; `register`+`sweep` differentially tested** |
| `musicos` (`release.move`) | `4cb3c926b1f9bb5103f3f7194e4e1e34b6c87840` | split-sum rule — read only |
| `musicos-actions` (`release_revenue_distributor`) | `7e96810f82f9db16cf903dca364bca6614fa0e70` | Stage A split — **modeled; NOT differentially tested (see F11)** |

`sui` 1.78.1-722ac4fcf484. Both Move source trees under `royalty-sim/move/` were verified
byte-identical to the `github-root` checkouts (`diff -r ... /sources`) before the campaign.
No Move package was modified. The only files written under `royalty-sim/move/` are
generated tests in `routed-stake/tests/gen/`.

**Not modeled** (inherited from TASKS-SONNET §7, re-affirmed): gas, object ownership and
transfer, permission checks (`assert_derived_from` is always-true except one model-only
negative), the crank service and PTB packing, and real address-balance settlement timing
(parked funds settle immediately).

### Residual gap: the funded address-balance paths are never executed

**This is the largest remaining gap and it is not closed by anything in this report.** Two
functions on the money path have a funded success case that **cannot run in the Move unit
VM at all**:

- `release_revenue_distributor::redeem_all_and_distribute` — needs a non-zero settled
  balance on the Release's address;
- `royalty_pool::pool::sweep_and_deposit` — needs a non-zero
  `balance::settled_funds_value` on the pool's address.

The unit VM never populates a positive settled-funds snapshot, so in every test — the
package's own suite (which says so in a comment in `royalty_pool_tests.move`), Sonnet's
generated tests, mine, and the verifier's — these paths can only be exercised on their
**abort** branches (`ENoSettledFunds = 7`, and the zero-balance no-op). The campaign's
`sweep_and_deposit` success path is a **substitution**: `movegen` proxies it through
`receive_and_deposit`, which reduces to the identical `pool::deposit` call *after*
redemption. That substitution is sound for the arithmetic and says nothing about redemption
itself.

So what remains untested by execution is: `settled_funds_value` capping at `u64::MAX`,
snapshot timing (a sweep in the same consensus commit as the send sees 0 and aborts 7 — a
retry, not a loss), the u128→u64 redemption chunking, and the interaction of all three with
the crank. **These need a scripted localnet or testnet E2E**; the arithmetic downstream of
redemption is what this campaign covers.

They have been exercised **once, by hand, on testnet** — the "Between the Doors" release:
distribution through the app, the resulting recording-pool deposits, and four routed sweeps,
in digest `3NwduZ4n6Zw93tjYmdRBWsJHSgxpnQyfSV6drf7bz1mG`. That is a real end-to-end
execution and it worked, but it is **one manual observation, not a scripted, repeatable
test**: it is not replayable from `CORPUS.json`, it asserts nothing automatically, and it
covers one shape of input. It should not be counted as coverage, only as evidence that the
path is not fundamentally broken.

Additionally **not covered by generated scenarios**: Stage A (`release_revenue_distributor`)
has no `movegen` support — see F11(a). That gap is now largely closed by 10 hand-written
Move tests contributed by the independent verification pass (see "Differential runs"), which
execute `distribute` on the real VM for the 1-bps dust boundary, the 255-track vector at
`T = 10 000` and `T = u64::MAX`, a three-way split at `u64::MAX`, and remainder
recirculation.

## Invariant table

| ID | Statement | Method | Runs | Violations | Notes |
|---|---|---|---|---|---|
| I-A1 | `T == Σ amount_i + R` | sim + Python oracle + **10 Move tests** | 60 018 distributions (incl. T=1..20 000 sweep, 255-track) | 0 | now differentially covered — see F11(a) |
| I-A2 | `R < n` | sim + oracle + Move | same | 0 | on chain `n ≤ 255` so **`R ≤ 254`**; max observed 77 at n=255, and 42 at `T = u64::MAX` (asserted on Move) |
| I-A3 | floor monotone in split | oracle | 7 split vectors × T sweep | 0 | trivially true of `⌊T·s/10⁴⌋` |
| I-B1 | solvency `balance ≥ Σ claimable` | sim (every op) + diff | 88M ops, 231 diff scenarios | 0 | never once fired, incl. at `balance == u64::MAX` |
| I-B2 | **exact** `balance·P == Σ owed + carry + forfeited` | sim (every op) + diff | 88M ops | 0 | exact equality in P-units, not a bound |
| I-B3 | `amount·index ≥ debt` | sim + prover | 88M ops | 0 | proven at function level (`claim_specs`) |
| I-B4 | `carry < staked_shares@last_deposit` | sim + prover | 88M ops | 0 | proven (`deposit_spec`) |
| I-B5 | index monotone | sim + prover | 88M ops | 0 | proven; index *can* stay equal when `staked_shares > value·P` — observed |
| I-B6 | `paid + pending == ⌊amount·Δindex/P⌋` | **sim, exact identity** | 88M ops | 0 | newly enforced this campaign; see F2 |
| I-B7 | no overflow | sim + diff | 88M ops | 0 | max `amount·index` observed **180 bits** (u256 has 76 bits spare) |
| I-B8 | `forfeited < P · unregisters` | sim | 88M ops | 0 | observed max 98 whole units forfeited per pool |
| I-B9 | claim idempotence | sim + diff + prover | 10 000-claim scenario, diff at 60 | 0 | proven (`claim_specs`) |
| I-B10 | late-joiner isolation | sim + **diff** | `01-sandwich` | 0 | verified on real Move |
| I-B11 | unregister only at `claimable == 0` | sim + diff | `05`,`06`,`12`,`03` | 0 | abort 5 confirmed on Move |
| I-B12 | deposit with no stakers aborts | sim + diff | `07-deposit-no-stakers` | 0 | abort 1 confirmed on Move |
| I-C1 | sweep conservation | sim + diff | `06a/06b`,`07a/07b`,`09` | 0 | `claimed == deposited + parked` |
| I-C2 | delayed sweep loses nothing | sim + **diff** | `06a`/`06b` + 24 000 random configs | 0 loss | **but SPEC's statement is wrong twice — F4, F5** |
| I-C3 | parked funds recoverable | sim + diff | `07a`,`07b` | 0 | 725 of 725 recovered |
| I-C4 | end-to-end floor composition | **sim, exact closed form** | 88M ops | 0 | SPEC's bound is wrong — F1; exact form in F2 |

## Findings

### F1 — SPEC's I-C4 bound is wrong: it is one-sided, and stakers can be *over*-paid relative to pro-rata
**Severity S3** (design property + SPEC defect; no funds at risk). **SPEC ref:** I-C4, and
`DISCREPANCIES.md` #2, which I re-derived independently and **confirm**.

SPEC states `paid + pending ≤ ideal` with `ideal − (paid+pending) < 1 + claims`. The
first inequality is false. `register_stake` computes a new stake's debt against the
*current* `index`, but a deposit's sub-share remainder sits in `carry` and is folded in
against whatever `staked_shares` is when it *next* folds — which may now include that new
stake. A stake can therefore collect a share of a remainder accrued before it existed.

Observed maximum deviation over the full 88M-operation campaign: **34.45 units**
(`stress`) and **29.99 units** (`hugeshares`), against `max_ic4_error` of exactly **1 unit**
for `realistic`, `churn` and `dust`.

Note that 34.45 **exceeds** `u64::MAX / P = 18.45`, the bound for a *single*
carry-inheritance episode. That is the campaign confirming the compounding prediction
directly: when several registrations and unregistrations move `staked_shares` during one
stake's window, each contributes its own episode and the errors add. The Abel-summed form
of `ΔCD` (see F2) picks up one bounded term per share-set change; the campaign's largest
observed `|ΔCD|` was **6.97 × 10¹⁸** (`stress`). So there is **no fixed constant** bounding
the I-C4 error independent of how many times the share set changes — SPEC's `< 1 + claims`
is wrong in form, not merely in magnitude.

What *does* bound it: the effect is governed by `amount/P` per episode, so it is invisible
(under one unit, total) for any stake of at most `P = 10¹⁸` shares regardless of episode
count, and `realistic`, `churn` and `dust` — every profile with SPEC §5's realistic
magnitudes (≤ 10¹³ shares) — measured exactly **1 unit**, the single sub-unit floor and
nothing more. **Only pools whose total stake exceeds 10¹⁸ shares can observe this at all.**

Not a Move bug: conservation (I-B2) holds exactly in every failing case. It is a real,
bounded fairness perturbation of the floor+carry design that SPEC's I-C4 statement, which
implicitly assumed a fixed share set, does not admit.

*Scenario:* `royalty-sim/scenarios/adversarial/02-whale-dilution-zero-increment-modelonly.json`,
plus `fuzz --profile hugeshares`. *Move reproducer:* `02d-whale-dilution-diff` (AGREE).

### F2 — SPEC's I-C4 `+ number of claims` error term is unnecessary; the true relation is an exact closed form
**Severity S3** (SPEC defect — the bound is *looser* than reality). **SPEC ref:** I-C4, I-B6.

SPEC budgets one unit of error per claim. That is wrong: claiming is free. `claim_rewards`
adds `reward·P` to `debt` (`pool.move:330`), retaining each claim's sub-unit residue, so

> `paid + pending == ⌊amount · (index − index_at_registration) / P⌋`

holds **exactly and independently of claim count** (this is I-B6, now enforced bit-for-bit
after every op — it was not checked at all in the handoff). Combining it with the deposit
fold's exact identity gives the whole story in closed form:

```
ideal_index − carry_drift/P == index/P                      (per pool, exact)
paid + pending == ⌊ideal_r − (amount/P)·ΔCD⌋                 (per registration, exact)
```

where `carry_drift := Σ_k (carry_k − carry_{k−1}) / S_k`. The *entire* deviation of a
staker's payout from exact pro-rata is therefore `(amount/P)·ΔCD + frac`, `frac ∈ [0,1)`
— one sub-unit floor, plus a term that is zero unless `staked_shares` changed mid-window.
For a window with a fixed share set, `|ΔCD| < 1`, so the error is `< 1 + amount/P` and
**a staker of at most `P` shares is never off by as much as 2 units, no matter how many
deposits or claims occur.** That qualifier is essential — dropped, the sentence is false;
see the Quantitative section's correction V1 for an 18-unit counterexample on a *1-share*
stake, reproduced on Move.

**Correction (A1): only identity (b) was actually enforced during the 88M-operation
campaign.** `check_accumulator_identity` was written and derived, but was reachable only
through a wrapper (`check_c4_exact`) that nothing called — `check_pool` invoked
`check_c4_exact_regs` directly and skipped it. An earlier draft of this report claimed both
identities "held over all 88 000 000 operations"; that was true of **(b) alone**. The
independent verification pass caught it.

Now closed: the call is wired into `check_pool` (`invariants.rs`), and with identity (a)
enforced after **every op of every pool** everything was re-run — **248/248 scenarios pass,
all five gate-4 fuzz profiles report 0 failures, and the full 88 000 000-operation campaign
was re-run from scratch** (see "Fuzz runs"). It holds, as the derivation requires.

One caveat on what (a) is worth: unlike (b), it is a *definitional* consequence of the two
ghosts being accumulated from the same `(v_k, S_k, carry_k)` the model's own `deposit`
produced, so it can only fail if that division stops being Euclidean — a silent wrap, already
excluded by the checked arithmetic. It is a strong guard against a **model** regression and
says nothing directly about Move. The statements that bear on Move are (b), enforced
throughout, and the prover's per-deposit form of (a), proved against the real bytecode
(`deposit_spec`).

*Implementation:* `royalty-sim/src/model/invariants.rs::check_accumulator_identity`,
`check_c4_exact_regs` (full derivation in the doc comments).

### F3 — Model defect: the `paid` ghost was `u64` and aborted claims that Move executes
**Severity S4** (model defect, found and fixed). Every `claim` abort under the `stress`
profile — 101 of them in a 30-case sample — was the *model's* `paid` ghost overflowing
`u64`, a field with no on-chain counterpart. Move's `claim_rewards` succeeds there. The
model was silently truncating its own stress coverage. Widened to `u128` (a registration's
lifetime payout is bounded by the pool's `u128` `cumulative_deposits`, not by `u64`).
After the fix, **every** remaining abort under `stress` is a genuine `Balance::join` u64
overflow (verified by instrumenting each `checked_*` site individually) — never a silent
wrap, which is exactly what SPEC I-B7 asks for.

*File:* `royalty-sim/src/model/stake.rs` (`Registration::paid`).

### F4 — SPEC I-C2 is wrong: deposit folding **is** exactly associative
**Severity S3** (SPEC defect — the real guarantee is *stronger* than stated).

SPEC I-C2 states, parenthetically and emphatically, that late and eager sweeping are
"**not** bit-identical: depositing 3+4 into the child is not the same as depositing 7 for
the child's per-share floors". This is false. The carry makes the fold exactly
associative: after any sequence of deposits, `index·S + carry == Σ value·P + carry₀` with
`carry < S`, which has a unique solution — so the resulting `(index, carry)` depends only
on the *total* deposited, not on how it was split.

Verified three ways: algebraically; on the literal 3+4-vs-7 example SPEC cites (identical
index, carry, and both stakers' rewards); and over **20 000 random configurations**
(1–5 stakers, 2–6 deposits, values to 10⁹) — **zero counterexamples**. The consequence:
SPEC's simulation requirement "`|late − eager| ≤ 1 unit per staker per sweep`" is satisfied
with the difference identically **0**, provided the child pool's share set does not change
between the sweeps.

*Scenarios:* `06a-routed-eager-sweep` / `06b-routed-late-sweep` (both AGREE on Move; identical
per-staker pendings `[1, 2, 4]`).

### F5 — Sweep *timing* is economically significant: a delayed sweep pays stakers who joined after the rewards were earned
**Severity S3** (design property, operationally important; no funds lost).
**SPEC ref:** I-C2, I-C3, F1.

F4's associativity holds only while the child's share set is fixed. Once a stake registers
in the child pool *between* two sweeps, eager and late sweeping diverge — and not at
rounding scale. In a 20 000-case search the worst case found was:

| | child stakers `[1, 9]` | late joiner (20 shares) |
|---|---|---|
| eager (sweep after every deposit) | `136`, `1224` | **0** |
| late (one sweep at the end) | `45`, `408` | **907** |

A **907-unit** swing on ~1360 units distributed. The mechanism is exactly the design
property SPEC already documents for *parked* funds (I-C3: parked funds are split by shares
at `sweep_and_deposit` time, not at park time) — but it applies to **every** delayed sweep,
not just the cold-start case, and SPEC's I-C2 wording ("Sweeping late yields the same total
as sweeping after every deposit, modulo the child pool's own floor/carry") materially
understates it. The child pool has no notion of when a reward was *earned*; it splits what
arrives, when it arrives, among whoever is registered then.

Conservation holds throughout (I-C1/I-B2 verified in both arms). **Recommendation for the
crank:** treat sweep cadence as a fairness parameter, not an optimisation. Sweeping before
admitting new child registrations, or on a fixed schedule, makes the outcome predictable;
an unswept backlog is a standing incentive to register into a composition pool just before
a large sweep.

I also confirmed the narrower parked-funds case directly on Move: three sweeps park 725
units into a stakerless child; registering **two** stakes (10 and 30 shares) before
`sweep_and_deposit` splits the 725 as **181 / 543** — pro-rata at sweep time, with neither
having been registered when any of it was earned.

*Scenarios:* `07a-parked-then-one-staker`, `07b-parked-then-two-stakers` (both AGREE on Move).

### F6 — SPEC A3 is wrong: the distributor *does* skip zero sends (confirms handoff DISCREPANCIES #1), and A4 has the same defect
**Severity S3** (SPEC defect). SPEC A3 says the per-track loop sends "including when
`amount_i == 0` (no zero-skip in the loop)". `release_revenue_distributor.move:95-97`
reads `if (amount > 0) { revenue.split(amount).send_funds(...) };` — there is a zero-skip.
I confirm Sonnet's DISCREPANCIES #1 by direct reading. **Additionally, and not previously
recorded:** SPEC A4 says the remainder "is sent back to the Release's own address balance"
unconditionally, but the same function guards that too — `if (remainder > 0) { ...
send_funds ... } else { revenue.destroy_zero() }`. Neither affects any number.

Consequently SPEC's open question **F6 is resolved: it does not arise.** `send_funds(0)` is
never reached on this path, so a 1-bps track cannot make a release un-distributable.
Instead the track simply receives nothing that round (SPEC's own A-D4), and the dust
accrues on the Release (A-D2).

**The crank's dust floor of 10 000 is exactly right and exactly tight**: for the split
vector `[9999, 1]` the minimum `T` at which the 1-bps track receives ≥ 1 unit is
**precisely 10 000** (swept over `T = 1..20 000`, all 20 000 rounds agreeing with the
model). In general `min T = ⌈10 000 / min_nonzero_split⌉`.

### F7 — Churn cannot be used to extract value; it is strictly self-harming
**Severity S3** (confirms SPEC F3 quantitatively). 1 000 cycles of
`deposit(1) → claim → unregister → register` with a 3-share churner against a 1 000-share
holder forfeited **2.991026919242273178 units** total — matching the analytic prediction
`1000 × 3/1003 = 2.9910…` to the last P-unit — while the churner was **paid 0**. Forfeited
value stays in `balance` where no one can claim it (dead balance); the churner pays for
the privilege. I-B8's bound (`forfeited < 1 unit per unregister`) held with three orders of
magnitude of headroom. I-B2 held exactly throughout.

*Scenarios:* `03b-churn-forfeit-1000-modelonly` (model), `03-churn-forfeit-15` (AGREE on Move).

### F8 — Splitting a stake in two costs at most **1 unit, ever** (not 1 unit per deposit)
**Severity S3** (design property; SPEC/TASKS bound is far looser than reality).
TASKS-OPUS §2.5 asks for the exact bound on merged-vs-split payouts. It is:

> `merged − split == ⌊2z⌋ − 2⌊z⌋ ∈ {0, 1}`, where `z = a·Δindex/P`

— because two equal registrations opened at the same index each floor the *same* `z`.
The difference therefore **does not accumulate with the number of deposits**: it is 0 or 1
for the whole lifetime of the position, so long as neither half claims or unregisters
(claims don't matter — F2 — but an unregister forfeits its residue and does).
Verified over **30 000 random configurations** (amounts to 10⁹, 1–8 deposits): observed
values exactly `{0, 1}`, zero violations. The natural guess "< 2 units per deposit" is
correct but off by a factor of the deposit count.

*Scenarios:* `05a-merged-single-1000` (1023 units) vs `05b-split-two-500` (511+511 = 1022),
both AGREE on Move.

### F9 — Handoff defect: the fuzzer wasted ~80% of its operations on guaranteed-abort no-ops
**Severity S4** (tooling defect in the handoff, fixed). `fuzz.rs` never decremented
`total_registered` when a stake unregistered, so a profile's `supply` cap was consumed
monotonically. Once exhausted, `register` became permanently unavailable; with no live
stakes, every other op kind was also unavailable, and the generator's fallback was a
`receive_and_deposit` that aborts `ENoStakedShares` every single time. Measured abort
rates before the fix: **realistic 80%, hugeshares 89%, stress 71%**. The `realistic`
profile was effectively exercising one or two stakers and then idling.

Fixed by releasing shares back to the cap on unregister and by falling back to `register`
(not `deposit`) when the pool is empty. After the fix: **0% wasted ops** on realistic,
churn, dust and hugeshares; `stress` retains a 28% abort rate that is entirely intentional
`u64`-boundary probing. This is why the campaign's coverage is not comparable to the
handoff's gate-4 numbers, which were run against the defective generator.

I also strengthened the `dust` profile, which TASKS-OPUS §1 specifies as exercising
"value=1 deposits" but which drew `value == 1` only once in 10 000; a third of its deposits
are now exactly 1 unit.

### F10 — Handoff defect: the enforced I-C4 invariant was vacuous
**Severity S4** (tooling defect, fixed by replacement). `check_c4` enforced
`|ideal − (paid+pending)| < 2·cumulative_deposits + 1`, a bound that (as its own doc comment
concedes) is "trivially, unconditionally true by conservation". Since both quantities are
individually at most `cumulative_deposits`, the check could not fail for *any* arithmetic
whatsoever short of a sign error — it was not testing the rounding behaviour it was named
for. Replaced with the exact closed form of F2, which is falsifiable at the P-unit level.
`max_ic4_error` is still recorded for reporting, now derived from the same `ΔCD` rather
than recomputed.

### F11 — Tooling gaps: Stage A had no differential coverage (now largely closed); one oversized scenario silently poisoned an entire differential batch; and `carry` was never asserted
**Severity S4** (tooling). Two distinct issues.

**(a)** `movegen` cannot generate Move tests for `release_new` / `release_fund` /
`release_distribute` (it errors naming the op), so Stage A — the `release_revenue_distributor`
split — was **not** checked against the Move VM anywhere in the original campaign. Its
results rested on the Rust model, my independent Python oracle, and direct source reading,
which agree exactly on 60 018 distributions.

**Largely closed.** The independent verification pass wrote the fixtures I had deferred and
contributed `fable_stage_a_tests.move` — **10 tests, all passing** against a scratch copy of
the real `release_revenue_distributor` package (whose own suite also passes, 11/11). They
execute `distribute` on the real VM for: the 1-bps track at `T ∈ {1, 9 999, 10 000, 10 001}`
(confirming the dust boundary is exactly 10 000 and that a zero-floor track is never sent);
the 255-track vector `[9746, 1×254]` at `T = 10 000` and at `T = u64::MAX` (remainder **42**,
conservation exact); a three-way `[3334, 3333, 3333]` split at `T = u64::MAX`; and remainder
recirculation across three successive distributions (A-D2 on real chain semantics). Every
value matches the Rust model and the Python oracle.

Two of the ten are harness probes rather than distributor tests, and worth recording so
nobody misreads them: sending twice to one address **within a single transaction** past
`u64::MAX` raises an arithmetic error in `sui::funds_accumulator` (the test VM merges an
address's pending funds in u64), whereas the production shape — funds settled in an earlier
commit, redemption as a split — is fine. That is a property of the test harness, not a
distributor defect.

What remains uncovered is not the split arithmetic but the **funded redemption** that feeds
it — see "Residual gap" in Scope.

**(b)** A generated test function that overruns Move's 255-locals-per-function budget makes
`move-compiler` **panic** rather than emit a diagnostic, which fails the whole package build
— so every *other* scenario in the same batch was reported as `DISAGREE ... test not found in
output`. My first adversarial batch produced **12 false DISAGREEs** this way. Two fixes:
`diff` now detects the panic and reports a build failure instead of disagreements, and
`movegen`'s density heuristic is now cost-aware (it counted ops, not `assert_eq!` call sites,
so a 10-op scenario with full assertions could still overrun at 262 locals — `05a` did).
The practical ceiling is **~85 ops per generated scenario**; scenarios above it are marked
`-modelonly` and paired with a diff-sized twin. This also caps TASKS-OPUS §3's "≤ 200 ops"
fuzz-derived scenarios, which were run at **60 ops** each.

**(c) Correction (A2): `carry` and `cumulative_deposits` were never asserted
differentially.** Both are public accessors (`pool.move:382`, `:387`) and SPEC §4 explicitly
asks for `carry` to be asserted when it is exposed, but `assert_pool_state` asserted only
`balance`, `staked_shares`, `cumulative_reward_per_share` and per-stake `pending_rewards`.
A wrong `carry` after a scenario's **last** deposit was therefore invisible to the entire
differential corpus — the one piece of pool state that the floor/carry design turns on.
Caught by the independent verification pass, not by me.

Now closed: both accessors are asserted at every `Full` site. Because each full assertion
costs two more of Move's 255 local slots, the density budgets had to drop with them
(`SITE_BUDGET` 30→20, `ASSERT_SITE_BUDGET` 16→12) — without that, three batches failed to
*build* at 266/266/256 locals. The whole corpus was re-run with the assertions in place:
**239 AGREE, 0 DISAGREE, 1 SKIP across 225 `carry()` and 225 `cumulative_deposits()`
assertion sites** (hugeshares scenarios pin carries up to ~1.8×10¹⁹). Nothing was hiding
there, but the campaign could not previously have said so.

Residual granularity, stated plainly: intermediate states in a 60-op scenario are
balance-only roughly every 5th op, with a full state assertion at the last op. An
intermediate disagreement would have to be exactly compensated later to escape the final
check, which is why this is acceptable — but it is weaker than SPEC §4's "assert after
every step".

### F12 — Model deviation (harmless): the model types a basis-point rate as `u64`, Move types it as `u16`
**Severity S4** (model deviation, reported per TASKS-OPUS §0.3's "even one that cannot
matter"). `royalty-sim`'s `distributor::bps_apply(amount: u64, rate_bps: u64)` accepts any
`u64` rate. Move's `bps::BPS` wraps a **`u16`** and `bps::new` asserts `v <= 10_000`
(`EOverflow`), so a rate above 10 000 — or above 65 535 — is unrepresentable on chain.

Consequences: (a) the model would happily evaluate a split vector Move could not
construct, but every scenario now uses a representable vector, so no such input is
supplied; (b) the arithmetic itself matches — both widen before multiplying
(`mul_bps!<u64, u128>` vs the model's `u128` product) and floor at 10 000.

**Corrected (V2).** An earlier draft of this report reasoned that "because each non-zero
split is ≥ 1 bps and the sum is exactly 10 000, a Release can have at most 10 000 tracks".
That bound is real but not binding: `release.move:115` sets **`MAX_TRACKS = 255`**, asserted
at `release.move:230` with `EMaxTracksExceeded = 31` (musicos's own `release_tests.move`
pins 256 → abort). **The model does not enforce this** — a second, separate deviation of the
same kind, and the one that actually mattered, because the campaign's 1024-track scenario
described an input the chain rejects. Replaced throughout with the widest *representable*
dust vector, `[9746, 1×254]` (`09-release-255-tracks-modelonly`). A 1024-track
`new_for_testing` fixture cannot even be distributed in the unit VM — it dies with
`MEMORY_LIMIT_EXCEEDED` in `sui::event` on the per-track events.

I also confirmed `release.move:233` sums the splits as `u16 as u64`, which cannot overflow
for any representable tracklist, matching the model's `u128` sum.

### F13 — SPEC F2 confirmed: unstaking parks rewards safely and restaking recovers them in full
**Severity S3** (design property confirmed, no defect). SPEC F2 asserts that a `RoutedStake`
whose inner stake has been removed cannot be swept, and that a later `restake` finds the
rewards intact. Confirmed end to end in the model (`movegen` cannot emit
`routed_unstake`/`routed_restake`/`routed_unregister`, so this one is model-only):

- `routed_unregister` while rewards are pending aborts **`ELastClaimIndexMismatch` (5)** —
  the routed wrapper inherits `unregister_stake`'s safety (I-B11), it does not bypass it;
- after `routed_unstake`, `routed_sweep` aborts **`ENoStake` (1)**, and the parent pool's
  `staked_shares` is 0 so a further deposit aborts **`ENoStakedShares` (1)** rather than
  being absorbed (I-B12);
- after `routed_restake` + `routed_register`, sweeping resumes normally, and the child
  staker's total pending is **2 100** = 500 + 700 + 900 — every unit deposited across the
  unstake/restake cycle arrives, none stranded.

*Scenario:* `15-unstake-restake-preserves-rewards-modelonly.json`.

### F14 — Model deviation (harmless): `sweep` omits the derivation assert that Move performs twice
**Severity S4** (model deviation, reported per TASKS-OPUS §0.3). Line-by-line review of
`routed.rs` against `routed_stake.move` found the model's `register`, `unregister`,
`unstake` and `restake` all call `assert_derived` first, matching Move's argument order
exactly — but `RoutedStake::sweep` **does not call it at all**, while
`routed_stake.move:210-211` asserts derivation **twice**:

```move
self.assert_derived_from(parent_id);
routed_pool.assert_derived_from(parent_id);
assert!(self.stake.is_some(), ENoStake);
```

Consistent with this, `Op::RoutedSweep` carries no `parent_override`, so the
"sweep with a forged parent" negative case cannot be expressed in the scenario language at
all. This is inside SPEC §7's out-of-scope carve-out (`assert_derived_from` is modeled as
always-true), and it cannot affect any accounting result — but it *is* an asymmetry with
the other four routed ops, and `sweep` is the only permissionless entry point on the routed
path, so it is the check most worth a negative test.

**Correction.** An earlier draft said this case was "covered by neither the model nor a
generated Move test", which invited the reading that the behaviour was untested anywhere.
It was not: `routed-stake`'s **own** suite already contains `sweep_rejects_wrong_parent_id`
and a pool-derivation case (`routed_stake_tests.move:126-160`), both passing. The accurate
statement is narrower — *this campaign's artefacts* did not cover it, and the model still
cannot express it.

**Now closed for the campaign too.** The independent verification pass contributed
`manual-move-tests/fable_f14_sweep_derivation.move` (**3 PASS**, verified in this tree):
an attacker passing a foreign parent id *and* that parent's pool aborts
`ENotDerivedFromParent` in `routed_stake` (`routed_stake.move:212`); passing the correct
parent id but a foreign destination pool aborts `EPoolNotDerivedFromParent` in
`royalty_pool::pool` (`:213`); and a control showing an *honest* sweep submitted by a
stranger succeeds and parks 1 000 units at the right pool — confirming the call is safely
permissionless, which is the actual property that matters.

Everything else in `routed.rs` matches `routed_stake.move` line for line, including the
`reward == 0 → destroy_zero, return` early exit with no event, the park-vs-deposit branch
on `routed_pool.staked_shares() == 0`, and `unstake`'s reliance on `stake::destroy` to
abort while any registration remains.

## Quantitative

**Max rounding error per staker** (`ideal − (paid + pending)`, exact rationals):

| Profile | max error (units) | interpretation |
|---|---|---|
| realistic | **1** | one sub-unit floor; `amount/P` term invisible at ≤10¹³ shares |
| churn | **1** | same |
| dust | **1** | same |
| hugeshares | **29.99** | `amount/P` ≤ 18.45 per episode, compounding across episodes (F1) |
| stress | **34.45** | same mechanism |

**Over a window in which the share set does not change**, the error is
`< 1 + amount/P ≤ 2` units total for a stake of at most `P = 10¹⁸` shares, for any number
of deposits and claims (F2). That bound is **tight** — over 6 000 random fixed-share-set
configurations the observed error reached **0.9995×** it.

**Correction (V1): the fixed-share-set qualifier is load-bearing, and an earlier draft of
this report dropped it.** Stated without it, "any stake of at most `P` shares is off by
< 2 units" is **false**, and the counterexample is not exotic. A whale of `u64::MAX − 1`
shares and a **1-share** minnow are both registered (`S = u64::MAX`); a deposit of 18 gives
`numerator = 18·10¹⁸ < S`, so `index` stays 0 and all 18 units sit in `carry`. The whale
claims 0, unregisters (residue 0, nothing forfeited), leaving `S = 1`. A deposit of 1 now
folds `19·10¹⁸` against a single share: the minnow's pending is **19** against an ideal of
`1 + 18/(2⁶⁴−1) ≈ 1.000000000000000001` — **over-paid by 18 units** on a 1-share stake.
Verified on the real Move VM (`verifier/f6a-whale-leaves-carry-to-minnow`, AGREE, the claim
of 19 asserted). Conservation holds exactly: `19·P = 1·19·10¹⁸`.

So the deviation is **not** governed by the beneficiary's own size. It is governed by the
carry left behind at each share-set change: `< (S_before − 1)/P` units per fold, i.e.
≤ 18.45 at `S = u64::MAX`, accruing to whoever is registered when that carry folds in,
however small they are. **The correct condition is a property of the pool, not the stake:
only a pool whose total stake exceeds `P = 10¹⁸` shares can produce a non-zero carry-drift
term at all.** At SPEC §5's realistic magnitudes (total stake ≤ 10¹³) the term is under
10⁻⁵ units and the three realistic profiles measured exactly 1 unit — the single sub-unit
floor and nothing else.

**Split-vs-merge:** exactly `{0, 1}` units, for the whole lifetime of the position, not per
deposit (F8).

**Forfeited under churn:** max **246 whole units** per pool observed (`churn`, 5000-op
runs; 230 under `dust`, 99 under `realistic`); 1 000 explicit churn cycles forfeited 2.991 units, matching `cycles × amount/S`
exactly. Bound `forfeited < 1 unit per unregister` never approached.

**Carry / index maxima:**

| Quantity | Max observed | Headroom |
|---|---|---|
| `carry` | 18 446 734 875 425 604 552 (hugeshares) | bounded by `staked_shares`; u128 field, ~2⁶⁴ used |
| `index` bit-length | **124 bits** (stress) | u256: **132 bits spare** |
| `amount·index` bit-length | **188 bits** (stress) | u256: **68 bits spare** (SPEC predicted ≤ 252) |
| `staked_shares` | 18 446 744 073 709 551 615 (`u64::MAX`) | at the type limit, reached under hugeshares and stress |
| `balance` | 18 446 704 109 362 994 946 (stress) | within 4×10¹³ of `u64::MAX`; the exact ceiling is verified on Move by `manual_1.move` |
| `\|ΔCD\|` (carry drift) | 6.97 × 10¹⁸ (stress) | the F1/F2 fairness term; `< 1` whenever the share set is fixed |

**Temporarily unclaimable value.** With `staked_shares > P` an index increment can be
zero and value accumulates in `carry`. At any instant, at most `⌊(S−1)/P⌋ + 1` whole units
are unclaimable: 1 unit for `S ≤ 10¹⁸`, 10 units at `S = 2⁶³`, 19 units at `S = u64::MAX`.
Worked example (`02`): a *sole* staker of 2⁶³ shares receiving 10⁶ deposits of 1 unit can
claim **999 997** of the 1 000 000 — 2.0037 units held in `carry` plus a 0.9962-unit
reward residue, conserved exactly (`balance·P == owed + carry`, verified). The value is not
lost; it folds in on later deposits.

**Dead balance.** Value forfeited on unregister is permanently unclaimable. Worked example
(`12`, AGREE on Move): a sole 3-share staker receiving a 1-unit deposit is owed
0.999999999999999999 units, can claim 0, and unregisters — forfeiting the lot. A fresh
3-share staker then registers and a further 1 unit is deposited: it can claim **0**, the
pool holds **2 units**, and total claimable is **0**. Exactly **999 999 999 999 999 999
P-units (0.999999999999999999 units) are dead forever**; the other unit remains claimable
on future deposits.

**Dust starvation thresholds** — minimum `T` for every track to receive ≥ 1 unit,
`= ⌈10 000 / min_nonzero_split⌉`:

| Split vector | min nonzero split | min T | max `R` observed (bound `n−1`) |
|---|---|---|---|
| `[5000, 5000]` | 5000 | 2 | 1 (1) |
| `[3334, 3333, 3333]` | 3333 | 4 | 2 (2) |
| `[2500]×4` | 2500 | 4 | 3 (3) |
| `[9000, 900, 90, 10]` | 10 | 1 000 | 3 (3) |
| `[9999, 1]` | 1 | **10 000** | 1 (1) |
| 20 tracks `[9981, 1×19]` | 1 | **10 000** | 6 (19) |
| **255 tracks `[9746, 1×254]`** (the widest representable: `MAX_TRACKS = 255`) | 1 | **10 000** | 77 (254); **`R = 42` at `T = u64::MAX`**, asserted on Move |

The crank's 10 000 dust floor is exactly the threshold at which a 1-bps track stops
starving, for every vector tested.

## Fuzz runs

Budgets were run **at the sizes TASKS-OPUS §1 specifies**, sharded 4 ways per seed across
30 cores (`--skip` was added for this). Seeds 1..=8 per profile; each seed's case `i` uses
the same derived seed regardless of sharding, so every run is reproducible from
`CORPUS.json`.

**The whole campaign was run twice.** Run 1 (`fuzz-logs-run1/`) enforced identity (b) only —
the A1 defect. Run 2 (`fuzz-logs/`) re-ran all 160 jobs, same profiles, seeds, budgets and
shard offsets, with **identity (a) additionally enforced after every op of every pool**. All
**160/160** jobs exited 0 with **zero violations**, and every shard log is **byte-identical**
to its run-1 counterpart across `profile=` and `telemetry=` lines (160/160 identical) — which
is the expected outcome, since identity (a) is a pure added assertion that never fires and
does not touch the RNG or the op sequence. So the figures below are simultaneously run 1's
and run 2's, and the F2 claim now holds at full scale rather than merely being corrected.

| Profile | `--ops` | `--count` (per seed) | seeds | runs | **ops applied** | expected aborts | **violations** | max I-C4 error (units) |
|---|---|---|---|---|---|---|---|---|
| realistic | 2000 | 2000 | 1..=8 | 16000 | **32,000,000** | 0 (0%) | **0** | 1 |
| churn | 5000 | 500 | 1..=8 | 4000 | **20,000,000** | 0 (0%) | **0** | 1 |
| dust | 5000 | 500 | 1..=8 | 4000 | **20,000,000** | 0 (0%) | **0** | 1 |
| hugeshares | 2000 | 500 | 1..=8 | 4000 | **8,000,000** | 0 (0%) | **0** | 29.99 |
| stress | 500 | 2000 | 1..=8 | 16000 | **8,000,000** | 1,216,920 (15%) | **0** | 34.45 |
| **total** | | | | **44,000** | **88,000,000** | | **0** | |

Per-profile telemetry (TASKS-OPUS §1's required quantities):

| Profile | total `forfeited` (whole units, max/pool) | max `carry` | max `index` bits | max `amount·index` bits | max `staked_shares` | max `balance` | max &#124;ΔCD&#124; |
|---|---|---|---|---|---|---|---|
| realistic | 99 | 9,999,816,070,765 | 101 | **144** | 10,000,000,000,000 | 32,213,388,602,812 | 6.23e+12 |
| churn | 246 | 8,503,244 | 72 | **92** | 8,954,587 | 14,403 | 1.22e+06 |
| dust | 230 | 9,034 | 74 | **83** | 9,501 | 188,672 | 422 |
| hugeshares | 60 | 18,446,734,875,425,604,552 | 18 | **81** | 18,446,744,073,709,551,615 | 29,217 | 822 |
| stress | 29 | 18,446,531,716,969,394,653 | 124 | **188** | 18,446,744,073,709,551,615 | 18,446,704,109,362,994,946 | 6.97e+18 |

**Zero invariant violations across all 88,000,000 operations.** `fuzz-out/` (where a
minimized failing scenario would be dumped) is empty. Every abort counted above is an
expected one: `ENoStakedShares`/`EInvalidValue` preconditions, and — in `stress` — the
`Balance::join` u64 ceiling, verified individually (F3). Note `stress` deliberately
probes the type limits, so its abort rate is the point, not a defect.

Wall-clock: **5 633 s (94 min)** for run 1 and **6 239 s (104 min)** for run 2, all 160 jobs
at 30-way parallelism on 32 cores (~27 core-hours each; run 2 is ~11 % slower, the cost of
the extra big-rational comparison per pool per op). No budget was reduced — every profile ran
at exactly the `--ops` and `--count` TASKS-OPUS §1 specifies, for all eight seeds, in both
runs.

## Differential runs

All batches below were re-run **after** the two strengthenings from the independent
verification pass — identity (a) enforced after every op (A1), and `carry()` +
`cumulative_deposits()` asserted at every full assertion site (A2):

| Corpus | Scenarios | AGREE | DISAGREE | SKIP | Notes |
|---|---|---|---|---|---|
| `scenarios/ported` + `scenarios/handwritten` | 16 | **16** | 0 | 0 | handoff gate 3, re-verified after every model change |
| `scenarios/adversarial` (diff-sized) | 16 | **15** | 0 | 1 | SKIP = `10-u64-balance-limit`, an arithmetic abort `movegen` can't express; covered by a hand-written Move test instead |
| `scenarios/fuzzgen` (§3, 60 ops each) | 200 | **200** | 0 | 0 | 50 each from realistic/churn/dust/hugeshares, seeds 100..103 |
| `scenarios/verifier` (contributed by the verification pass) | 8 | **8** | 0 | 0 | carry-inheritance over-payment, sweep-timing eager/late, whale→minnow (V1), parked+dead residue, 190-bit `amount·index` with u128 `cumulative_deposits`, same-index churn, max carry at `S = P+1` |
| **Differential total** | **240** | **239** | **0** | **1** | across **225** `carry()` and **225** `cumulative_deposits()` assertion sites |
| hand-written Move: `manual_1.move` | 2 tests | **2 PASS** | — | — | u64 balance ceiling + overflow abort |
| hand-written Move: `fable_f14_sweep_derivation.move` | 3 tests | **3 PASS** | — | — | F14 — forged parent id, foreign destination pool, honest control |
| hand-written Move: `fable_stage_a_tests.move` (in `manual-move-tests/rrd/`) | 10 tests | **10 PASS** | — | — | **Stage A on the real VM** — closes most of F11(a) |
| **Move tests total** | **15 tests** | **15 PASS** | — | — | |

The adversarial corpus is 23 scenarios / **74 404 model operations**, all passing with zero
invariant violations. Seven are model-only — above the ~85-op generator ceiling, or using
ops `movegen` cannot emit:

| Scenario | ops | why model-only |
|---|---|---|
| `02-whale-dilution-zero-increment-modelonly` | 2 002 | size; twin `02d` AGREEs |
| `03b-churn-forfeit-1000-modelonly` | 4 002 | size; twin `03` AGREEs |
| `11-zero-claim-idempotence-modelonly` | 10 003 | size (TASKS-OPUS §2.11's literal 10 000 claims); twin `11d` AGREEs |
| `08-release-1bps-dust-boundary-modelonly` | 12 | `release_*` ops — F11(a) |
| `08b-release-1bps-full-sweep-modelonly` | 60 000 | `release_*` ops — F11(a); T = 1..20 000 |
| `09-release-255-tracks-modelonly` | 6 | `release_*` ops in the *scenario language*; the same vector is now covered directly by Move tests — F11(a) |
| `15-unstake-restake-preserves-rewards-modelonly` | 18 | `routed_unstake`/`restake`/`unregister` unsupported by movegen — F13 |

**`sui move test` runtime:** 16 scenarios in **5.4 s**; the 200-scenario fuzzgen corpus in
four batches of 50 in **~4 minutes** total; the full seven-batch re-run with the added
assertions in **~6 minutes**. Well inside the gas meter — no scenario was
reduced for gas, only for the locals ceiling (F11b).

A second, independent differential also ran throughout: every `expect` value in every
adversarial scenario was computed by a **separately written Python re-implementation** of
`pool.move` (`oracle/oracle.py`, written from the Move source rather than from the Rust
model). Rust model vs Python oracle: **20/20 scenarios agree**, including all abort codes.

## Prover

Status copied from `PROVER.md`: **GO**. `sui-prover` v1.5.3 runs locally (Boogie 3.5.7 +
.NET 8 + Z3 4.15.3 under `toolchain/`; the repo's own `prover_setup.sh` installs an
incompatible Boogie 2.15.8). `prover-pool-specs/` verifies against the **real**
`royalty-pool` package in 11.5 s: `deposit_spec` (I-B4, I-B5, and the exact per-deposit
fold identity — which is precisely the per-step form of F2's accumulator identity),
`register_stake_spec` (I-B10, `debt == amount·index`), and `claim_rewards_spec` (I-B3, I-B9,
residue `< P`).

**Extended this campaign (PROVER.md phase P1):** I added
`unregister_specs::unregister_stake_spec`, proven against the real package. What it
genuinely establishes, for unbounded inputs, is the shape of a *successful* unregister:

- the registration is gone afterwards and `staked_shares` drops by exactly the stake's amount;
- `index`, `carry` and `balance` are **untouched** — the residue is forfeited *in place*,
  into `balance`, neither paid out nor destroyed. This is the dead-balance mechanism of F7
  and the Quantitative section, now proven rather than sampled, and it is the substantive
  result of the spec.

**Correction (verification §3.5): this spec does not "prove I-B8".** An earlier draft said
its `amount·index − debt < PRECISION` postcondition was "I-B8's per-unregister bound proven
rather than fuzzed". It is not: the spec **requires** that same inequality as a precondition
(it must — otherwise the target aborts with code 5 and the no-abort check fails) and then
restates it as an `ensures`. That is a tautology, not a proof. I-B8 for the campaign rests
on the simulation, plus the trivial argument that `reward == 0` is asserted by
`unregister_stake` and `reward == ⌊residue/P⌋`, so `residue < P` follows from the guard the
function itself checks. Likewise the **abort** direction of I-B11 (code 5 when a whole unit
is claimable) is established by the differential tests (`05`, `06`, `12`, `03`), **not** by
the prover.

A second, related precision note: `claim_rewards_spec` **assumes** I-B1 —
`requires(reward ≤ balance)`, marked "(assumed)" in the spec — so the invariant table's
I-B1 row rests on simulation and the differential corpus, not on the prover.

All four specs verify in **21 s** (`prover-run-opus.log`). Note the existing `deposit_spec`
already proves `(index' − index)·staked_shares + carry' == v·P + carry`, which is exactly
the per-deposit step of F2's accumulator identity — so F2's per-pool identity is the
inductive closure of an already-proven lemma.

Unchanged assessment of what remains: I-B1 and I-B2 quantify over registrations that live on
`Stake` objects rather than in the pool, so a function-level proof needs a `prover::ghost`
sum plus an `inv_target` datatype invariant — a 1–3 day task. Given that F2 reduced the
whole rounding story to two closed-form identities, the highest-value next prover target is
now the accumulator identity itself (`ideal_index − carry_drift/P == index/P`), which is a
pure statement about `deposit` and needs no ghost over registrations.

## Handoff defects

Re-ran every TASKS-SONNET §6 gate. **All five were green as handed off:**

| Gate | Result |
|---|---|
| 1. `cargo build --release`, `cargo test`, clippy `-D warnings` | green (20 + 1 + 2 tests) |
| 2. `run scenarios/ported/*` | green, 16/16 passed, 0 violations |
| 3. `diff ported + handwritten` | green, **16/16 AGREE** in 5.4 s |
| 4. fuzz realistic 500×200, churn/dust/hugeshares 500×100 | green, 0 failures |
| 5. `README.md` / `NOTES.md` documentation | present and accurate |

Nothing was red, so nothing was escalated. However, two of the artefacts those gates
certify are themselves defective — **F9** (the fuzzer wasted ~80% of its ops, so gate 4 was
far weaker than its numbers suggest) and **F10** (the I-C4 invariant gate 4 checks was
vacuous). Both were fixed before this campaign's runs; all five gates were re-verified green
after every change. A third, **F11(b)**, is why gate 3 had to be re-run repeatedly: the
`diff` harness could report false DISAGREEs.

### My own defects, caught by the independent pass

Two defects in *my* additions to the harness got past me and were found only by the
independent verification. Both are the same species as F9/F10 — a check that looks present
and is not:

- **A1** — I wrote `check_accumulator_identity`, derived it carefully, documented it as one
  of the campaign's two strongest checks, and never wired it into `check_pool`. It sat behind
  a wrapper with no callers for the entire 88M-operation campaign. The lesson is the one F10
  already taught and I did not apply to my own work: *a check must be shown to fail on a
  seeded fault, not merely written.*
- **A2** — I asserted four accessors in the generated Move tests and omitted `carry`, the one
  piece of state the floor/carry design actually turns on, despite SPEC §4 naming it.

Neither was hiding a defect — the strengthened re-run is clean — but neither claim in the
previous revision was true as stated. All five gates were re-verified green after wiring
both in.

`NOTES.md`'s claim that long scenarios get "a cheap `balance().value()` check on every other
op" was inaccurate — the code asserted on *every* op, which is what overran the locals budget.

## Reproduction

**Replay was verified, not merely asserted** (TASKS-OPUS §4: "Fable will replay from this
manifest; if it cannot, the campaign does not count"). Two checks:

- Regenerating the whole 200-scenario `fuzzgen` corpus from the seeds recorded in
  `CORPUS.json` reproduces it **byte-for-byte** (sha256 over the sorted per-file hashes:
  `a18e2ce20e07fcc36e26e3396b1321840c1f8d80fe825c6f162d2a4000c791d7`, identical).
- Re-running a single fuzz shard (`--profile hugeshares --seed 3 --ops 2000 --count 125
  --skip 250`) reproduces its log line exactly, down to the full 113-digit-over-113-digit
  rational `max_ic4_error`. Sharding does not perturb seeds.

All commands from `royalty-sim/`. `SUI` must be an absolute path (the harness `cd`s into
the Move package, so a relative `--sui` breaks). Full per-file hashes, seeds and verdicts
are in `CORPUS.json`.

```sh
R=<this directory>
SUI=$R/../bin/sui                      # sui 1.78.1-722ac4fcf484
cd $R/royalty-sim

# gates
cargo build --release && cargo test --release
cargo clippy --release --all-targets -- -D warnings
./target/release/royalty-sim run scenarios/ported/*.json scenarios/handwritten/*.json

# differential (clear generated tests between batches)
rm -f move/routed-stake/tests/gen/*.move
./target/release/royalty-sim diff scenarios/ported/*.json scenarios/handwritten/*.json \
    --move-root move --sui $SUI                       # expect 16 AGREE

rm -f move/routed-stake/tests/gen/*.move
./target/release/royalty-sim run scenarios/adversarial/*.json
./target/release/royalty-sim diff $(ls scenarios/adversarial/*.json | grep -v modelonly) \
    --move-root move --sui $SUI                       # expect 15 AGREE, 1 SKIP

# §3 fuzz-derived corpus (200 scenarios, 60 ops each)
rm -rf scenarios/fuzzgen
for pair in "realistic 100" "churn 101" "dust 102" "hugeshares 103"; do set -- $pair
  ./target/release/royalty-sim sample --profile $1 --seed $2 --ops 60 --count 50 \
      --out scenarios/fuzzgen
done
for p in realistic churn dust hugeshares; do
  rm -f move/routed-stake/tests/gen/*.move
  ./target/release/royalty-sim diff scenarios/fuzzgen/$p-*.json --move-root move --sui $SUI
done                                                   # expect 200 AGREE

# hand-written Move reproducer (u64 balance ceiling)
(cd move/routed-stake && $SUI move test royalty_sim_gen_manual)   # expect 2 PASS

# independent Python oracle
(cd $R/oracle && python3 -c "import oracle")

# fuzz campaign (160 jobs, 30-way; see CORPUS.json for the exact job list)
xargs -P 30 -I{} -d'\n' bash -c '{}' < $R/fuzz-jobs.txt
```

## 2026-09-10 API revision

Scope: `royalty_pool::pool`'s two funded-recovery entries were replaced —
`receive_and_deposit`/`sweep_and_deposit` (the latter aborting with
`ENoSettledFunds` on an empty snapshot) became `settle`/`recover_coins`, both
total (never abort for "nothing to do"; see the "Royalty Money Path" design
doc, principle 4, and `TASKS-CORE.md` task A). `hikida` was bumped to its
2026-09-09 publish (`c91d6a0f`). No economic behavior changed — this is a
surface/semantics revision (abort → 0-return for the empty cases), not a math
change — so this section re-runs the corpus against the new source rather
than re-deriving any invariant.

**Model and harness changes** (`royalty-sim/src/`): `model/pool.rs`'s
`sweep_and_deposit` became `settle` (checks `staked_shares == 0` first and
returns `Ok(0)` without touching `parked_at_address`, matching the new
guard order; the old `ENoSettledFunds` abort path is gone); the
`receive_and_deposit` model method was removed (its scenario op reduced to
`deposit` already, so scenarios that used it now call `deposit` directly).
`model/world.rs`'s `Op::ReceiveAndDeposit`/`Op::SweepAndDeposit` collapsed to
one `Op::Settle` returning `Outcome::Amount`. `model/abort.rs` drops
`PoolAbort::NoSettledFunds` (7; not renumbered, matching the Move side).
`scenario.rs`'s op parser drops `"receive_and_deposit"` and renames
`"sweep_and_deposit"` to `"settle"`. `movegen.rs`: a genuine `settle` call
(nothing parked in the model) now generates a real `settle(&root)` call
against a real `AccumulatorRoot` and asserts a `0` return with unchanged
balance — the unit VM never populates a positive settled-funds snapshot, so
that's the only real behavior it can generate; a `settle` call recovering a
value the model parked via a routed sweep still can't be reproduced by a
real `settle` call for the same reason, so it keeps proxying through a
direct `deposit` of the same value (previously via `receive_and_deposit`,
now a plain `deposit(balance::create_for_testing(..))`, which is what
`receive_and_deposit` reduced to anyway). `fuzz.rs`'s "sweep" weight bucket
now emits a second `deposit` instead of `receive_and_deposit` (the two were
already bit-identical). `model/routed.rs`'s unit test renamed to
`settle_recovers_parked_funds`.

**Scenario JSON**: every `"op": "receive_and_deposit"` (149 `fuzzgen` files)
became `"op": "deposit"`; every `"op": "sweep_and_deposit"` (`handwritten/10`,
`adversarial/07a`/`07b`, `verifier/f6b`) became `"op": "settle"`, same
`pool`/`value` fields, same economic content. `verifier/f6b`'s final op
previously asserted `{"abort": 7}` on an empty settle; it now asserts
`{"reward": 0}` (a successful no-op), which is the one behavioral
expectation that had to change — everything else in every scenario keeps
its original numbers.

**`royalty-sim/move/royalty-pool/`** (pinned copy): `sources/pool.move`,
`sources/stake.move`, and both test files replaced with the new-generation
originals; `Move.toml`'s `hikida` rev bumped to `c91d6a0f536a5f1457b342a8838fc1d7ba09212e`
(same as the main package). `move/routed-stake/` is untouched (task B); it
still builds and tests clean against the updated local `royalty-pool` dependency
because it never called the two removed functions directly (only in prose).

### Gates re-run (`sui 1.78.1-722ac4fcf484`)

| Gate | Result |
|---|---|
| 1. `cargo build --release`, `cargo test --release`, `cargo clippy --release --all-targets -- -D warnings` | green — 21 + 1 + 2 = 24 Rust tests, 0 clippy warnings |
| 2. `run scenarios/ported/*.json scenarios/handwritten/*.json` | green, 16/16 passed, 0 violations |
| 3. `diff scenarios/ported/*.json scenarios/handwritten/*.json --move-root move --sui $SUI` | green, **16/16 AGREE** |
| 4. `fuzz --profile {realistic,stress,churn,dust,hugeshares} --seed 1 --ops 500 --count 50` (lighter than the original gate-4 counts, per task A5 — see the fuzz table below) | green, 0 failures |
| 5. `README.md`/`NOTES.md` | present; `NOTES.md`'s `receive_and_deposit`/`sweep_and_deposit` notes updated to the new API (`README.md` needed no change — it never named either function) |

### Full corpus re-run (every `scenarios/**/*.json`, 248 files)

`run` over every corpus (`ported`, `handwritten`, `adversarial`, `verifier`,
`fuzzgen`): **248/248 passed, 0 violations.**

`diff --move-root move --sui $SUI`, in the same seven batches as the
2026-09-09 campaign (`CORPUS.json`'s `differential_batches`):

| Batch | AGREE | DISAGREE | SKIP |
|---|---|---|---|
| `ported` + `handwritten` (16) | 16 | 0 | 0 |
| `adversarial`, non-`modelonly` (16) | 15 | 0 | 1 (`10-u64-balance-limit`: arithmetic abort, not representable as `expected_failure` — pre-existing, unrelated to this change) |
| `fuzzgen/realistic-*` (50) | 50 | 0 | 0 |
| `fuzzgen/churn-*` (50) | 50 | 0 | 0 |
| `fuzzgen/dust-*` (50) | 50 | 0 | 0 |
| `fuzzgen/hugeshares-*` (50) | 50 | 0 | 0 |
| `verifier`, non-`modelonly` (8) | 8 | 0 | 0 |
| **Total** | **239** | **0** | **1** |

239 AGREE + 1 SKIP + 8 `-modelonly` (7 `adversarial`, 1 `verifier`:
`f6d-two-routed-stakes-one-child-modelonly`, excluded from `diff` the same
way as the adversarial `-modelonly` files — two routed stakes sharing one
`routed_pool` id isn't representable by `movegen`'s one-dedicated-parent-
per-routed-stake scheme) = 248, exactly reproducing `CORPUS.json`'s
pre-revision `differential_result` (`AGREE: 239, DISAGREE: 0, SKIP: 1`). No
scenario's economic expectation changed except `verifier/f6b`'s last op (see
above), and it still AGREEs.

Five fuzz profiles at `--count 50` (lighter than the §6 gate-4 counts, per
task A5 — the 88M-operation campaign itself was not re-run):

| Profile | Runs × ops | Failures | max I-C4 error |
|---|---|---|---|
| `realistic` | 50 × 500 | 0 | 1 unit |
| `stress` | 50 × 500 | 0 | ≤ 20 units (rational, huge-share regime) |
| `churn` | 50 × 500 | 0 | 1 unit |
| `dust` | 50 × 500 | 0 | 1 unit |
| `hugeshares` | 50 × 500 | 0 | ≤ 22 units (rational, huge-share regime) |

Zero violations across all five. `CORPUS.json`'s per-file `sha256` was
regenerated for the 153 scenario files this revision touched (149 `fuzzgen`
`receive_and_deposit`→`deposit` renames + the 4 `sweep_and_deposit`→`settle`
renames), and `toolchain.royalty_sim_content_sha256` was recomputed over the
full `src`/`scenarios` tree. No other `CORPUS.json` field (verdicts, op
counts, the 88M campaign's own numbers) was touched.

No differential run disagreed; nothing was adjusted to force agreement.

## 2026-09-10 verifier fixes (VERIFY-A F1, F2, and cheap S3s)

An independent verification pass of this PR (`VERIFY-A.md`) found the on-chain
change sound (no S0/S1) but caught two S2 defects in the *harness*, not the
Move package, plus several S3 hygiene notes. Both S2s are fixed here.

**F1 — `movegen`'s `Op::Settle` proxy disagreed with the model when funds
were parked at a pool with `staked_shares == 0`.** The arm branched only on
`parked_at_address == 0`: a positive parked value always took the `deposit`
proxy, even when no stake was registered, generating a real
`p.deposit(balance::create_for_testing(parked))` call that aborts
`ENoStakedShares` — while both the model (`Pool::settle`, which checks
`staked_shares == 0` and returns before ever reading `parked_at_address`)
and the real Move `settle` return 0 and leave the parked value in place.
Fixed by checking `staked_shares == 0` alongside `parked == 0` in
`movegen.rs`'s `Op::Settle` arm, so that case takes the genuine-`settle`
branch (asserting a 0 return and unchanged balance) instead of the proxy.
Added `scenarios/verifier/a1-settle-parked-no-stakers.json` (the verifier's
reproducer): `routed_sweep` parks a reward at a pool with no stakers,
`settle` on it now correctly expects `reward: 0`, a stake then registers,
and a second `settle` recovers the parked value. `run`: 0 violations.
`diff`: **AGREE**. `NOTES.md`'s proxy paragraph amended to describe both
guard conditions and this fix.

**F2 — `CORPUS.json`'s `move_revisions."royalty-pool"` and `residual_gap`
were stale.** The manifest still pinned `royalty-pool` at `18c55f6` (the
pre-revision commit) with a note claiming the pinned copy's sources were
"verified byte-identical to these checkouts; no Move package was modified"
— no longer true once this PR's commits landed. Updated
`move_revisions."royalty-pool"` to `538d48b` (the commit that changed
`sources/pool.move`) and reworded the note to say the copy tracks this
branch's 2026-09-10 API revision, not the pre-revision checkout.
`residual_gap.funded_address_balance_paths` still named
`sweep_and_deposit`; renamed to `settle`.

**S3s addressed:**
- `move/royalty-pool/README.md` and `AUDIT.md` (the pinned copy) now match
  the top-level files (previously the pre-revision copies, still describing
  `receive_and_deposit`/`sweep_and_deposit` as the live API).
- `src/main.rs`'s `cmd_diff` now clears every `*.move` file out of
  `move/routed-stake/tests/gen/` at the start of each invocation.
  `CORPUS.json`'s `hand_written_move_tests[].install` field already
  documented this ("diff clears that directory"); it wasn't true before —
  running the seven documented batches back-to-back in one tree
  accumulated generated modules across batches and the fourth batch onward
  failed to build (`PACKAGE_ARENA_LIMIT_REACHED`), which the tool then
  misreported as a `DISAGREE` for every scenario in that batch. Each batch
  is still its own separate `diff` invocation (a single
  `scenarios/**/*.json` glob still fails a different way — the model-only
  scenarios alone exceed `LOCAL_INDEX_MAX`), but no longer needs a manual
  `rm -f`/`git checkout` cycle between runs within one batch.
- `README.md`'s `diff` section now states plainly that the full corpus runs
  as seven separate invocations (not one glob) and why, and that a
  hand-installed reproducer must be reinstalled after any `diff` run that
  clears it out.

**CORPUS.json**: added a `post_revision_additions` entry recording the new
`a1-settle-parked-no-stakers` scenario (249th entry in `scenarios[]`,
`model_verdict: PASS`, `move_verdict: AGREE`) as a 2026-09-10 addition —
explicitly *not* part of the original campaign's own 248-scenario
`totals`/`headline`/`differential_result`, which are left as the historical
record of that campaign and were not re-run. `royalty_sim_content_sha256`
recomputed.

### Re-run numbers after the fix

```
cargo build --release && cargo test --release && cargo clippy --release --all-targets -- -D warnings
  → build OK; 21 + 1 + 2 = 24 tests pass; clippy clean

diff scenarios/ported/*.json scenarios/handwritten/*.json --move-root move --sui $SUI
  → 16/16 AGREE (gate 3, unchanged)

diff scenarios/verifier/a1-settle-parked-no-stakers.json --move-root move --sui $SUI
  → AGREE a1-settle-parked-no-stakers

diff $(ls scenarios/verifier/*.json | grep -v modelonly) --move-root move --sui $SUI
  → 9/9 AGREE (was 8/8; a1 added), 1 model-only (f6d) still excluded
```

Full corpus is now 249 scenarios (248 + `a1`). Batch totals: ported+handwritten
16/16, adversarial 15/0/1 (unchanged), fuzzgen 50/50/50/50 (unchanged),
verifier 9/9 (was 8/8). New aggregate: **240 AGREE / 0 DISAGREE / 1 SKIP**,
+ 8 model-only = 249. `run` over the full corpus (249 files): 249/249 passed,
0 violations. No differential run disagreed.
