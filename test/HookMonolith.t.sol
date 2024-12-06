// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/HookMonolith.sol";
import "../src/TokenFactory.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract HookMonolithTest is Test {
    using PoolIdLibrary for PoolKey;

    HookMonolith public hook;
    TokenFactory public factory;
    TestERC20 public usdt;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        // Deploy mock USDT
        usdt = new TestERC20(18);
        
        // Deploy TokenFactory
        factory = new TokenFactory();
        
        // Deploy mock pool manager
        IPoolManager poolManager = IPoolManager(makeAddr("poolManager"));
        
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        deployCodeTo(
            "HookMonolith.sol",
            abi.encode(poolManager, address(usdt), address(factory)),
            address(flags)
        );

        // Deploy our hook
        hook = HookMonolith(address(flags));
        
        // Setup test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        
        // Mint some USDT to test accounts
        usdt.mint(alice, 1000000e18);
        usdt.mint(bob, 1000000e18);
    }

    function testInitializeAuction() public {
        vm.startPrank(alice);
        
        address token = hook.initializeAuction(
            "Test Token",
            "TEST",
            1_000_000e18,
            100_000e18,
            500, // 0.05% creator fee
            0 // salt
        );
        
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdt)),
            currency1: Currency.wrap(token),
            fee: hook.PERIOD_ZERO_FEE(),
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        PoolId poolId = key.toId();
        (address creator, uint256 allocation, uint256 startTime, uint24 creatorFee, address tokenAddr) = hook.auctions(poolId);
        
        assertEq(creator, alice);
        assertEq(allocation, 100_000e18);
        assertEq(creatorFee, 500);
        assertEq(tokenAddr, token);
        assertEq(IERC20(token).balanceOf(alice), 100_000e18);
        assertEq(IERC20(token).balanceOf(address(hook)), 900_000e18);
        
        vm.stopPrank();
    }

    function testPeriodTransition() public {
        vm.startPrank(alice);
        
        address token = hook.initializeAuction(
            "Test Token",
            "TEST",
            1_000_000e18,
            100_000e18,
            500,
            0
        );
        
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdt)),
            currency1: Currency.wrap(token),
            fee: hook.PERIOD_ZERO_FEE(),
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        PoolId poolId = key.toId();
        
        // Still period 0
        (,,uint256 startTime,,) = hook.auctions(poolId);
        assertEq(hook.getCurrentPeriod(startTime), 0);
        
        // Advance time
        vm.warp(block.timestamp + 48 hours + 1);
        
        // Now period 1
        (,,startTime,,) = hook.auctions(poolId);
        assertEq(hook.getCurrentPeriod(startTime), 1);
        
        vm.stopPrank();
    }

    function testSwapFeesPerPeriod() public {
        vm.startPrank(alice);
        
        address token = hook.initializeAuction(
            "Test Token",
            "TEST",
            1_000_000e18,
            100_000e18,
            500, // 0.05% creator fee
            0
        );
        
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdt)),
            currency1: Currency.wrap(token),
            fee: hook.PERIOD_ZERO_FEE(),
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Period 0: Should use PERIOD_ZERO_FEE
        (, , uint24 fee0) = hook.beforeSwap(
            alice,
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 100e18,
                sqrtPriceLimitX96: 0
            }),
            ""
        );
        assertEq(fee0, hook.PERIOD_ZERO_FEE());

        // Advance to Period 1
        vm.warp(block.timestamp + 48 hours + 1);

        // Period 1: Should use creator fee
        (, , uint24 fee1) = hook.beforeSwap(
            alice,
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 100e18,
                sqrtPriceLimitX96: 0
            }),
            ""
        );
        assertEq(fee1, 500); // Creator fee

        vm.stopPrank();
    }
} 