// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.21;

import { IStETH } from "../../../src/interfaces/IStETH.sol";
import { PermitTokenBase } from "../Permit.sol";

contract WstETHMock is PermitTokenBase {
    IStETH public stETH;

    mapping(address => uint256) public _balance;
    uint256 public _totalSupply;

    error NotEnoughBalance(uint256 balance);

    /**
     * @param _stETH address of the StETH token to wrap
     */
    constructor(address _stETH) {
        stETH = IStETH(_stETH);
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balance[account];
    }

    function unwrap(uint256 _wstETHAmount) public returns (uint256) {
        require(_wstETHAmount > 0, "wstETH: zero amount unwrap not allowed");
        uint256 stETHAmount = stETH.getPooledEthByShares(_wstETHAmount);
        _burn(msg.sender, _wstETHAmount);
        stETH.transfer(msg.sender, stETHAmount);
        return stETHAmount;
    }

    function wrap(uint256 _stETHAmount) external returns (uint256) {
        require(_stETHAmount > 0, "wstETH: can't wrap zero stETH");
        uint256 wstETHAmount = stETH.getSharesByPooledEth(_stETHAmount);
        _mint(msg.sender, wstETHAmount);
        stETH.transferFrom(msg.sender, address(this), _stETHAmount);
        return wstETHAmount;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public {
        if (_balance[sender] < amount) {
            revert NotEnoughBalance(_balance[sender]);
        }
        _balance[sender] -= amount;
        _balance[recipient] += amount;
    }

    /**
     * @notice Get amount of wstETH for a given amount of stETH
     * @param _stETHAmount amount of stETH
     * @return Amount of wstETH for a given stETH amount
     */
    function getWstETHByStETH(
        uint256 _stETHAmount
    ) external view returns (uint256) {
        return stETH.getSharesByPooledEth(_stETHAmount);
    }

    /**
     * @notice Get amount of stETH for a given amount of wstETH
     * @param _wstETHAmount amount of wstETH
     * @return Amount of stETH for a given wstETH amount
     */
    function getStETHByWstETH(
        uint256 _wstETHAmount
    ) external view returns (uint256) {
        return stETH.getPooledEthByShares(_wstETHAmount);
    }

    function _mint(address _account, uint256 _amount) internal {
        _totalSupply += _amount;
        _balance[_account] += _amount;
    }

    function _burn(address _account, uint256 _amount) internal {
        _totalSupply -= _amount;
        _balance[_account] -= _amount;
    }
}
