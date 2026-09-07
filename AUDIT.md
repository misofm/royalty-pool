# Security Audit — `royalty_pool`

**Revision:** working tree (source snapshot — no `.git` in repo) ·
**Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

**Pinned dependencies** (`Move.toml`): `hikida` `e88c6fa8` (audited clean;
re-read here). Consumers pin `miso_share` `047d74d5` transitively.

Audit of `pool.move` (433 LOC) + `stake.move` (184 LOC) — the accumulator
royalty-distribution pool that all share-holder revenue flows through. This
is a money package; it got the deepest treatment in this audit set. Verdict:
**safe to publish — no Critical/High/Medium findings.** Two Low items are
caller-custody obligations, both already documented in the code and in the
downstream plugin audits.

## What it does

- `RoyaltyPool<Share, Currency>` (`pool.move:88`) is a derived object of any
  UID-bearing parent; at most one pool per `(parent_id, Share, Currency)`
  (phantom-typed `RoyaltyPoolKey`, `pool.move:111`), necessarily correctly
  typed and, being `key`-only with `share` as sole consumer, necessarily
  shared. Creation requires the parent's `&mut UID` — cap-gating is the
  parent's (`pool.move:152`).
- `Stake<Share>` (`stake.move:29`) is an owned, `key + store` position with an
  immutable balance; registrations live inline in a `VecMap<TypeName,
  Registration>` keyed by **Currency** `TypeName` (`stake.move:35`).
- Funding: `deposit` (`pool.move:182`) from any caller, or permissionless
  recovery of address-delivered funds via `receive_and_deposit` /
  `sweep_and_deposit` (`pool.move:207-230`). Both fold into the same
  accumulator path.
- Distribution: classic cumulative-index accumulator.
  `cumulative_reward_per_share += value · 10¹⁸ / staked_shares` on deposit
  (`pool.move:191-192`); a claim pays
  `staked · (index − last_claim_index) / 10¹⁸` (`calculate_reward`,
  `pool.move:389-393`) and advances `last_claim_index` by only the
  *consumed* delta (`pool.move:310-311`), preserving sub-base-unit credit.
- Exit: `unregister_stake` requires a fully drained claim
  (`calculate_reward == 0`, `pool.move:271-274`); `stake::destroy` requires
  zero registrations (`stake.move:85`).

Threat model: value leakage between claimants, double-claims, stranded
balances, rounding/precision exploits, index arithmetic overflow, registration
griefing, pool impersonation (wrong-parent or wrong-type pool at a canonical
address), and custody traps around the `Stake` object.

## Solvency proof (the core property)

**Invariant: `pool.balance ≥ Σ outstanding claimable`.** Let deposits
`d = 1..n` land with `value_d` while `S_d` shares are staked; each adds
`rps_d = ⌊value_d·P / S_d⌋` to the index (`P = 10¹⁸`). A stake registered
before deposit `d` (registration index `last_i ≥ Σ_{e<d} rps_e` is enforced
by `register_stake`, `pool.move:238-240`) only ever has `d` inside its delta.
Hence

```
Σ_i claimable_i = Σ_i staked_i·(cum − last_i)/P
                ≤ Σ_d rps_d · (Σ_{i registered before d} staked_i) / P
                = Σ_d rps_d · S_d / P  ≤  Σ_d value_d  =  total deposited.
```

