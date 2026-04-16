// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// putting imports from openzeppelin for interface to interact with, security
// for price feed, pausable for emergency 

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract LendingProtocol is ReentrancyGuard, Pausable {

    using SafeERC20 for IERC20;

    // state variables 

    IERC20 public immutable usdt;
    AggregatorV3Interface public immutable priceFeed;
    address public owner;
    uint256 public constant LTV_RATIO = 75;
    uint256 public constant LIQUIDATION_THRESH = 80;
    uint256 public constant LIQUIDATION_BONUS = 10;
    uint256 public constant INTEREST_RATE_BPS = 500;
    uint256 public constant CLOSE_FACTOR = 50;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant PRECISION = 1e18;

    struct Position {
        uint256 collateralETH;
        uint256 debtUSDT;
        uint256 lastInterestAccrual;
    }

    mapping(address => Position) public positions;

    // Liquidity providers
    mapping(address => uint256) public liquidityProvided;
    uint256 public totalLiquidity;

    
    // events
   
    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed liquidator, address indexed borrower, uint256 debtRepaid, uint256 collateralSeized);
    event LiquiditySupplied(address indexed supplier, uint256 amount);
    event Paused();
    event Unpaused();

    // Constructor

    constructor(address _usdt, address _priceFeed) {
        require(_usdt != address(0), "Invalid USDT");
        require(_priceFeed != address(0), "Invalid oracle");

        usdt = IERC20(_usdt);
        priceFeed = AggregatorV3Interface(_priceFeed);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // Liquidity Supply


    function supplyUSDT(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        usdt.safeTransferFrom(msg.sender, address(this), amount);

        liquidityProvided[msg.sender] += amount;
        totalLiquidity += amount;

        emit LiquiditySupplied(msg.sender, amount);
    }

    // collateral
    

    function depositCollateral() external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "Zero ETH");
        _accrueInterest(msg.sender);

        positions[msg.sender].collateralETH += msg.value;

        emit CollateralDeposited(msg.sender, msg.value);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        _accrueInterest(msg.sender);

        Position storage pos = positions[msg.sender];
        require(pos.collateralETH >= amount, "Not enough collateral");

        pos.collateralETH -= amount;

        require(_isHealthy(msg.sender), "Would breach health factor");

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "ETH transfer failed");

        emit CollateralWithdrawn(msg.sender, amount);
    }

    // Borrow and repay
    

    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");

        _accrueInterest(msg.sender);

        Position storage pos = positions[msg.sender];
        pos.debtUSDT += amount;

        require(_isHealthy(msg.sender), "Exceeds LTV");
        require(usdt.balanceOf(address(this)) >= amount, "Insufficient liquidity");

        usdt.safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");

        _accrueInterest(msg.sender);

        Position storage pos = positions[msg.sender];
        require(pos.debtUSDT > 0, "No debt");

        uint256 repayAmount = amount > pos.debtUSDT ? pos.debtUSDT : amount;

        pos.debtUSDT -= repayAmount;

        usdt.safeTransferFrom(msg.sender, address(this), repayAmount);

        emit Repaid(msg.sender, repayAmount);
    }

    // Liquidation partial 
    

    function liquidate(address borrower) external nonReentrant whenNotPaused {
        require(borrower != msg.sender, "Self liquidate");

        _accrueInterest(borrower);
        require(!_isHealthy(borrower), "Position healthy");

        Position storage pos = positions[borrower];

        uint256 maxLiquidatable = (pos.debtUSDT * CLOSE_FACTOR) / 100;
        require(maxLiquidatable > 0, "Nothing to liquidate");

        uint256 ethPrice = _getETHPrice();

        uint256 collateralToSeize =
            (maxLiquidatable * 1e20 * (100 + LIQUIDATION_BONUS))
            / (ethPrice * 100);

        if (collateralToSeize > pos.collateralETH) {
            collateralToSeize = pos.collateralETH;
        }

        pos.debtUSDT -= maxLiquidatable;
        pos.collateralETH -= collateralToSeize;

        usdt.safeTransferFrom(msg.sender, address(this), maxLiquidatable);

        (bool sent, ) = msg.sender.call{value: collateralToSeize}("");
        require(sent, "ETH transfer failed");

        emit Liquidated(msg.sender, borrower, maxLiquidatable, collateralToSeize);
    }

    
    // interest
    

    function _accrueInterest(address user) internal {
        Position storage pos = positions[user];

        if (pos.debtUSDT == 0) {
            pos.lastInterestAccrual = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - pos.lastInterestAccrual;
        if (elapsed == 0) return;

        uint256 interest =
            (pos.debtUSDT * INTEREST_RATE_BPS * elapsed)
            / (SECONDS_PER_YEAR * 10_000);

        pos.debtUSDT += interest;
        pos.lastInterestAccrual = block.timestamp;
    }

    // Health Factor

    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function _healthFactor(address user) internal view returns (uint256) {
        Position storage pos = positions[user];

        if (pos.debtUSDT == 0) return type(uint256).max;

        uint256 ethPrice = _getETHPrice();

        uint256 collateralValueUSD =
            (pos.collateralETH * ethPrice) / 1e20;

        uint256 adjusted =
            (collateralValueUSD * LIQUIDATION_THRESH) / 100;

        return (adjusted * PRECISION) / pos.debtUSDT;
    }

    function _isHealthy(address user) internal view returns (bool) {
        return _healthFactor(user) >= PRECISION;
    }

    // oracle
    

    function _getETHPrice() internal view returns (uint256) {
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        require(price > 0, "Invalid price");
        require(answeredInRound >= roundId, "Stale round");
        require(updatedAt >= block.timestamp - 1 hours, "Price stale");

        return uint256(price);
    }
    // Admin Controls

    function pause() external onlyOwner {
        _pause();
        emit Paused();
    }

    function unpause() external onlyOwner {
        _unpause();
        emit Unpaused();
    }

    receive() external payable {}
}
