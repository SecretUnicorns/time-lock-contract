# time-lock-contract

Lock any ERC20 token (e.g. tokens launched on pons.family) until a chosen time on Robinhood Chain (or any EVM chain).

## How it works

1. **Approve** the `TimeLock` contract to spend your tokens: `token.approve(timeLock, amount)`.
2. **Deposit**: `deposit(token, amount, unlockTime, withdrawer)`
   - `unlockTime`: when the tokens become withdrawable, as a Unix timestamp in seconds (must be in the future). For example, `1798761600` is 2027-01-01 00:00 UTC.
   - `withdrawer`: who can withdraw. Pass `0x0000000000000000000000000000000000000000` to default to yourself.
   - Returns a `lockId` (also emitted in the `Deposited` event).
3. **Withdraw**: once `block.timestamp >= unlockTime`, the withdrawer calls `withdraw(lockId)` and the tokens are sent to them.

Each deposit is its own lock. Nobody else (not even the depositor, if they named a different withdrawer) can touch it, and there's no owner/admin.

### Timing

The unlock time is compared against `block.timestamp`, the time of the block a withdrawal lands in. On Robinhood Chain the sequencer sets block timestamps, which can run up to an hour ahead of real time, so a lock can open up to about an hour early.

### Notes

- Fee-on-transfer tokens: the lock records the amount actually received, not the amount requested.
- Rebasing tokens aren't supported. If the contract's balance shrinks, later withdrawals of that token could fail.

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
git clone --recursive https://github.com/jarrensj/time-lock-contract
forge build
forge test
```
