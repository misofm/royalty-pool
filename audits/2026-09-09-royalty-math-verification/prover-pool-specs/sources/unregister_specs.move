module royalty_pool_specs::unregister_specs;

use std::type_name;
use prover::prover::{requires, ensures};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};

const P: u128 = 1_000_000_000_000_000_000;

/// SPEC I-B8 and I-B11, for `unregister_stake` (`pool.move:282-309`).
///
/// I-B11 (unregister safety): the call only succeeds when the stake's
/// claimable reward is already 0 — i.e. `ELastClaimIndexMismatch` is the
/// only way a *registered, matching-pool* stake can fail to unregister, and
/// a preceding `claim_rewards` always reaches that state (proven separately
/// in `claim_specs`: `pending_rewards == 0` after a claim).
///
/// I-B8 (residue bound): the value forfeited on exit is exactly
/// `amount·index − debt`, and it is **strictly less than PRECISION** — under
/// one whole base unit — because `⌊(amount·index − debt)/P⌋ == 0` is the
/// precondition the function asserts. This is the statement that repeated
/// register/unregister churn cannot forfeit more than one unit per cycle.
///
/// Also pinned: `staked_shares` drops by exactly the stake's amount, the
/// pool's `index`, `carry` and `balance` are untouched (the residue stays in
/// `balance` as dead value, by design — commit 27e2ceb), and the
/// registration is gone afterwards.
#[spec(prove, target = royalty_pool::pool::unregister_stake)]
fun unregister_stake_spec<Share, Currency>(
    self: &mut RoyaltyPool<Share, Currency>,
    stake: &mut Stake<Share>,
) {
    let currency = type_name::with_defining_ids<Currency>();
    requires(stake.has_registration(&currency));
    requires(stake::registration_pool_id(stake.get_registration(&currency)) == object::id(self));

    let amount = stake.value();
    let index = self.cumulative_reward_per_share();
    let debt = stake::registration_debt(stake.get_registration(&currency));
    let owed = amount.to_int().mul(index.to_int());

    // Reachability bounds (SPEC I-B7) and the no-underflow invariant (I-B3).
    requires(owed.lte(115792089237316195423570985008687907853269984665640564039457584007913129639935u256.to_int()));
    requires(debt.to_int().lte(owed));
    // The function's own assert: claimable must already be 0.
    requires(owed.sub(debt.to_int()).lt(P.to_int()));
    // staked_shares covers this stake (it is registered here).
    requires(amount.to_int().lte(self.staked_shares().to_int()));

    let old_shares = self.staked_shares();
    let old_balance = self.balance().value();
    let old_carry = self.carry();

    pool::unregister_stake(self, stake);

    // The registration is gone (I-B11's postcondition).
    ensures(!stake.has_registration(&currency));
    ensures(stake.value() == amount);
    // Shares drop by exactly this stake's amount.
    ensures(self.staked_shares().to_int() == old_shares.to_int().sub(amount.to_int()));
    // The accumulator and the money are untouched: the residue is forfeited
    // in place, into `balance`, not paid out and not destroyed.
    ensures(self.cumulative_reward_per_share() == index);
    ensures(self.balance().value() == old_balance);
    ensures(self.carry() == old_carry);
    // I-B8: the forfeited residue is strictly under one whole base unit.
    ensures(owed.sub(debt.to_int()).lt(P.to_int()));
}
