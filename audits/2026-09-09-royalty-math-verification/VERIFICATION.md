# Independent verification of the royalty-pool math campaign — 2026-09-09

Verifier: Fable (adversarial pass over Opus's `REPORT.md` / `CORPUS.json` and Sonnet's
`royalty-sim`). Everything below was executed by me on this machine; every command is given
with its outcome. Root `R` = this directory. `SUI = R/../bin/sui` = `sui 1.78.1-722ac4fcf484`.
Move sources of record (read-only, revisions verified with `git rev-parse HEAD`):
`royalty-pool 18c55f62`, `routed-stake 950daa98`, `musicos 4cb3c926`,
`musicos-actions 7e96810f` (`release_revenue_distributor/sources/release_revenue_distributor.move`).

Files I wrote (all under `R`, nothing outside; the read-only checkouts and `royalty-sim/`
were not modified):

| Path | Purpose |
|---|---|
| `replay/replay.sh`, `replay/replay.log`, `replay/*` | §1 replay of the manifest |
| `fable-scenarios/*.json`, `fable-scenarios/run-all.json`, `fable-scenarios/diff-out/` | §4/§6 scenarios, model + Move results |
| `manual-move-tests/rrd/` | scratch copy of `release_revenue_distributor` + `tests/fable_stage_a_tests.move` (sha256 `cfed525a…484ffc`) |
| `manual-move-tests/move/` | scratch copy of `royalty-sim/move` used for all my `diff` runs |
| `manual-move-tests/fable_f14_sweep_derivation.move` (sha256 `84cb1a51…b8c273`) | §5 F14 tests |
| `fable-sim/` | scratch copy of the crate with two strengthenings (§3.4), its own `target/` |
| `replay/prover-replay.log` | §3 prover re-run |

---

## 1. Replay from the manifest

**Crate identity.** `CORPUS.json` records `royalty_sim_content_sha256 =
564b5834…59a2a8` without saying how it was computed. It reproduces as
`cd royalty-sim && find src scenarios -type f | sort | xargs sha256sum | sha256sum`
→ `564b58340b5b07ae25755a00836a18d734728345f319eb4a5e13778b0f59a2a8` (match). The release
binary (`04:12:48`) post-dates every source file (latest `04:12:44`) and `cargo build
--release` reports up-to-date, so the binary is the manifest's source.

**All 239 scenario files on disk hash to the values in `CORPUS.json`** (0 mismatches;
checked by the Python block in `replay/replay.sh`).

Script: `replay/replay.sh` (log: `replay/replay.log`). Outcomes, in order:

| Step | Command (from `royalty-sim/`) | Result |
|---|---|---|
| Gate 1 | `cargo build --release` | up-to-date, exit 0 |
| Gate 1 | `cargo test --release` | 20 + 0 + 1 + 2 + 0 tests, all `ok` (fuzz proptest 7.9 s, `single_staker_agrees_with_move` 5.3 s) |
| Gate 1 | `cargo clippy --release --all-targets -- -D warnings` | clean, exit 0 |
| Gate 2 | `royalty-sim run scenarios/ported/*.json scenarios/handwritten/*.json` | 16 passed, 0 failed |
| Gate 3 | `rm -f move/routed-stake/tests/gen/*.move; royalty-sim diff scenarios/ported/*.json scenarios/handwritten/*.json --move-root move --sui $SUI` | **16 AGREE** |
| §3 adv | `royalty-sim run scenarios/adversarial/*.json` | 23 passed |
| §3 adv | `diff $(ls scenarios/adversarial/*.json \| grep -v modelonly)` | **15 AGREE, 1 SKIP** (`10-u64-balance-limit`, as recorded) |
| §3 corpus | `sample --profile {realistic,churn,dust,hugeshares} --seed {100,101,102,103} --ops 60 --count 50 --out replay/fuzzgen` (into a fresh directory, not the checked-in one) | 200 files regenerated; **200/200 sha256 identical** to `CORPUS.json` |
| §3 corpus | `diff replay/fuzzgen/<profile>-*.json` × 4 batches | **50 + 50 + 50 + 50 AGREE** |
| manual | `cp manual-move-tests/manual_1.move move/routed-stake/tests/gen/; (cd move/routed-stake && $SUI move test royalty_sim_gen_manual)` | 2 PASS |
| Gate 4 | `fuzz --profile realistic --seed 1 --ops 500 --count 200`; `churn`/`dust`/`hugeshares` `--seed 1 --ops 500 --count 100` | failures=0 each; max I-C4 error 1, 1, 1, ≤22 units (hugeshares) |
| Prover | `source prover-env.sh && sui-prover -p prover-pool-specs` | `Verification successful`, 14.6 s wall (`replay/prover-replay.log`) |

**Fuzz shards** (4, one per profile family, none of them the shard Opus already replayed).
Exact command lines were taken verbatim from `fuzz-jobs.txt` with only the log/out paths
redirected (`replay/shard-*.cmd`):

