// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "v4-core/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./TokenFactory.sol";
import "forge-std/console.sol";

contract HookMonolith is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using TickMath for uint160;

    struct AuctionConfig {
        address creator;
        uint256 allocation;
        uint256 startTime;
        uint24 creatorFee;
        address token;
    }

    struct CallbackData {
        // Minimal data needed initially, more info passed here now
        address creator;
        address token;
        uint256 totalSupply;
        uint256 allocation;
        uint24 creatorFee;
        int24 initialTick;
    }

    TokenFactory public immutable tokenFactory;
    mapping(PoolId => AuctionConfig) public auctions;
    address public immutable USDT;
    uint24 public constant PERIOD_ZERO_FEE = 3000; // 0.3%
    uint256 public constant COOLDOWN_PERIOD = 48 hours;
    IPoolManager public immutable manager;

    constructor(IPoolManager _poolManager, address _USDT, address _tokenFactory) BaseHook(_poolManager) {
        USDT = _USDT;
        tokenFactory = TokenFactory(_tokenFactory);
        manager = _poolManager;
    }

    function initializeAuction(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint256 allocation,
        uint24 creatorFee,
        int24 initialTick
    ) external returns (address token) {
        token = tokenFactory.deployToken(name, symbol, totalSupply);

        // We only call manager.unlock here and do all steps in _unlockCallback
        bytes memory hookData = abi.encode(msg.sender, token, totalSupply, allocation, creatorFee, initialTick);

        // Call unlock with just the callback data. We do not call modifyLiquidity here.
        manager.unlock(abi.encode(CallbackData({
            creator: msg.sender,
            token: token,
            totalSupply: totalSupply,
            allocation: allocation,
            creatorFee: creatorFee,
            initialTick: initialTick
        })));

        return token;
    }

    // Helper function: Gets the full positive delta (credit) owed to this contract by the manager for the given currency.
    function _getFullCredit(Currency currency) internal view returns (uint256 amount) {
        int256 delta = manager.currencyDelta(address(this), currency);
        require(delta >= 0, "Delta not positive");
        amount = uint256(delta);
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory cbData = abi.decode(rawData, (CallbackData));

        // Construct the pool key
        bool isToken0 = address(cbData.token) < USDT;
        Currency currency0 = Currency.wrap(address(USDT) < cbData.token ? address(USDT) : cbData.token);
        Currency currency1 = Currency.wrap(address(USDT) < cbData.token ? cbData.token : address(USDT));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: PERIOD_ZERO_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        // Initialize the pool
        uint160 sqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(cbData.initialTick));
        manager.initialize(key, sqrtPriceX96);

        // Here we provide on a range that's immediately below the initial tick or immediately above
        // To ensure we only provide one token
         // Dynamically set tick range based on token position
        int24 tickLower;
        int24 tickUpper;
        if (isToken0) {
            tickLower = cbData.initialTick + key.tickSpacing;
            tickUpper = cbData.initialTick + 2 * key.tickSpacing;
        } else {
            tickLower = cbData.initialTick - 2 * key.tickSpacing;
            tickUpper = cbData.initialTick - key.tickSpacing;
        }

        uint256 amountDesired = cbData.totalSupply - cbData.allocation;

        // 1. Sync to ensure poolmanager sees updated balances
        manager.sync(isToken0 ? key.currency0 : key.currency1);

        // 2. Transfer tokens into the manager
        IERC20(cbData.token).transfer(address(manager), amountDesired);

        // 3. Settle, finalizing the deltas
        manager.settle();

        // 4. Now we have credit at the manager, let's compute the liquidity to add
        uint256 amount0Credit = _getFullCredit(currency0);
        uint256 amount1Credit = _getFullCredit(currency1);

        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);


        uint128 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtLowerX96,
            sqrtUpperX96,
            amount0Credit,
            amount1Credit
        );

        // 5. Now modify liquidity with the computed liquidity
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(int128(liquidityToAdd)),
            salt: bytes32(0)
        });

        // Perform modifyLiquidity inside the callback
        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, new bytes(0));

        // Store auction config
        PoolId poolId = key.toId();
        auctions[poolId] = AuctionConfig({
            creator: cbData.creator,
            allocation: cbData.allocation,
            startTime: block.timestamp,
            creatorFee: cbData.creatorFee,
            token: cbData.token
        });

        // Distribute creator allocation
        IERC20(cbData.token).transfer(cbData.creator, cbData.allocation);

        return abi.encode(delta);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) external override returns (bytes4) {
        return this.afterInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        AuctionConfig memory config = auctions[poolId];
        uint8 period = getCurrentPeriod(config.startTime);

        if (period == 0) {
            require(
                params.zeroForOne && Currency.unwrap(key.currency0) == USDT,
                "Only USDT->Token in Period 0"
            );
        }

        // Return appropriate fee based on period
        uint24 fee = period == 0 ? PERIOD_ZERO_FEE : config.creatorFee;
        
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        return (this.afterSwap.selector, 0); // No delta modifications
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        AuctionConfig memory config = auctions[poolId];

        require(
            getCurrentPeriod(config.startTime) == 1,
            "Liquidity locked in Period 0"
        );
        
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        AuctionConfig memory config = auctions[poolId];
        
        require(
            getCurrentPeriod(config.startTime) == 1,
            "Liquidity locked in Period 0"
        );  

        return this.beforeRemoveLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual override returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual override returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function getCurrentPeriod(uint256 startTime) public view returns (uint8) {
        require(startTime > 0, "Auction not initialized");
        return block.timestamp < startTime + COOLDOWN_PERIOD ? 0 : 1;
    }
}