// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

interface ICSFeeDistributor {
    function getFeesToDistribute(
        bytes32[] calldata rewardProof,
        uint256 noIndex,
        uint256 shares
    ) external view returns (uint256);

    function distributeFees(
        bytes32[] calldata rewardProof,
        uint256 noIndex,
        uint256 shares
    ) external returns (uint256);

    function processTreeData(
        bytes32 _treeRoot,
        string calldata _treeCid,
        uint256 distributedShares
    ) external;
}
