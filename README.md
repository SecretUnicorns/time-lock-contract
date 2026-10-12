# time-lock-contract

Lock any ERC20 token (e.g. tokens launched on pons.family) or ERC721 NFT until a chosen time on Robinhood Chain (or any EVM chain).

## How it works

1. **Approve** the `TimeLock` contract:
   - ERC20: `token.approve(timeLock, amount)`
   - ERC721: `nft.approve(timeLock, tokenId)` or `nft.setApprovalForAll(timeLock, true)`
2. **Deposit**:
   - ERC20: `deposit(token, amount, unlockTime, withdrawer)`
   - ERC721: `depositERC721(nft, tokenId, unlockTime, withdrawer)`
   - `unlockTime`: when the tokens become withdrawable, as a Unix timestamp in seconds (must be in the future). For example, `1798761600` is 2027-01-01 00:00 UTC.
   - `withdrawer`: who can withdraw. Pass `0x0000000000000000000000000000000000000000` to default to yourself.
   - Returns a `lockId` (also emitted in the `Deposited` or `ERC721Deposited` event).
3. **Withdraw**: once `block.timestamp >= unlockTime`, the withdrawer calls `withdraw(lockId)` and the tokens or NFT are sent to them. `withdraw` works for both kinds of lock.

Each deposit is its own lock. Nobody else (not even the depositor, if they named a different withdrawer) can touch it, and there's no owner/admin.

### Timing

The unlock time is compared against `block.timestamp`, the time of the block a withdrawal lands in. On Robinhood Chain the sequencer sets block timestamps, which can run up to an hour ahead of real time, so a lock can open up to about an hour early.

### Notes

- Fee-on-transfer tokens: the lock records the amount actually received, not the amount requested.
- Use the matching deposit function. `deposit` rejects NFTs and `depositERC721` rejects ERC20s.
- Only lock NFTs through `depositERC721`. An NFT sent straight to the contract with `transferFrom` can't be recovered (`safeTransferFrom` to the contract reverts, so that path is blocked).
- Rebasing tokens aren't supported. If the contract's balance shrinks, later withdrawals of that token could fail.

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
git clone --recursive https://github.com/jarrensj/time-lock-contract
forge build
forge test
```
