// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @author skhomuti
library ValidatorCountsReport {
    error InvalidReportData();

    // TODO: consider joining with validate
    function countOperators(
        bytes calldata ids
    ) internal pure returns (uint256) {
        return ids.length / 8;
    }

    function validate(bytes calldata ids, bytes calldata counts) internal pure {
        if (
            counts.length / 16 != ids.length / 8 ||
            ids.length % 8 != 0 ||
            counts.length % 16 != 0
        ) {
            revert InvalidReportData();
        }
    }

    function next(
        bytes calldata ids,
        bytes calldata counts,
        uint256 offset
    ) internal pure returns (uint256 nodeOperatorId, uint256 keysCount) {
        // TODO: Rewrite to Yul (@madlabman)
        nodeOperatorId = uint256(
            bytes32(ids[8 * offset:8 * offset + 8]) >> 192
        );
        keysCount = uint256(
            bytes32(counts[16 * offset:16 * offset + 16]) >> 128
        );
    }
}
