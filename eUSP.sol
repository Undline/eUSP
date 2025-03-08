// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin contracts for ERC20 and Ownable.
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal interface for Uniswap V2 Router and Factory, extended for token–token swaps and liquidity.
interface IUniswapV2Router02 {
    // Swap tokens for ETH.
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
         uint256 amountIn,
         uint256 amountOutMin,
         address[] calldata path,
         address to,
         uint256 deadline
    ) external;
    
    // Swap tokens for tokens (e.g., native token to USDC).
    function swapExactTokensForTokens(
         uint256 amountIn,
         uint256 amountOutMin,
         address[] calldata path,
         address to,
         uint256 deadline
    ) external returns (uint[] memory amounts);

    // Add liquidity for ETH-based pairs.
    function addLiquidityETH(
         address token,
         uint256 amountTokenDesired,
         uint256 amountTokenMin,
         uint256 amountETHMin,
         address to,
         uint256 deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    
    // Add liquidity for token–token pairs.
    function addLiquidity(
         address tokenA,
         address tokenB,
         uint256 amountADesired,
         uint256 amountBDesired,
         uint256 amountAMin,
         uint256 amountBMin,
         address to,
         uint256 deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function factory() external pure returns (address);
    function WETH() external pure returns (address);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/// @title eUGPToken
/// @notice ERC‑20 token with dynamic fees, anti-sniper measures, and an auto-liquidity mechanism that converts the liquidity fee portion to USDC.
/// @dev
///  • Total Supply: 1,111,111 tokens (18 decimals) minted to the master wallet (exempt from fees and limits).
///  • Dynamic Fee Schedule:
///       - 0 to 1 minute: 45% fee
///       - 1 to 3 minutes: 45% fee
///       - 3 to 10 minutes: 25% fee
///       - 10 to 15 minutes: 10% fee
///       - 15 minutes to 24 hours: 6% fee
///       - After 24 hours: 4% fee
///  • Standard Fee Distribution (once dynamic phase is over):
///       - 2% (50% of 4%) to the developer (master) wallet,
///       - 1% (25% of 4%) to the marketing wallet,
///       - 1% (25% of 4%) allocated for liquidity.
///  • Fee Conversion:
///       - Collected fees are initially in the native token.
///       - The liquidity portion is auto-swapped for USDC and added as liquidity (using half of the liquidity portion swapped and paired with the remaining tokens).
///       - Developer and marketing fee portions remain as native tokens.
///  • Anti-Sniper: Max wallet restrictions are enforced during the first 24 hours.
///  • Exemptions: Master (developer), marketing, and liquidity wallets are exempt.
///  • Multi-network: Designed to be EVM‑compatible. For networks like Base, update RPC and USDC/router addresses accordingly.
contract eUGPToken is ERC20, Ownable {
    // --- Fee Distribution Configuration (for standard 4% fee) ---
    // Shares: Developer (TEAM) : Marketing : Liquidity = 2 : 1 : 1.
    uint256 public constant TEAM_SHARE = 2;
    uint256 public constant MARKETING_SHARE = 1;
    uint256 public constant LIQUIDITY_SHARE = 1;
    uint256 public constant TOTAL_SHARES = TEAM_SHARE + MARKETING_SHARE + LIQUIDITY_SHARE; // 4

    // --- Mappings for Exemptions ---
    mapping(address => bool) private _isFeeExempt;
    mapping(address => bool) private _isMaxWalletExempt;

    // --- Trading Control ---
    bool public tradingEnabled = false;
    uint256 public launchTime; // Timestamp when trading is enabled

    // --- Uniswap Integration ---
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    // USDC token address for liquidity pairing.
    address public usdcAddress;

    // --- Swap & Liquidity Mechanism ---
    bool private inSwap;
    uint256 public swapThreshold;

    // --- Wallets ---
    address payable public teamWallet;      // Developer wallet (receives native tokens)
    address payable public marketingWallet; // Marketing wallet (receives native tokens)
    address payable public liquidityWallet; // Liquidity wallet (receives LP tokens)
    // Master wallet: receives total minted supply; considered the developer wallet.
    address public masterWallet;

    // --- Modifiers ---
    modifier lockTheSwap {
        inSwap = true;
        _;
        inSwap = false;
    }

    /// @notice Constructor sets up the token and initial configuration.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param totalSupply_ Total token supply (with 18 decimals).
    /// @param routerAddress Address of the Uniswap V2 Router.
    /// @param _usdcAddress USDC token address.
    /// @param _teamWallet Developer wallet address (payable).
    /// @param _marketingWallet Marketing wallet address (payable).
    /// @param _liquidityWallet Liquidity wallet address (payable) to receive LP tokens.
    /// @param _masterWallet Master wallet address (receives minted tokens; fully exempt).
    constructor(
         string memory name_,
         string memory symbol_,
         uint256 totalSupply_,
         address routerAddress,
         address _usdcAddress,
         address payable _teamWallet,
         address payable _marketingWallet,
         address payable _liquidityWallet,
         address _masterWallet
    ) ERC20(name_, symbol_) {
         // Mint total supply to the master wallet.
         _mint(_masterWallet, totalSupply_);

         // Set up Uniswap router and create the eUGP–WETH pair.
         uniswapV2Router = IUniswapV2Router02(routerAddress);
         uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
                        .createPair(address(this), uniswapV2Router.WETH());
         // Set USDC address.
         usdcAddress = _usdcAddress;

         // Set designated wallets.
         teamWallet = _teamWallet;
         marketingWallet = _marketingWallet;
         liquidityWallet = _liquidityWallet;
         masterWallet = _masterWallet;

         // Exempt critical addresses from fees.
         _isFeeExempt[msg.sender] = true;
         _isFeeExempt[address(this)] = true;
         _isFeeExempt[uniswapV2Pair] = true;
         _isFeeExempt[masterWallet] = true;
         _isFeeExempt[teamWallet] = true;
         _isFeeExempt[marketingWallet] = true;
         _isFeeExempt[liquidityWallet] = true;

         // Exempt critical addresses from max wallet limits.
         _isMaxWalletExempt[msg.sender] = true;
         _isMaxWalletExempt[address(this)] = true;
         _isMaxWalletExempt[uniswapV2Pair] = true;
         _isMaxWalletExempt[masterWallet] = true;
         _isMaxWalletExempt[teamWallet] = true;
         _isMaxWalletExempt[marketingWallet] = true;
         _isMaxWalletExempt[liquidityWallet] = true;

         // Set swap threshold (example: 0.05% of total supply).
         swapThreshold = totalSupply_ * 5 / 10000;
    }

    /// @notice Enables trading and records the launch time.
    function enableTrading() external onlyOwner {
         require(!tradingEnabled, "Trading already enabled");
         tradingEnabled = true;
         launchTime = block.timestamp;
    }

    /// @notice Allows owner to adjust fee exemption.
    function setFeeExempt(address account, bool exempt) external onlyOwner {
         _isFeeExempt[account] = exempt;
    }

    /// @notice Allows owner to adjust max wallet exemption.
    function setMaxWalletExempt(address account, bool exempt) external onlyOwner {
         _isMaxWalletExempt[account] = exempt;
    }

    /// @notice Overrides ERC20 _transfer to apply dynamic fees and max wallet checks.
    function _transfer(address from, address to, uint256 amount) internal override {
         // If trading not enabled, only allow transfers from/to fee-exempt addresses.
         if (!tradingEnabled) {
              require(_isFeeExempt[from] || _isFeeExempt[to], "Trading not enabled");
         }

         // --- Max Wallet Check ---
         if (tradingEnabled && block.timestamp < launchTime + 24 hours && !_isMaxWalletExempt[to]) {
              // For buys from the liquidity pair, enforce max wallet limit.
              if (from == uniswapV2Pair) {
                   uint256 currentMaxWallet = _getCurrentMaxWallet();
                   require(balanceOf(to) + amount <= currentMaxWallet, "Exceeds max wallet limit");
              }
         }

         // --- Auto Liquidity & Fee Swap ---
         uint256 contractTokenBalance = balanceOf(address(this));
         if (!inSwap && to == uniswapV2Pair && contractTokenBalance >= swapThreshold) {
              swapAndLiquify(contractTokenBalance);
         }

         // --- Fee Calculation ---
         uint256 feeAmount = 0;
         if (!_isFeeExempt[from] && !_isFeeExempt[to]) {
              // Apply fee on transactions interacting with the liquidity pair.
              if (from == uniswapV2Pair || to == uniswapV2Pair) {
                   uint256 currentTax = _getCurrentTax();
                   feeAmount = (amount * currentTax) / 100;
              }
         }

         if (feeAmount > 0) {
              super._transfer(from, address(this), feeAmount);
         }
         super._transfer(from, to, amount - feeAmount);
    }

    /// @notice Splits and processes the accumulated fee tokens:
    ///  - Liquidity portion is auto-converted to USDC and added as liquidity.
    ///  - The remaining portion is distributed to team and marketing wallets.
    function swapAndLiquify(uint256 tokenAmount) private lockTheSwap {
         // Calculate liquidity portion based on defined shares.
         uint256 liquidityPortion = (tokenAmount * LIQUIDITY_SHARE) / TOTAL_SHARES;
         uint256 otherPortion = tokenAmount - liquidityPortion; // for team and marketing
         
         // For liquidity: split liquidityPortion into two halves.
         uint256 tokensForLiquidity = liquidityPortion / 2;
         uint256 tokensToSwap = liquidityPortion - tokensForLiquidity; // ideally equal to tokensForLiquidity

         // Swap tokensToSwap for USDC.
         uint256 usdcReceived = swapTokensForUSDC(tokensToSwap);
         // Add liquidity using tokensForLiquidity and the USDC obtained.
         if (usdcReceived > 0 && tokensForLiquidity > 0) {
              addLiquidityUSDC(tokensForLiquidity, usdcReceived);
         }

         // Distribute remaining tokens (otherPortion) to team and marketing.
         uint256 teamAmount = (otherPortion * TEAM_SHARE) / (TEAM_SHARE + MARKETING_SHARE); // 2/3 of otherPortion
         uint256 marketingAmount = otherPortion - teamAmount;
         if (teamAmount > 0) {
              super._transfer(address(this), teamWallet, teamAmount);
         }
         if (marketingAmount > 0) {
              super._transfer(address(this), marketingWallet, marketingAmount);
         }
    }

    /// @notice Swaps a given amount of native tokens for USDC using Uniswap.
    /// @param tokenAmount Amount of tokens to swap.
    /// @return usdcReceived Amount of USDC received.
    function swapTokensForUSDC(uint256 tokenAmount) private returns (uint256 usdcReceived) {
         address[] memory path = new address[](2);
         path[0] = address(this);
         path[1] = usdcAddress;
         
         _approve(address(this), address(uniswapV2Router), tokenAmount);
         
         uint[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
              tokenAmount,
              0, // Accept any amount of USDC (for simplicity; consider slippage in production)
              path,
              address(this),
              block.timestamp
         );
         usdcReceived = amounts[amounts.length - 1];
    }

    /// @notice Adds liquidity to the USDC–eUGP pair.
    /// @param tokenAmount Amount of native tokens to add.
    /// @param usdcAmount Amount of USDC to add.
    function addLiquidityUSDC(uint256 tokenAmount, uint256 usdcAmount) private {
         _approve(address(this), address(uniswapV2Router), tokenAmount);
         // Add liquidity for token–USDC pair.
         uniswapV2Router.addLiquidity(
              address(this),
              usdcAddress,
              tokenAmount,
              usdcAmount,
              0, // Accept any amount of tokens.
              0, // Accept any amount of USDC.
              liquidityWallet, // LP tokens are sent to the liquidity wallet.
              block.timestamp
         );
    }

    /// @notice Returns the current fee percentage based on time elapsed since trading enabled.
    function _getCurrentTax() internal view returns (uint256) {
         uint256 timeElapsed = block.timestamp - launchTime;
         if (timeElapsed < 1 minutes) {
              return 45;
         } else if (timeElapsed < 3 minutes) {
              return 45;
         } else if (timeElapsed < 10 minutes) {
              return 25;
         } else if (timeElapsed < 15 minutes) {
              return 10;
         } else if (timeElapsed < 24 hours) {
              return 6;
         } else {
              return 4;
         }
    }

    /// @notice Returns the current maximum wallet size (in tokens) based on time elapsed (only enforced for 24 hours).
    function _getCurrentMaxWallet() internal view returns (uint256) {
         uint256 total = totalSupply();
         uint256 timeElapsed = block.timestamp - launchTime;
         if (timeElapsed < 1 minutes) {
              return total * 1 / 1000;  // 0.1%
         } else if (timeElapsed < 3 minutes) {
              return total * 25 / 10000; // 0.25%
         } else if (timeElapsed < 10 minutes) {
              return total * 25 / 10000; // 0.25%
         } else if (timeElapsed < 15 minutes) {
              return total * 5 / 1000;   // 0.5%
         } else {
              return total * 2 / 100;    // 2%
         }
    }

    /// @notice Fallback function to accept ETH (if needed for other swaps).
    receive() external payable {}
}
