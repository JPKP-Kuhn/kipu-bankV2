# Kipu Bank V2
Final project from the third module of ETH Kipu.  
Improvements from the previous version of [KipuBank](https://github.com/JPKP-Kuhn/kipu-bank) project. Now it implements a withdraw limit in USD with an interface to oracle chainlink, an admin recovery, and a multi token support.

- Important documentation  
  [Chainlink data feeds](https://docs.chain.link/data-feeds/price-feeds/addresses?page=1&testnetPage=2);
  [Chainlink contract](https://sepolia.etherscan.io/address/0x694AA1769357215DE4FAC081bf1f309aDC325306#readContract);
  [AccessControl github](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/AccessControl.sol);
  [AccessControl docs](https://docs.openzeppelin.com/contracts/3.x/access-control#using-accesscontrol);
  [EIP-7528](https://eips.ethereum.org/EIPS/eip-7528);
  [USDC Sepolia Address](https://sepolia.etherscan.io/token/0xf08a50178DFCdE18524640Ea6618a1F965821715)  

See my deploy on [Etherscan](https://sepolia.etherscan.io/tx/0x6483efa17ace29f2b672b3d8ab6f187bc1d7973d9ccb20b15006912e3c7d0c9e)

## Key features
The contract is separated in two files, InternalHelperKipuBank.sol is for internal functions, like communication with the chainlink oracle and the core math to convert tokens and their decimals in 1e18 base. KipuBankV2.sol is the main contract, for admin roles, accounts balances, and deposit and withdraw function.

### New Custom Errors
- InvalidOraclePrice(): Negative oracle price.
- TokenNotSupported(): Unsupported token.
- InvalidAddress(): Zero/null address.
- TokenAlreadySupported(): Duplicate token.

(Plus inherited from V1: ZeroAmount, MinimunDepositRequired, ExceedsBankCap, InsufficientBalance, ExceedsWithdrawLimit, TransferFailed, ReentrancyDetected.)

### Oracle Integration
Uses Chainlink for dynamic USD-based limits (e.g., $1000 withdraw max). Interface for ETH/USD and token/USD feeds.

```solidity
interface IChainLink {
    function latestAnswer() external view returns (int256);
    function decimals() external view returns (uint8);
}
```

Helper functions like `_convertTokenToEth` handle decimals and prices for multi-token accounting.

### Roles
Implemented [AccessControl](https://docs.openzeppelin.com/contracts/3.x/access-control), a role-based access control by OpenZeppelin for admins and tokens managers. OnlyRole functions.

```solidity
bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
bytes32 public constant TOKEN_MANAGER_ROLE = keccak256("TOKEN_MANAGER_ROLE");
```

- ADMIN_ROLE: For recovery functions (e.g., adminRecoverTokenBalance).
- TOKEN_MANAGER_ROLE: For add/remove tokens.

### Deposit
Supports ETH (via payable) and ERC-20. ERC-20 Deposit example (follows CEI pattern):

```solidity
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
   
    // Interaction
    bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
    if (!success) revert TransferFailed();
   
    emit DepositTokenOk(msg.sender, token, amount, "Token Deposit Success!");
}
```

### Withdraw
Similar to deposit, with USD limit check via oracle. Example for token:

```solidity
function withdrawToken(address token, uint256 amount) external noReentrancy checkSupportedToken(token) {
    if (amount == 0) revert ZeroAmount();
    
    uint256 withdrawLimit = getWithdrawLimitInToken(token);  // USD-based
    if (amount > withdrawLimit) revert ExceedsWithdrawLimit();
    
    if (amount > accountsBalance[msg.sender][token]) revert InsufficientBalance();
    
    // Effects
    accountsBalance[msg.sender][token] -= amount;
    uint256 ethEquivalent = _convertTokenToEth(amount, token);
    totalBalance -= ethEquivalent;
    _incrementWithdraw();
    
    // Interaction
    bool success = IERC20(token).transfer(msg.sender, amount);
    if (!success) revert TransferFailed();
    
    emit WithdrawTokenOk(msg.sender, token, amount, "Token Withdraw Success!");
}
```

### Token Management
Add/remove supported tokens dynamically (requires TOKEN_MANAGER_ROLE).

```solidity
function addToken(address token, IChainLink tokenOracle) external onlyRole(TOKEN_MANAGER_ROLE) {
    // Checks and effects...
    tokenOracles[token] = tokenOracle;
    supportedTokens.push(token);
    isSupportedToken[token] = true;
    emit TokenAdded(token, address(tokenOracle), "Token Added Success!");
}
```

### Admin Recovery
For emergency balance adjustments (ADMIN_ROLE only).

```solidity
function adminRecoverTokenBalance(address user, address token, uint256 newBalance) 
    external onlyRole(ADMIN_ROLE) checkSupportedToken(token) {
    // Update balance and totalBalance (ETH equiv.)
    emit adminRecovery(user, oldBalance, newBalance, "Token Recovery Success!");
}
```

### Events
Enhanced for observability: DepositOk, WithdrawOk, DepositTokenOk, WithdrawTokenOk, TokenAdded, TokenRemoved, adminRecovery.

## Deploy
You can use [REMIX IDE](https://remix-project.org/?lang=en) to test this contract  
For chainlink oracle in sepolia testnet use this pair ETH/USD: `0x694AA1769357215DE4FAC081bf1f309aDC325306`  

1. Create a new file KipuBankV2.sol and InternalHelperKipuBank.sol in the same directory.  
2. Compile KipuBankV2.sol  
3. In the deploy, you need to select the REMIX VM - Sepolia fork, with this the oracle will work  
4. The deploy constructor needs two parameters, a bankcap (previously needed in the first version) and the address of the oracle, use this for chainlink sepolia: `0x694AA1769357215DE4FAC081bf1f309aDC325306`  
5. You can see all the functions in the Deployed Contracts, select the value in ether or others and test them, with ether you use the functions from previous KipuBank version (those without token in the name).  
6. For multi-token: Deploy a mock oracle (you can use the MockOracle.sol in contracts) for token/USD (e.g., USDC/USD=100000000), call `addToken(USDC_ADDRESS, mockOracle)`. Approve tokens via At Address > approve(KipuBankV2, amount), then depositToken/withdrawToken. USDC Sepolia: 0xf08a50178DFCdE18524640Ea6618a1F965821715 (get from faucet.circle.com).
