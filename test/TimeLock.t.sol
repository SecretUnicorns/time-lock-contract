// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimeLock} from "../src/TimeLock.sol";

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

contract TimeLockTest is Test {
    TimeLock lock;
    MockToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        lock = new TimeLock();
        token = new MockToken();
        token.mint(alice, 1_000 ether);
        vm.prank(alice);
        token.approve(address(lock), type(uint256).max);
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
}
