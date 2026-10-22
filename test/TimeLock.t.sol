// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimeLock, ITimeLockFlashBorrower} from "../src/TimeLock.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeBps;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        uint256 fee = amount * feeBps / 10_000;
        balanceOf[to] += amount - fee;
    }
}

contract MockBorrower is ITimeLockFlashBorrower {
    enum Action {
        Repay,
        KeepTokens,
        BadReturn,
        Deposit,
        Withdraw
    }

    TimeLock immutable lock;
    address public initiator;
    uint256 public balanceDuringLoan;

    constructor(TimeLock lock_) {
        lock = lock_;
    }

    function onFlashLoan(address initiator_, uint256 lockId, address token, uint256 amount, bytes calldata data)
        external
        returns (bytes32)
    {
        initiator = initiator_;
        balanceDuringLoan = MockToken(token).balanceOf(address(this));
        Action action = abi.decode(data, (Action));
        if (action == Action.Deposit) {
            MockToken(token).approve(address(lock), amount);
            lock.deposit(token, amount, block.timestamp + 1, address(0));
        } else if (action == Action.Withdraw) {
            lock.withdraw(lockId);
        }
        if (action != Action.KeepTokens) MockToken(token).approve(address(lock), amount);
        return action == Action.BadReturn ? bytes32(0) : lock.FLASH_LOAN_CALLBACK_SUCCESS();
    }
}