Claims subtract from both sides. So `claim_rewards`' `self.balance.split(
reward_amount)` (`pool.move:319`) can never abort from insolvency, and no
claimant can be paid another's entitlement. Floor rounding everywhere points
into the pool, never out of it.

**Overflow.** Deposit: `value·P ≤ 2⁶⁴·10¹⁸ ≈ 1.8e37 < u128::MAX ≈ 3.4e38`
(`u128::mul_div` widens internally; `pool.move:191`). Index: cumulative
deposits are bounded by the currency's supply (the pool `Balance` joins real
value; `u64` per deposit), so `cum ≤ ~1.8e37`, far under `u256`. Reward:
`staked·delta ≤ 10¹³·1.8e37 ≈ 1.8e50 < u256::MAX`; and since reward ≤ total
deposited ≤ `u64::MAX` (by the solvency bound), the `reward as u64` cast
(`pool.move:392`) cannot truncate. `cumulative_deposits` (u128,
analytics-only, `pool.move:193`) cannot overflow for the same reason.
`staked_shares` is bounded by the 10¹³ fixed share supply.

**No-truncation-lock.** With `staked_shares ≤ 10¹³` (guaranteed by
`miso_share` fixed supply), any `value ≥ 1` advances the index by
`≥ ⌊1·10¹⁸/10¹³⌋ = 10⁵` — the classic "deposit truncates to zero and locks
forever" case is impossible by construction (`pool.move:49-58`).

**Consumed-index advance is exact.** `consumed = ⌊reward·P / staked⌋ ≤ delta`
(`pool.move:310`), so `last_claim_index` never overtakes `cum`, residue stays
credited to the same stake, and no index is ever skipped for other claimants
(the index is per-pool, not per-stake). Verified behaviorally:
`test_fractional_holder_credit_preserved_across_zero_claims` — a 1-base-unit
staker whose per-claim reward truncates to 0 eventually claims 1 full unit.

## Findings

- **L1 (Low — caller obligation): a bare shared `Stake` is drainable by
  anyone.** `claim_rewards` takes `&mut Stake<Share>` and returns the reward
  to the *caller* (`pool.move:288-320`). `Stake` is `key + store`
  (`stake.move:29`), so if a holder shares one (or wraps it into a shared
  object that hands out `&mut`), any passerby can claim its accrued rewards.
  This is the documented reason `routed_stake` exists (its module doc,
  `routed_stake.move:12-13`) and is called out in both misofm plugin audits.
  Stakes must stay address-owned or wrapped; the pool cannot enforce this
  itself.
  **Disposition (2026-08-24):** accepted — a caller-custody obligation the
  pool cannot enforce; now warned in the `stake.move` module doc and
  documented in the `routed_stake` and misofm plugin audits.
- **L2 (Low — caller obligation): one registration per (stake, Currency)
  makes registration order sticky.** `register_stake` rejects a second
  same-currency registration (`EAlreadyRegistered`, `pool.move:233`), and
  registration is permissionless given `&mut Stake`. A custodian error (or
  anyone, if L1's shared-stake mistake is made) can bind a stake to a
  legitimate-but-wrong same-currency pool. **Recoverable**: the stake holder
  can always `claim_rewards` (paying themselves) then `unregister_stake`
  from the wrong pool — a griefer can at most force a claim-first detour by
  dust-funding their pool; they cannot trap the stake or redirect already-
  accrued rewards, which belong to the stake wherever it is registered.
  **Disposition (2026-08-24):** accepted — recoverable by the stake holder
  (claim, then unregister); a griefer can force at most a claim-first detour
  and can neither trap the stake nor redirect accrued rewards.
- **F3 (Informational): bounded dust lockup.** Two residues stay in the pool
  forever by design: per-deposit index remainder
  `value − rps·S/P < S/P ≤ 10¹³/10¹⁸ = 10⁻⁵` base units, and per-stake
  sub-base-unit exit residue forfeited at `unregister_stake`
  (documented at `pool.move:250-255`). Neither can ever reach one whole base
  unit per stake; not actionable.
  **Disposition (2026-08-24):** accepted-by-design — both residues are bounded
  below one base unit per stake by construction and are unreachable dust.
- **F4 (Informational): deposits abort while `staked_shares == 0`, so
  pre-registration funding waits at the pool's address.** Deliberate
  (`ENoStakedShares`, `pool.move:186`): an unattributable deposit is
  rejected rather than absorbed. Address-delivered funds sit at the derived
  address — which only the correctly-typed shared pool can ever claim — and
  are folded later by the permissionless recovery paths. Locked-then-
  recoverable, never lost, never redirected.
  **Disposition (2026-08-24):** accepted-by-design — rejecting unattributable
  deposits is deliberate; address-delivered funds are locked-then-
  permissionlessly-recoverable, never lost or redirected.
- **F5 (Informational — integration constraint): the precision argument
  assumes `staked_shares ≤ 10¹³`.** It holds because `Share` is a
  `miso_share`-issued token (fixed 10¹³ supply, 6 decimals, freeze-proof).
  `RoyaltyPool` is generic and would silently lose that guarantee with an
  arbitrary token: a large-supply `Share` could make deposits truncate to
  zero (permanent lock) and would admit `DenyCap`-freeze griefing of staked
  principal. The misofm plugin audits already record "do not reuse
  `RoyaltyPool` with other share types"; restated here as the package's one
  environmental assumption.
  **Disposition (2026-08-24):** accepted — an environmental assumption:
  `Share` must remain a `miso_share`-issued fixed-supply token; recorded here
  and in the misofm plugin audits.
- **F6 (Informational): settled-balance sweeps are commit snapshots.**
  `sweep_and_deposit` reads the pool-address balance as of the beginning of
  the current consensus commit. Funds credited later in the commit remain for
  a later sweep. The framework clamps an underlying u128 accumulator to
  `u64::MAX`, so a larger balance is recovered across multiple commits. Empty
  snapshots abort explicitly with `ENoSettledFunds`; competing cranks may race,
  but accumulator redemption prevents overdrawing and transaction atomicity
  rolls back any failed deposit.

Checked and cleared — no finding:

- **Double-claim / skipped claim**: index advance is monotone and exactly
  consumed-delta-sized; second claim in the same state yields 0
  (`test_claim_twice_second_yields_zero`).
- **Late-registration retroactivity**: a stake registered after a deposit has
  `last_claim_index = cum`, so past deposits are excluded
  (`test_late_register_no_retroactive_share`,
  `test_re_register_after_destroy_no_retroactive_earnings`). No activation
  delay is needed and none exists (module doc, `pool.move:37-47`) — a
  just-in-time stake only competes for *future* deposits, never dilutes past
  ones.
- **Unregister mid-accrual**: blocked until drained (`ELastClaimIndexMismatch`);
  enforced ordering sweep→unregister, which is what `routed_stake` relies on.
- **Pool impersonation**: `RoyaltyPoolKey` encodes both phantom types, so the
  address of a pool fully determines its type; a wrong-`Share` pool claims a
  different (unpaid) address and can neither squat nor spoof the canonical
  one (`pool.move:98-111`). `assert_derived_from` lets consumers pin the
  parent (`pool.move:377-385`, tested both ways).
- **Registration key confusion**: keyed by `type_name::with_defining_ids`
  (defining-id form), so two currencies cannot collide on a name; two pools
  of the *same* currency are intentionally one-slot (see L2).
- **`Stake` balance is immutable** (`stake.move:31-32`) — no top-up path, so
  no mid-registration amount-change desync; enlarge by minting more stakes.
- **Event honesty**: all amounts are measured from actual balances at
  mutation time.

## Edge cases (verified by reading + tests, 32/32 passing)

- Zero-value deposit aborts (`EInvalidValue`); zero-balance stake rejected
  (`EZeroBalance`); destroy with registrations aborts (`EPoolsRegistered`).
- Two-currency stake: independent registrations, independent claims, clean
  destroy (`test_two_currencies_same_stake`).
- Sole staker drains an indivisible deposit to exact zero and unregisters
  (`test_sole_staker_drains_indivisible_deposit_and_unregisters`) — the pool
  can reach balance 0 with no stuck dust in the single-staker case.
- `pending_rewards` matches the subsequent claim exactly and returns 0 for
  unregistered/foreign-pool stakes (`test_pending_rewards_*`).
- Coin-object recovery folds real value and distributes it
  (`test_receive_and_deposit_*`). Empty settled-balance sweeps abort with
  `ENoSettledFunds`. The Move unit VM does not populate funded
  `AccumulatorRoot` reads, so a funded amountless sweep must be verified on
  localnet or a live network.

## Verification

- **32/32 unit tests** (`sui move test`, sui 1.77.2), including the
  fractional-credit, zero-stake-abort, re-registration, and wrong-parent
  negatives cited above.
- Solvency and overflow arguments re-derived from the source (above), not
  assumed.
- Cross-read of consumers: `routed_stake` (this audit set) and the three
  misofm vault plugins (audits + sources) — all use the pool exactly within
  the invariants proven here.

## Load-bearing assumptions

- **`miso_share` fixed supply ≤ 10¹³** per share type (F5) — the whole
  precision/no-lock argument.
- Framework: `derived_object::claim` uniqueness; accumulator semantics of
  `send_funds`/`withdraw_funds_from_object`/`public_receive` (via `hikida`);
  `type_name::with_defining_ids` stability. Framework rev pinned in
  `Move.lock`: `06734f6`.
- `hikida` `e88c6fa8` correctness (58 LOC, re-read: thin, correct wrappers).

## Amendment — 2026-09-07 (exact accounting)

- **F7 (Medium — fixed): the consumed-index advance over-credited claimants.**
  `claim_rewards` advanced `last_claim_index` by `⌊reward·P/s⌋`, which is
  less than the index the reward actually consumed unless `reward·P` is
  divisible by `s`; the claimant kept up to `s/P` base units of phantom credit
  per claim. At the 10¹³ share supply that is ≈10⁻⁵ units per claim, so a
  near-full-supply staker running ~10⁵ one-unit deposit+claim cycles made the
  pool one base unit insolvent and other stakes' `claim_rewards` abort in
  `balance.split` — for `routed_stake`, that blocked `sweep`, hence
  `unregister` and `unstake`. The "consumed-index advance is exact" claim and
  the solvency proof above were wrong in that step.
  **Fix:** registrations now store `debt` in `shares·index` units at full
  precision (`stake.move`), a claim pays `⌊(shares·index − debt)/P⌋` and adds
  `reward·P` to the debt, and deposits keep their division remainder in a
  `carry` field folded into the next deposit (`pool.move`). Lifetime payout
  per registration is exactly `⌊shares·Δindex/P⌋`; the invariant
  `balance·P == Σ(shares·index − debt) + carry + forfeited` holds after every
  operation and is asserted by the randomized property tests in
  `tests/royalty_pool_accounting_tests.move` (three seeds × 250 operations,
  plus the whale replay, the sub-unit late registrant, and the `S > P` carry
  fold). Deposit truncation-to-zero (F5) is no longer reachable for any share
  supply. Behavioral change: a sole staker with an indivisible deposit is
  paid the exact floor (1 of 2), not the phantom 2.
- Reviewed alternatives: `⌈reward·P/s⌉` for the consumed index (flips the
  drift into a bounded per-claim loss) and a ceil'd settled counter (forfeits
  up to two units per registration); both rejected for the exact-debt form.
