module royalty_pool_specs::claim_specs;

use std::type_name;
use prover::prover::{requires, ensures};
use sui::balance::Balance;
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};

const P: u128 = 1_000_000_000_000_000_000;

/// SPEC I-B3/I-B9 and the claim bookkeeping: reward = floor((amount·index − debt)/P),
/// debt' = debt + reward·P, balance' = balance − reward, and a second claim would pay 0.
/// Solvency (I-B1) is assumed as a precondition here; it is a state invariant proven elsewhere.
#[spec(prove, target = royalty_pool::pool::claim_rewards)]
fun claim_rewards_spec<Share, Currency>(self: &mut RoyaltyPool<Share, Currency>, stake: &mut Stake<Share>): Balance<Currency> {
    let currency = type_name::with_defining_ids<Currency>();
    requires(stake.has_registration(&currency));
    requires(stake::registration_pool_id(stake.get_registration(&currency)) == object::id(self));
    let amount = stake.value();
    let index = self.cumulative_reward_per_share();
    let debt = stake::registration_debt(stake.get_registration(&currency));
    let owed = amount.to_int().mul(index.to_int());
    requires(owed.lte(115792089237316195423570985008687907853269984665640564039457584007913129639935u256.to_int())); // I-B7
    requires(debt.to_int().lte(owed));                                   // I-B3
    let reward_int = owed.sub(debt.to_int()).div(P.to_int());
    requires(reward_int.lte(self.balance().value().to_int()));           // I-B1 (assumed)
    let old_bal = self.balance().value();
    let old_shares = self.staked_shares();

    let reward = pool::claim_rewards(self, stake);

    // post-state shape first, so later ensures that read the registration cannot abort
    ensures(stake.has_registration(&currency));
    ensures(stake::registration_pool_id(stake.get_registration(&currency)) == object::id(self));
    ensures(stake.value() == amount);
    ensures(reward.value().to_int() == reward_int);
    ensures(self.balance().value().to_int() == old_bal.to_int().sub(reward_int));
    ensures(self.cumulative_reward_per_share() == index);
    ensures(self.staked_shares() == old_shares);
    ensures(stake::registration_debt(stake.get_registration(&currency)).to_int()
        == debt.to_int().add(reward_int.mul(P.to_int())));
    // residue after claim is < P, so a second claim pays 0 (I-B9)
    ensures(owed.sub(stake::registration_debt(stake.get_registration(&currency)).to_int()).lt(P.to_int()));
    ensures(pool::pending_rewards(self, stake) == 0);
    reward
}
