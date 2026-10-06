// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @title TimeLock
/// @notice Lock any ERC20 until a given block. Only the designated withdrawer can
///         claim the tokens, and only once the unlock block has been reached.
/// @dev On Arbitrum-based chains (e.g. Robinhood Chain) `block.number` returns the
///      parent chain's block number, so the L2 block number is read from ArbSys.
contract TimeLock {
    struct Lock {
        address token;
        address depositor;
        address withdrawer;
        uint256 amount;
        uint256 unlockBlock;
        bool withdrawn;
    }

    address private constant ARB_SYS = address(100);

    Lock[] private _locks;
    uint256 private _entered = 1;

    event Deposited(
        uint256 indexed lockId,
        address indexed token,
        address indexed withdrawer,
        address depositor,
        uint256 amount,
        uint256 unlockBlock
    );
    event Withdrawn(uint256 indexed lockId, address indexed token, address indexed withdrawer, uint256 amount);

    error ZeroAmount();
    error UnlockBlockNotInFuture(uint256 unlockBlock, uint256 currentBlock);
    error InvalidLock();
    error NotWithdrawer();
    error StillLocked(uint256 unlockBlock, uint256 currentBlock);
    error AlreadyWithdrawn();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    /// @notice Deposit `amount` of `token`, locked until `unlockBlock`.
    /// @param withdrawer Address allowed to withdraw. Pass address(0) to use msg.sender.
    /// @return lockId The id of the new lock.
    function deposit(address token, uint256 amount, uint256 unlockBlock, address withdrawer)
        external
        nonReentrant
        returns (uint256 lockId)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 current = currentBlock();
        if (unlockBlock <= current) revert UnlockBlockNotInFuture(unlockBlock, current);
        if (withdrawer == address(0)) withdrawer = msg.sender;

        // Record what actually arrived, so fee-on-transfer tokens can't overdraw the contract.
        uint256 before = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        lockId = _locks.length;
        _locks.push(
            Lock({
                token: token,
                depositor: msg.sender,
                withdrawer: withdrawer,
                amount: received,
                unlockBlock: unlockBlock,
                withdrawn: false
            })
        );

        emit Deposited(lockId, token, withdrawer, msg.sender, received, unlockBlock);
    }

    /// @notice Withdraw a lock's tokens to its withdrawer once the unlock block is reached.
    function withdraw(uint256 lockId) external nonReentrant {
        if (lockId >= _locks.length) revert InvalidLock();
        Lock storage l = _locks[lockId];
        if (msg.sender != l.withdrawer) revert NotWithdrawer();
        if (l.withdrawn) revert AlreadyWithdrawn();
        uint256 current = currentBlock();
        if (current < l.unlockBlock) revert StillLocked(l.unlockBlock, current);

        l.withdrawn = true;
        _safeTransfer(l.token, l.withdrawer, l.amount);

        emit Withdrawn(lockId, l.token, l.withdrawer, l.amount);
    }

    function getLock(uint256 lockId) external view returns (Lock memory) {
        if (lockId >= _locks.length) revert InvalidLock();
        return _locks[lockId];
    }

    function lockCount() external view returns (uint256) {
        return _locks.length;
    }

    /// @notice The block number that `unlockBlock` is compared against.
    function currentBlock() public view returns (uint256) {
        (bool ok, bytes memory ret) = ARB_SYS.staticcall(abi.encodeCall(IArbSys.arbBlockNumber, ()));
        if (ok && ret.length == 32) return abi.decode(ret, (uint256));
        return block.number;
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        _call(token, abi.encodeWithSignature("transfer(address,uint256)", to, amount));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        _call(token, abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
    }

    /// @dev Supports tokens that return nothing (e.g. USDT-style) as well as bool-returning ones.
    function _call(address token, bytes memory data) private {
        if (token.code.length == 0) revert TransferFailed();
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
