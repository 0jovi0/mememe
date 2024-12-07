// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/HookMonolith.sol";
import "../src/TokenFactory.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HookMonolithTest is Test {
    using PoolIdLibrary for PoolKey;

    HookMonolith public hook;
    TokenFactory public factory;
    TestERC20 public usdt;
    PoolManager public poolManager;

    address public alice;
    address public bob;

    address public auctionToken;
    PoolId public auctionPoolId;

    uint256 constant ALICE_INITIAL_ETH = 100 ether;
    uint256 constant BOB_INITIAL_ETH = 100 ether;
    uint256 constant USDT_MINT_AMOUNT = 1_000_000e18;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy mock USDT
        usdt = new TestERC20(18);

        // Deploy TokenFactory
        factory = new TokenFactory();

        // Deploy pool manager
        poolManager = new PoolManager(makeAddr("poolManager"));

        // Deploy HookMonolith
        hook = deployHookMonolith();

        // Setup test accounts
        vm.deal(alice, ALICE_INITIAL_ETH);
        vm.deal(bob, BOB_INITIAL_ETH);

        // Mint USDT for test accounts
        usdt.mint(alice, USDT_MINT_AMOUNT);
        usdt.mint(bob, USDT_MINT_AMOUNT);

    }

    /// @notice Test initializing an auction
    function testInitializeAuction() public {
        vm.prank(alice);
        // Initialize auction and store globally
        (auctionToken, auctionPoolId) = initializeAuctionHelper(
            "Test Token",
            "TEST",
            1_000_000e18,
            100_000e18,
            500,
            0,
            true
        );
        assertAuctionDetails(auctionPoolId, address(alice), 100_000e18, 500, auctionToken);
        assertTokenDistribution(auctionToken, address(alice), 100_000e18, address(poolManager), 900_000e18);
    }

    /// @notice Test period transition logic
    function testPeriodTransition() public {
        vm.prank(alice);
        // Initialize auction and store globally
        (auctionToken, auctionPoolId) = initializeAuctionHelper(
            "Test Token",
            "TEST",
            1_000_000e18,
            100_000e18,
            500,
            0,
            true
        );
        (, , uint256 startTime,,) = hook.auctions(auctionPoolId);

        // Initially in period 0
        assertEq(hook.getCurrentPeriod(startTime), 0);

        // Warp to after cooldown
        vm.warp(block.timestamp + 48 hours + 1);

        // Now should be period 1
        assertEq(hook.getCurrentPeriod(startTime), 1);
    }

    /// @notice Test liquidity addition and distribution
    function testLiquidityDistribution() public {

        // Initialize auction and store globally
        (auctionToken, auctionPoolId) = initializeAuctionHelper(
            "Test Token",
            "TEST",
            1_000_000e18,
            100_000e18,
            500,
            0,
            true
        );
        assertTokenDistribution(auctionToken, address(this), 100_000e18, address(poolManager), 900_000e18);
    }

    /// @notice Test auction initialization with inverted token order
    function testAuctionWithInvertedTokenOrder() public {
        (address token, PoolId poolId) = initializeAuctionHelper("Inverted Token", "INV", 500_000e18, 50_000e18, 1000, 0, true);

        assertAuctionDetails(poolId, address(this), 50_000e18, 1000, token);
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

    // ----- Helper Functions -----

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
        uint160 deployedFlags = uint160(address(deployedHook)) & HookMiner.FLAG_MASK;
        assertEq(deployedFlags, requiredFlags, "Hook address does not match required flags");

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
        address token = hook.initializeAuction(name, symbol, totalSupply, allocation, creatorFee, initialTick);
        PoolKey memory key = createPoolKey(token, forceInverted);
        PoolId poolId = key.toId();
        return (token, poolId);
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
        (address creator, uint256 allocation,, uint24 creatorFee, address token) = hook.auctions(poolId);
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

    function getSwapFee(PoolKey memory key, bool zeroForOne, uint256 amount) internal returns (uint24) {
        (, , uint24 fee) = hook.beforeSwap(
            alice,
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amount),
                sqrtPriceLimitX96: 0
            }),
            ""
        );
        return fee;
    }
}
