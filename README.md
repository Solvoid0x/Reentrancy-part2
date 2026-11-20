# DeFi Security — Collateral Locking & Cross-Contract Accounting

**Lab:** ReadOnlyReentrancyLab  
**Language:** Solidity 0.8.20  
**Focus:** Smart Contract Security, Access Control, CEI, Cross-Contract Interactions, Collateral Accounting

> Educational research project. This implementation is a simplified accounting model and is not intended for production use or real funds.

## 1. Overview

This lab explores an important DeFi security principle:

**Securing individual smart contracts does not automatically secure the entire protocol.**

The laboratory consists of two contracts:

- `ShareVault.sol` — accepts ETH, issues internal shares, tracks locked collateral and controls withdrawals.
- `LendingPool.sol` — calculates borrowing capacity, tracks user debt and requests collateral locking from the Vault.

The primary objective was to identify and address an architectural flaw that allowed users to withdraw collateral while retaining an outstanding debt.

## 2. Initial Architectural Vulnerability

The initial LendingPool implementation calculated borrowing capacity using the user's Vault shares:

```solidity
function collateralValue(address user)
    public
    view
    returns (uint256)
{
    uint256 shares = vault.balanceOf(user);
    uint256 price = vault.sharePrice();

    return (shares * price) / 1e18;
}
```

However, the protocol did not actually lock those shares.

This created the following sequence:

1. A user deposits ETH into ShareVault.
2. The user receives shares.
3. The user records a loan through LendingPool.
4. The user withdraws their shares from ShareVault.
5. LendingPool retains an outstanding debt without corresponding collateral.

The underlying problem was the absence of synchronization between collateral ownership and debt accounting.

**Finding:** Borrowing capacity was calculated from collateral that the protocol did not restrict from being withdrawn.

## 3. Collateral Locking Architecture

To address this issue, collateral locking was introduced.

### ShareVault

Two important state variables were added:

```solidity
mapping(address => uint256) public lockedShares;
address public lendingPool;
```

`lockedShares` tracks the amount of shares unavailable for withdrawal.

`lendingPool` identifies the only contract authorized to manage collateral locks.

An authorization modifier enforces this restriction:

```solidity
modifier onlyLendingPool() {
    require(
        msg.sender == lendingPool,
        "Caller is not LendingPool"
    );
    _;
}
```

The Vault exposes two restricted functions:

```solidity
function lockShares(
    address user,
    uint256 shares
) external onlyLendingPool {
    require(shares > 0, "Zero shares");
    require(
        availableShares(user) >= shares,
        "Insufficient available shares"
    );

    lockedShares[user] += shares;
}
```

```solidity
function unlockShares(
    address user,
    uint256 shares
) external onlyLendingPool {
    require(shares > 0, "Zero shares");
    require(
        lockedShares[user] >= shares,
        "Insufficient locked shares"
    );

    lockedShares[user] -= shares;
}
```

Available shares are calculated as:

```solidity
function availableShares(
    address user
) public view returns (uint256) {
    return balanceOf[user] - lockedShares[user];
}
```

The withdrawal function now checks available shares rather than the user's entire balance.

```solidity
require(
    availableShares(msg.sender) >= shares,
    "Shares are locked"
);
```

This prevents users from withdrawing shares that secure an outstanding loan.

## 4. Access Control and Deployment

Only the authorized LendingPool should be able to lock or unlock collateral.

Allowing arbitrary users to call `unlockShares()` would invalidate the entire collateral protection mechanism.

Allowing arbitrary users to call `lockShares()` would also create inconsistencies between the Vault's collateral accounting and LendingPool's debt records.

A one-time configuration function was introduced:

```solidity
function setLendingPool(
    address _lendingPool
) external onlyOwner {
    require(
        lendingPool == address(0),
        "LendingPool already set"
    );
    require(
        _lendingPool != address(0),
        "Zero address"
    );

    lendingPool = _lendingPool;
}
```

The deployment sequence is:

1. Deploy ShareVault.
2. Deploy LendingPool using the ShareVault address.
3. Configure the LendingPool address in ShareVault.
4. Verify both contract addresses and their configuration.

The one-time assignment prevents subsequent replacement of the authorized LendingPool.

The initial owner-controlled configuration remains a trust and deployment consideration.

## 5. Borrowing and Repayment Flow

LendingPool maintains two accounting mappings:

```solidity
mapping(address => uint256) public debtOf;

mapping(address => uint256)
    public collateralSharesOf;
```

These mappings have different purposes:

- `debtOf` tracks outstanding debt.
- `collateralSharesOf` tracks the collateral assigned to each borrowing position.

The Vault independently tracks locked shares to enforce withdrawal restrictions.

The intended invariant is:

```text
collateralSharesOf[user] == lockedShares[user]
```

This assumes LendingPool is the only source of collateral locking.

### Borrowing

The borrowing flow follows these steps:

1. Validate the requested borrowing amount.
2. Read the current share price.
3. Calculate the required collateral.
4. Check the user's borrowing limit.
5. Update LendingPool accounting.
6. Request collateral locking from ShareVault.
7. Emit a borrowing event.

The state changes occur before the external Vault call.

This follows the Checks-Effects-Interactions pattern.