| Shard | Command | Outcome vs `fuzz-logs/<shard>.log` |
|---|---|---|
| `churn-s8-sh2` | `fuzz --profile churn --seed 8 --ops 5000 --count 125 --skip 250` | **identical** (625 000 ops, failures=0, `max_forfeited_units=233`, `max_carry=7598858`) |
| `stress-s5-sh1` | `fuzz --profile stress --seed 5 --ops 500 --count 500 --skip 500` | **identical**, including the 143-digit/143-digit `max_ic4_error` rational (≤ 26 units), `aborts=37810`, `max_amount_index_bits=188` |
| `dust-s7-sh3` | `fuzz --profile dust --seed 7 --ops 5000 --count 125 --skip 375` | **byte-identical** (`cmp`): 625 000 ops, failures=0, `max_forfeited_units=230`, `max_balance=182665` |
| `realistic-s2-sh0` | `fuzz --profile realistic --seed 2 --ops 2000 --count 500 --skip 0` | **byte-identical** (`cmp`): 1 000 000 ops, failures=0, `max_amount_index_bits=143`, `max_balance=30213838419268` (23 min wall) |

**Replay verdict: the campaign replays.** Gates, differential corpus (231 AGREE, 0
DISAGREE, 1 SKIP), corpus regeneration and fuzz shards reproduce bit-for-bit from the
manifest.

---

## 2. Independent line-by-line check of the model against Move

I compared each Rust function against the Move source myself (not against REPORT's
description of it). Widths, operation order and abort order:

| Move | Rust | Deviation? |
|---|---|---|
| `deposit` (pool.move:198-220): `assert staked_shares>0` (1), `assert value>0` (6); `numerator: u128 = value·P + carry`; `index += (numerator / staked_shares) as u256`; `carry = numerator % staked_shares`; `cumulative_deposits += value` (u128); `balance.join` (u64) | `pool.rs:103-157`: same two checks, same order; `checked_mul/checked_add` for the numerator; `/` and `%` in u128 with `staked_shares as u128`; `checked_add` on index (u256), cumulative (u128), balance (u64) | **None affecting results.** Model checks the index overflow before the cumulative/balance overflow; Move evaluates cumulative (l.213) then `join` (l.214). All are whole-tx aborts mapped to one `Abort::Arithmetic`, so order is unobservable. |
| `register_stake` (255-275): `has_registration` → 2; `debt = (amount as u256)·index`; insert; `staked_shares += amount` | `pool.rs:182-209`: same; `checked_mul` (u256) and `checked_add` (u64) computed before mutation | **None.** Registrations keyed by `u32` instead of `TypeName` — no effect (single currency everywhere; `13-same-currency-second-pool-aborts` AGREEs on abort 2). |
| `calculate_reward` (416-418): `((amount as u256)·index − debt) / P as u64` | `pool.rs:296-303`: `checked_mul`, `checked_sub`, `/ U256(P)`, `u64::try_from` | **None.** |
| `claim_rewards` (313-339): `has_registration` → 3; pool id → 4; `reward`; `debt += reward·P`; `balance.split(reward)` | `pool.rs:246-279`: identical order; `checked_sub` on balance | **None.** `paid` ghost is u128 (F3); not on chain. |
| `unregister_stake` (282-309): → 3; → 4; `reward == 0` else 5; remove; `staked_shares −= amount` | `pool.rs:213-243`: identical; adds the `forfeited` ghost | **None.** |
| `pending_rewards` (345-365): 0 if unregistered / other pool | `pool.rs:283-291` | **None.** |
| `sweep_and_deposit` (241-249): `value = min(u64::MAX, settled u128)`; `assert value>0` (7); redeem; `deposit` | `pool.rs:172-179`: `parked_at_address: u64` → 7 if 0; deposit all | **Two, not result-affecting:** (a) the model's parked queue is u64 with `checked_add` on parking, Move's settled balance is u128 and is redeemed in ≤ u64::MAX chunks — divergence only past 1.8×10¹⁹ units parked at one address (SUI supply is 10¹⁹ MIST); (b) settlement timing modeled as immediate (declared out of scope). |
| `receive_and_deposit` (225-231): `hikida::receive_balance` joins coins (abort on empty vector / u64 join overflow) then `deposit` | `pool.rs:164-166`: takes a value | **None** for the accounting; the empty-vector abort is not modeled (declared). |
| `routed_stake::sweep` (206-234): `assert_derived_from(self)`, `assert_derived_from(routed_pool)`, `is_some` (1); claim; `0 → destroy_zero, return`; `staked_shares()==0 → send_funds(pool addr)` else `deposit`; event | `routed.rs:95-122`: **no derivation asserts** (REPORT F14, confirmed); rest identical. Cross-object atomicity on a failing child `deposit` is provided by `World::apply`'s snapshot (`world.rs:161-168`) — matches Move's whole-tx abort. | **F14 confirmed**; cannot affect a number. Covered instead by Move tests (§5). |
| `distribute` (rrd:86-120): `amount = bps::apply(split, T)` = `floor(T·rate/10⁴)` via `mul_bps!<u64,u128>`; `total_distributed += amount`; `if amount > 0 send`; `remainder = revenue.value()`; `if remainder > 0 send back else destroy_zero` | `distributor.rs:34-78`: same floor in u128; `checked_add`; `remainder = T − Σ` | **Two, not result-affecting:** (a) rate typed `u64` vs `u16 ≤ 10 000` (REPORT F12); (b) **new**: the model does not enforce `MAX_TRACKS = 255` (`release.move:115`, `EMaxTracksExceeded = 31`, asserted at `release.move:230`), so it evaluates split vectors that no Release can have (see §5). Every number it computes for a *representable* vector is Move's number. |

**Result-affecting deviations found: 0.** Non-result-affecting: 5 (currency key; parked
queue width/timing; receive value; F14; bps width + MAX_TRACKS).

---

## 3. Audit of Opus's changes to the handoff

