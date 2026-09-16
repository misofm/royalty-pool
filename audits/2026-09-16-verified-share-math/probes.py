#!/usr/bin/env python3
"""Independent integer oracle. No target implementation is imported."""
from fractions import Fraction
import json
import random

P = 10**18
N = 10**14
U64 = 2**64 - 1
U128 = 2**128 - 1
U256 = 2**256 - 1


class Pool:
    def __init__(self, cap=N):
        self.cap = cap
        self.index = self.carry = self.balance = self.deposits = 0
        self.forfeited = self.paid = 0
        self.live = {}

    def register(self, key, amount):
        assert key not in self.live and 0 < amount <= self.cap - self.shares()
        self.live[key] = [amount, amount * self.index, self.index, 0, self.deposits]
        self.check()

    def shares(self):
        return sum(x[0] for x in self.live.values())

    def deposit(self, value):
        assert 0 < value <= U64 and self.balance + value <= U64
        assert self.deposits + value <= U128 and self.shares() > 0
        delta, carry = divmod(value * P + self.carry, self.shares())
        if self.cap == N:
            assert delta >= value * (P // N)
        self.index += delta
        self.carry = carry
        self.balance += value
        self.deposits += value
        self.check()

    def pending(self, key):
        amount, debt, *_ = self.live[key]
        return (amount * self.index - debt) // P

    def claim(self, key):
        value = self.pending(key)
        self.live[key][1] += value * P
        self.live[key][3] += value
        self.balance -= value
        self.paid += value
        self.check()
        return value

    def unregister(self, key):
        assert self.pending(key) == 0
        amount, debt, *_ = self.live.pop(key)
        residual = amount * self.index - debt
        assert 0 <= residual < P
        self.forfeited += residual
        self.check()

    def check(self):
        owed = sum(x[0] * self.index - x[1] for x in self.live.values())
        assert self.balance * P == owed + self.carry + self.forfeited
        assert self.deposits == self.balance + self.paid
        assert sum(self.pending(key) for key in self.live) <= self.balance
        assert 0 <= self.carry < self.cap
        assert self.index <= self.deposits * P <= U128 * P < 2**188
        assert 0 <= self.shares() <= self.cap
        for amount, debt, entry_index, paid, entry_deposits in self.live.values():
            assert 0 <= debt <= amount * self.index <= U256
            assert paid + (amount * self.index - debt) // P == amount * (self.index - entry_index) // P
            if self.cap == N:
                assert amount * (self.index - entry_index) >= amount * (self.deposits - entry_deposits) * (P // N)


def old_generic_reproducer():
    p = Pool(U64)
    p.register('old', U64 - 1)
    p.deposit(18)
    assert p.index == 0 and p.carry == 18 * P
    p.unregister('old')
    p.register('new', 1)
    p.deposit(1)
    assert p.claim('new') == 19
    return {'old_share_amount': U64 - 1, 'new_payout': 19, 'production_supply': N}


def repeated_carry(rounds=10002):
    p = Pool()
    denominator = 99_990_000_999_901
    p.register('persistent', 1)
    for _ in range(rounds):
        p.register('transient', denominator - 1)
        p.deposit(1)
        assert p.carry == 99_990_000_990_000
        p.unregister('transient')
        p.deposit(1)
        p.claim('persistent')
    paid = p.live['persistent'][3]
    ideal = rounds * (1 + Fraction(1, denominator))
    assert paid == 10003
    assert paid > ideal
    return {'rounds': rounds, 'deposits': p.deposits, 'persistent_payout': paid,
            'ideal_current_registered_pro_rata': str(ideal),
            'payout_minus_ideal': str(paid - ideal), 'pool_balance': p.balance,
            'forfeited_scaled': p.forfeited, 'carry': p.carry,
            'assumption': 'Transient shareholder voluntarily unregisters with subunit credit each round.'}


def fuzz(seed, steps=25000):
    rng = random.Random(seed)
    p = Pool()
    next_id = 0
    counts = dict(register=0, deposit=0, claim=0, unregister=0)
    for _ in range(steps):
        action = rng.randrange(4)
        if not p.live or action == 0 and p.shares() < N and len(p.live) < 16:
            available = N - p.shares()
            amount = rng.choice([1, available, rng.randint(1, available)])
            p.register(next_id, amount)
            next_id += 1
            counts['register'] += 1
        elif action == 1:
            remaining = U64 - p.balance
            if remaining:
                amount = rng.choice([1, remaining, rng.randint(1, remaining)])
                p.deposit(amount)
                counts['deposit'] += 1
        else:
            key = rng.choice(list(p.live))
            p.claim(key)
            assert p.claim(key) == 0
            counts['claim'] += 2
            if action == 3:
                p.unregister(key)
                counts['unregister'] += 1
    return {'seed': seed, 'steps': steps, 'calls': counts, 'deposits': p.deposits}


def bounds():
    assert U64 * P + N - 1 < U128
    assert U128 * P < 2**188
    assert N * U128 * P < 2**235 < 2**256
    return {'deposit_numerator_bits': (U64 * P + N - 1).bit_length(),
            'max_index_bits': (U128 * P).bit_length(),
            'max_share_times_index_bits': (N * U128 * P).bit_length(),
            'maximum_full_u64_deposits_before_lifetime_cap': U128 // U64,
            'maximum_full_u64_deposits_in_u128_scaled_reward': U128 // (U64 * P)}


if __name__ == '__main__':
    print(json.dumps({'bounds': bounds(), 'old_generic': old_generic_reproducer(),
                      'aggregate_carry': repeated_carry(),
                      'randomized': [fuzz(s) for s in [1, 29, 20260916, 4294967295]]}, indent=2))
