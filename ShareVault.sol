// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ShareVault is ReentrancyGuard, Ownable {
    mapping(address => uint256) public balanceOf;
    // 1. Учёт заблокированных долей пользователя
    mapping(address => uint256) public lockedShares;

    uint256 public totalSupply;
    uint256 public accountedAssets;

    address public lendingPool;

    event LendingPoolSet(address indexed lendingPool);
    event SharesLocked(address indexed user, uint256 amount);
    event SharesUnlocked(address indexed user, uint256 amount);

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "Caller is not LendingPool");
        _;
    }

    constructor() Ownable(msg.sender) {}

    // Одноразовая привязка LendingPool для решения циклической зависимости при деплое
    function setLendingPool(address _lendingPool) external onlyOwner {
        require(lendingPool == address(0), "LendingPool already set");
        require(_lendingPool != address(0), "Zero address");
        lendingPool = _lendingPool;
        emit LendingPoolSet(_lendingPool);
    }

    // Вспомогательная view-функция для проверки свободных (незаблокированных) долей
    function availableShares(address user) public view returns (uint256) {
        return balanceOf[user] - lockedShares[user];
    }

    // 2. Блокировка долей (только для LendingPool)
    function lockShares(address user, uint256 shares) external onlyLendingPool {
        require(shares > 0, "Zero shares");
        require(availableShares(user) >= shares, "Insufficient available shares");

        lockedShares[user] += shares;
        emit SharesLocked(user, shares);
    }

    // 3. Разблокировка долей (только для LendingPool)
    function unlockShares(address user, uint256 shares) external onlyLendingPool {
        require(shares > 0, "Zero shares");
        require(lockedShares[user] >= shares, "Insufficient locked shares");

        lockedShares[user] -= shares;
        emit SharesUnlocked(user, shares);
    }

    // Депозит
    function deposit() external payable nonReentrant {
        require(msg.value > 0, "Zero deposit");

        uint256 shares;

        if (totalSupply == 0) {
            shares = msg.value;
        } else {
            require(accountedAssets > 0, "Invalid accounting");
            shares = (msg.value * totalSupply) / accountedAssets;
        }

        require(shares > 0, "Zero shares");

        balanceOf[msg.sender] += shares;
        totalSupply += shares;
        accountedAssets += msg.value;
    }

    // 4. Вывод с проверкой доступных (свободных) долей
    function withdraw(uint256 shares) external nonReentrant {
        require(shares > 0, "Zero shares");
        // Проверяем не общий баланс, а именно свободный остаток!
        require(availableShares(msg.sender) >= shares, "Shares are locked");
        require(totalSupply > 0, "Empty vault");

        uint256 amount = (shares * accountedAssets) / totalSupply;

        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        accountedAssets -= amount;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    // Расчёт цены доли
    function sharePrice() external view nonReentrantView returns (uint256) {
        if (totalSupply == 0) return 0;

        return (accountedAssets * 1e18) / totalSupply;
    }
}
