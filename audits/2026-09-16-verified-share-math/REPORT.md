# Independent royalty arithmetic review — 2026-09-16

**Verdict: no production arithmetic defect or publication-blocking math change found. Keep `PRECISION = 10^18` and the `u256` index/debt.** The new verified-share constructor makes the old unrestricted-supply carry example unreachable. The production design preserves the intended minimum reward for continuously registered holders, exact conservation, and solvency. Pool-wide carry and voluntary exit residue remain intentional allocation policies; neither requires redesign under the stated contract.

This is a fresh, focused arithmetic assessment of `share`, `royalty-pool`, `routed-stake`, and the four MusicOS action modules. It is not a deployment, SDK, event-ingestion, or whole-repository security sign-off. Production source was not changed. Exact source hashes and review-time Git heads are recorded in [source-manifest.json](source-manifest.json). The Sui Move security, DeFi accounting, and testing standards were applied to this scope. Existing reports were used as hypotheses and historical evidence, not as substitutes for the proofs and new probes below.

## Finding and severity reconciliation

### The previous Medium carry finding is not a blocker for this production design

Relevant code: `royalty-pool/sources/pool.move:246–259,380–412,596–619`, `share/sources/share.move:25–28,128–132`.

The former example used `u64::MAX - 1` registered shares, deposited 18 payout units into carry without moving the index, removed that cohort, then paid a new one-share registrant 19 after its one-unit deposit. That sequence is valid in an unrestricted generic arithmetic model. It is not admitted by this production constructor: `pool::new` requires a registry `Currency<Share>` passing `share::is_share`, including permanently fixed supply **N = 100,000,000,000,000** base units. The unchecked entry is test-only. Stakes hold actual immutable share balances, so admitted pool registration totals cannot exceed N.

More fundamentally, the former blocker assumed exact attribution to the cohort present at each historical deposit. That is a stronger requirement than the accepted design, which explicitly retains global carry, forfeits subunit registration residue on exit, and guarantees continuously registered holders at least their fixed-total-supply entitlement. The old reproduction usefully identified a generic cohort-allocation property. Treating all such carry reassignment as a required math fix overstates the result under this contract. The earlier report's generic-supply concern is also addressed by the new admission gate.

**Disposition:** withdraw the publication-blocking Medium classification for this candidate. Retain the cohort behavior as a documented design property and regression surface. A different requirement—exact historical cohort ownership, including every fractional residual—would require a deliberate accounting redesign, not merely a smaller supply or a different integer width.

### Documentation qualification, not an arithmetic defect

At review time, `royalty-pool/README.md:13` compared approximately 18 maximum-`u64` deposits in a `u128` scaled obligation with more than `10^39` in `u256`. The small comparison is useful, but the large figure describes an isolated `u256` scaled quantity. It is not the supported lifetime of the whole pool: `cumulative_deposits: u128` reaches its limit first, and a late large stake multiplies the accumulated historical index. Prefer the concrete bounds below. No change to the accounting statements is necessary.

## Why the intended holder minimum holds

Let P = 10^18, N = 10^14, v be a positive deposit, S the registered supply, c the previous carry, and q the index increment. In production, `1 <= S <= N`, `c >= 0`, and **P/N = 10,000 is an integer**. Therefore:

```text
q = floor((v P + c) / S)
  >= floor(v P / N)
  = v * 10,000.
```

A position of s shares continuously registered over deposits totaling V consequently has:

```text
s * (index_now - index_at_entry) / P >= s * V / N
paid + pending = floor(s * (index_now - index_at_entry) / P)
               >= floor(s * V / N).
```

This is a cumulative whole-unit guarantee; fractional accrual remains credit until claimable. It is independent of other holders entering, leaving, or choosing when to claim. Thus short-lived registration cannot take a continuously registered holder below its fixed-total-supply floor. Every positive production deposit advances the index by at least 10,000, so the old zero-increment whale state is impossible.

This minimum is different from exact current-registered-set allocation `sum(v * s / S)`. Global carry can perturb the latter. It also differs from historical ownership at an upstream revenue source: the pool allocates when a deposit is made, not when a recording first earned revenue or an address first received funds.

## Conservation, claims, and exit treatment

For each active registration i define `x_i = s_i * I - d_i`. Let F be the ghost sum of all numerators voluntarily forfeited on unregister. The on-chain pool does not need to store F to preserve the identity:

```text
B * P = sum(x_i) + carry + F.
```

The proof is inductive and exact, including membership changes:

- A deposit satisfies `S*q + c_new = v*P + c_old`, so liabilities and carry grow by precisely the deposited value.
- A registration sets `debt = shares * current_index`, adds zero liability, and changes only future deposit allocation.
- A claim pays `r = floor(x_i/P)` and increases debt by `r*P`; balance and liabilities decrease by the same amount. The remaining numerator is in `[0,P)`.
- Unregister requires zero whole-unit pending reward. Removing `x_i < P` transfers it from active liabilities to F in the proof, without moving funds. Later registrations receive no claim on F.
- A stake's balance cannot change during a registration. Same-currency uniqueness and exact stored pool ID checks prevent duplicated registration or claims against a different pool.

