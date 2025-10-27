// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// EIP-7528 ETH address
address constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

// Oracle with chainlink
interface IChainLink {
    function latestAnswer()
    external
    view
    returns (
      int256
    );

    function decimals()
    external
    view
    returns (
      uint8
    );
    
    function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}

/// @title InternalHelperKipuBank
/// @notice Base contract with internal helper functions and common state
/// @author JPKP-Kuhn
abstract contract InternalHelperKipuBank {

    // ============================================
    // State Variables (protected for child contract)
    // ============================================
    
    /// @notice Oracle to communicate with Chainlink (ETH/USD)
    IChainLink internal immutable oracle;
    
    /// @notice Token oracles mapping
    mapping(address => IChainLink) public tokenOracles;
    
    /// @notice Check if a token is supported
    mapping(address => bool) public isSupportedToken;

    // ============================================
    // Custom Errors
    // ============================================

    /// @dev Custom error for zero-value deposits or withdrawls
    error ZeroAmount();

    /// @dev Custom error for minimun deposit value
    error MinimunDepositRequired();

    /// @dev Custom error when deposit would exceed global bank cap
    error ExceedsBankCap();

    /// @dev Custom error when user has insufficient balance
    error InsufficientBalance();

    /// @dev Custom error when withdrawal exceeds per-transaction limit
    error ExceedsWithdrawLimit();

    /// @dev Custom error for failed ETH transfer
    error TransferFailed();

    /// @dev Custom error for reentrancy attempt
    error ReentrancyDetected();
    
    /// @dev Only if the ETH/USD price is negative
    error InvalidOraclePrice();

    /// @dev Token not supported
    error TokenNotSupported();

    /// @dev Invalid address
    error InvalidAddress();
    
    /// @dev Token already supported
    error TokenAlreadySupported();
    
    /// @dev Oracle data is stale or invalid
    error StaleOracleData();

    // ============================================
    // Events
    // ============================================
    
    event TokenAdded(address indexed token, address indexed oracle, bytes feedback);
    event TokenRemoved(address indexed token, bytes feedback);

    // ============================================
    // Constructor
    // ============================================
    
    /// @param _oracle Chainlink ETH/USD oracle address
    constructor(IChainLink _oracle) {
        oracle = _oracle;
    }

    // ============================================
    // Modifiers
    // ============================================

    /// @dev Modifier to check if token is supported
    modifier checkSupportedToken(address token) {
        if (!isSupportedToken[token]) revert TokenNotSupported();
        _;
    }

    // ============================================
    // Oracle & Price Functions
    // ============================================

    /// @notice Gets the latest ETH/USD price with staleness checks
    function getEthUSD() public view returns (uint256) {
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();
        
        // Validate price
        if (price <= 0) revert InvalidOraclePrice();
        
        // Check staleness: answeredInRound should be >= roundId
        if (answeredInRound < roundId) revert StaleOracleData();
        
        // Check staleness: updatedAt should be within 1 hour
        if (block.timestamp - updatedAt > 1 hours) revert StaleOracleData();
        
        return uint256(price);
    }

    /// @notice Get ETH/USD oracle decimals
    function getDecimals() public view returns (uint8) {
        return oracle.decimals();
    }

    /// @notice Get price for a specific token in USD with staleness checks
    /// @param token Token address
    function getTokenPriceUSD(address token) 
    public view checkSupportedToken(token) returns (uint256) {
        IChainLink tokenOracle = tokenOracles[token];
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = tokenOracle.latestRoundData();
        
        // Validate price
        if (price <= 0) revert InvalidOraclePrice();
        
        // Check staleness: answeredInRound should be >= roundId
        if (answeredInRound < roundId) revert StaleOracleData();
        
        // Check staleness: updatedAt should be within 1 hour
        if (block.timestamp - updatedAt > 1 hours) revert StaleOracleData();
        
        return uint256(price);
    }

    /// @notice Get decimals for a token's oracle
    /// @param token Token address
    function getTokenOracleDecimals(address token) 
    public view checkSupportedToken(token) returns (uint8) {
        return tokenOracles[token].decimals();
    }

    // ============================================
    // Internal Helper Functions
    // ============================================

    /// @dev Get token decimals (18 for ETH, actual decimals for ERC-20)
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == ETH_ADDRESS) {
            return 18;
        }
        return IERC20Metadata(token).decimals();
    }
    
    /// @dev Convert token amount to ETH equivalent using oracle prices
    function _convertTokenToEth(uint256 tokenAmount, address token) internal view returns (uint256) {
        if (token == ETH_ADDRESS) return tokenAmount;
        
        uint256 tokenPrice = getTokenPriceUSD(token);
        uint256 ethPrice = getEthUSD();
        uint8 tokenOracleDecimals = getTokenOracleDecimals(token);
        uint8 ethOracleDecimals = getDecimals();
        
        // Convert: (tokenAmount * tokenPrice) / ethPrice
        // Adjust for decimals
        uint256 ethEquivalent = Math.mulDiv(tokenAmount * tokenPrice, 10 ** ethOracleDecimals, 
                                            ethPrice * (10 ** tokenOracleDecimals));
        
        // Adjust for token decimals difference
        uint8 tokenDecimals = _getTokenDecimals(token);
        if (tokenDecimals < 18) {
            ethEquivalent = ethEquivalent * (10 ** (18 - tokenDecimals));
        } else if (tokenDecimals > 18) {
            ethEquivalent = ethEquivalent / (10 ** (tokenDecimals - 18));
        }
        
        return ethEquivalent;
    }
    
    /// @dev Convert ETH amount to token equivalent
    function _convertEthToToken(uint256 ethAmount, address token) internal view returns (uint256) {
        if (token == ETH_ADDRESS) return ethAmount;
        
        uint256 tokenPrice = getTokenPriceUSD(token);
        uint256 ethPrice = getEthUSD();
        uint8 tokenOracleDecimals = getTokenOracleDecimals(token);
        uint8 ethOracleDecimals = getDecimals();
        
        // Convert: (ethAmount * ethPrice) / tokenPrice
        uint256 tokenEquivalent = (ethAmount * ethPrice * (10 ** uint256(tokenOracleDecimals))) / 
                                  (tokenPrice * (10 ** uint256(ethOracleDecimals)));
        
        // Adjust for token decimals difference
        uint8 tokenDecimals = _getTokenDecimals(token);
        if (tokenDecimals < 18) {
            tokenEquivalent = tokenEquivalent / (10 ** (18 - tokenDecimals));
        } else if (tokenDecimals > 18) {
            tokenEquivalent = tokenEquivalent * (10 ** (tokenDecimals - 18));
        }
        
        return tokenEquivalent;
    }
}