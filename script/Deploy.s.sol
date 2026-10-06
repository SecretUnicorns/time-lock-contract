// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TimeLock} from "../src/TimeLock.sol";

contract Deploy is Script {
    function run() external returns (TimeLock lock) {
        vm.startBroadcast();
        lock = new TimeLock();
        vm.stopBroadcast();
        console.log("TimeLock deployed at", address(lock));
    }
}