Compared `src/model/invariants.rs`, `src/fuzz.rs`, `src/movegen.rs` against
`NOTES.md`/`DISCREPANCIES.md` (the handoff's description of itself) and REPORT §"Handoff
defects"/F9/F10/F11(b).

### 3.1 `invariants.rs` — what is enforced now

`check_pool` (l.542-556) runs, per pool per op: `check_b1_regs`, `check_b2_regs` (which
also raises `I-B3` on `amount·index < debt`), `check_b4`, `check_b5`, `check_b8`,
`check_c4_regs`, `check_c4_exact_regs`, `record_telemetry`; `check_all` adds `I-A1/I-A2`
on `ReleaseDistribute` and `I-C1` on `RoutedSweep`. **Nothing that the handoff enforced was
removed**: I-B1, B2, B3, B4, B5, B8, A1, A2, C1 are all still live.

- `check_c4_regs` is now an empty stub (l.312-321). The handoff's enforced bound
  `|ideal − (paid+pending)| < 2·cumulative_deposits + 1` **still exists** inside
  `check_c4_exact_regs` (l.492-506) — it was not removed, merely joined by the exact check.
- **Old bound is vacuous — confirmed.** With I-B1/I-B2 holding (checked first in the same
  pass): `paid ≤ cumulative_deposits` (every unit paid was deposited) and
  `pending ≤ balance ≤ cumulative_deposits`, so `paid + pending ≤ 2·cumulative_deposits`;
  and `ideal_r = a·Σ v_k/S_k ≤ Σ v_k = cumulative_deposits` since `a ≤ S_k`. Hence
  `|ideal − (paid+pending)| ≤ 2·cumulative_deposits < 2·cumulative_deposits + 1` for any
  arithmetic satisfying I-B1/I-B2. It cannot fire on its own.
- **New enforced check (b)** — `paid + pending == ⌊a·(index − index_at_registration)/P⌋`
  (l.455-475), per registration per op. Re-derived from Move: `register_stake` sets
  `debt₀ = a·index_j` (pool.move:265); each claim `i` computes
  `r_i = ⌊(a·index − debt)/P⌋` (l.417) and sets `debt += r_i·P` (l.330); so after `n` claims
  `debt = a·index_j + P·Σr_i` and `pending = ⌊(a·index_m − a·index_j − P·Σr_i)/P⌋ =
  ⌊a·Δindex/P − Σr_i⌋ = ⌊a·Δindex/P⌋ − Σr_i` because `Σr_i` is an integer
  (`⌊x − n⌋ = ⌊x⌋ − n`). Therefore `paid + pending = ⌊a·Δindex/P⌋` **exactly, for any number
  of claims, given no overflow** (which the model checks separately). This is a genuine
  theorem about Move's bookkeeping, not a ghost tautology: it is falsified by any
  implementation that, e.g., stored `debt = a·index` after a claim (discarding the residue)
  or rounded the reward up. As a model check it is non-vacuous (`paid` and
  `idx_at_registration` are plain recordings; the right-hand side is an independent
  quantity). **Valid, non-vacuous, and stronger than SPEC's `< 1 + claims` sketch.**
- **Identity (a)** `ideal_index − carry_drift/P == index/P` (`check_accumulator_identity`,
  l.413-428). Re-derived from pool.move:208-212: with `n_k = v_k·P + c_{k−1}`,
  `index_k = index_{k−1} + ⌊n_k/S_k⌋` and `c_k = n_k mod S_k`, Euclidean division gives
  `(index_k − index_{k−1})·S_k = v_k·P + c_{k−1} − c_k` (this per-step form is exactly what
  the prover's `deposit_spec` proves against the real bytecode). Dividing by `S_k·P` and
  summing from the pool's creation (`index₀ = c₀ = 0`):
  `index_m/P = Σ v_k/S_k − (1/P)·Σ (c_k − c_{k−1})/S_k = ideal_index − carry_drift/P`. Valid.
  But note it is a *definitional* consequence of how the two ghosts are accumulated from
  the same `(v_k, S_k, c_k)` the model's `deposit` produced; it can only fail if the model's
  own division stops being Euclidean (e.g. a silent wrap — already excluded by checked ops).
  It says nothing about Move.
- **Audit finding A1 — identity (a) is not wired in.** `check_accumulator_identity` is
  only called from `check_c4_exact` (l.392-395), and `check_c4_exact` has **no callers**
  anywhere in `src/` or `tests/` (`grep -rn check_c4_exact\\b src tests` → only its
  definition). REPORT F2's "Both identities were added to the model this campaign and held
  over all 88 000 000 operations" is therefore overstated for identity (a): only (b) ran.
  I wired (a) into `check_pool` in a scratch copy (`fable-sim/`) and re-ran every corpus and
  fuzz sample (§3.4): it holds, as the derivation predicts.
- The reported `max_ic4_error` is now computed as `frac(a·Δindex/P) + (a/P)·ΔCD`
  (l.483-491). Combining (a) and (b): `paid + pending = ⌊a·ΔII − (a/P)·ΔCD⌋ =
  ⌊ideal_r − (a/P)·ΔCD⌋`, so `ideal_r − (paid+pending) = frac(a·Δindex/P) + (a/P)·ΔCD`.
  Correct; I checked it numerically on my `f4a` scenario (§4.3): the reported `781/92 =
  8.489` is stake A's deviation after op 4 (`(a/P)·ΔCD = 9·(8/9 + 1/18.4) = 8.489`, frac 0),
  which is the true maximum over the run.

### 3.2 `fuzz.rs`

Changes vs NOTES.md (F9): `total_registered` is released on unregister (l.259-261), the
empty-pool fallback is `register` instead of a guaranteed-abort deposit (l.206-216), `dust`
draws `value == 1` a third of the time (l.88), `--skip` sharding (l.386-399, seed derivation
`(base + i)·0x9E3779B97F4A7C15`, confirmed by the bit-identical shard replays). All are
coverage improvements; no check was removed. Invariants are evaluated only after
successful ops (l.292-297) — correct, since `World::apply` restores the snapshot on abort.
Limitation (unchanged from the handoff, stated in the module doc): every profile is a
**single plain-stake pool**; `routed_sweep`, `sweep_and_deposit` and `release_*` are never
fuzzed, only hand-written.

### 3.3 `movegen.rs`

Changes (F11b): cost-aware density (`SITE_BUDGET = 30` full-assert sites; otherwise
`ASSERT_SITE_BUDGET = 16` balance-only sites evenly spaced, `Full` at the last op,
l.513-550) and build-panic detection in `main.rs`. This is **weaker per op** than SPEC §4's
"assert after every op" and than the handoff's stated behaviour, but every generated test
still ends with a `Full` assertion (balance, `staked_shares`, `cumulative_reward_per_share`
and every live stake's `pending_rewards`), and intermediate claim amounts are asserted only
at `Full` level (l.355-358). Because index and debts are deterministic in the op sequence,
an intermediate disagreement would have to be exactly compensated later to escape the final
check; for the 60-op fuzzgen scenarios that means balance every 4th op plus the final full
state. Acceptable, but weaker than REPORT's phrasing.

**Audit finding A2 — `carry()` and `cumulative_deposits()` were never asserted.** Both are
public accessors (pool.move:382, 387) and SPEC §4 asks for `carry` to be asserted when
exposed; `assert_pool_state` (l.126-174) asserts neither. A wrong carry after the *last*
deposit of a scenario is invisible to the campaign's differential. Closed in §3.4.

### 3.4 Strengthened re-run (scratch copy `fable-sim/`, two one-line changes)

`fable-sim/src/model/invariants.rs`: `check_accumulator_identity(pool)?` inserted into
`check_pool`. `fable-sim/src/movegen.rs`: `assert_eq!(p.carry(), …u128)` and
`assert_eq!(p.cumulative_deposits(), …u128)` added to every `Full` assertion. Script
`fable-sim/strengthened.sh`, log `fable-sim/strengthened.log`, Move runs in
`manual-move-tests/move/`:

| Run | Result |
|---|---|
| `run` of **every** scenario file (ported 4 + handwritten 12 + adversarial 23 + fuzzgen 200 + mine 9 = 248) with identity (a) enforced after every op | 248 passed, 0 violations (`fable-sim/out/run-all.json`) |
| gate-4 fuzz set + `stress --seed 1 --ops 500 --count 100` with identity (a) enforced | failures=0 in all five profiles |
| `hugeshares --seed 3 --ops 2000 --count 125 --skip 250` (Opus's own replay shard) and `stress --seed 1 --ops 500 --count 500 --skip 0`, identity (a) enforced | failures=0; the hugeshares `max_ic4_error` rational is digit-for-digit the one in `fuzz-logs/hugeshares-s3-sh2.log` |
| `diff` of all 7 batches with `carry()` + `cumulative_deposits()` asserted at every `Full` site | first attempt: 3 batches failed to *build* (266/266/256 locals > 255 — the two extra `assert_eq!` sites per full assertion overran the generator's ceiling, F11b); after lowering `SITE_BUDGET` 30→20 and `ASSERT_SITE_BUDGET` 16→12 in the scratch copy (`fable-sim/rediff.sh`, `rediff.log`): **16 AGREE; 15 AGREE + 1 SKIP; 50; 50; 50; 50; 8 AGREE** with 32 + 8 + 47 + 39 + 45 + 48 + 6 = **225 `carry()` assertion sites** (hugeshares carries up to `1.8×10¹⁹`), 0 disagreements |

So neither omission hid anything — but neither was true as REPORT states it, and the
`carry` assertion should be upstreamed (it costs two assertion sites per full check, which
is why the density budgets have to drop with it).

### 3.5 Prover claims

Re-ran: `Verification successful` for all four specs (14.6 s). Two accuracy notes on REPORT
§Prover: (i) `unregister_stake_spec` **requires** `owed − debt < P` (it must, or the target
aborts with code 5 and the no-abort check fails) and then **ensures** the same inequality —
so "`amount·index − debt < PRECISION` … proven rather than fuzzed" is the precondition
restated; what the spec genuinely proves is that a successful unregister leaves `index`,
`carry` and `balance` untouched and drops `staked_shares` by exactly `amount` (the
in-place forfeit). The *abort* direction of I-B11 (code 5 when a whole unit is claimable)
is established by the differential tests (`05`, `12`, `03`), not the prover. (ii)
`claim_rewards_spec` assumes I-B1 (`requires(reward ≤ balance)`, marked "(assumed)" in the
spec, not in REPORT's table row for I-B1).

---

## 4. Independent re-derivation of the three headline findings

### 4.1 F4 — split deposits are bit-identical to one combined deposit (confirmed, proven)

From §3.1's per-step identity, telescoping over deposits `v_1..v_n` with **constant**
`S`: `index_n·S + c_n = index_0·S + c_0 + P·Σv_k` with `0 ≤ c_n < S`. Euclidean division
by `S` has a unique quotient/remainder, so `(index_n − index_0, c_n) =
divmod(c_0 + P·Σv_k, S)` depends only on `Σv_k`, not on the split. The intermediate
`numerator = v·P + c` never exceeds `2⁶⁴·10¹⁸ + 2⁶⁴ < 2¹²⁴`, so no u128 overflow can break
the telescoping. Balance is additive; every registration's `paid + pending =
⌊a·Δindex/P⌋` (§3.1 b) depends only on `Δindex`; and the routed stake's own claims from the
parent pool sum to the same `⌊a·Δindex_parent/P⌋` whether claimed once or many times. So
eager and late sweeping are bit-identical **end to end, provided the child's share set is
unchanged between the sweeps** (F4's proviso). Direct computation of SPEC's own example,
`S = 3`: deposits 3 then 4 → `index = 1e18 + ⌊4e18/3⌋ = 2 333 333 333 333 333 333`, carry
`1`; single deposit 7 → `⌊7e18/3⌋ = 2 333 333 333 333 333 333`, carry `1`. Identical.
20 000 random `(S, v⃗, index₀, c₀)` including `S ∈ {1, 2, 3, 7, 10⁶, 10¹⁸, 2⁶³, 2⁶⁴−1}`:
0 counterexamples. **No counterexample exists; F4 is a theorem.**

### 4.2 F5 — sweep timing (907 of 1360 reproduced by hand and on Move)

REPORT gives the numbers but not the inputs (Opus's search script was not preserved in
the root). Reconstruction: late arm → three floors `45, 408, 907` at shares `1, 9, 20`
(`S = 30`) force `D ∈ [1360.5, 1361.7)`, i.e. `D = 1361`; eager arm `136 = ⌊1361/10⌋`,
`1224 = ⌊9·1361/10⌋` with the joiner absent (`S = 10`). By hand:
late: `⌊1361·10¹⁸/30⌋ = 45 366 666 666 666 666 666`, carry `20`;
`⌊1·idx/P⌋ = 45`, `⌊9·idx/P⌋ = 408`, `⌊20·idx/P⌋ = 907`, sum `1360` (+ 1 unit in carry).
Eager: `idx = 136.1·10¹⁸` → `136`, `1224`, joiner `0`, sum `1360`.
Scenarios `fable-scenarios/f5a-sweep-timing-eager.json` / `f5b-sweep-timing-late.json`
(parent pool deposits 500 + 500 + 361 to a sole routed stake of 1 share; child stakers 1 and
9; a 20-share stake registers in the child after the parent deposits): model
`136/1224/0` and `45/408/907`; **both AGREE on Move** (`diff-out/`).

Precise design property: `pool::deposit` splits a deposit among the registrations present
*at deposit time* (pool.move's "No activation delay" section, l.37-47); a routed stake's
rewards accrue in the **parent** pool against the routed stake's fixed amount and become a
**child** deposit only when `sweep` runs. The child pool therefore uses the share set *at
sweep time* to split rewards that were earned earlier. pool.move's guarantee ("a
continuously registered stake is guaranteed at least its pro-rata share of total supply on
every deposit") still holds for each child deposit — `45 ≥ ⌊1361/30⌋`, `408 ≥ ⌊9·1361/30⌋`
— what sweep latency changes is *which* deposits a late registrant participates in. It is
the same property as I-C3's parked-funds split, applied to every unswept backlog. The
fraction transferable to a late joiner is bounded only by its share of the child pool
(→ 100 % as its shares dominate), so "unbounded fraction" is the right phrase. Not a bug;
an operational parameter for the crank (sweep before admitting child registrations, or
accept the incentive). REPORT's characterisation is accurate.

### 4.3 The over-payment observation (34.45 units; reproduced and extended)

Mechanism, from §3.1: `ideal_r − (paid+pending) = frac + (a/P)·ΔCD` with
`ΔCD = Σ (c_k − c_{k−1})/S_k` over the registration's window. A negative `ΔCD` (carry that
existed at registration and later folded into the index) over-pays the registrant.

Hand instance, `fable-scenarios/f4a-overpayment-carry-inheritance.json`: A = 9·10¹⁸ shares
registers; deposit 8 → `numerator = 8·10¹⁸ < S` so `index = 0`, `carry = 8·10¹⁸`;
B = 9.4·10¹⁸ registers (`debt_B = 0`, `S = 18.4·10¹⁸ ≤ u64::MAX`); deposit 1 → `carry =
9·10¹⁸`, `index = 0`; deposit 10 → `numerator = 19·10¹⁸`, `index = 1`, `carry = 6·10¹⁷`.
Pending A = `⌊9·10¹⁸·1/10¹⁸⌋ = 9`, pending B = `⌊9.4·10¹⁸·1/10¹⁸⌋ = 9`.
Ideal B = `11·9.4/18.4 = 5.6196` → **B is over-paid by 3.3804 units**
(`(a/P)·ΔCD_B = 9.4·(6·10¹⁷ − 9·10¹⁸)/18.4·10¹⁸ = −3.7804`, `frac = 0.4`). Ideal A =
`8 + 11·9/18.4 = 13.3804` → A is under-paid by 4.3804; the 0.6 difference sits in `carry`.
**Conservation holds exactly:** `19·P = (9·10¹⁸·1 − 0) + (9.4·10¹⁸·1 − 0) + 6·10¹⁷ =
19·10¹⁸`. Model: `passed`, `max_ic4_error = 781/92`; **AGREE on Move** (pendings and both
claims of 9 asserted by the generated test).

**New finding V1 — REPORT's stake-size bound is wrong as stated.** REPORT §Quantitative:
"For any stake of at most `P = 10¹⁸` shares the error is `< 1 + amount/P ≤ 2` units total,
for any number of deposits and claims (F2)." That holds only for a **fixed share set** (F2
itself says so; REPORT's summary drops the qualifier). Counterexample
`fable-scenarios/f6a-whale-leaves-carry-to-minnow.json`: whale `u64::MAX − 1` shares and
minnow `1` share registered (`S = u64::MAX`); deposit 18 → `numerator = 18·10¹⁸ < S`,
`index = 0`, `carry = 18·10¹⁸`; whale claims 0 and unregisters (`S = 1`, residue 0); deposit
1 → `numerator = 19·10¹⁸`, `index = 19·10¹⁸`, carry 0; the 1-share minnow's pending is
**19** for an ideal of `1 + 18/u64::MAX ≈ 1.000000000000000001`: over-paid by 18 units,
`(a/P)·ΔCD = (1/P)·(18·10¹⁸/u64::MAX − 18·10¹⁸/1) ≈ −18`. Conservation: `19·P = 1·19·10¹⁸ −
0 + 0`. Model `max_ic4_error = 110680464442257309684/6148914691236517205 = 18.000…`;
**AGREE on Move** (claim of 19 asserted). So the correct statement is: the deviation is
governed by the carry left behind at each share-set change, `< (S_before − 1)/P` units per
fold (`≤ 18.45` at `S = u64::MAX`), regardless of the beneficiary's own size; it is
invisible (`< 10⁻⁵` units) whenever the pool's total stake stays `≤ 10¹³` as in SPEC §5, and
REPORT's *pool-level* condition ("only pools whose total stake exceeds 10¹⁸ shares can
observe this at all") is the correct one. The 34.45 in `stress` is this mechanism
compounding over several share-set changes, exactly as REPORT F1 describes.

---

## 5. Attacking the admitted gaps

### 5.1 Stage A (`release_revenue_distributor::distribute`) on the Move VM

Package copied to `manual-move-tests/rrd/` (its own suite: 11/11 pass). New file
`tests/fable_stage_a_tests.move`; run:
`cd manual-move-tests/rrd && $SUI move test fable_stage_a` → **10 passed, 0 failed.**
Expected values were computed by hand / pure-Python integer arithmetic from
`mul_bps!<u64,u128>` and then compared with the Rust model's outputs:

| Test | Input | Move result | Rust model |
|---|---|---|---|
| `one_bps_track_t_1` | `[9999, 1]`, T=1 | amounts `[0, 0]`, distributed 0, remainder 1 (no `send_funds` at all) | same |
| `one_bps_track_t_9999_starves` | T=9 999 | `[9998, 0]`, rem 1 | same (`08-…dust-boundary`) |
| `one_bps_track_t_10000_first_unit` | T=10 000 | `[9999, 1]`, rem 0 | same |
| `one_bps_track_t_10001` | T=10 001 | `[9999, 1]`, rem 1 | same |
| `two_fifty_five_tracks_t_10000` | `[9746, 1×254]` (n = 255), T=10 000 | `9746` + 254×`1`, rem 0 | same |
| `two_fifty_five_tracks_t_u64_max_conserves` | same vector, T=u64::MAX | `a₀ = 17 978 196 774 237 329 003`, `a_i = 1 844 674 407 370 955`, distributed + remainder = u64::MAX, **remainder 42 < 255** | same numbers from `distribute(u64::MAX, …)` |
| `three_way_split_t_u64_max` | `[3334, 3333, 3333]`, T=u64::MAX | `[6 150 144 474 174 764 508, 6 148 299 799 767 393 553, 6 148 299 799 767 393 553]`, rem 1 | same |
| `remainder_returns_to_release_and_recirculates` | `[6000, 4000]`: T=10 001, then redeem the returned 1, then 10 000 | rem 1 → `[0,0]` rem 1 (dust comes straight back, never sent as 0) → `[6000, 4000]` rem 0 | same (A-D2 confirmed on chain semantics) |
| `accumulator_probe_p1_same_tx_sends_past_u64_max_overflow` | two `send_funds` to one address summing past u64::MAX **in one tx** | arithmetic error in `sui::funds_accumulator` (expected) | n/a |
| `accumulator_probe_p2_prior_max_then_redeem_and_send_back_is_fine` | u64::MAX settled earlier; redeem u64::MAX and send 42 (+1) back in one tx | passes | n/a |

**New finding V2 — the 1 024-track case does not exist on chain.** `release::new`
(`release.move:229-230`) enforces `MAX_TRACKS = 255` (`EMaxTracksExceeded = 31`; musicos's
own `release_tests.move:84-91` pins 256 → abort). Consequences: TASKS-OPUS §2.9, REPORT's
I-A2 row ("max R observed 307 at n=1024"), the Quantitative dust table's 1 024-track row,
scenario `09-release-1024-tracks-modelonly`, and REPORT F12's "a Release can have at most
10 000 tracks with a non-zero split" describe inputs Move rejects. The on-chain bound is
`R ≤ 254`, and the widest representable dust vector is `[9746, 1×254]`. The model's
`release_new` lacks the `≤ 255` check (deviation, §2). A 1 024-track `new_for_testing`
fixture (which bypasses the check) also cannot even be *distributed* in the unit VM:
`MEMORY_LIMIT_EXCEEDED` in `sui::event` on the 1 024 per-track events. Not a Move bug; a
campaign-scope error. The 255-track numbers above are the correct replacement.

Harness boundary (probes P1/P2): my first draft failed because it minted u64::MAX to the
release address and let the distributor send the remainder back **in the same
transaction**; the test VM's per-transaction pending merge for one address is u64 and
overflows. The production shape (funds settled in an earlier commit, redeem is a split)
is fine (P2). Recorded so nobody mistakes it for a distributor defect.

### 5.2 F14 — permissionless `sweep` with a forged parent id

`manual-move-tests/fable_f14_sweep_derivation.move`, copied into
`manual-move-tests/move/routed-stake/tests/gen/`;
`(cd manual-move-tests/move/routed-stake && $SUI move test fable_f14)` → **3 passed**:

- `sweep_with_foreign_parent_id_and_foreign_pool_aborts`: A's routed stake (1 000 units
  claimable), attacker passes parent **B**'s id and B's pool → abort
  `ENotDerivedFromParent (0)` in `routed_stake` (routed_stake.move:212).
- `sweep_with_correct_parent_but_foreign_pool_aborts`: correct id A, destination B's pool →
  abort `EPoolNotDerivedFromParent (0)` in `royalty_pool::pool` (routed_stake.move:213).
- `honest_sweep_from_stranger_parks_at_a_pool` (control): same attacker address, honest
  arguments → succeeds, 1 000 units leave the stake pool and are parked at A's pool address.

Note: the upstream suite already has `sweep_rejects_wrong_parent_id` and a pool-derivation
case (`routed_stake_tests.move:125-160`, both pass in the copies), so REPORT F14's "covered
by neither the model nor a generated Move test" is true of the campaign's artefacts but the
package itself was not unprotected by tests. The model still cannot express this case.

---

## 6. Attacks of my own (not in TASKS-OPUS §2)

All scenarios in `fable-scenarios/`; model: `royalty-sim run` (all `passed`, 0 invariant
violations); Move: `royalty-sim diff … --move-root manual-move-tests/move --sui $SUI`
→ **8 AGREE** (`f6d` is model-only: `movegen` gives each `routed_new` its own parent+pool).

| # | Idea | Scenario | Result |
|---|---|---|---|
| A1 | **Whale leaves its carry to the minnow** — share set shrinks after a large carry accumulated (`S > P`) | `f6a-whale-leaves-carry-to-minnow` | 1-share stake collects 19 units on 19 deposited (over-paid 18 vs ideal). Conservation and solvency hold; it is the mirror of F1 and the source of V1. **AGREE.** |
| A2 | **Parked funds land on a pool that already holds dead residue and stale carry** — child staker claims 9 of 10, unregisters (forfeits 0.999…, carry 1 stays), sweep parks 7, new 2-share staker registers, `sweep_and_deposit` | `f6b-parked-plus-dead-residue` | new staker gets exactly 7 (`(7·10¹⁸ + 1)/2`, carry 1); pool balance 1 = the dead residue, permanently; second `sweep_and_deposit` aborts 7. **AGREE** (prefix + abort tests). |
| A3 | **Index near its practical limits with realistic shares** — 1 share, three deposits of u64::MAX each claimed in full (`cumulative_deposits = 3·u64::MAX = 5.53·10¹⁹ > u64::MAX` on chain, index `3·u64::MAX·P`, 126 bits), then a `u64::MAX − 1` stake registers (`debt` 190 bits) and 1 000 is deposited | `f6c-index-near-limits-u128-cumulative` | pendings 0 / 996, carry `3 875 820 019 684 212 790`; both claims succeed. **AGREE** — exercises the u128 `cumulative_deposits` past u64 and a 190-bit `amount·index` on the real VM. |
| A4 | **Two routed stakes from one parent feeding one child**, interleaved with a child registration between their sweeps | `f6d-…-modelonly` | pendings 32 / 97 / 29, `159·P = Σowed + carry` exact; model-only. |
| A5 | **Register / unregister / register at the same index** with non-zero carry and residue-bearing neighbour, then the neighbour leaves; final deposit into an empty pool | `f6e-register-unregister-same-index` | zero forfeit on same-index churn; B later gets `⌊1.3⌋ = 1`; deposit into the emptied pool aborts 1. **AGREE.** |
| A6 | **Maximum carry with `S` just above `P`** (`S = 10¹⁸ + 1`, then `2·10¹⁸ + 1`): carry hits `S − 1` twice before the fold | `f6f-max-carry-shares-just-above-P` | carry `10¹⁸`, `2·10¹⁸` (= `S − 1`), then index 1 and both stakers get 1 of the 3 deposited (0.999… units in carry). **AGREE.** |

Ideas considered and rejected as unreachable: sweeping a routed stake into its own
`stake_pool` (needs two `&mut` to one object — impossible in Move/PTB; in production
`StakeShare ≠ PoolShare`); registering a stake in two pools of one currency (abort 2,
already `13-…`); claiming from the wrong pool (abort 4, already `14-…`).

---

## 7. Verdict

**The royalty distribution arithmetic is exact and dependable; the plumbing is dependable
as far as it can be exercised off-network, with two paths still resting on reading and
network tests rather than execution.** Every replay reproduced bit-for-bit; the Rust model
has no result-affecting deviation from `pool.move`, `routed_stake.move` or
`release_revenue_distributor.move`; the conservation identity `balance·P = Σowed + carry +
forfeited` is an algebraic consequence of Euclidean division that I re-derived and that the
prover confirms per step, and it held on the real VM in every one of the 231 + 8 + 10 + 3
Move tests, including my own at `u64::MAX`, `S = u64::MAX`, `S = P + 1`, 190-bit
`amount·index` and u128 `cumulative_deposits`. The three headline findings stand (F4 is a
theorem; F5's 907/1360 reproduces by hand and on Move; the over-payment is real, conserving,
and reproduces with 3.38 and 18 units on Move). Nothing I tried lost, minted, or wedged
funds. What I would not sign: (i) REPORT's stake-size bound sentence (V1, wrong without
the fixed-share-set qualifier); (ii) every 1 024-track number (V2, unrepresentable — 255
is the ceiling); (iii) the claim that identity (a) was enforced (A1) and that `carry` was
differentially checked (A2), both now closed in a scratch copy with no change in outcome;
(iv) the prover "proves I-B8" phrasing (§3.5).

**Residual risks, precisely:**
1. **Address-balance settlement paths are not executed anywhere in the campaign or here**:
   `redeem_all_and_distribute` and `sweep_and_deposit` funded success paths cannot run in
   the unit VM (settled snapshot is always 0; the package's own tests say so). Their
   arithmetic after redemption is the tested `distribute`/`deposit`; what is untested is
   `settled_funds_value` capping at u64::MAX, snapshot timing (a sweep in the same commit as
   the send sees 0 and aborts 7 — a retry, not a loss), and the interaction with the crank.
   Needs a localnet E2E; this is the largest gap.
2. **Routed path is hand-tested only** (no random fuzzing of `routed_sweep` /
   `sweep_and_deposit` interleavings); 13 hand scenarios + my 3 cover the branches.
3. **Differential granularity**: intermediate states in 60-op scenarios are balance-only
   every ~4 ops; `carry`/`cumulative_deposits` were unasserted until my scratch run.
4. **I-B1/I-B2 are simulated, not proven** as state invariants; the claim spec assumes I-B1.
5. **Design properties that are economically visible** and must be documented for
   operators: sweep-timing attribution (F5), carry redistribution on share-set change
   (F1/V1 — only when a pool's total stake exceeds 10¹⁸ shares, i.e. never at SPEC §5
   magnitudes), dead balance on unregister (F7/`12`), cold-start parking (I-C3).
6. **Out of scope and still out of scope**: custody of `Stake` objects, permission checks
   other than F14, gas, PTB packing, currencies whose supply exceeds u64::MAX.

**Confidence:** high (≈95 %) that the on-chain math of `pool`, `stake`, `routed_stake` and
`distribute` conserves exactly and never under-pays a registered stake below
`⌊a·Δindex/P⌋` for any u64 inputs; medium-high (≈80 %) for the end-to-end money path
including address-balance settlement. Raising it: a localnet E2E of the two funded
redemption paths under the crank; upstreaming the `carry`/`cumulative_deposits` assertions
and the wired identity into `royalty-sim`; a prover proof of I-B2 as a datatype invariant
with a ghost sum; a fuzz profile over the routed path; and correcting REPORT (V1, V2, A1,
§3.5) before publication.

---

## Summary

- **Replay:** reproduces bit-for-bit — 5 gates green; 16 + 15 + 200 AGREE (0 DISAGREE,
  1 SKIP as recorded); 200/200 fuzzgen files regenerate to identical sha256; fuzz shards
  `realistic-s2-sh0`, `churn-s8-sh2`, `dust-s7-sh3`, `stress-s5-sh1` byte-identical to the recorded logs; prover
  `Verification successful`. The campaign counts.
- **Deviations (model vs Move):** 0 result-affecting; 5 cosmetic/scope (currency key,
  parked-queue width/timing, receive value, F14 asserts, bps width + unmodeled MAX_TRACKS).
- **Findings confirmed:** F4 (proven), F5 (907/408/45 and 136/1224/0 by hand and on Move),
  over-payment (3.38 and 18 units on Move, conservation exact), F14, F6/F12's zero-skip.
- **Refuted / corrected:** V1 — REPORT's "`< 2` units for any stake `≤ P`" is false
  without a fixed share set (1-share stake over-paid 18 units, on Move); V2 — no Release
  can have 1 024 tracks (`MAX_TRACKS = 255`), so those rows/scenario/F12's "10 000 tracks"
  are wrong, R ≤ 254 on chain; A1 — accumulator identity (a) was never enforced; A2 —
  `carry`/`cumulative_deposits` never asserted differentially; §3.5 — prover's residue
  bound is a restated precondition.
- **New coverage:** 10 Stage A Move tests (255-track vector at T = 10 000 and u64::MAX,
  1-bps track at T ∈ {1, 9 999, 10 000, 10 001}, three-way u64::MAX, remainder
  recirculation, two harness probes); 3 F14 tests; 8 new differential scenarios AGREE +
  1 model-only; strengthened re-run of every corpus with identity (a) enforced and
  `carry`/`cumulative_deposits` asserted: 248/248 model passes, 239 + 8 Move AGREE with
  225 `carry()` sites, 0 disagreements.
- **Verdict:** math rock solid; plumbing dependable off-network, with the funded
  address-balance redemption paths (`redeem_all_and_distribute`, `sweep_and_deposit`) as
  the one untested link — needs a localnet E2E before "rock solid" applies end to end.
