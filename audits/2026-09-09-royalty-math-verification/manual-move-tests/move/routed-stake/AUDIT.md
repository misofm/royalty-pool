# Security Audit — `routed_stake`

**Revision:** working tree (source snapshot — no `.git` in repo) ·
**Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65

**Pinned dependencies** (`Move.toml`): `royalty_pool` `8470e492` (audited in
this set, `royalty-pool/AUDIT.md`); transitive `hikida` `e88c6fa8`.

Audit of `routed_stake.move` (278 LOC) — the wrapper that makes a
shared-object stake safe by fixing its reward route. This is a money package;
it got deep treatment. Verdict: **safe to publish — no Critical/High/Medium
findings.**

## What it does

A `RoutedStake<StakeShare, PoolShare>` is a derived object of any UID-bearing
parent, wrapping a `royalty_pool::stake::Stake<StakeShare>` in an `Option`
(`routed_stake.move:48-54`). The route is the whole point: the **only**
reachable claim path for the wrapped stake's rewards is the permissionless
`sweep` (`:199-222`), which deposits them into the parent's own
`RoyaltyPool<PoolShare, Currency>`. Lifecycle ops (`register`, `unregister`,
`unstake`, `restake`) require the parent's `&mut UID` — cap-gating happens at
the parent, exactly as with `RoyaltyPool` creation. The wrapper is never
deleted: `unstake` empties it, `restake` refills it, so the one derived
address per `(parent, StakeShare)` stays usable forever (`:29-31`).

Threat model: reward redirection (a crank sending rewards anywhere but the
parent's pool), principal theft (someone other than the parent's admin
extracting the wrapped shares), pool/stake substitution with same-typed
foreign objects, derivation-address squatting, PTB-composability abuse within
one transaction.

## Why it's safe

- **Rewards cannot be redirected.** `sweep` asserts the wrapper's own address
  derives from `parent_id` *and* the destination pool's address derives from
  the same `parent_id` under `RoyaltyPoolKey<PoolShare, Currency>`
  (`:205-206`; `pool.move:377-385`). Because `derived_object` addresses are a
  pure function of `(parent, key-type)`, the caller chooses *when* to sweep,
  never *where to*: any `routed_pool` that isn't the parent's own
  correctly-typed pool aborts `EPoolNotDerivedFromParent`. The claimed
  `Balance` is moved straight into `routed_pool.deposit` — it never exists as
  a caller-owned value in a state where it could be diverted, so there is no
  intra-transaction window to abuse (PTB-safe by construction, `:209-221`).
- **The claim source is pinned too.** `stake_pool.claim_rewards` enforces
  that the stake's registration names *that* pool (`EPoolIdMismatch`,
  `pool.move:301`), so a sweep can only draw from a pool the stake is
  actually registered with.
- **Principal cannot leave except to the parent's admin.** `unstake`
  (`:154-169`) is gated by the parent's `&mut UID` (via
  `assert_derived_from(parent.to_inner())`, `:158`) — only whoever holds the
  parent's admin cap can obtain that reference. The returned principal
  `Balance<StakeShare>` goes to that caller; the misofm plugin
  (`composition_routed_stake`) forwards it to the composition's own address,
  closing the loop.
- **The wrapper cannot be escaped or duplicated.** `RoutedStake` is
  `key`-only, no `store`, no `drop`, no delete path: it can't be wrapped,
  transferred, or discarded; `share` (`:115`) is the terminal state. The
  wrapped `Stake` (which *is* `store`) is sealed inside the `Option`; no
  accessor returns `&mut` to it except internally to pool functions. The
  bare-shared-`Stake` drain (royalty-pool L1) is exactly what this design
  eliminates.
- **Derivation honesty.** `RoutedStakeKey<StakeShare>` (`:57`) yields at most
  one wrapper per `(parent, StakeShare)`; `claim` aborts on re-claim, so no
  second wrapper can shadow the first. A wrapper created under a foreign
  parent claims a different address and fails every `assert_derived_from`
  against the victim parent.

## Findings

- **L1 (Low): `PoolShare` is not pinned by the derivation key — it is burned
  in by first claim.** `RoutedStakeKey` encodes only `StakeShare`
  (`:57`), so the `PoolShare` chosen at the first `new` fixes the sweep
  destination type for that `(parent, StakeShare)` pair forever. Only the
  parent's cap holder (or code they authorize) can call `new` — this is not
  third-party-reachable — but a **buggy** parent extension that passes the
  wrong `PoolShare` permanently misroutes: `sweep` would then need a
  `RoyaltyPool<WrongShare, Currency>` derived from the parent, and until the
  parent admin creates and funds one, positive sweeps abort and rewards sit
  claimable in the stake pool. Stranded-not-stolen, admin-recoverable. The
  misofm plugins pin `PoolShare` to the parent's own share type; the module
  doc flags the expectation (`:25-28`).
  **Disposition (2026-08-24):** accepted — no in-package fix exists:
  committing `PoolShare` into the derivation key would break the
  one-wrapper-per-(parent, StakeShare) invariant, and the misofm plugins pin
  `PoolShare` to the parent's own share type (verified 2026-08-24).