If `lockShares()` fails, the entire transaction reverts, including LendingPool's preceding state changes.

### Repayment

The repayment flow reduces outstanding debt and unlocks a proportional amount of collateral.

For partial repayment, the implementation rounds the unlocked share amount down:

```solidity
sharesToUnlock =
    (currentCollateralShares * amount) / currentDebt;
```

For full repayment, the entire remaining collateral balance is released.

This prevents rounding dust from leaving a small amount of collateral permanently locked after complete repayment.

**Important limitation:** The current `recordBorrow()` and `recordRepay()` functions only simulate accounting. They do not transfer borrowed assets or collect repayment. A real implementation must enforce actual payment and asset transfers.

## 6. Checks-Effects-Interactions

CEI is applied across both contracts.

In ShareVault, withdrawal accounting is updated before ETH is transferred:

```solidity
balanceOf[msg.sender] -= shares;
totalSupply -= shares;
accountedAssets -= amount;

(bool success, ) =
    payable(msg.sender).call{value: amount}("");

require(success, "Transfer failed");
```

In LendingPool, debt and collateral accounting are updated before calling the Vault.

This reduces the risk of observing or exploiting inconsistent state during external interactions.

Transaction atomicity is also important: if a required external operation reverts, preceding state changes in the same transaction are reverted.

## 7. Read-only Reentrancy Protection

The ShareVault exposes a share price function:

```solidity
function sharePrice()
    external
    view
    nonReentrantView
    returns (uint256)
{
    if (totalSupply == 0) return 0;

    return (accountedAssets * 1e18) / totalSupply;
}
```

The `nonReentrantView` modifier prevents this function from being called while a protected operation is in progress.

This adds protection against reading sensitive intermediate states during external callbacks.

However, this mechanism is supplementary. Correct state-update ordering through CEI remains essential.

## 8. Arithmetic and Rounding Considerations

Collateral calculations require careful rounding.

For collateral requirements, rounding up is generally preferable because the protocol should not accept less collateral than required.

For borrowing limits, rounding down is conservative.

For partial collateral release, rounding down avoids unlocking more collateral than the proportional repayment permits.

The current implementation also contains multiplication expressions that can overflow before division.

OpenZeppelin's `Math.mulDiv` is a more robust option for full-precision multiplication and division.

Another consideration is double rounding:

```solidity
(accountedAssets * 1e18) / totalSupply;
```

followed by:

```solidity
(shares * price) / 1e18;
```

A direct share-to-asset conversion can avoid this intermediate rounding.

## 9. Remaining Security Considerations

The laboratory is an educational prototype and still has important limitations.

### Repayment Validation

`recordRepay()` currently does not collect ETH or tokens. A user can reduce the recorded debt and unlock collateral without making an actual payment.

A production implementation must verify payment using native ETH transfers or a correctly implemented ERC-20 transfer mechanism.

### Collateral Revaluation

The borrowing implementation calculates additional collateral based on the requested amount.

A more robust design should calculate the total collateral requirement based on the user's total debt after the new borrowing operation and the current share price.

Otherwise, an existing position may become undercollateralized after a share-price change.

### Dependency Validation

The LendingPool constructor calls `sharePrice()` as a basic sanity check.

This does not prove that the supplied contract correctly implements the complete interface or can be trusted.

Deployment validation and dependency assumptions must be documented.

### Liquidation and Risk Management

The current model does not include:

- Liquidation mechanisms.
- Interest accrual.
- External asset transfers.
- A production collateral valuation system.
- Full recovery mechanisms for undercollateralized positions.

These features require additional design and testing.

## 10. Core Security Invariants

The following properties should remain true:

1. `lockedShares[user]` must never exceed `balanceOf[user]`.
2. Users must not withdraw locked shares.
3. Only the authorized LendingPool may lock or unlock collateral.
4. LendingPool collateral accounting must remain synchronized with Vault collateral accounting.
5. Failed external locking or unlocking operations must not leave partial accounting changes.
6. Fully repaid positions must release their remaining collateral.

## 11. Testing Plan

Recommended tests for the next laboratory stage:

- `testOnlyLendingPoolCanLockShares`
- `testOnlyLendingPoolCanUnlockShares`
- `testCannotWithdrawLockedShares`
- `testCanWithdrawAvailableShares`
- `testBorrowLocksRequiredCollateral`
- `testFailedCollateralLockRevertsBorrowAccounting`
- `testPartialRepaymentUnlocksProportionalCollateral`
- `testFullRepaymentUnlocksAllCollateral`
- `testRepaymentRequiresActualPayment`
- `testBorrowingRecalculatesTotalCollateralRequirement`

## 12. Key Takeaways

This exercise demonstrated several important DeFi security principles:

- Individual contract security does not guarantee protocol security.
- Collateral must be actively protected, not merely read and evaluated.
- Access control must reflect the protocol's trust boundaries.
- Cross-contract state synchronization is critical.
- CEI and transaction atomicity help prevent inconsistent accounting.
- Rounding direction can affect economic security.
- Read-only functions can still participate in security-sensitive interactions.
- A suspicious code pattern must be analyzed in its complete architectural context.

**The central lesson: A secure DeFi protocol must preserve its economic and state invariants across every interacting contract.**
