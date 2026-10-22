// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title TimeLock
/// @notice Lock any ERC20 or ERC721 until a given time. Only the designated withdrawer
///         can claim it, and only once the unlock time has been reached.
contract TimeLock {
    enum AssetType {
        ERC20,
        ERC721
    }

    struct Lock {
        address token;
        AssetType assetType;
        address depositor;
        address withdrawer;
        uint256 amount; // ERC20 amount received (0 for ERC721)
        uint256 tokenId; // ERC721 token id (0 for ERC20)
        uint256 unlockTime;
        bool withdrawn;
    }

    bytes4 private constant ERC721_INTERFACE_ID = 0x80ac58cd;

    Lock[] private _locks;
    uint256 private _entered = 1;

    event Deposited(
        uint256 indexed lockId,
        address indexed token,
        address indexed withdrawer,
        address depositor,
        uint256 amount,
        uint256 unlockTime
    );
    event Withdrawn(uint256 indexed lockId, address indexed token, address indexed withdrawer, uint256 amount);
    event ERC721Deposited(
        uint256 indexed lockId,
        address indexed token,
        address indexed withdrawer,
        address depositor,
        uint256 tokenId,
        uint256 unlockTime
    );
    event ERC721Withdrawn(uint256 indexed lockId, address indexed token, address indexed withdrawer, uint256 tokenId);

    error ZeroAmount();
    error UnlockTimeNotInFuture(uint256 unlockTime, uint256 currentTime);
    error InvalidLock();
    error NotWithdrawer();
    error StillLocked(uint256 unlockTime, uint256 currentTime);
    error AlreadyWithdrawn();
    error TransferFailed();
    error WrongAssetType();
    error Reentrancy();

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    /// @notice Deposit `amount` of ERC20 `token`, locked until `unlockTime` (Unix seconds).
    /// @param withdrawer Address allowed to withdraw. Pass address(0) to use msg.sender.
    /// @return lockId The id of the new lock.
    function deposit(address token, uint256 amount, uint256 unlockTime, address withdrawer)
        external
        nonReentrant
        returns (uint256 lockId)
    {
        if (amount == 0) revert ZeroAmount();
        // NFTs must use depositERC721: withdraw here calls ERC20 `transfer(withdrawer, amount)`, which on
        // an NFT either fails or moves token id `amount`, possibly someone else's. This catches NFTs that
        // report ERC721 through ERC165...
        if (_isERC721(token)) revert WrongAssetType();
        withdrawer = _checkLockParams(unlockTime, withdrawer);

        // Record what actually arrived, so fee-on-transfer tokens can't overdraw the contract.
        uint256 before = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();
        // ...and this catches older ones that don't: if this contract now owns token id `amount`, it was an NFT.
        if (_ownerOf(token, amount) == address(this)) revert WrongAssetType();

        lockId = _locks.length;
        _locks.push(
            Lock({
                token: token,
                assetType: AssetType.ERC20,
                depositor: msg.sender,
                withdrawer: withdrawer,
                amount: received,
                tokenId: 0,
                unlockTime: unlockTime,
                withdrawn: false
            })
        );

        emit Deposited(lockId, token, withdrawer, msg.sender, received, unlockTime);
    }

    /// @notice Deposit ERC721 `tokenId` of `token`, locked until `unlockTime` (Unix seconds).
    ///         Approve this contract for the token (or setApprovalForAll) first.
    /// @param withdrawer Address allowed to withdraw. Pass address(0) to use msg.sender.
    /// @return lockId The id of the new lock.
    function depositERC721(address token, uint256 tokenId, uint256 unlockTime, address withdrawer)
        external
        nonReentrant
        returns (uint256 lockId)
    {
        withdrawer = _checkLockParams(unlockTime, withdrawer);

        _safeTransferFrom(token, msg.sender, address(this), tokenId);
        // Also rejects ERC20s, where the transferFrom above would have moved `tokenId` units.
        if (_ownerOf(token, tokenId) != address(this)) revert WrongAssetType();

        lockId = _locks.length;
        _locks.push(
            Lock({
                token: token,
                assetType: AssetType.ERC721,
                depositor: msg.sender,
                withdrawer: withdrawer,
                amount: 0,
                tokenId: tokenId,
                unlockTime: unlockTime,
                withdrawn: false
            })
        );

        emit ERC721Deposited(lockId, token, withdrawer, msg.sender, tokenId, unlockTime);
    }

    /// @notice Withdraw a lock's tokens or NFT to its withdrawer once the unlock time is reached.
    function withdraw(uint256 lockId) external nonReentrant {
        if (lockId >= _locks.length) revert InvalidLock();
        Lock storage l = _locks[lockId];
        if (msg.sender != l.withdrawer) revert NotWithdrawer();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < l.unlockTime) revert StillLocked(l.unlockTime, block.timestamp);

        l.withdrawn = true;
        if (l.assetType == AssetType.ERC721) {
            // Plain transferFrom (not safeTransferFrom): the withdrawer is the caller, so it can handle the NFT.
            _safeTransferFrom(l.token, address(this), l.withdrawer, l.tokenId);
            emit ERC721Withdrawn(lockId, l.token, l.withdrawer, l.tokenId);
        } else {
            _safeTransfer(l.token, l.withdrawer, l.amount);
            emit Withdrawn(lockId, l.token, l.withdrawer, l.amount);
        }
    }

    function getLock(uint256 lockId) external view returns (Lock memory) {
        if (lockId >= _locks.length) revert InvalidLock();
        return _locks[lockId];
    }

    function lockCount() external view returns (uint256) {
        return _locks.length;
    }

    function _checkLockParams(uint256 unlockTime, address withdrawer) private view returns (address) {
        if (unlockTime <= block.timestamp) revert UnlockTimeNotInFuture(unlockTime, block.timestamp);
        return withdrawer == address(0) ? msg.sender : withdrawer;
    }

    function _isERC721(address token) private view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC165.supportsInterface, (ERC721_INTERFACE_ID)));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    function _ownerOf(address token, uint256 tokenId) private view returns (address) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC721.ownerOf, (tokenId)));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
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