Since every term on the right is nonnegative, the pool always covers the sum of pending whole-unit claims. `calculate_reward` is at most B and therefore fits `u64`. Debt subtraction cannot underflow. Repeating a claim pays zero. Arbitrarily frequent claims preserve fractional credit and do not compound rounding loss: `paid + pending = floor(s * delta_index/P)` throughout one registration.

Splitting a position with the same entry point cannot increase its combined payout: the sum of floors is no larger than the floor of the sum. Exit/re-entry discards credit rather than creating it. Unregister can strand nearly one payout base unit per registration, and repeated exits can strand whole units in aggregate. That is the accepted voluntary forfeiture policy, distinct from transferable global carry. A claimable whole unit must be drained before exit; no whole claim is silently erased.

## Carry: per-episode and aggregate bounds

After every deposit, `0 <= c < S_at_that_deposit <= N`. Registration changes do not increase c. Therefore the entire outstanding global carry always represents **strictly less than 0.0001 payout base unit**. This statement refers to payout base units, not whole display tokens, dollars, or a universal economic materiality threshold.

For one continuously live registration:

```text
unrounded_accrual
  = sum(v_k * s / S_k)
    + (s/P) * sum((c_(k-1) - c_k) / S_k).
```

Within a block of deposits with constant S, the carry term telescopes. For b such blocks within the registration, the difference between unrounded accrual and exact current-registered-set pro rata has magnitude less than `b*N/P`. Including the final whole-unit floor gives:

```text
-1 - b*0.0001 < paid + pending - current_set_ideal < b*0.0001.
```

This is a safe bound, not an assertion that every block reaches the maximum. There is no lifetime bound of 0.0001 independent of membership changes. A tiny residual can also cross a pre-existing whole-unit claim threshold; a bound on fractional allocation does not imply identical integer payouts after every individual action.

For an adversary owning several positions, use its aggregate registered fraction `w_k` rather than counting each position as a separate victim or beneficiary. Its carry-related accrual difference is exactly:

```text
(1/P) * sum(w_k * (c_(k-1) - c_k)).
```

Summation by parts bounds positive reassignment by `N/P` times the initial registered fraction plus the total positive variation in w. Claim frequency does not appear. Registration residue forfeitures further reduce realizable proceeds. This proves that repeated favorable ownership changes can accumulate carry, while cycling one's own entire cohort does not manufacture net value: all controlled positions and all forfeitures must be counted together.

### Explicit bounded-supply repeated-carry example

The independent oracle starts a permanent one-share position. For each of 10,002 rounds, a transient position of `99,990,000,999,900` shares registers, one unit is deposited, the transient position voluntarily unregisters with zero whole-unit pending reward, and another unit is deposited with only the permanent share registered. The permanent position claims each round.

The large-denominator deposit produces `q = 10,000` and `carry = 99,990,000,990,000`. The following one-share deposit folds that carry exactly. After 10,002 rounds:

| Quantity | Value |
| --- | ---: |
| Total deposited | 20,004 |
| Permanent position's payout | 10,003 |
| Its exact current-set ideal | `10,002 + 10,002 / 99,990,000,999,901` |
| Remaining pool balance | 10,001 |
| Final carry | 0 |

The remaining balance equals forfeited registration numerators plus the permanent position's remaining fractional credit. There is no loss from the conservation ledger. The permanent holder is above its current-set ideal by just under one unit, demonstrating accumulation; the transient holder intentionally abandons nearly one unit each round. If one actor controls both positions and funds all deposits, that actor loses value to forfeiture rather than profiting. An external holder's repeated departures can transfer the much smaller carry to a remaining holder, as the documented policy permits.

The real Move VM verifies the first 100 cycles through the production constructor and genuine fixed-supply share balances, including the exact accumulated index. The independently derived recurrence and integer oracle establish the 10,002-cycle result. An initial attempt to put all 10,002 cycles into one VM test exceeded the event-memory limit; it was not an arithmetic failure and is not presented as a successful 10,002-cycle Move execution. See the retained [event-limit log](move-probes-10002-event-limit.log).

## Width and lifetime proof

Let D be successful lifetime deposits, bounded by `u128::MAX`. Each successful deposit has `v <= u64::MAX`.

| Quantity | Bound | Required bits |
| --- | --- | ---: |
| Deposit numerator | `v*P + c <= (2^64-1)*10^18 + N-1` | 124 |
| Cumulative index | `I <= D*P` | at most 188 |
| Any `shares * I`, including a late large entrant | `<= N*D*P` | at most 235 |
| Registration debt | `<= shares*I` | at most 235 |
| Single claim | `<= pool.balance` | at most 64 |

To prove the index bound despite changing denominators, each deposit satisfies `S_k*q_k = v_k*P + c_(k-1) - c_k`. Summing gives `sum(S_k*q_k) = D*P - c_final`. Since `S_k >= 1` and `q_k >= 0`, `I = sum(q_k) <= D*P`. This proof does not assume a fixed cohort.

