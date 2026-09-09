"""An independent Python re-implementation of the royalty_pool math,
written directly from pool.move (not from the Rust model), used as a third
oracle for the adversarial scenarios' expected values.

pool.move:207-214   deposit
pool.move:265       register_stake debt
pool.move:416-418   calculate_reward
pool.move:330       claim adds reward*P to debt
"""
P = 10**18
U64 = 2**64 - 1

class Abort(Exception):
    pass

class Pool:
    def __init__(self):
        self.index = 0        # cumulative_reward_per_share (u256)
        self.carry = 0        # u128
        self.staked = 0       # u64
        self.balance = 0      # u64
        self.cum = 0          # cumulative_deposits (u128)
        self.forfeited = 0    # ghost, P-units
        self.parked = 0       # ghost: funds at the pool address

    def deposit(self, value):
        if self.staked == 0:
            raise Abort("ENoStakedShares(1)")
        if value == 0:
            raise Abort("EInvalidValue(6)")
        if self.balance + value > U64:
            raise Abort("balance::join u64 overflow")
        numerator = value * P + self.carry
        self.index += numerator // self.staked
        self.carry = numerator % self.staked
        self.cum += value
        self.balance += value

    def sweep_and_deposit(self):
        if self.parked == 0:
            raise Abort("ENoSettledFunds(7)")
        v, self.parked = self.parked, 0
        self.deposit(v)

    def register(self, stake):
        if stake.reg is not None:
            raise Abort("EAlreadyRegistered(2)")
        stake.reg = {"debt": stake.amount * self.index, "paid": 0,
                     "idx0": self.index}
        self.staked += stake.amount

    def reward(self, stake):
        return (stake.amount * self.index - stake.reg["debt"]) // P

    def claim(self, stake):
        r = self.reward(stake)
        stake.reg["debt"] += r * P
        stake.reg["paid"] += r
        self.balance -= r
        return r

    def unregister(self, stake):
        if self.reward(stake) != 0:
            raise Abort("ELastClaimIndexMismatch(5)")
        self.forfeited += stake.amount * self.index - stake.reg["debt"]
        self.staked -= stake.amount
        stake.reg = None

class Stake:
    def __init__(self, amount):
        if amount == 0:
            raise Abort("EZeroBalance(0)")
        self.amount = amount
        self.reg = None

def bps_apply(amount, rate):
    return (amount * rate) // 10000

def distribute(total, splits):
    amounts = [bps_apply(total, s) for s in splits]
    return amounts, total - sum(amounts)
