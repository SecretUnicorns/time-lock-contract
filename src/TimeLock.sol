// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Implemented by contracts that take flash loans from TimeLock.
interface ITimeLockFlashBorrower {
    /// @dev Called after `amount` of `token` has been sent to this contract. Approve TimeLock to
    ///      pull `amount` back and return TimeLock's FLASH_LOAN_CALLBACK_SUCCESS. Check `initiator`:
    ///      anyone can start a loan that names this contract as the receiver.
    function onFlashLoan(address initiator, uint256 lockId, address token, uint256 amount, bytes calldata data)
        external
        returns (bytes32);
}

/// @title TimeLock
/// @notice Lock any ERC20 until a given time. Only the designated withdrawer can
///         claim the tokens, and only once the unlock time has been reached. The depositor
///         or withdrawer can change the withdrawer; the unlock time can never be changed.
///         Locks can opt in to flash loans, which pay the withdrawer an ETH fee per loan.
contract TimeLock {
    struct Lock {
        address token;
        address depositor;
        address withdrawer;
        uint256 amount;
        uint256 unlockTime;
        bool withdrawn;
        bool flashLoanEnabled; // set with setFlashLoanTerms
        uint256 flashLoanFee; // ETH (wei) a borrower pays per flash loan
    }

    bytes32 public constant FLASH_LOAN_CALLBACK_SUCCESS = keccak256("ITimeLockFlashBorrower.onFlashLoan");

    Lock[] private _locks;
    uint256 private _entered = 1;

    /// @notice Flash loan fees (ETH) earned by each withdrawer and not yet claimed.
    mapping(address => uint256) public feesOwed;

    event Deposited(
        uint256 indexed lockId,
        address indexed token,
        address indexed withdrawer,
        address depositor,
        uint256 amount,
        uint256 unlockTime
    );
    event Withdrawn(uint256 indexed lockId, address indexed token, address indexed withdrawer, uint256 amount);
    event WithdrawerUpdated(uint256 indexed lockId, address indexed oldWithdrawer, address indexed newWithdrawer);
    event FlashLoanTermsUpdated(uint256 indexed lockId, bool enabled, uint256 fee);
    event FlashLoan(
        uint256 indexed lockId,
        address indexed token,
        address indexed receiver,
        address initiator,
        uint256 amount,
        uint256 fee
    );
    event FeesClaimed(address indexed withdrawer, uint256 amount);

    error ZeroAmount();
    error UnlockTimeNotInFuture(uint256 unlockTime, uint256 currentTime);
    error InvalidLock();
    error NotWithdrawer();
    error StillLocked(uint256 unlockTime, uint256 currentTime);
    error AlreadyWithdrawn();
    error NotDepositorOrWithdrawer();
    error ZeroAddress();
    error TransferFailed();
    error Reentrancy();
    error FlashLoanDisabled();
    error AmountExceedsLock(uint256 amount, uint256 lockAmount);
    error WrongFee(uint256 sent, uint256 fee);
    error FlashLoanCallbackFailed();
    error FlashLoanNotRepaid();
    error NoFees();

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    /// @notice Deposit `amount` of `token`, locked until `unlockTime` (Unix seconds).
    /// @param withdrawer Address allowed to withdraw. Pass address(0) to use msg.sender.
    /// @return lockId The id of the new lock.
    function deposit(address token, uint256 amount, uint256 unlockTime, address withdrawer)
        external
        nonReentrant
        returns (uint256 lockId)
    {
        if (amount == 0) revert ZeroAmount();
        if (unlockTime <= block.timestamp) revert UnlockTimeNotInFuture(unlockTime, block.timestamp);
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
                unlockTime: unlockTime,
                withdrawn: false,
                flashLoanEnabled: false,
                flashLoanFee: 0
            })
        );

        emit Deposited(lockId, token, withdrawer, msg.sender, received, unlockTime);
    }

    /// @notice Withdraw a lock's tokens to its withdrawer once the unlock time is reached.
    function withdraw(uint256 lockId) external nonReentrant {
        if (lockId >= _locks.length) revert InvalidLock();
        Lock storage l = _locks[lockId];
        if (msg.sender != l.withdrawer) revert NotWithdrawer();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < l.unlockTime) revert StillLocked(l.unlockTime, block.timestamp);

        l.withdrawn = true;
        _safeTransfer(l.token, l.withdrawer, l.amount);

        emit Withdrawn(lockId, l.token, l.withdrawer, l.amount);
    }

    /// @notice Change who can withdraw a lock. Callable by the depositor or the current withdrawer.
    ///         The unlock time stays the same.
    function updateWithdrawer(uint256 lockId, address newWithdrawer) external {
        if (lockId >= _locks.length) revert InvalidLock();
        if (newWithdrawer == address(0)) revert ZeroAddress();
        Lock storage l = _locks[lockId];
        if (msg.sender != l.depositor && msg.sender != l.withdrawer) revert NotDepositorOrWithdrawer();
        if (l.withdrawn) revert AlreadyWithdrawn();

        address oldWithdrawer = l.withdrawer;
        l.withdrawer = newWithdrawer;
        emit WithdrawerUpdated(lockId, oldWithdrawer, newWithdrawer);
    }

    /// @notice Opt a lock in or out of flash loans and set the ETH fee per loan.
    ///         Callable by the depositor or the current withdrawer. Fees go to the withdrawer.
    function setFlashLoanTerms(uint256 lockId, bool enabled, uint256 fee) external {
        if (lockId >= _locks.length) revert InvalidLock();
        Lock storage l = _locks[lockId];
        if (msg.sender != l.depositor && msg.sender != l.withdrawer) revert NotDepositorOrWithdrawer();
        if (l.withdrawn) revert AlreadyWithdrawn();

        l.flashLoanEnabled = enabled;
        l.flashLoanFee = fee;
        emit FlashLoanTermsUpdated(lockId, enabled, fee);
    }

    /// @notice Borrow up to a lock's tokens and return them in the same transaction. Send exactly
    ///         the lock's `flashLoanFee` as msg.value. `receiver` gets `amount`, its `onFlashLoan`
    ///         is called, and then `amount` is pulled back from `receiver`.
    function flashLoan(uint256 lockId, uint256 amount, address receiver, bytes calldata data)
        external
        payable
        nonReentrant
    {
        if (lockId >= _locks.length) revert InvalidLock();
        Lock storage l = _locks[lockId];
        if (!l.flashLoanEnabled) revert FlashLoanDisabled();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (amount == 0) revert ZeroAmount();
        if (amount > l.amount) revert AmountExceedsLock(amount, l.amount);
        if (msg.value != l.flashLoanFee) revert WrongFee(msg.value, l.flashLoanFee);

        address token = l.token;
        uint256 before = IERC20(token).balanceOf(address(this));
        _safeTransfer(token, receiver, amount);
        bytes32 result = ITimeLockFlashBorrower(receiver).onFlashLoan(msg.sender, lockId, token, amount, data);
        if (result != FLASH_LOAN_CALLBACK_SUCCESS) revert FlashLoanCallbackFailed();
        _safeTransferFrom(token, receiver, address(this), amount);
        // Pulling back `amount` can still leave the contract short, e.g. with fee-on-transfer tokens.
        if (IERC20(token).balanceOf(address(this)) < before) revert FlashLoanNotRepaid();

        // TODO: Revisit the fee model. For now it's a flat ETH fee per loan whatever the amount, and a loan
        //       draws on a single lock. A fee proportional to the amount, or loans pooled across locks of the
        //       same token, may suit borrowers and lockers better.
        feesOwed[l.withdrawer] += msg.value;
        emit FlashLoan(lockId, token, receiver, msg.sender, amount, msg.value);
    }

    /// @notice Send the caller the flash loan fees they've earned as a withdrawer.
    function claimFees() external nonReentrant {
        uint256 owed = feesOwed[msg.sender];
        if (owed == 0) revert NoFees();
        feesOwed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: owed}("");
        if (!ok) revert TransferFailed();
        emit FeesClaimed(msg.sender, owed);
    }

    function getLock(uint256 lockId) external view returns (Lock memory) {
        if (lockId >= _locks.length) revert InvalidLock();
        return _locks[lockId];
    }

    function lockCount() external view returns (uint256) {
        return _locks.length;
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
