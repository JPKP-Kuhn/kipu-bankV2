// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./InternalHelperKipuBank.sol";

/// @title KipuBankV2
/// @notice Multi-token bank with ETH and ERC-20 support, USD-based limits, and admin recovery
/// @author JPKP-Kuhn
contract KipuBankV2 is AccessControl, InternalHelperKipuBank {
    
    // ============================================
    // Roles
    // ============================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TOKEN_MANAGER_ROLE = keccak256("TOKEN_MANAGER_ROLE");

    // ============================================
    // Constants
    // ============================================
    
    uint256 public constant WITHDRAW_LIMIT_USD = 1000 * 1e18;
    uint256 public constant minimumDeposit = 0.001 ether;

    // ============================================
    // State Variables
    // ============================================
    
    /// @notice Total count of deposits and withdraws
    uint256 public depositCount;
    uint256 public withdrawCount;

    /// @notice Global limit for deposits
    uint256 public immutable bankCap;

    /// @notice Total balance in ETH equivalent
    uint256 public totalBalance;

    /// @notice Multi-token balance: user => token => balance
    mapping(address => mapping(address => uint256)) private accountsBalance;

    /// @notice Array of supported tokens for enumeration
    address[] public supportedTokens;

    /// @notice tonken => index of token in supportedToken, for O(1) search
    mapping(address => uint256) private tokenIndex;

    /// @notice Reentrancy lock
    bool private locked;

    // ============================================
    // Modifiers
    // ============================================

    /// @dev Modifier to prevent reentrancy attacks
    modifier noReentrancy() {
        if (locked) revert ReentrancyDetected();
        locked = true;
        _;
        locked = false;
    }

    // ============================================
    // Events
    // ============================================

    event DepositOk(address indexed user, uint256 value, bytes feedback);
    event WithdrawOk(address indexed user, uint256 value, bytes feedback);
    event DepositTokenOk(address indexed user, address indexed token, uint256 value, bytes feedback);
    event WithdrawTokenOk(address indexed user, address indexed token, uint256 value, bytes feedback);
    event adminRecovery(address indexed user, uint256 oldBalance, uint256 newBalance, bytes feedback);

    // ============================================
    // Constructor
    // ============================================
    
    /// @param _bankcap Bank capacity in ETH
    /// @param _oracle ETH/USD Chainlink oracle address
    constructor(uint256 _bankcap, IChainLink _oracle) 
        InternalHelperKipuBank(_oracle) 
    {
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TOKEN_MANAGER_ROLE, msg.sender);
        
        bankCap = _bankcap * 1 ether;

        // Add ETH as default supported token
        tokenOracles[ETH_ADDRESS] = _oracle;
        supportedTokens.push(ETH_ADDRESS);
        isSupportedToken[ETH_ADDRESS] = true;
    }

    // ============================================
    // Counter Functions
    // ============================================

    function _incrementDeposit() private {
        depositCount++;
    }

    function getDepositCount() external view returns (uint256) {
        return depositCount;
    }

    function _incrementWithdraw() private {
        withdrawCount++;
    }

    function getWithdrawCount() external view returns (uint256) {
        return withdrawCount;
    }

    // ============================================
    // Balance Query Functions
    // ============================================

    /// @notice Get ETH balance for the caller
    function getAccountBalance() external view returns (uint256) {
        return accountsBalance[msg.sender][ETH_ADDRESS];
    }
    
    /// @notice Get balance for a specific token
    /// @param token Token address (use ETH_ADDRESS for ETH)
    function getAccountBalanceToken(address token) external view returns (uint256) {
        return accountsBalance[msg.sender][token];
    }
    
    /// @notice Get balance for a specific user and token
    /// @param user User address
    /// @param token Token address (use ETH_ADDRESS for ETH)
    function getBalanceOf(address user, address token) external view checkSupportedToken(token) returns (uint256) {
        return accountsBalance[user][token];
    }

    // ============================================
    // Withdrawal Limit Functions
    // ============================================

    /// @notice Calculate withdraw limit in Wei for ETH
    function getWithdrawLimitInWei() public view returns (uint256) {
        uint256 price = getEthUSD();
        uint8 decimals = getDecimals();

        uint256 limitWei = (WITHDRAW_LIMIT_USD * (10 ** uint256(decimals))) / price;
        return limitWei;
    }

    /// @notice Calculate withdraw limit in token units for a specific token
    /// @param token Token address
    function getWithdrawLimitInToken(address token) public view checkSupportedToken(token) returns (uint256) {
        uint256 price = getTokenPriceUSD(token);
        uint8 decimals = getTokenOracleDecimals(token);

        uint8 tokenDecimals = _getTokenDecimals(token);

        // Calculate limit: (WITHDRAW_LIMIT_USD * oracle_decimals / price) adjusted for token decimals
        uint256 limitInToken = (WITHDRAW_LIMIT_USD * (10 ** uint256(decimals))) / price;

        // Adjust for token decimals (assuming WITHDRAW_LIMIT_USD is in 18 decimals)
        if (tokenDecimals < 18) {
            limitInToken = limitInToken / (10 ** (18 - tokenDecimals));
        } else if (tokenDecimals > 18) {
            limitInToken = limitInToken * (10 ** (tokenDecimals - 18));
        }

        return limitInToken;
    }

    // ============================================
    // ETH Deposit & Withdraw Functions
    // ============================================

    /// @notice Deposit ETH
    function deposit() external payable {
        if (msg.value == 0) revert ZeroAmount();
        if (msg.value < minimumDeposit) revert MinimunDepositRequired();
        if (totalBalance + msg.value > bankCap) revert ExceedsBankCap();
        
        // Effects
        accountsBalance[msg.sender][ETH_ADDRESS] += msg.value;
        totalBalance += msg.value;
        _incrementDeposit();

        emit DepositOk(msg.sender, msg.value, "Deposit Success!");
    }

    /// @notice Withdraw ETH
    /// @dev Follows CEI pattern: checks, effects, interactions
    function withdraw(uint256 _value) external noReentrancy {
        if (_value == 0) revert ZeroAmount();

        uint256 withdrawLimit = getWithdrawLimitInWei();
        if (_value > withdrawLimit) revert ExceedsWithdrawLimit();

        if (_value > accountsBalance[msg.sender][ETH_ADDRESS]) revert InsufficientBalance();

        // Effects
        accountsBalance[msg.sender][ETH_ADDRESS] -= _value;
        totalBalance -= _value;
        _incrementWithdraw();

        // Interaction
        (bool success, ) = msg.sender.call{value: _value}("");
        if (!success) revert TransferFailed();

        // Emit event
        emit WithdrawOk(msg.sender, _value, "Withdraw Success!");
    }

    // ============================================
    // ERC-20 Token Deposit & Withdraw Functions
    // ============================================

    /// @notice Deposit ERC-20 tokens
    /// @param token Token address to deposit
    /// @param amount Amount of tokens to deposit
    function depositToken(address token, uint256 amount) external noReentrancy checkSupportedToken(token) {
        if (amount == 0) revert ZeroAmount();
        
        // Check minimum deposit (converted to token units)
        uint256 minDepositInToken = _convertEthToToken(minimumDeposit, token);
        if (amount < minDepositInToken) revert MinimunDepositRequired();
        
        // Convert token amount to ETH equivalent for bank cap check
        uint256 ethEquivalent = _convertTokenToEth(amount, token);
        if (totalBalance + ethEquivalent > bankCap) revert ExceedsBankCap();
        
        // Effects
        accountsBalance[msg.sender][token] += amount;
        totalBalance += ethEquivalent;
        _incrementDeposit();
        
        // Interaction - transfer tokens from user to contract
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        
        emit DepositTokenOk(msg.sender, token, amount, "Token Deposit Success!");
    }
    
    /// @notice Withdraw ERC-20 tokens
    /// @param token Token address to withdraw
    /// @param amount Amount of tokens to withdraw
    function withdrawToken(address token, uint256 amount) external noReentrancy checkSupportedToken(token) {
        if (amount == 0) revert ZeroAmount();
        
        uint256 withdrawLimit = getWithdrawLimitInToken(token);
        if (amount > withdrawLimit) revert ExceedsWithdrawLimit();
        
        if (amount > accountsBalance[msg.sender][token]) revert InsufficientBalance();
        
        // Effects
        accountsBalance[msg.sender][token] -= amount;
        uint256 ethEquivalent = _convertTokenToEth(amount, token);
        totalBalance -= ethEquivalent;
        _incrementWithdraw();
        
        // Interaction - transfer tokens to user
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
        
        emit WithdrawTokenOk(msg.sender, token, amount, "Token Withdraw Success!");
    }

    // ============================================
    // Admin Functions
    // ============================================

    /// @notice Admin recovery for ETH balance
    /// @param user User address
    /// @param newBalance New balance in wei
    function adminRecoverBalance(address user, uint256 newBalance) external onlyRole(ADMIN_ROLE) {
        uint256 oldBalance = accountsBalance[user][ETH_ADDRESS];
        accountsBalance[user][ETH_ADDRESS] = newBalance;
        totalBalance += newBalance - oldBalance;
        emit adminRecovery(user, oldBalance, newBalance, "Recovery success!");
    }
    
    /// @notice Admin recovery for specific token balance
    /// @param user User address
    /// @param token Token address
    /// @param newBalance New balance for the user
    function adminRecoverTokenBalance(
        address user, 
        address token, 
        uint256 newBalance
    ) 
        external 
        onlyRole(ADMIN_ROLE)
        checkSupportedToken(token)
    {
        uint256 oldBalance = accountsBalance[user][token];
        accountsBalance[user][token] = newBalance;
        
        // Adjust totalBalance (convert to ETH equivalent)
        if (token == ETH_ADDRESS) {
            totalBalance += newBalance - oldBalance;
        } else {
            uint256 oldEthEquiv = _convertTokenToEth(oldBalance, token);
            uint256 newEthEquiv = _convertTokenToEth(newBalance, token);
            totalBalance = totalBalance - oldEthEquiv + newEthEquiv;
        }
        
        emit adminRecovery(user, oldBalance, newBalance, "Token Recovery Success!");
    }
    
    /// @notice Admin can withdraw tokens from contract (emergency recovery)
    /// @param token Token address (use ETH_ADDRESS for ETH)
    /// @param recipient Recipient address
    /// @param amount Amount to withdraw
    function adminWithdrawFunds(
        address token, 
        address recipient, 
        uint256 amount
    ) 
        external 
        onlyRole(ADMIN_ROLE)
        noReentrancy
    {
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        
        if (token == ETH_ADDRESS) {
            // Withdraw ETH
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // Withdraw ERC-20
            bool success = IERC20(token).transfer(recipient, amount);
            if (!success) revert TransferFailed();
        }
    }

    // ============================================
    // Token Management Functions
    // ============================================

    /// @notice Add support for a new ERC-20 token
    /// @param token Token address
    /// @param tokenOracle Chainlink oracle for token/USD price feed
    function addToken(address token, IChainLink tokenOracle) 
        external 
        onlyRole(TOKEN_MANAGER_ROLE) 
    {
        if (token == address(0) || token == ETH_ADDRESS) revert InvalidAddress();
        if (address(tokenOracle) == address(0)) revert InvalidAddress();
        if (isSupportedToken[token]) revert TokenAlreadySupported();
        
        tokenOracles[token] = tokenOracle;
        supportedTokens.push(token);
        isSupportedToken[token] = true;
        
        emit TokenAdded(token, address(tokenOracle), "Token Added Success!");
    }
    
    /// @notice Remove support for a token
    /// @param token Token address to remove
    function removeToken(address token) 
        external 
        onlyRole(TOKEN_MANAGER_ROLE) 
    {
        if (token == ETH_ADDRESS) revert InvalidAddress();
        if (!isSupportedToken[token]) revert TokenNotSupported();
        
        uint indexToRemove = tokenIndex[token] -1;
        uint lastIndex = supportedTokens.length -1;

        // If not the last element, move the last element to the removed position
        if (indexToRemove != lastIndex) {
            address lastToken = supportedTokens[lastIndex];
            supportedTokens[indexToRemove] = lastToken;
            tokenIndex[lastToken] = indexToRemove + 1; // Update moved token's index
        }

        // Remove from supportedTokens array
        supportedTokens.pop();

        isSupportedToken[token] = false;
        delete tokenOracles[token];
        delete tokenIndex[token];
        
        emit TokenRemoved(token, "Token Removed Success!");
    }
    
    /// @notice Get list of all supported tokens
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    // ============================================
    // Fallback Functions
    // ============================================

    fallback() external { 
        revert("Invalid Call");
    }

    receive() external payable {
        revert("Direct ETH not accepted. Use deposit()");
    }
}
