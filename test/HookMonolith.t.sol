// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/HookMonolith.sol";
import "../src/SwapRouter.sol";
import "../src/TokenFactory.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HookMonolithTest is Test {
    using PoolIdLibrary for PoolKey;

    // Constants
    uint256 public constant ALICE_INITIAL_ETH = 100 ether;
    uint256 public constant BOB_INITIAL_ETH = 100 ether;
    uint256 public constant USDT_MINT_AMOUNT = 1_000_000e18;

    uint256 public constant USDT_SWAP_AMOUNT = 10e18;
    uint256 public constant INVALID_SWAP_AMOUNT = 1e18;
    uint256 public constant TOKEN_SWAP_AMOUNT = 100e18;

    uint160 public constant MIN_SQRT_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_SQRT_PRICE = TickMath.MAX_SQRT_PRICE - 1;

    address public alice;
    address public bob;

    HookMonolith public hook;
    TokenFactory public factory;
    TestERC20 public usdt;
    PoolManager public poolManager;
    SwapRouter public swapRouter;

    address public auctionToken;
    PoolId public auctionPoolId;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    
        usdt = new TestERC20(18);
        factory = new TokenFactory();
        poolManager = new PoolManager(makeAddr("poolManager"));
        hook = deployHookMonolith();
        swapRouter = new SwapRouter(poolManager);
    
        // Deal initial ETH balances
        vm.deal(alice, ALICE_INITIAL_ETH);
        vm.deal(bob, BOB_INITIAL_ETH);
    
        // Mint USDT for Alice and Bob
        usdt.mint(alice, USDT_MINT_AMOUNT);
        usdt.mint(bob, USDT_MINT_AMOUNT);
    
        // Approve HookMonolith to pull USDT for auction fees
        vm.startPrank(alice);
        usdt.approve(address(hook), 1_000_000e18); // Large allowance for simplicity
        vm.stopPrank();
    
        vm.startPrank(bob);
        usdt.approve(address(hook), 1_000_000e18);
        vm.stopPrank();
    }

    function deployHookMonolith() internal returns (HookMonolith) {
        uint160 requiredFlags = uint160(
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

        bytes memory creationCode = type(HookMonolith).creationCode;
        bytes memory constructorArgs = abi.encode(poolManager, address(usdt), address(factory));
        (address hookAddress, bytes32 salt) = HookMiner.find(address(this), requiredFlags, creationCode, constructorArgs);

        HookMonolith deployedHook = new HookMonolith{salt: salt}(poolManager, address(usdt), address(factory));
        return deployedHook;
    }

    function initializeAuctionHelper(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint256 allocation,
        uint24 creatorFee,
        int24 initialTick,
        bool forceInverted
    ) internal returns (address, PoolId) {
        // Use dummy values for referrer (0x0), referrerAllocation (0), and pricePerToken (1e18)
        address token = hook.initializeAuction(
            name,
            symbol,
            totalSupply,
            allocation,
            creatorFee,
            initialTick,
            address(0),     // referrer
            0,              // referrerAllocation
            1e18            // pricePerToken
        );
        PoolKey memory key = createPoolKey(token, forceInverted);
        return (token, key.toId());
    }

    function createPoolKey(address token, bool forceInverted) internal view returns (PoolKey memory) {
        bool inverted = forceInverted ? (token < address(usdt)) : (address(usdt) < token);
        return PoolKey({
            currency0: Currency.wrap(inverted ? token : address(usdt)),
            currency1: Currency.wrap(inverted ? address(usdt) : token),
            fee: hook.PERIOD_ZERO_FEE(),
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function assertAuctionDetails(
        PoolId poolId,
        address expectedCreator,
        uint256 expectedAllocation,
        uint24 expectedCreatorFee,
        address expectedToken
    ) internal {
        (
            address creator,
            uint256 allocation,
            ,
            uint24 creatorFee,
            address token,
            
        ) = hook.auctions(poolId);
        assertEq(creator, expectedCreator, "creator mismatch");
        assertEq(allocation, expectedAllocation, "allocation mismatch");
        assertEq(creatorFee, expectedCreatorFee, "creatorFee mismatch");
        assertEq(token, expectedToken, "token mismatch");
    }

    function assertTokenDistribution(
        address token,
        address expectedHolder,
        uint256 expectedHolderBalance,
        address expectedManager,
        uint256 expectedManagerBalance
    ) internal {
        assertEq(IERC20(token).balanceOf(expectedHolder), expectedHolderBalance, "holder balance mismatch");
        assertEq(IERC20(token).balanceOf(expectedManager), expectedManagerBalance, "manager balance mismatch");
    }

    function testInitializeAuction() public {
        vm.prank(alice);
        (auctionToken, auctionPoolId) = initializeAuctionHelper(
            "Test Token",
            "TEST",
            1_000_000e18,
            100_000e18,
            500,
            0,
            true
        );
        assertAuctionDetails(auctionPoolId, alice, 100_000e18, 500, auctionToken);
        assertTokenDistribution(auctionToken, address(alice), 100_000e18, address(poolManager), 900_000e18);
    }

    function testPeriodTransition() public {
        vm.prank(alice);
        (auctionToken, auctionPoolId) = initializeAuctionHelper(
            "Test Token",
            "TEST",
            1_000_000e18,
            100_000e18,
            500,
            0,
            true
        );
        (,,uint256 startTime,,,) = hook.auctions(auctionPoolId);

        assertEq(hook.getCurrentPeriod(startTime), 0);
        vm.warp(block.timestamp + 48 hours + 1);
        assertEq(hook.getCurrentPeriod(startTime), 1);
    }

    function testLiquidityDistribution() public {
        vm.prank(alice);
        (auctionToken, auctionPoolId) = initializeAuctionHelper(
            "Test Token",
            "TEST",
            1_000_000e18,
            100_000e18,
            500,
            0,
            true
        );
        assertTokenDistribution(auctionToken, address(alice), 100_000e18, address(poolManager), 900_000e18);
    }

    function testAuctionWithInvertedTokenOrder() public {
        vm.prank(alice);
        (address token, PoolId poolId) = initializeAuctionHelper(
            "Inverted Token",
            "INV",
            500_000e18,
            50_000e18,
            1000,
            0,
            true
        );
        assertAuctionDetails(poolId, address(alice), 50_000e18, 1000, token);
    }

    function testSwapFeesPerPeriod() public {
        vm.startPrank(alice);
        (auctionToken, auctionPoolId) = initializeAuctionHelper(
            "Test Token",
            "TEST",
            1_000_000e18,
            100_000e18,
            500,
            0,
            true
        );

        PoolKey memory key = createPoolKey(auctionToken, true);
        (, , uint24 fee0) = hook.beforeSwap(
            alice,
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: 0}),
            ""
        );
        assertEq(fee0, hook.PERIOD_ZERO_FEE());

        vm.warp(block.timestamp + 48 hours + 1);
        (, , uint24 fee1) = hook.beforeSwap(
            alice,
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: 0}),
            ""
        );
        assertEq(fee1, 500);
        vm.stopPrank();
    }

    function testPurchaseTokensPeriodZero() public {
        vm.startPrank(alice);
        (auctionToken, auctionPoolId) = initializeAuctionHelper(
            "Auction Token",
            "AUCT",
            1_000_000e18,
            100_000e18,
            500,
            0,
            true
        );

        PoolKey memory key = createPoolKey(auctionToken, true);

        usdt.approve(address(swapRouter), USDT_SWAP_AMOUNT);
        swapRouter.executeSwap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(USDT_SWAP_AMOUNT),
                sqrtPriceLimitX96: MIN_SQRT_PRICE
            }),
            alice
        );

        IERC20(auctionToken).approve(address(swapRouter), INVALID_SWAP_AMOUNT);
        vm.expectRevert("Only USDT->Token in Period 0");
        swapRouter.executeSwap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(INVALID_SWAP_AMOUNT),
                sqrtPriceLimitX96: MAX_SQRT_PRICE
            }),
            alice
        );

        vm.stopPrank();
    }

    function testDoubleWaySwapsPeriodOne() public {
        vm.startPrank(alice);
        (auctionToken, auctionPoolId) = initializeAuctionHelper(
            "Auction Token",
            "AUCT",
            1_000_000e18,
            100_000e18,
            500,
            0,
            true
        );

        PoolKey memory key = createPoolKey(auctionToken, true);
        vm.warp(block.timestamp + 48 hours + 1);

        usdt.approve(address(swapRouter), USDT_SWAP_AMOUNT);
        swapRouter.executeSwap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(USDT_SWAP_AMOUNT),
                sqrtPriceLimitX96: MIN_SQRT_PRICE
            }),
            alice
        );

        IERC20(auctionToken).approve(address(swapRouter), TOKEN_SWAP_AMOUNT);
        swapRouter.executeSwap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(TOKEN_SWAP_AMOUNT),
                sqrtPriceLimitX96: MAX_SQRT_PRICE
            }),
            alice
        );

        vm.stopPrank();
    }
}
