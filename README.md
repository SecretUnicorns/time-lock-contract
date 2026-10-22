# time-lock-contract

Lock any ERC20 token (e.g. tokens launched on pons.family) until a chosen time on Robinhood Chain (or any EVM chain).

## How it works

1. **Approve** the `TimeLock` contract to spend your tokens: `token.approve(timeLock, amount)`.
2. **Deposit**: `deposit(token, amount, unlockTime, withdrawer)`
   - `unlockTime`: when the tokens become withdrawable, as a Unix timestamp in seconds (must be in the future). For example, `1798761600` is 2027-01-01 00:00 UTC.
   - `withdrawer`: who can withdraw. Pass `0x0000000000000000000000000000000000000000` to default to yourself.
   - Returns a `lockId` (also emitted in the `Deposited` event).
3. **Withdraw**: once `block.timestamp >= unlockTime`, the withdrawer calls `withdraw(lockId)` and the tokens are sent to them.

4. **Change the withdrawer** (optional): the depositor or the current withdrawer can call `updateWithdrawer(lockId, newWithdrawer)` any time before the lock is withdrawn.

Each deposit is its own lock. Only the withdrawer can withdraw, and there's no owner/admin. The unlock time is fixed at deposit and can't be changed by anyone.

Because the depositor can always change the withdrawer, a lock made out to someone else isn't guaranteed to them until they withdraw it.

### Flash loans (opt-in)

The depositor or withdrawer of a lock can let others flash-loan its tokens, meaning borrow them and pay them back in the same transaction, for a fee per loan in ETH or an ERC20 such as a stablecoin.

- **Opt in**: `setFlashLoanTerms(lockId, true, feeToken, fee)`. `feeToken` is `address(0)` for ETH or the ERC20 to charge in, and `fee` is in that token's smallest unit (for ETH, wei: `10000000000000000` = 0.01 ETH). Call it again to change the terms, or pass `false` to opt out.
- **Borrow**: `flashLoan(lockId, amount, receiver, data, feeToken, fee)` for up to the lock's amount, passing the lock's current fee terms. If they've changed, the loan reverts with `FeeTermsChanged`, so a change sent just before can't charge you more. Pay an ETH fee as `msg.value`; an ERC20 fee is taken from the caller, so approve the TimeLock for it first. `receiver` must implement `ITimeLockFlashBorrower.onFlashLoan`, approve the TimeLock to take `amount` back, and return `FLASH_LOAN_CALLBACK_SUCCESS`. If the tokens don't come back, the whole transaction reverts.
- **Collect fees**: each loan's fee is credited to the lock's withdrawer at the time of the loan. `feesOwed(withdrawer, feeToken)` shows the balance, and `claimFees(feeToken)` sends it to the caller.

**Stablecoin fees on Robinhood Chain**: Robinhood Chain's [token contracts page](https://docs.robinhood.com/chain/contracts/) lists USDG (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`) as its stablecoin. Circle's [USDC address list](https://developers.circle.com/stablecoins/usdc-contract-addresses) doesn't include Robinhood Chain yet; once USDC is deployed there, pass its address as `feeToken` the same way. Check the token's `decimals()` when setting `fee`.

A loan can't take tokens out of a lock or change it, and the borrower can't deposit or withdraw during the loan. For the length of the transaction, though, the borrower does hold the tokens, so anything that checks balances mid-transaction (some airdrop claims or votes) will count them as the borrower's. Don't opt in a lock if that matters for its token.

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

## Deploy

Deploy to Robinhood Chain testnet first, then mainnet. The deployer needs ETH on that network for gas; get testnet ETH from the [testnet faucet](https://faucet.testnet.chain.robinhood.com).

Import the deployer's key once into an encrypted keystore, so it never sits in your shell history:

```sh
cast wallet import deployer --interactive
```

**Testnet** (chain ID 46630):

```sh
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --account deployer --broadcast \
  --verify --verifier blockscout --verifier-url https://explorer.testnet.chain.robinhood.com/api/
```

**Mainnet** (chain ID 4663):

```sh
forge script script/Deploy.s.sol --rpc-url robinhood --account deployer --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

The script logs the deployed address, and `--verify` publishes the source on the [testnet explorer](https://explorer.testnet.chain.robinhood.com) or [mainnet explorer](https://robinhoodchain.blockscout.com). Leave out `--broadcast` for a dry run. The public RPCs in `foundry.toml` are rate-limited; to use your own (e.g. Alchemy), pass its URL to `--rpc-url` instead.
