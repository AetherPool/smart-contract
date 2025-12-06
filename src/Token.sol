// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Token
 * @notice General-purpose 6-decimal ERC20 token with claim functionality
 * @dev Can be deployed multiple times with different names/symbols
 */
contract Token is ERC20, Ownable {
    uint8 private constant _decimals = 6;

    // 1,000,000 tokens per claim - enough for comprehensive testing
    uint256 public constant CLAIM_AMOUNT = 1_000_000 * 10 ** 6;
    mapping(address => bool) public hasClaimed;

    /**
     * @notice Deploy a new token with custom name and symbol
     * @param name Full token name (e.g., "Fyntera", "Quarita")
     * @param symbol Token symbol (e.g., "FYN", "QRT")
     */
    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {}

    /**
     * @notice Returns the number of decimals used for token amounts
     * @return uint8 Always returns 6 for this token
     */
    function decimals() public pure override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Allows users to claim a one-time allocation of tokens
     * @param _user Address to receive the claimed tokens
     */
    function claim(address _user) external {
        require(!hasClaimed[_user], "Already claimed");

        hasClaimed[_user] = true;
        _mint(_user, CLAIM_AMOUNT);
    }

    /**
     * @notice Mint new tokens (only owner)
     * @param to Address to receive minted tokens
     * @param amount Amount of tokens to mint (in 6 decimals)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from caller's balance
     * @param amount Amount of tokens to burn (in 6 decimals)
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
