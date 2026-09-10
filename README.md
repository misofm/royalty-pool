# `royalty_pool`

> Accumulator-based royalty distribution: holders stake share tokens, callers deposit revenue, and every deposit is split pro-rata with O(1) work per deposit and per claim.

**Layer:** `lib` — a primitive, not core protocol and not an extension (it attaches to nothing miso-specific). A `RoyaltyPool<Share, Currency>` is a derived object of any UID-bearing parent.

## How it works

The pool keeps a `cumulative_reward_per_share` index. A deposit of `v` across `S` staked shares advances the index by `⌊(v · PRECISION + carry) / S⌋` and keeps the remainder in `carry`, so deposit rounding never loses value; a registration records its debt as `shares · index` at full precision and a claim pays `⌊(shares · index − debt) / PRECISION⌋`, adding `reward · PRECISION` back to the debt. Neither operation iterates over holders, so cost does not grow with the number of stakers.

The accounting is exact: a registration's lifetime payout is precisely `⌊shares · Δindex / PRECISION⌋`, sub-unit credit carries across claims without ever being inflated, and `balance · PRECISION == Σ(shares · index − debt) + carry + forfeited` holds at all times — the pool can never owe more than it holds. The only value that stays behind is under one base unit of residue per registration, forfeited at unregister.

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

## License

Apache-2.0
