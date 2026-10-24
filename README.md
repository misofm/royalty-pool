# `royalty_pool`

> **Archived.** This package moved to [`misofm/framework`](https://github.com/misofm/framework/tree/main/royalty_pool),
> with its history. Depend on it with `git = "https://github.com/misofm/framework.git"` and `subdir = "royalty_pool"`.

> Accumulator-based royalty distribution: holders stake a work's share coin, callers deposit revenue, and every deposit is split pro-rata with O(1) work per deposit and per claim.

A `RoyaltyPool<Share, Currency>` distributes `Currency` payouts to holders of
the `Share` coin. Each `miso_music` Recording and Composition has one canonical pool
per payout currency, derived from the work and staking the work's own coin, and
every revenue stream for the work (sales, streams, merch) pays its holders
through it. `Stake<Share>` holds a plain `Balance<Share>`.

## How it works

The pool keeps a `cumulative_royalty_per_share` index. A deposit of `v` across `S` staked shares advances the index by `⌊(v · PRECISION + carry) / S⌋` and keeps the remainder in `carry`, so deposit rounding never loses value; a registration records its debt as `shares · index` at full precision and a claim pays `⌊(shares · index − debt) / PRECISION⌋`, adding `royalty · PRECISION` back to the debt. Neither operation iterates over holders, so cost does not grow with the number of stakers.

The accounting is exact: a registration's lifetime payout is precisely `⌊shares · Δindex / PRECISION⌋`, sub-unit credit carries across claims without ever being inflated, and `balance · PRECISION == Σ(shares · index − debt) + carry + forfeited` holds at all times — the pool can never owe more than it holds. With a share supply of at most `100_000_000_000_000` base units and `PRECISION = 10^18`, the pool-wide deposit carry is strictly less than `10^-4` of one payout base unit. Carry is folded into a later index update against the stake set then registered, so this conservation guarantee does not promise exact attribution of that sub-base-unit residual to the cohort present when it arose. The only other value that stays behind is under one base unit of residue per registration, forfeited at unregister.

The supply bound is an assumption, not a check. `miso_music` work coins have exactly `10^14` base units, but the pool cannot read the supply of an arbitrary `Share` type, so `pool::new` does not verify it. Overflow safety and conservation hold for any supply; only the carry and attribution bounds in this section assume at most `10^14`.

The fixed supply does not by itself bound lifetime deposits; the number of transactions does. The deposit numerator `value · PRECISION + carry` needs at most 124 bits, and `carry` is below `staked_shares` as of the last deposit (so it fits a `u64`) and is in `value · PRECISION` units. Each deposit advances the index by less than `2^124`, so the `u256` index and `shares · index` or registration debt (`shares < 2^64`) cannot overflow before `2^68` maximum-sized deposits. Keep `PRECISION = 10^18`, the `u128` deposit intermediate, and `u256` index/debt: a `u128` scaled obligation would overflow on the 19th fully paid `u64::MAX` deposit cycle for a one-share position. Overflow aborts atomically.

Because `10^18 / 10^14 = 10,000` exactly, every positive deposit of `v` advances the index by at least `v * 10,000`. A continuously registered holder with `s` shares therefore receives at least `floor(s * total_deposits_during_registration / 10^14)` across claims and pending royalties. This is the fixed-total-supply minimum, not exact historical attribution to each changing registered group. Repeated membership changes can accumulate carry differences over time; the `10^-4` bound applies to the outstanding remainder, not lifetime aggregate differences.

## Construction and identity

`pool::new_for_recording<RecordingShare, Currency>(recording, cap)` and
`pool::new_for_composition<CompositionShare, Currency>(composition, cap)` take
the work and its admin cap, and claim the pool's ID from the work under
`RoyaltyPoolKey<Currency>()`. Taking the work fixes `Share` to the work's own
coin, and the key is private to this package, so no one else can create a pool
at these addresses. There is one pool per work and currency: a second one
aborts with `derived_object::EObjectAlreadyExists`.
`pool::derive_address<Currency>(work_id)` computes the address from the work's
ID and the currency alone, without the share type; funds sent there for any
other ID are unrecoverable. Creation returns an unshared pool; callers register
stakes and call `pool::share` in the same transaction, so waiting funds are
settled to the registered stakes rather than collected by the first staker.

`stake::new(balance, ctx)` consumes a positive `Balance<Share>`, and
`stake::destroy` returns it after all registrations are removed. The type
system ties stakes to pools: `register_stake`, `unregister_stake`,
`claim_royalties` and `pending_royalties` take `Stake<Share>` for the pool's own
`Share`. The wrapper never exposes mutable access to its principal while
registered. A stake registers in each pool at most once; its registrations are
keyed by pool ID. Anyone with `&mut Stake` can claim its royalties, so stakes
must stay address-owned or wrapped by a module that gates access; a shared or
carelessly wrapped stake is drainable.

## Honest addresses

Each payout currency has its own derived pool address under the work. Funds
can be sent to the derived pool address before construction and settled after
holders register.

While `staked_shares == 0`, `deposit` aborts with `ENoStakedShares` (a zero
deposit is still a no-op), and funds at the pool address keep accumulating and go
to whoever registers next. Tooling should keep at least one stake registered
with every pool that receives revenue.

Coins or funds in a currency other than the pool's `Currency` sent to a pool
address are not recoverable: `recover_coins` and `settle` only handle the
pool's own `Currency`.

## Settlement guard

Within one consensus commit the accumulator's settled snapshot is fixed, and a
second accumulator withdraw from the same address in the same commit fails the
whole transaction (`InsufficientFundsForWithdraw`, which Move cannot catch).
Sui's `Clock` is set once per commit and never goes backwards. The pool keeps
`last_settled_at_ms` and redeems from the accumulator at most once per clock
timestamp, through `settle`:

1. If `clock.timestamp_ms() == last_settled_at_ms`, return 0.
2. Stamp `last_settled_at_ms` with the current time.
3. If no stake is registered, return 0; the funds stay at the pool address.
4. Redeem everything settled; if zero, return 0.
5. Fold it in like a deposit and emit `RoyaltyDepositedEvent`.

`settle`, `register_stake` and `unregister_stake` run this first, before any
accounting change. Without the guard, anyone calling `settle` in every commit
would make every other register or unregister in that commit fail.
`claim_royalties` and `pending_royalties` do not settle and take no clock.

- Registering settles first, so funds already waiting go to the stakes
  registered before the newcomer.
- Unregistering settles first, so the leaving stake is credited for funds
  that arrived while it was registered, and returns its remaining royalties.
- A claimant who wants the latest funds calls `settle` before
  `claim_royalties`.

**Exit.** `unregister_stake` returns everything the stake can still claim
as a `Balance<Currency>`; only sub-base-unit residue is forfeited. No prior
claim is needed.

## Recovery paths

Both recovery entries are **total**: a crank-facing call never aborts for
having nothing to do; it returns 0 and changes nothing besides the settle
stamp.

- `settle(pool, root, clock)` redeems everything settled at the pool's own
  address (via Sui's funds accumulator) and folds it into the accumulator.
  Callers pass the immutable system `AccumulatorRoot` at `0xacc` and the
  `Clock` at `0x6`; they do not calculate or supply an amount. Returns the
  value deposited; returns 0 when this timestamp was already settled, when
  nothing is settled, or when the pool has no staked shares yet (the funds
  stay at the pool's address, unredeemed, until a stake registers). The
  framework's read returns at most `u64::MAX` per call, so excess value and
  funds arriving later in the current commit remain for a later `settle`.
- `recover_coins(pool, coins)` converts `Coin<Currency>` objects sent
  directly to the pool's address into funds at that same address, so a later
  `settle` can fold them in. It never deposits by itself. Returns the value
  converted; 0 for an empty vector. It emits no event.

Funded `settle` withdraws from the pool's address balance, which requires the
`enable_object_funds_withdraw` protocol feature on the network.

The Move unit-test VM does not settle accumulators, so settled value is
always 0 in unit tests. They cover the root wiring, the guard's stamping and
skip paths, and the zero-return paths of `settle`. The funded settle path,
including the same-commit double-withdraw failure the guard prevents, must be
verified on localnet or a live network.

## Views

- `pool::staked_shares`, `pool::balance_value` (held for stakes, including
  sub-unit residue), `pool::cumulative_royalty_per_share` (scaled by
  `PRECISION`) and `pool::last_settled_at_ms`.
- `pool::pending_royalties(pool, stake)`: what `claim_royalties` would pay now.
- `pool::derive_address<Currency>(work_id)`: the pool address.
- `stake::value`, `stake::has_registration(stake, pool_id)` and
  `stake::pool_ids` (the pools the stake is registered with).

## Event schemas

An indexer can rebuild every pool and stake from these events and the
transaction envelope alone, without reading object storage. Pool events are
phantom-typed as `Name<Currency>` (the created event as
`RoyaltyPoolCreatedEvent<Share, Currency>`) and type object identities as
`ID`. All payloads are fixed-size (BCS bytes below), far under Sui's 250 KiB
per-event limit.

| Event | Fields | Bytes |
| --- | --- | --- |
| `RoyaltyPoolCreatedEvent` | `pool_id`, `work_id` | 64 |
| `StakeRegisteredEvent` | `pool_id`, `stake_id`, `amount`, `staked_shares` | 80 |
| `RoyaltyDepositedEvent` | `pool_id`, `value`, `balance`, `cumulative_royalty_per_share` | 80 |
| `RoyaltyClaimedEvent` | `pool_id`, `stake_id`, `value`, `balance` | 80 |
| `StakeUnregisteredEvent` | `pool_id`, `stake_id`, `amount`, `value`, `balance`, `staked_shares` | 96 |
| `StakeCreatedEvent<Share>` | `stake_id`, `amount` | 40 |
| `StakeDestroyedEvent<Share>` | `stake_id`, `amount` | 40 |

- A new pool starts with zero balance, staked shares and index.
- `amount` is the stake's share amount; `value` is the `Currency` moved.
  `balance`, `staked_shares` and `cumulative_royalty_per_share` are the pool's
  values after the action.
- `RoyaltyDepositedEvent` is emitted by `deposit` and by a positive `settle`
  (including the settle inside register and unregister, which precedes their
  own event). A zero deposit is a silent no-op.
- `RoyaltyClaimedEvent` is emitted for positive claims only.
- Registration debt stays derived: a registration's debt is
  `amount · cumulative_royalty_per_share` (the index from the pool's latest
  deposit event, or 0), and each claim adds `value · PRECISION`. Pending
  royalties follow from the formula in "How it works".
- Not emitted: `carry` (internal; the emitted index already includes it) and
  `last_settled_at_ms` (the settle guard's stamp, written by every settle
  attempt; it is not pool data). Sharing, `recover_coins` (it moves funds to
  the pool's address balance, visible in the transaction effects) and views
  emit nothing.

## License

[Functional Source License 1.1, ALv2 Future License](./LICENSE.md)
(FSL-1.1-ALv2). Any use except a Competing Use is permitted, and each version
becomes Apache-2.0 two years after its release.