Thus the existing `u128` deposit numerator/carry and `u256` index/debt have ample headroom for every state reachable before the lifetime counter's own limit. Narrowing the index/debt to `u128` would introduce a practical repeated-deposit bound: a one-share registration's scaled debt exceeds `u128` on the 19th fully paid `u64::MAX` deposit cycle. A late large entrant makes an index-only estimate insufficient. Keep the widths.

The actual lifetime counter can accommodate `u128::MAX // u64::MAX = 18,446,744,073,709,551,617` maximum-sized successful deposits. The next value crossing `u128::MAX` aborts atomically; it does not wrap, reset, or bypass the cap. This is a finite representation bound, not unlimited lifetime. Even though the counter is described as analytics, its checked addition is part of every deposit and hence part of this bound.

`Balance<Currency>` remains `u64`; a join above its capacity aborts atomically, including a direct routed sweep. Arbitrary payout types are admitted, so the pool is not a promise that every externally constructed balance can always fit. Claim/withdrawal is not gated on index growth or new deposits. These are existing representation/asset constraints, not a demonstrated arithmetic insolvency. General claims that routing is never blocked should be read as the documented empty-destination handling, not exemption from all balance or lifetime limits.

Reducing P is unnecessary for the new supply. P/N = 10,000 gives the useful minimum-allocation proof and the less-than-0.0001 carry bound. Using P = N would preserve the fixed-supply minimum but loosen carry to almost one whole payout base unit. Merely shrinking carry storage to `u64` would offer no economic correction and would change the stored schema.

## Routed sweeps and upstream allocation

Relevant code: `routed-stake/sources/routed_stake.move:351–444`; action `new_pool`, `receive_and_deposit`, `redeem_settled_value_and_deposit`, and `distribute` paths.

- A direct sweep claims r from the source and deposits the same r into the derived destination. Source balance decreases by r, source registration debt increases by rP, and destination deposits/balance increase by r. Both pools retain their own exact accounting identities. A failing destination operation rolls back the source claim too.
- If the destination has zero stake, the same r goes to its address accumulator; its inline pool accounting is unchanged until settlement. The global custody ledger must include these parked funds. Zero-value claims and absent/incorrect registrations are no-ops. Parent/address and source registration bindings prevent redirection.
- Self-routing to the identical pool is rejected at registration, preserving the required mutable-source/destination call shape. Unregister requires source rewards to have been swept; unstake requires no registrations. Composition routing adds the appropriate recording/composition bindings and does not replace the core arithmetic.
- Sweep cadence does not introduce repeated claim rounding: fractional source credit is retained in debt. For an unchanged destination cohort, splitting the same deposited total into several successful deposits is exactly associative in `(index, carry)`.
- With destination membership changes, eager and delayed sweeping can distribute large whole amounts differently. New destination registrations participate in later deposits, including a pre-existing source backlog or parked funds settled later. This is deposit-time eligibility, not the tiny carry effect. The intended contract must not promise historical upstream ownership allocation. No stronger promise was required for this review.
- Release distribution floors `T * bps_i / 10,000`, using a `u128` intermediate for `u64` T. Immutable track splits sum to 10,000 and there are at most 255 tracks. Thus `T = sum(outputs) + remainder`, and `0 <= remainder <= 254`. The remainder is returned to the Release address for future aggregation; a tiny remainder need not distribute further without new funds. Composition/Recording actions hand the redeemed/received balance to the same verified pool accounting path.

## New verification and limits

- [probes.py](probes.py): independently written integer oracle; four fixed seeds, 25,000 randomized steps each, plus the old generic example, bounded repeated-carry example, and explicit width bounds. It checks conservation, deposit/payout reconciliation, solvency, debt ordering, exact claim lifetime identity, idempotence, supply bounds, and the fixed-total-supply minimum after operations. All pass; full results are in [probe-results.json](probe-results.json).
- [fresh_math_review.move](package/tests/fresh_math_review.move): isolated real Move probes using `pool::new`, a registry-backed initialized share currency, and its genuine fixed share balance. Tests cover the 100-cycle carry recurrence and the full-supply 10,000-index-unit minimum. The target production pool/stake sources are copied unchanged; only the isolated manifest and new tests differ. Compiler: Sui 1.79.0, mainnet build environment, `--lint --warnings-are-errors`. Results are in [move-probes.log](move-probes.log).
- Existing candidate `pool-pinned-tests.log` records 50/50 core tests passing. This review read those tests and the earlier extensive differential campaign; their historical counts are not represented as newly rerun independent coverage.
- These proofs and probes do not establish positive live consensus address-accumulator redemption, end-to-end settlement timing, deployed bytecode, or final dependency publication. The earlier funded snapshot fixture supports the post-redemption arithmetic, with the same live-settlement limitation.

**Required production math changes: none.** The identified documentation qualification and the distinction between fixed-supply minimum, current-set pro rata, and historical upstream allocation should accompany the decision to retain the current design.
