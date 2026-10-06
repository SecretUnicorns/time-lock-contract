# time-lock-contract

Lock any ERC20 token (e.g. tokens launched on pons.family) until a chosen block on Robinhood Chain (or any EVM chain).

## How it works

1. **Approve** the `TimeLock` contract to spend your tokens: `token.approve(timeLock, amount)`.
2. **Deposit**: `deposit(token, amount, unlockBlock, withdrawer)`
   - `unlockBlock`: the block at which the tokens become withdrawable (must be in the future)
   - `withdrawer`: who can withdraw. Pass `0x0000000000000000000000000000000000000000` to default to yourself.
   - Returns a `lockId` (also emitted in the `Deposited` event).
3. **Withdraw**: once `currentBlock() >= unlockBlock`, the withdrawer calls `withdraw(lockId)` and the tokens are sent to them.

Each deposit is its own lock. Nobody else (not even the depositor, if they named a different withdrawer) can touch it, and there's no owner/admin.

### Block numbers on Robinhood Chain

Robinhood Chain is an Arbitrum Orbit chain. On Arbitrum chains, Solidity's `block.number` returns the *parent chain's* block number,
not the L2 block shown in the explorer. This contract reads the L2 block number from the ArbSys precompile
(`0x...64`) and falls back to `block.number` elsewhere. Call `currentBlock()` to see the number that `unlockBlock` is compared against.

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
