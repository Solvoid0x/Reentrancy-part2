// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IShareVault {
    function balanceOf(address account) external view returns (uint256);
    function lockedShares(address account) external view returns (uint256);
    function availableShares(address account) external view returns (uint256);
    function sharePrice() external view returns (uint256);
    function lockShares(address user, uint256 shares) external;
    function unlockShares(address user, uint256 shares) external;
}

contract LendingPool {
    IShareVault public immutable vault;

    mapping(address => uint256) public debtOf;
    // 5. Учёт залога пользователя на стороне LendingPool
    mapping(address => uint256) public collateralSharesOf;

    uint256 public constant LTV = 50; // 50%

    event BorrowRecorded(address indexed user, uint256 amount, uint256 sharesLocked);
    event RepayRecorded(address indexed user, uint256 amount, uint256 sharesUnlocked);

    constructor(address vaultAddress) {
        require(vaultAddress != address(0), "Zero address");
        // Sanity check: убеждаемся, что по адресу есть контракт с нужной функцией
        IShareVault(vaultAddress).sharePrice();
        vault = IShareVault(vaultAddress);
    }

    // Стоимость всех долей пользователя
    function collateralValue(address user) public view returns (uint256) {
        uint256 shares = vault.balanceOf(user);
        uint256 price = vault.sharePrice();

        return (shares * price) / 1e18;
    }

    // Оформление займа с расчётом и блокировкой необходимого залога
    function recordBorrow(uint256 amount) external {
        require(amount > 0, "Zero amount");

        uint256 price = vault.sharePrice();
        require(price > 0, "Invalid share price");

        // Вычисляем минимальную стоимость залога для нового долга при LTV = 50%:
        // requiredValue = amount / (LTV / 100) = (amount * 100) / LTV
        uint256 requiredCollateralValue = (amount * 100) / LTV;

        // Переводим требуемую стоимость залога в количество shares (с округлением вверх!)
        uint256 sharesToLock = (requiredCollateralValue * 1e18 + price - 1) / price;

        // Проверяем общий лимит долга пользователя
        uint256 totalValue = collateralValue(msg.sender);
        uint256 maxDebt = (totalValue * LTV) / 100;
        require(debtOf[msg.sender] + amount <= maxDebt, "Insufficient collateral");

        // Обновляем состояние в пуле (Checks-Effects-Interactions)
        debtOf[msg.sender] += amount;
        collateralSharesOf[msg.sender] += sharesToLock;

        // Блокируем доли в Vault (если свободных долей не хватит, вся транзакция откатится)
        vault.lockShares(msg.sender, sharesToLock);

        emit BorrowRecorded(msg.sender, amount, sharesToLock);
    }

    // Погашение займа и разблокировка пропорциональной части залога
    function recordRepay(uint256 amount) external {
        require(amount > 0, "Zero amount");
        uint256 currentDebt = debtOf[msg.sender];
        require(currentDebt >= amount, "Repay exceeds debt");

        uint256 currentCollateralShares = collateralSharesOf[msg.sender];

        // Считаем, сколько долей освободить пропорционально погашенному долгу
        uint256 sharesToUnlock;
        if (amount == currentDebt) {
            // При полном погашении возвращаем ровно весь остаток залога без погрешностей округления
            sharesToUnlock = currentCollateralShares;
        } else {
            sharesToUnlock = (currentCollateralShares * amount) / currentDebt;
        }

        // Обновляем состояние в пуле
        debtOf[msg.sender] -= amount;
        collateralSharesOf[msg.sender] -= sharesToUnlock;

        // Разблокируем доли в Vault
        if (sharesToUnlock > 0) {
            vault.unlockShares(msg.sender, sharesToUnlock);
        }

        emit RepayRecorded(msg.sender, amount, sharesToUnlock);
    }
}
