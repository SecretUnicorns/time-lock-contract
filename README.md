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

### Timing

The unlock time is compared against `block.timestamp`, the time of the block a withdrawal lands in. On Robinhood Chain the sequencer sets block timestamps, which can run up to an hour ahead of real time, so a lock can open up to about an hour early.

### Notes

- Only ERC20s can be locked. `deposit` rejects NFTs (ERC721), which share ERC20's `transferFrom` and would otherwise get stuck.
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

Forge also needs the deployer's address as `--sender`; without it, it falls back to a default sender and refuses to broadcast. Look it up from the keystore (this asks for the keystore password):

```sh
DEPLOYER=$(cast wallet address --account deployer)
```

**Testnet** (chain ID 46630):

```sh
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --account deployer --sender $DEPLOYER --broadcast \
  --verify --verifier sourcify
```

**Mainnet** (chain ID 4663):

```sh
forge script script/Deploy.s.sol --rpc-url robinhood --account deployer --sender $DEPLOYER --broadcast \
  --verify --verifier sourcify
```

The script logs the deployed address, and `--verify` publishes the source on [Sourcify](https://sourcify.dev), which needs no API key; the verified source is then at `https://repo.sourcify.dev/<chain ID>/<address>`. Verifying through the testnet explorer's own Blockscout API currently fails with "Unable to verify" even for an exact match, so Sourcify is used instead. To verify an already-deployed contract, run `forge verify-contract <address> src/TimeLock.sol:TimeLock --chain-id <chain ID> --verifier sourcify`. For a dry run, leave out `--broadcast` and the `--verify --verifier sourcify` flags (forge only accepts `--verify` together with `--broadcast`). The public RPCs in `foundry.toml` are rate-limited; to use your own (e.g. Alchemy), pass its URL to `--rpc-url` instead.
