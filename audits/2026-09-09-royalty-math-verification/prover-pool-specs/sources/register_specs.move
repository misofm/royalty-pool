module royalty_pool_specs::register_specs;

use std::type_name;
use prover::prover::{requires, ensures};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};

/// SPEC I-B10 (late-joiner isolation): registration sets debt to amount·index, so
/// pending is zero immediately after registering; staked_shares grows by amount; index unchanged.
#[spec(prove, target = royalty_pool::pool::register_stake)]
fun register_stake_spec<Share, Currency>(self: &mut RoyaltyPool<Share, Currency>, stake: &mut Stake<Share>) {
    let currency = type_name::with_defining_ids<Currency>();
    requires(!stake.has_registration(&currency));
    let shares = self.staked_shares();
    let amount = stake.value();
    requires(shares.to_int().add(amount.to_int()).lte(18446744073709551615u64.to_int()));
    requires(amount.to_int().mul(self.cumulative_reward_per_share().to_int()).lte(
        115792089237316195423570985008687907853269984665640564039457584007913129639935u256.to_int()));
    let old_index = self.cumulative_reward_per_share();

    pool::register_stake(self, stake);

    ensures(self.staked_shares().to_int() == shares.to_int().add(amount.to_int()));
    ensures(self.cumulative_reward_per_share() == old_index);
    ensures(stake.has_registration(&currency));
    ensures(stake.value() == amount);
    ensures(stake::registration_pool_id(stake.get_registration(&currency)) == object::id(self));
    ensures(stake::registration_debt(stake.get_registration(&currency)).to_int()
        == amount.to_int().mul(old_index.to_int()));
    ensures(pool::pending_rewards(self, stake) == 0);
}
