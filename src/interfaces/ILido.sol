// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.21;

import { IStETH } from "./IStETH.sol";

/**
 * @title Interface defining Lido contract
 */
interface ILido is IStETH {
    function submit(address _referal) external payable returns (uint256);

    function deposit(
        uint256 _maxDepositsCount,
        uint256 _stakingModuleId,
        bytes calldata _depositCalldata
    ) external;
}
