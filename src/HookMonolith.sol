// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./TokenFactory.sol";

contract HookMonolith is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    struct AuctionConfig {
        address creator;
        uint256 allocation;
        uint256 startTime;
        uint24 creatorFee;
        address token;
    }

    TokenFactory public immutable tokenFactory;
    mapping(PoolId => AuctionConfig) public auctions;
    address public immutable USDT;
    uint24 public constant PERIOD_ZERO_FEE = 3000; // 0.3%
    uint256 public constant COOLDOWN_PERIOD = 48 hours;

    constructor(IPoolManager _poolManager, address _USDT, address _tokenFactory) BaseHook(_poolManager) {
        USDT = _USDT;
        tokenFactory = TokenFactory(_tokenFactory);
    }

    function initializeAuction(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint256 allocation,
        uint24 creatorFee,
        uint256 salt
    ) external returns (address token) {
        token = tokenFactory.deployToken(name, symbol, totalSupply);
        
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(USDT),
            currency1: Currency.wrap(token),
            fee: PERIOD_ZERO_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();
        auctions[poolId] = AuctionConfig({
            creator: msg.sender,
            allocation: allocation,
            startTime: block.timestamp,
            creatorFee: creatorFee,
            token: token
        });

        // Transfer tokens to creator and hook
        IERC20(token).transfer(msg.sender, allocation);
        IERC20(token).transfer(address(this), totalSupply - allocation);
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
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external override returns (bytes4) {
        return this.afterInitialize.selector;
    }

    function beforeSwap(
        address sender,
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
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        return (this.afterSwap.selector, 0); // No delta modifications
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
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
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
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
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta poolFees,
        bytes calldata hookData
    ) external virtual override returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta poolFees,
        bytes calldata hookData
    ) external virtual override returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function getCurrentPeriod(uint256 startTime) public view returns (uint8) {
        require(startTime > 0, "Auction not initialized");
        return block.timestamp < startTime + COOLDOWN_PERIOD ? 0 : 1;
    }
}