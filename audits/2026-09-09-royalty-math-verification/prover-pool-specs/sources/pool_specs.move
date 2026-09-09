module royalty_pool_specs::pool_specs;

use prover::prover::{requires, ensures};
use sui::balance::Balance;
use royalty_pool::pool::{Self, RoyaltyPool};

const P: u128 = 1_000_000_000_000_000_000;

/// SPEC I-B4 (carry bound) and the deposit-fold conservation that underlies I-B2.
#[spec(prove, target = royalty_pool::pool::deposit)]
fun deposit_spec<Share, Currency>(self: &mut RoyaltyPool<Share, Currency>, balance: Balance<Currency>) {
    let shares = self.staked_shares();
    requires(shares > 0);
    requires(balance.value() > 0);
    requires(self.carry() < (shares as u128));
    // Reachability bounds (SPEC I-B7): the on-chain counters must have room for this deposit,
    // otherwise Move aborts with an arithmetic error (which is the desired behaviour, not corruption).
    requires(self.balance().value().to_int().add(balance.value().to_int()).lte(18446744073709551615u64.to_int()));
    requires(self.cumulative_deposits().to_int().add(balance.value().to_int()).lte(340282366920938463463374607431768211455u128.to_int()));
    requires(self.cumulative_reward_per_share().to_int().add(balance.value().to_int().mul(P.to_int())).lte(
        115792089237316195423570985008687907853269984665640564039457584007913129639935u256.to_int()));
    let old_index = self.cumulative_reward_per_share();
    let old_carry = self.carry();
    let old_bal = self.balance().value();
    let old_cum = self.cumulative_deposits();
    let v = balance.value();

    pool::deposit(self, balance);

    ensures(self.staked_shares() == shares);
    ensures(self.carry() < (shares as u128));
    ensures(self.balance().value().to_int() == old_bal.to_int().add(v.to_int()));
    ensures(self.cumulative_deposits().to_int() == old_cum.to_int().add(v.to_int()));
    ensures(self.cumulative_reward_per_share().to_int().gte(old_index.to_int()));
    // (index' - index) * shares + carry' == v * P + carry
    ensures(
        self.cumulative_reward_per_share().to_int().sub(old_index.to_int()).mul(shares.to_int()).add(self.carry().to_int())
            == v.to_int().mul(P.to_int()).add(old_carry.to_int())
    );
}
