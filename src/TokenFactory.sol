// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenFactory {
    function deployToken(
        string memory name,
        string memory symbol,
        uint256 totalSupply
    ) external returns (address) {
        AuctionToken token = new AuctionToken(name, symbol, totalSupply);
        return address(token);
    }
}

contract AuctionToken is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint256 totalSupply
    ) ERC20(name, symbol) {
        _mint(msg.sender, totalSupply);
    }
} 