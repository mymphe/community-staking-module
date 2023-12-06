// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.21;

abstract contract CSBondLockBase {
    event BondLockChanged(
        uint256 indexed nodeOperatorId,
        uint256 newAmount,
        uint256 retentionUntil
    );
    event BondLockPeriodsChanged(
        uint256 retentionPeriod,
        uint256 managementPeriod
    );

    error InvalidBondLockPeriods();
    error InvalidBondLockAmount();
}

abstract contract CSBondLock is CSBondLockBase {
    struct BondLock {
        uint256 amount;
        uint256 retentionUntil;
    }

    // todo: should be reconsidered
    uint256 public constant MIN_BOND_LOCK_RETENTION_PERIOD = 4 weeks;
    uint256 public constant MAX_BOND_LOCK_RETENTION_PERIOD = 365 days;
    uint256 public constant MIN_BOND_LOCK_MANAGEMENT_PERIOD = 1 days;
    uint256 public constant MAX_BOND_LOCK_MANAGEMENT_PERIOD = 7 days;

    uint256 internal _bondLockRetentionPeriod;
    uint256 internal _bondLockManagementPeriod;

    mapping(uint256 => BondLock) internal _bondLock;

    constructor(uint256 retentionPeriod, uint256 managementPeriod) {
        _setBondLockPeriods(retentionPeriod, managementPeriod);
    }

    function _setBondLockPeriods(
        uint256 retention,
        uint256 management
    ) internal {
        _validateBondLockPeriods(retention, management);
        _bondLockRetentionPeriod = retention;
        _bondLockManagementPeriod = management;
        emit BondLockPeriodsChanged(retention, management);
    }

    function getBondLockPeriods()
        external
        view
        returns (uint256 retention, uint256 management)
    {
        return (_bondLockRetentionPeriod, _bondLockManagementPeriod);
    }

    function _validateBondLockPeriods(
        uint256 retention,
        uint256 management
    ) internal pure {
        if (
            retention < MIN_BOND_LOCK_RETENTION_PERIOD ||
            retention > MAX_BOND_LOCK_RETENTION_PERIOD ||
            management < MIN_BOND_LOCK_MANAGEMENT_PERIOD ||
            management > MAX_BOND_LOCK_MANAGEMENT_PERIOD
        ) {
            revert InvalidBondLockPeriods();
        }
    }

    /// @notice Returns the amount and retention time of locked bond by the given node operator.
    function _get(
        uint256 nodeOperatorId
    ) internal view returns (BondLock memory) {
        return _bondLock[nodeOperatorId];
    }

    /// @notice Returns the amount of locked bond by the given node operator.
    function _getActualAmount(
        uint256 nodeOperatorId
    ) internal view returns (uint256) {
        if (_bondLock[nodeOperatorId].retentionUntil >= block.timestamp) {
            return _bondLock[nodeOperatorId].amount;
        }
        return 0;
    }

    /// @notice Reports EL rewards stealing for the given node operator.
    /// @param nodeOperatorId id of the node operator to lock bond for.
    /// @param amount amount to lock.
    function _lock(uint256 nodeOperatorId, uint256 amount) internal {
        if (amount == 0) {
            revert InvalidBondLockAmount();
        }
        _changeBondLock({
            nodeOperatorId: nodeOperatorId,
            amount: _bondLock[nodeOperatorId].amount + amount,
            retentionUntil: block.timestamp + _bondLockRetentionPeriod
        });
    }

    /// @dev Should be called by the committee. Doesn't settle blocked bond if it is in the safe frame (1 day)
    /// @notice Settles blocked bond for the given node operators.
    /// @param nodeOperatorIds ids of the node operators to settle blocked bond for.
    function _settle(uint256[] memory nodeOperatorIds) internal {
        for (uint256 i; i < nodeOperatorIds.length; ++i) {
            uint256 nodeOperatorId = nodeOperatorIds[i];
            BondLock storage bondLock = _bondLock[nodeOperatorId];
            if (
                block.timestamp +
                    _bondLockRetentionPeriod -
                    bondLock.retentionUntil <
                _bondLockManagementPeriod
            ) {
                // blocked bond in safe frame to manage it by committee or node operator
                continue;
            }
            uint256 uncovered;
            if (
                bondLock.amount > 0 &&
                bondLock.retentionUntil >= block.timestamp
            ) {
                uncovered = _penalize(nodeOperatorId, bondLock.amount);
            }
            _changeBondLock({
                nodeOperatorId: nodeOperatorId,
                amount: uncovered,
                retentionUntil: bondLock.retentionUntil
            });
        }
    }

    function _reduceAmount(uint256 nodeOperatorId, uint256 amount) internal {
        uint256 blocked = _getActualAmount(nodeOperatorId);
        if (amount == 0) {
            revert InvalidBondLockAmount();
        }
        if (blocked < amount) {
            revert InvalidBondLockAmount();
        }
        _changeBondLock(
            nodeOperatorId,
            _bondLock[nodeOperatorId].amount - amount,
            _bondLock[nodeOperatorId].retentionUntil
        );
    }

    function _changeBondLock(
        uint256 nodeOperatorId,
        uint256 amount,
        uint256 retentionUntil
    ) private {
        if (amount == 0) {
            delete _bondLock[nodeOperatorId];
            emit BondLockChanged(nodeOperatorId, 0, 0);
            return;
        }
        _bondLock[nodeOperatorId] = BondLock({
            amount: amount,
            retentionUntil: retentionUntil
        });
        emit BondLockChanged(nodeOperatorId, amount, retentionUntil);
    }

    function _penalize(
        uint256 nodeOperatorId,
        uint256 amount
    ) internal virtual returns (uint256);
}
