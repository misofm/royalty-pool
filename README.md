# `royalty_pool`

> Accumulator-based royalty distribution: holders stake share tokens, callers deposit revenue, and every deposit is split pro-rata with O(1) work per deposit and per claim.

**Layer:** `lib`. A `RoyaltyPool<Share, Currency>` is a derived object of any UID-bearing parent. Production construction requires a `coin_registry::Currency<Share>` that passes `share::share::is_share`; payout `Currency` remains arbitrary.

## How it works

The pool keeps a `cumulative_reward_per_share` index. A deposit of `v` across `S` staked shares advances the index by `⌊(v · PRECISION + carry) / S⌋` and keeps the remainder in `carry`, so deposit rounding never loses value; a registration records its debt as `shares · index` at full precision and a claim pays `⌊(shares · index − debt) / PRECISION⌋`, adding `reward · PRECISION` back to the debt. Neither operation iterates over holders, so cost does not grow with the number of stakers.

The accounting is exact: a registration's lifetime payout is precisely `⌊shares · Δindex / PRECISION⌋`, sub-unit credit carries across claims without ever being inflated, and `balance · PRECISION == Σ(shares · index − debt) + carry + forfeited` holds at all times — the pool can never owe more than it holds. With verified share supply capped at `100_000_000_000_000` base units and `PRECISION = 10^18`, the pool-wide deposit carry is strictly less than `10^-4` of one payout base unit. Carry is folded into a later index update against the stake set then registered, so this conservation guarantee does not promise exact attribution of that sub-base-unit residual to the cohort present when it arose. The only other value that stays behind is under one base unit of residue per registration, forfeited at unregister.

The fixed supply does not by itself bound lifetime deposits. The existing `cumulative_deposits: u128` counter supplies that limit: before it is reached, the cumulative index needs at most 188 bits and `shares * index` or registration debt needs at most 235 bits. The deposit numerator needs at most 124 bits. Keep `PRECISION = 10^18`, the `u128` deposit intermediate, and `u256` index/debt. A `u128` scaled obligation would overflow on the 19th fully paid `u64::MAX` deposit cycle for a one-share position; the actual lifetime counter permits 18,446,744,073,709,551,617 maximum-sized deposits before the next addition exceeds its range. Overflow aborts atomically.

Because `10^18 / 10^14 = 10,000` exactly, every positive deposit of `v` advances the index by at least `v * 10,000`. A continuously registered holder with `s` shares therefore receives at least `floor(s * total_deposits_during_registration / 10^14)` across claims and pending rewards. This is the fixed-total-supply minimum, not exact historical attribution to each changing registered group. Repeated membership changes can accumulate carry differences over time; the `10^-4` bound applies to the outstanding remainder, not lifetime aggregate differences.

## Verified construction

`pool::new<Share, Currency>(parent, share_currency)` admits a pool only when `share_currency` proves that `Share` has the required type shape, immutable metadata, six decimals, no regulation or freeze authority, and the fixed 100,000,000-token supply. An invalid or incompletely initialized currency aborts with `EInvalidShareCurrency`. The unchecked constructor used by generic arithmetic tests is marked `#[test_only]` and is absent from production bytecode.

## Honest addresses

The derivation key encodes both type parameters, so a pool's address is determined by `(parent, Share, Currency)` — the same parameters that produce the object. The pool at a canonical address is therefore necessarily of the matching type, and (being `key`-only, with `share` as its only consumer) necessarily shared. A pool created with a foreign `Share` claims a different, unpaid address: it can neither impersonate nor block the real one.

That property is what lets payers deliver to a derived address before the pool exists — funds wait at an address only the correctly-typed, shared pool can ever claim, and folding them in is permissionless.

## Recovery paths

Both recovery entries are **total**: a crank-facing call never aborts for
having nothing to do; it returns 0 and changes nothing.

- `settle(pool, root)` redeems everything settled at the pool's own address
  (via Sui's funds accumulator) and folds it into the accumulator. Callers
  pass the immutable system `AccumulatorRoot` at `0xacc`; they do not
  calculate or supply an amount. Returns the value deposited; returns 0
  without touching the accumulator when nothing is settled, or when the pool
  has no staked shares yet (the funds stay at the pool's address, unredeemed,
  until a stake registers). The framework's read returns at most `u64::MAX`
  per call, so excess value and funds arriving later in the current commit
  remain for a later `settle`.
- `recover_coins(pool, coins)` converts `Coin<Currency>` objects sent
  directly to the pool's address into funds at that same address, so a later
  `settle` can fold them in. It never deposits by itself. Returns the value
  converted; 0 for an empty vector.
- `settled_value(pool, root)` is a read-only view of what `settle` would
  redeem right now.

The Move unit-test VM does not populate funded accumulator snapshots. Unit
tests cover the root wiring and both zero-return paths of `settle` (nothing
settled, and no stakers yet); the positive-redemption path must be verified
on localnet or a live network.

## Event schemas

Pool events are phantom-typed as `Name<Share, Currency>`, use `address` for
object identities, and report the post-state suffix
`(pool_balance_after: u64, staked_shares_after: u64,
cumulative_reward_per_share_after: u256, carry_after: u128,
cumulative_deposits_after: u128)`. The event-specific fields are:

- `RoyaltyPoolCreatedEvent`: `pool_id`, `parent_id`, `precision`.
- `RoyaltyDepositedEvent`: `pool_id`, `value`,
  `cumulative_reward_per_share_before`, `carry_before`.
- `RoyaltyPoolFundsSettledEvent`: `pool_id`, `source_address`,
  `accumulator_root_id`, `value`, `cumulative_reward_per_share_before`,
  `carry_before`; it is emitted only after a positive settlement.
- `RoyaltyPoolCoinsRecoveredEvent`: `pool_id`,
  `coin_count`, `funds_recipient`, `value`; it is emitted for every nonempty
  recovery input, including nonempty zero-value coins, and never for an empty
  vector.
- `StakeRegisteredEvent`: `pool_id`, `stake_id`, `staked_amount`,
  `registration_debt_after`, `stake_registration_count_after`.
- `StakeUnregisteredEvent`: `pool_id`, `stake_id`, `unstaked_amount`,
  `removed_registration_debt`, `forfeited_reward_numerator`,
  `stake_registration_count_after`.
- `RoyaltyClaimedEvent`: `pool_id`, `stake_id`, `staked_amount`,
  `reward_amount`, `registration_debt_before`, `registration_debt_after`,
  `reward_residue_after`, `stake_registration_count_after` (positive reward
  claims only; zero reward claims still advance debt and return a zero
  balance silently).

Stake lifecycle events are phantom-typed only by `Share`:
`StakeCreatedEvent` includes `stake_id`, `transaction_sender`, `amount`, and
`registration_count_after`; `StakeDestroyedEvent` includes `stake_id`,
`amount`, and `registration_count_before`. Read-only views emit nothing.

`RoyaltyDepositedEvent` and `RoyaltyPoolFundsSettledEvent` are mutually
exclusive accounting receipts. A direct balance deposit emits only the former;
a successful accumulator settlement emits only the latter. Consumers must not
sum framework accumulator effects as another pool deposit.

## License

Apache-2.0

Pool construction emits `RoyaltyPoolCreatedEvent` once with parent identity and initial accounting state. Sharing is silent; registration and deposits retain their own state-bearing events, including when performed before sharing.

Coin-receipt events retain the consumed coin count, amounts and business identities.
They do not duplicate a variable-length list of input coin IDs; transaction inputs/effects provide that provenance when needed.