- **L2 (Low): `register`'s `stake_pool` is deliberately unpinned** (`:125-133`)
  — the wrapper accepts any `RoyaltyPool<StakeShare, Currency>` the parent
  admin chooses. A buggy extension could register the stake into a
  foreign-parent pool of the right type; rewards would then accrue there, but
  `sweep` still routes them back to the parent's own pool, and `unregister`
  (sweep-then-exit) always works, so the mistake is recoverable with no value
  loss. The misofm plugin additionally pins the pool to the recording by
  derivation (`assert_pool_for_recording`) — the right place for that check.
  **Disposition (2026-08-24):** accepted — the downstream plugin pins the pool
  by derivation (`assert_pool_for_recording`, verified 2026-08-24), and any
  mis-registration is recoverable via sweep-then-unregister with no value
  loss.
- **F3 (Informational): a positive sweep aborts if the parent's pool has no
  registered stakes** (`ENoStakedShares` in `deposit`, `pool.move:186`).
  Documented (`:196-198`): rewards stay claimable in the stake pool until a
  share holder registers. A permanently stakeless parent pool means
  permanently unswept (but never stolen) rewards — incentive-aligned with the
  pool's purpose.
  **Disposition (2026-08-24):** accepted-by-design — rewards sit claimable,
  never stolen, until a share holder registers; the abort is documented and
  incentive-aligned with the pool's purpose.
- **F4 (Informational): zero-reward sweep is a silent no-op** (destroys the
  zero balance, emits nothing, `:219-221`). Deliberate — composes safely into
  batch cranks.
  **Disposition (2026-08-24):** accepted-by-design — the silent no-op is
  deliberate so batch cranks compose safely.

Checked and cleared — no finding:

- **Unregister ordering**: `unregister` inherits the pool's drained-first
  requirement (`pool.move:271-274`), so accrued rewards provably reach the
  parent's pool before the position can move; `unstake` inherits
  `stake::destroy`'s zero-registrations requirement (`stake.move:85`).
  Principal can never skip out ahead of rewards.
- **Double-claim via sweep**: impossible — pool-side consumed-index advance
  (see `royalty-pool/AUDIT.md` solvency section).
- **State machine**: filled wrapper rejects `restake` (`EStakeExists`),
  empty rejects `unstake`/`register`/`unregister`/`sweep` (`ENoStake`) —
  tested both ways.
- **Arithmetic**: none in this package; reward math is `royalty_pool`'s
  (audited); principal values pass through untouched.

## Edge cases (verified by reading + tests, 16/16 passing)

- Stranger-crank sweep: capability-less caller sweeps and funds land in the
  parent's pool intact (covered by the misofm plugin e2e, and here by
  `routed_stake_e2e_tests`).
- `assert_derived_from` wrong-parent aborts on both wrapper and pool sides.
- Empty-wrapper state transitions all abort correctly; `restake` after
  `unstake` reuses the same derived address (the burned-address persistence
  argument, `:29-31`).
- `stake()` view aborts while empty; `value()` reads 0 while empty.

## Verification

- **16/16 unit + e2e tests** (`sui move test`, sui 1.77.2) in
  `tests/routed_stake_tests.move` and `tests/routed_stake_e2e_tests.move`.
- Cross-read both directions of the contract: `royalty_pool` (this audit set)
  and `misofm/vault-plugins/composition_routed_stake` (audit + source) — the
  plugin's self-enforced bindings (`assert_stake_for_composition`,
  `assert_pool_for_recording`) layer cleanly on top of these primitives.

## Load-bearing assumptions

- `royalty_pool` correctness at pinned rev `8470e492`: derivation-key
  honesty, consumed-index accounting, `ENoStakedShares` behavior, no
  withdrawal path besides `claim_rewards` (all verified in
  `royalty-pool/AUDIT.md`).
- Framework: `derived_object::claim` uniqueness and address purity; `Option`
  semantics; `transfer::share_object` finality. Framework rev per sibling
  lockfiles: `b9149cbf`.
- Parent-side cap-gating: every `&mut UID` argument in this module is only as
  protected as the parent's `uid_mut` — audited for `miso`/`miso_party`
  objects in this set.

## Amendment — 2026-09-07

- **F1 (Medium, in `royalty_pool` — fixed upstream):** the pool's
  consumed-index rounding let a large staker make a pool one base unit
  insolvent, which made `sweep` abort in `balance.split` and so blocked
  `unregister`/`unstake`. Fixed by the exact-debt accounting in
  `royalty_pool` (see its AUDIT.md amendment); this package's
  `swept_rewards_are_claimed_exactly_pro_rata_by_parent_holders` pins the
  end-to-end claim arithmetic.
- **F2 (Low — fixed, protocol-actions #1):** `sweep` aborted while the
  parent's pool had no registered stake, leaving the principal immobile.
  `sweep` now sends the reward to the parent pool's own address in that case
  (folded in later by `pool::sweep_and_deposit`), so the exit path never
  depends on the destination's state
  (`sweep_into_stakeless_parent_pool_keeps_exit_open`).
- F3 (Low): funds delivered to the wrapper's own address remain
  unrecoverable — unchanged; do not pay the wrapper's address.
- **Localnet verification (2026-09-07, sui 1.78.1):** the stakeless-destination
  branch of `sweep` was exercised end to end on a local network: a stranger's
  sweep into a parent pool with zero staked shares succeeded
  (`RoutedStakeSweptEvent.value = 1000`, pool balance unchanged at 0); after a
  100-share holder registered, a stranger's `pool::sweep_and_deposit` folded
  the parked 1,000 from the pool's address (`cumulative_deposits = 1000`, index
  `10¹⁹`), the holder claimed exactly 1,000, the pool's address balance read 0,
  and the parent unregistered and unstaked its 1,000-share principal.