contract TimeLockTest is Test {
    TimeLock lock;
    MockToken token;
    MockBorrower borrower;
    MockToken stablecoin;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address dave = makeAddr("dave");

    function setUp() public {
        lock = new TimeLock();
        token = new MockToken();
        token.mint(alice, 1_000 ether);
        vm.prank(alice);
        token.approve(address(lock), type(uint256).max);

        borrower = new MockBorrower(lock);
        vm.deal(dave, 1 ether);

        // Stands in for USDG or USDC as a fee token.
        stablecoin = new MockToken();
        stablecoin.mint(dave, 100e6);
        vm.prank(dave);
        stablecoin.approve(address(lock), type(uint256).max);
    }

    function _optIn(uint256 lockId, uint256 fee) internal {
        vm.prank(alice);
        lock.setFlashLoanTerms(lockId, true, address(0), fee);
    }

    function _borrow(uint256 lockId, uint256 amount, uint256 fee, MockBorrower.Action action) internal {
        vm.prank(dave);
        lock.flashLoan{value: fee}(lockId, amount, address(borrower), abi.encode(action), address(0), fee);
    }

    function _borrowPayingToken(uint256 lockId, uint256 amount, address feeToken, uint256 fee) internal {
        vm.prank(dave);
        lock.flashLoan(lockId, amount, address(borrower), abi.encode(MockBorrower.Action.Repay), feeToken, fee);
    }

    function _deposit(uint256 amount, uint256 unlockTime, address withdrawer) internal returns (uint256) {
        vm.prank(alice);
        return lock.deposit(address(token), amount, unlockTime, withdrawer);
    }

    function test_DefaultsWithdrawerToDepositor() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, address(0));
        TimeLock.Lock memory l = lock.getLock(id);
        assertEq(l.withdrawer, alice);
        assertEq(l.depositor, alice);
        assertEq(l.amount, 100 ether);
        assertEq(token.balanceOf(address(lock)), 100 ether);
    }

    function test_WithdrawAfterUnlockTime() public {
        uint256 unlockTime = block.timestamp + 10;
        uint256 id = _deposit(100 ether, unlockTime, bob);

        vm.warp(unlockTime - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TimeLock.StillLocked.selector, unlockTime, unlockTime - 1));
        lock.withdraw(id);

        vm.warp(unlockTime);
        vm.prank(bob);
        lock.withdraw(id);
        assertEq(token.balanceOf(bob), 100 ether);
        assertTrue(lock.getLock(id).withdrawn);
    }

    function test_OnlyWithdrawerCanWithdraw() public {
        uint256 id = _deposit(100 ether, block.timestamp + 1, bob);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert(TimeLock.NotWithdrawer.selector);
        lock.withdraw(id);
    }

    function test_CannotWithdrawTwice() public {
        uint256 id = _deposit(100 ether, block.timestamp + 1, address(0));
        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        lock.withdraw(id);
        vm.expectRevert(TimeLock.AlreadyWithdrawn.selector);
        lock.withdraw(id);
    }

    function test_RevertsOnPastOrCurrentTime() public {
        vm.expectRevert(
            abi.encodeWithSelector(TimeLock.UnlockTimeNotInFuture.selector, block.timestamp, block.timestamp)
        );
        _deposit(1 ether, block.timestamp, address(0));
    }

    function test_RevertsOnZeroAmount() public {
        vm.expectRevert(TimeLock.ZeroAmount.selector);
        _deposit(0, block.timestamp + 1, address(0));
    }

    function test_RevertsOnUnknownLock() public {
        vm.expectRevert(TimeLock.InvalidLock.selector);
        lock.withdraw(0);
    }

    function test_FeeOnTransferRecordsReceivedAmount() public {
        token.setFee(100); // 1%
        uint256 id = _deposit(100 ether, block.timestamp + 1, address(0));
        assertEq(lock.getLock(id).amount, 99 ether);
    }

    function test_LocksAreIsolated() public {
        uint256 a = _deposit(10 ether, block.timestamp + 5, address(0));
        uint256 b = _deposit(20 ether, block.timestamp + 50, bob);
        vm.warp(block.timestamp + 5);
        vm.prank(alice);
        lock.withdraw(a);
        assertEq(token.balanceOf(address(lock)), 20 ether);
        vm.prank(bob);
        vm.expectRevert();
        lock.withdraw(b);
    }

    function testFuzz_DepositWithdraw(uint96 amount, uint32 delay) public {
        vm.assume(amount > 0 && amount <= 1_000 ether && delay > 0);
        uint256 unlockTime = block.timestamp + delay;
        uint256 id = _deposit(amount, unlockTime, bob);
        vm.warp(unlockTime);
        vm.prank(bob);
        lock.withdraw(id);
        assertEq(token.balanceOf(bob), amount);
    }

    function test_DepositorCanUpdateWithdrawer() public {
        uint256 unlockTime = block.timestamp + 10;
        uint256 id = _deposit(100 ether, unlockTime, bob);
        address carol = makeAddr("carol");

        vm.expectEmit(address(lock));
        emit TimeLock.WithdrawerUpdated(id, bob, carol);
        vm.prank(alice);
        lock.updateWithdrawer(id, carol);
        assertEq(lock.getLock(id).withdrawer, carol);

        vm.warp(unlockTime);
        vm.prank(bob);
        vm.expectRevert(TimeLock.NotWithdrawer.selector);
        lock.withdraw(id);
        vm.prank(carol);
        lock.withdraw(id);
        assertEq(token.balanceOf(carol), 100 ether);
    }

    function test_WithdrawerCanUpdateWithdrawer() public {
        uint256 id = _deposit(1 ether, block.timestamp + 1, bob);
        address carol = makeAddr("carol");
        vm.prank(bob);
        lock.updateWithdrawer(id, carol);
        assertEq(lock.getLock(id).withdrawer, carol);

        // Bob is no longer the withdrawer, so Bob can't change it back.
        vm.prank(bob);
        vm.expectRevert(TimeLock.NotDepositorOrWithdrawer.selector);
        lock.updateWithdrawer(id, bob);
    }

    function test_DepositorKeepsControlAfterWithdrawerChanges() public {
        uint256 id = _deposit(1 ether, block.timestamp + 1, bob);
        address carol = makeAddr("carol");
        vm.prank(bob);
        lock.updateWithdrawer(id, carol);

        // The README's caveat: a lock made out to someone else can still be redirected by the depositor.
        vm.prank(alice);
        lock.updateWithdrawer(id, alice);
        assertEq(lock.getLock(id).withdrawer, alice);
    }

    function test_OthersCannotUpdateWithdrawer() public {
        uint256 id = _deposit(1 ether, block.timestamp + 1, address(0));
        vm.prank(bob);
        vm.expectRevert(TimeLock.NotDepositorOrWithdrawer.selector);
        lock.updateWithdrawer(id, bob);
    }

    function test_UpdateWithdrawerRejectsZeroAddressAndUnknownLock() public {
        uint256 id = _deposit(1 ether, block.timestamp + 1, address(0));
        vm.startPrank(alice);
        vm.expectRevert(TimeLock.ZeroAddress.selector);
        lock.updateWithdrawer(id, address(0));
        vm.expectRevert(TimeLock.InvalidLock.selector);
        lock.updateWithdrawer(id + 1, bob);
    }

    function test_CannotUpdateWithdrawerAfterWithdraw() public {
        uint256 id = _deposit(1 ether, block.timestamp + 1, address(0));
        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        lock.withdraw(id);
        vm.expectRevert(TimeLock.AlreadyWithdrawn.selector);
        lock.updateWithdrawer(id, bob);
    }

    function test_UpdateWithdrawerKeepsUnlockTime() public {
        uint256 unlockTime = block.timestamp + 10;
        uint256 id = _deposit(1 ether, unlockTime, address(0));
        vm.prank(alice);
        lock.updateWithdrawer(id, bob);
        assertEq(lock.getLock(id).unlockTime, unlockTime);

        vm.warp(unlockTime - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TimeLock.StillLocked.selector, unlockTime, unlockTime - 1));
        lock.withdraw(id);
    }

    function test_FlashLoanLendsAndPaysWithdrawerFee() public {
        uint256 unlockTime = block.timestamp + 10;
        uint256 id = _deposit(100 ether, unlockTime, bob);
        _optIn(id, 0.01 ether);

        vm.expectEmit(address(lock));
        emit TimeLock.FlashLoan(id, address(token), address(borrower), dave, 100 ether, address(0), 0.01 ether);
        _borrow(id, 100 ether, 0.01 ether, MockBorrower.Action.Repay);

        assertEq(borrower.balanceDuringLoan(), 100 ether);
        assertEq(borrower.initiator(), dave);
        assertEq(token.balanceOf(address(lock)), 100 ether);
        assertEq(lock.feesOwed(bob, address(0)), 0.01 ether);
        assertEq(lock.feesOwed(alice, address(0)), 0);

        // The lock itself is untouched.
        vm.warp(unlockTime);
        vm.prank(bob);
        lock.withdraw(id);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_ClaimFees() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, bob);
        _optIn(id, 0.01 ether);
        _borrow(id, 50 ether, 0.01 ether, MockBorrower.Action.Repay);
        _borrow(id, 50 ether, 0.01 ether, MockBorrower.Action.Repay);

        vm.expectEmit(address(lock));
        emit TimeLock.FeesClaimed(bob, address(0), 0.02 ether);
        vm.startPrank(bob);
        lock.claimFees(address(0));
        assertEq(bob.balance, 0.02 ether);
        assertEq(lock.feesOwed(bob, address(0)), 0);
        assertEq(address(lock).balance, 0);

        vm.expectRevert(TimeLock.NoFees.selector);
        lock.claimFees(address(0));
    }

    function test_FeeGoesToCurrentWithdrawer() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, address(0));
        _optIn(id, 0.01 ether);
        vm.prank(alice);
        lock.updateWithdrawer(id, bob);
        _borrow(id, 100 ether, 0.01 ether, MockBorrower.Action.Repay);
        assertEq(lock.feesOwed(bob, address(0)), 0.01 ether);
        assertEq(lock.feesOwed(alice, address(0)), 0);
    }

    function test_FlashLoanRequiresOptIn() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, address(0));
        vm.expectRevert(TimeLock.FlashLoanDisabled.selector);
        _borrow(id, 1 ether, 0, MockBorrower.Action.Repay);

        _optIn(id, 0);
        _borrow(id, 1 ether, 0, MockBorrower.Action.Repay);

        vm.expectEmit(address(lock));
        emit TimeLock.FlashLoanTermsUpdated(id, false, address(0), 0);
        vm.prank(alice);
        lock.setFlashLoanTerms(id, false, address(0), 0);
        vm.expectRevert(TimeLock.FlashLoanDisabled.selector);
        _borrow(id, 1 ether, 0, MockBorrower.Action.Repay);
    }

    function test_FlashLoanRequiresExactEthFee() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, address(0));
        _optIn(id, 0.01 ether);
        bytes memory data = abi.encode(MockBorrower.Action.Repay);
        vm.startPrank(dave);
        vm.expectRevert(abi.encodeWithSelector(TimeLock.WrongFee.selector, 0, 0.01 ether));
        lock.flashLoan(id, 1 ether, address(borrower), data, address(0), 0.01 ether);
        vm.expectRevert(abi.encodeWithSelector(TimeLock.WrongFee.selector, 0.02 ether, 0.01 ether));
        lock.flashLoan{value: 0.02 ether}(id, 1 ether, address(borrower), data, address(0), 0.01 ether);
    }

    function test_FlashLoanRejectsChangedTerms() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, address(0));
        _optIn(id, 0.01 ether);

        // The fee goes up before the borrower's loan lands.
        _optIn(id, 0.02 ether);
        vm.expectRevert(abi.encodeWithSelector(TimeLock.FeeTermsChanged.selector, address(0), 0.02 ether));
        _borrow(id, 1 ether, 0.01 ether, MockBorrower.Action.Repay);

        // The fee switches to a token the borrower has approved: nothing is taken.
        vm.prank(alice);
        lock.setFlashLoanTerms(id, true, address(stablecoin), 50e6);
        vm.expectRevert(abi.encodeWithSelector(TimeLock.FeeTermsChanged.selector, address(stablecoin), 50e6));
        _borrowPayingToken(id, 1 ether, address(stablecoin), 5e6);
        assertEq(stablecoin.balanceOf(dave), 100e6);
    }

    function test_FlashLoanWithTokenFee() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, bob);
        vm.prank(alice);
        lock.setFlashLoanTerms(id, true, address(stablecoin), 5e6);

        vm.expectEmit(address(lock));
        emit TimeLock.FlashLoan(id, address(token), address(borrower), dave, 100 ether, address(stablecoin), 5e6);
        _borrowPayingToken(id, 100 ether, address(stablecoin), 5e6);
        assertEq(stablecoin.balanceOf(dave), 95e6);
        assertEq(lock.feesOwed(bob, address(stablecoin)), 5e6);
        assertEq(lock.feesOwed(bob, address(0)), 0);
        assertEq(token.balanceOf(address(lock)), 100 ether);

        vm.expectEmit(address(lock));
        emit TimeLock.FeesClaimed(bob, address(stablecoin), 5e6);
        vm.prank(bob);
        lock.claimFees(address(stablecoin));
        assertEq(stablecoin.balanceOf(bob), 5e6);
        assertEq(lock.feesOwed(bob, address(stablecoin)), 0);
    }

    function test_TokenFeeRejectsEth() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, address(0));
        vm.prank(alice);
        lock.setFlashLoanTerms(id, true, address(stablecoin), 5e6);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(TimeLock.WrongFee.selector, 1 wei, 0));
        lock.flashLoan{value: 1 wei}(
            id, 1 ether, address(borrower), abi.encode(MockBorrower.Action.Repay), address(stablecoin), 5e6
        );
    }

    function test_FeeInBorrowedTokenIsNotRepayment() public {
        uint256 unlockTime = block.timestamp + 10;
        uint256 id = _deposit(100 ether, unlockTime, address(0));
        vm.prank(alice);
        lock.setFlashLoanTerms(id, true, address(token), 2 ether);
        token.mint(dave, 2 ether);
        token.mint(address(borrower), 10 ether);
        vm.prank(dave);
        token.approve(address(lock), type(uint256).max);

        // With a 1% cut on transfer the repayment arrives 1 short. The fee (1.98 after the cut) would
        // cover that if it counted toward repayment, but it's collected before the loan.
        token.setFee(100);
        vm.expectRevert(TimeLock.FlashLoanNotRepaid.selector);
        _borrowPayingToken(id, 100 ether, address(token), 2 ether);
        token.setFee(0);

        _borrowPayingToken(id, 100 ether, address(token), 2 ether);
        assertEq(lock.feesOwed(alice, address(token)), 2 ether);
        assertEq(token.balanceOf(address(lock)), 102 ether);

        vm.warp(unlockTime);
        vm.startPrank(alice);
        lock.withdraw(id);
        lock.claimFees(address(token));
        assertEq(token.balanceOf(alice), 1_002 ether);
        assertEq(token.balanceOf(address(lock)), 0);
    }

    function test_FlashLoanCappedAtLockAmount() public {
        uint256 a = _deposit(100 ether, block.timestamp + 10, address(0));
        _deposit(50 ether, block.timestamp + 10, address(0));
        _optIn(a, 0);

        // The contract holds 150, but a loan can only draw on its own lock.
        vm.expectRevert(abi.encodeWithSelector(TimeLock.AmountExceedsLock.selector, 101 ether, 100 ether));
        _borrow(a, 101 ether, 0, MockBorrower.Action.Repay);
        vm.expectRevert(TimeLock.ZeroAmount.selector);
        _borrow(a, 0, 0, MockBorrower.Action.Repay);
    }

    function test_FlashLoanRevertsIfNotRepaid() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, address(0));
        _optIn(id, 0);
        vm.expectRevert(TimeLock.TransferFailed.selector);
        _borrow(id, 100 ether, 0, MockBorrower.Action.KeepTokens);
        assertEq(token.balanceOf(address(lock)), 100 ether);
    }

    function test_FlashLoanRevertsWhenRepaymentArrivesShort() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, address(0));
        _optIn(id, 0);
        // Fee-on-transfer: the borrower can pay back 100, but only 99 arrives.
        token.setFee(100);
        token.mint(address(borrower), 10 ether);
        vm.expectRevert(TimeLock.FlashLoanNotRepaid.selector);
        _borrow(id, 100 ether, 0, MockBorrower.Action.Repay);
    }

    function test_FlashLoanRevertsOnBadCallbackReturn() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, address(0));
        _optIn(id, 0);
        vm.expectRevert(TimeLock.FlashLoanCallbackFailed.selector);
        _borrow(id, 100 ether, 0, MockBorrower.Action.BadReturn);
    }

    function test_FlashLoanCannotReenter() public {
        uint256 id = _deposit(100 ether, block.timestamp + 1, address(borrower));
        _optIn(id, 0);
        vm.warp(block.timestamp + 1);

        // Re-depositing the borrowed tokens would otherwise pass the repayment check.
        vm.expectRevert(TimeLock.Reentrancy.selector);
        _borrow(id, 100 ether, 0, MockBorrower.Action.Deposit);
        vm.expectRevert(TimeLock.Reentrancy.selector);
        _borrow(id, 100 ether, 0, MockBorrower.Action.Withdraw);
    }

    function test_FlashLoanRevertsAfterWithdraw() public {
        uint256 id = _deposit(100 ether, block.timestamp + 1, address(0));
        _deposit(100 ether, block.timestamp + 1, address(0));
        _optIn(id, 0);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        lock.withdraw(id);

        // The other lock still holds 100 of the same token, but this one is spent.
        vm.expectRevert(TimeLock.AlreadyWithdrawn.selector);
        _borrow(id, 100 ether, 0, MockBorrower.Action.Repay);
        vm.prank(alice);
        vm.expectRevert(TimeLock.AlreadyWithdrawn.selector);
        lock.setFlashLoanTerms(id, true, address(0), 0);
    }

    function test_SetFlashLoanTermsPermissions() public {
        uint256 id = _deposit(100 ether, block.timestamp + 10, bob);
        vm.prank(bob);
        lock.setFlashLoanTerms(id, true, address(stablecoin), 5e6);
        TimeLock.Lock memory l = lock.getLock(id);
        assertTrue(l.flashLoanEnabled);
        assertEq(l.flashLoanFeeToken, address(stablecoin));
        assertEq(l.flashLoanFee, 5e6);

        vm.prank(dave);
        vm.expectRevert(TimeLock.NotDepositorOrWithdrawer.selector);
        lock.setFlashLoanTerms(id, true, address(0), 0);
    }
}
