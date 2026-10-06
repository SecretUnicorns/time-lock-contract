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

contract MockArbSys {
    uint256 public arbBlockNumber;

    function set(uint256 n) external {
        arbBlockNumber = n;
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

    function _deposit(uint256 amount, uint256 unlockBlock, address withdrawer) internal returns (uint256) {
        vm.prank(alice);
        return lock.deposit(address(token), amount, unlockBlock, withdrawer);
    }

    function test_DefaultsWithdrawerToDepositor() public {
        uint256 id = _deposit(100 ether, block.number + 10, address(0));
        TimeLock.Lock memory l = lock.getLock(id);
        assertEq(l.withdrawer, alice);
        assertEq(l.depositor, alice);
        assertEq(l.amount, 100 ether);
        assertEq(token.balanceOf(address(lock)), 100 ether);
    }

    function test_WithdrawAfterUnlockBlock() public {
        uint256 unlockBlock = block.number + 10;
        uint256 id = _deposit(100 ether, unlockBlock, bob);

        vm.roll(unlockBlock - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TimeLock.StillLocked.selector, unlockBlock, unlockBlock - 1));
        lock.withdraw(id);

        vm.roll(unlockBlock);
        vm.prank(bob);
        lock.withdraw(id);
        assertEq(token.balanceOf(bob), 100 ether);
        assertTrue(lock.getLock(id).withdrawn);
    }

    function test_OnlyWithdrawerCanWithdraw() public {
        uint256 id = _deposit(100 ether, block.number + 1, bob);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(TimeLock.NotWithdrawer.selector);
        lock.withdraw(id);
    }

    function test_CannotWithdrawTwice() public {
        uint256 id = _deposit(100 ether, block.number + 1, address(0));
        vm.roll(block.number + 1);
        vm.startPrank(alice);
        lock.withdraw(id);
        vm.expectRevert(TimeLock.AlreadyWithdrawn.selector);
        lock.withdraw(id);
    }

    function test_RevertsOnPastOrCurrentBlock() public {
        vm.expectRevert(abi.encodeWithSelector(TimeLock.UnlockBlockNotInFuture.selector, block.number, block.number));
        _deposit(1 ether, block.number, address(0));
    }

    function test_RevertsOnZeroAmount() public {
        vm.expectRevert(TimeLock.ZeroAmount.selector);
        _deposit(0, block.number + 1, address(0));
    }

    function test_RevertsOnUnknownLock() public {
        vm.expectRevert(TimeLock.InvalidLock.selector);
        lock.withdraw(0);
    }

    function test_FeeOnTransferRecordsReceivedAmount() public {
        token.setFee(100); // 1%
        uint256 id = _deposit(100 ether, block.number + 1, address(0));
        assertEq(lock.getLock(id).amount, 99 ether);
    }

    function test_LocksAreIsolated() public {
        uint256 a = _deposit(10 ether, block.number + 5, address(0));
        uint256 b = _deposit(20 ether, block.number + 50, bob);
        vm.roll(block.number + 5);
        vm.prank(alice);
        lock.withdraw(a);
        assertEq(token.balanceOf(address(lock)), 20 ether);
        vm.prank(bob);
        vm.expectRevert();
        lock.withdraw(b);
    }

    function test_UsesArbSysBlockNumberOnArbitrum() public {
        MockArbSys arb = new MockArbSys();
        vm.etch(address(100), address(arb).code);
        MockArbSys(address(100)).set(5_000_000);
        assertEq(lock.currentBlock(), 5_000_000);

        // Unlock block is compared against the L2 block, not block.number.
        uint256 id = _deposit(1 ether, 5_000_010, address(0));
        MockArbSys(address(100)).set(5_000_010);
        vm.prank(alice);
        lock.withdraw(id);
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    function testFuzz_DepositWithdraw(uint96 amount, uint32 delay) public {
        vm.assume(amount > 0 && amount <= 1_000 ether && delay > 0);
        uint256 unlockBlock = block.number + delay;
        uint256 id = _deposit(amount, unlockBlock, bob);
        vm.roll(unlockBlock);
        vm.prank(bob);
        lock.withdraw(id);
        assertEq(token.balanceOf(bob), amount);
    }
}
