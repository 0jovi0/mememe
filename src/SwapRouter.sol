// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract SwapRouter {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Perform a swap using `unlock` and `unlockCallback`
    /// @param key The pool key
    /// @param params The swap parameters
    /// @param recipient The address to receive swapped tokens
    /// @return delta The resulting balance delta from the swap
    function executeSwap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        address recipient
    ) external returns (BalanceDelta delta) {
        // Unlock the pool manager with encoded parameters
        poolManager.unlock(abi.encode(key, params, recipient));
    }

    /// @notice The callback function triggered by the pool manager during `unlock`
    /// @param data The encoded data containing swap details
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Unauthorized callback");

        // Decode the data for swap execution
        (PoolKey memory key, IPoolManager.SwapParams memory params, address recipient) = abi.decode(
            data,
            (PoolKey, IPoolManager.SwapParams, address)
        );

        // Perform the swap
        BalanceDelta delta = poolManager.swap(key, params, abi.encode(recipient));

        // Handle deltas
        handleDeltas(delta, key, recipient);
        return '';
    }

    /// @notice Handle the deltas resulting from the swap
    /// @param delta The balance delta
    /// @param key The pool key
    /// @param recipient The address receiving the tokens
    function handleDeltas(BalanceDelta delta, PoolKey memory key, address recipient) internal {
        // Process currency0 delta
        handleDeltaForCurrency(delta.amount0(), key.currency0, recipient);
        // Process currency1 delta
        handleDeltaForCurrency(delta.amount1(), key.currency1, recipient);
    }

    /// @notice Handle the delta for a specific currency
    /// @param delta The balance delta
    /// @param currency The currency to handle
    /// @param recipient The address involved in the swap
    function handleDeltaForCurrency(int128 delta, Currency currency, address recipient) internal {
        poolManager.sync(currency);
        if (delta < 0) {
            
            // Negative delta: transfer tokens from recipient to poolManager
            uint256 amountIn = uint256(uint128(-delta));
            IERC20(Currency.unwrap(currency)).transferFrom(recipient, address(poolManager), amountIn);

            // Settle this negative delta on the poolManager
            poolManager.settle();
        } else if (delta > 0) {
            // Positive delta: poolManager sends tokens to recipient
            uint256 amountOut = uint256(uint128(delta));

            // Take the token out to the recipient
            poolManager.take(currency, recipient, amountOut);
        }
    }
}
