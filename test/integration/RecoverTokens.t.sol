// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

import "forge-std/Test.sol";

import { CSModule } from "../../src/CSModule.sol";
import { CSAccounting } from "../../src/CSAccounting.sol";
import { IWstETH } from "../../src/interfaces/IWstETH.sol";
import { ILido } from "../../src/interfaces/ILido.sol";
import { ILidoLocator } from "../../src/interfaces/ILidoLocator.sol";
import { IWithdrawalQueue } from "../../src/interfaces/IWithdrawalQueue.sol";
import { ICSAccounting } from "../../src/interfaces/ICSAccounting.sol";
import { Utilities } from "../helpers/Utilities.sol";
import { PermitHelper } from "../helpers/Permit.sol";
import { DeploymentFixtures } from "../helpers/Fixtures.sol";
import { MerkleTree } from "../helpers/MerkleTree.sol";

contract RecoverIntegrationTest is
    Test,
    Utilities,
    PermitHelper,
    DeploymentFixtures
{
    address internal user;
    address internal recoverer;

    function setUp() public {
        Env memory env = envVars();
        vm.createSelectFork(env.RPC_URL);
        initializeFromDeployment(env.DEPLOY_CONFIG);

        recoverer = nextAddress("Recoverer");
        user = nextAddress("User");

        vm.startPrank(csm.getRoleMember(csm.DEFAULT_ADMIN_ROLE(), 0));
        csm.grantRole(csm.RESUME_ROLE(), address(this));
        csm.grantRole(csm.RECOVERER_ROLE(), recoverer);
        vm.stopPrank();
        if (csm.isPaused()) csm.resume();

        vm.startPrank(
            accounting.getRoleMember(accounting.DEFAULT_ADMIN_ROLE(), 0)
        );
        accounting.grantRole(accounting.RECOVERER_ROLE(), recoverer);
        vm.stopPrank();

        vm.startPrank(
            feeDistributor.getRoleMember(feeDistributor.DEFAULT_ADMIN_ROLE(), 0)
        );
        feeDistributor.grantRole(feeDistributor.RECOVERER_ROLE(), recoverer);
        vm.stopPrank();

        vm.startPrank(oracle.getRoleMember(oracle.DEFAULT_ADMIN_ROLE(), 0));
        oracle.grantRole(oracle.RECOVERER_ROLE(), recoverer);
        vm.stopPrank();
    }

    function test_recoverStETH_fromCSM() public {
        assertEq(lido.sharesOf(recoverer), 0);

        uint256 amount = 1 ether;
        vm.startPrank(user);
        vm.deal(user, amount);
        uint256 shares = lido.submit{ value: amount }({ _referal: address(0) });
        lido.transferShares(address(csm), shares);
        vm.stopPrank();

        vm.prank(recoverer);
        csm.recoverStETHShares();

        assertEq(lido.sharesOf(recoverer), shares);
    }

    function test_recoverETH_fromCSM() public {
        assertEq(recoverer.balance, 0);

        uint256 contractBalance = address(csm).balance;

        uint256 amount = 1 ether;
        vm.deal(address(csm), amount);

        vm.prank(recoverer);
        csm.recoverEther();

        assertEq(recoverer.balance, contractBalance + amount);
    }

    function test_recoverWstETH_fromCSM() public {
        assertEq(wstETH.balanceOf(recoverer), 0);

        uint256 amount = 1 ether;
        vm.startPrank(user);
        vm.deal(user, amount);
        uint256 shares = lido.submit{ value: amount }({ _referal: address(0) });
        lido.approve(address(wstETH), type(uint256).max);
        uint256 amountWstETH = wstETH.wrap(lido.getPooledEthByShares(shares));
        wstETH.transfer(address(csm), amountWstETH);
        vm.stopPrank();

        vm.prank(recoverer);
        csm.recoverERC20(address(wstETH), amountWstETH);

        assertEq(wstETH.balanceOf(recoverer), amountWstETH);
    }

    function test_recoverStETH_fromAccounting() public {
        assertEq(lido.sharesOf(recoverer), 0);

        uint256 amount = 1 ether;
        vm.startPrank(user);
        vm.deal(user, amount);
        uint256 shares = lido.submit{ value: amount }({ _referal: address(0) });
        lido.transferShares(address(accounting), shares);
        vm.stopPrank();

        vm.prank(recoverer);
        accounting.recoverStETHShares();

        assertEq(lido.sharesOf(recoverer), shares);
    }

    function test_recoverETH_fromAccounting() public {
        assertEq(recoverer.balance, 0);

        uint256 contractBalance = address(accounting).balance;

        uint256 amount = 1 ether;
        vm.deal(address(accounting), amount);

        vm.prank(recoverer);
        accounting.recoverEther();

        assertEq(recoverer.balance, contractBalance + amount);
    }

    function test_recoverWstETH_fromAccounting() public {
        assertEq(wstETH.balanceOf(recoverer), 0);

        uint256 amount = 1 ether;
        vm.startPrank(user);
        vm.deal(user, amount);
        uint256 shares = lido.submit{ value: amount }({ _referal: address(0) });
        lido.approve(address(wstETH), type(uint256).max);
        uint256 amountWstETH = wstETH.wrap(lido.getPooledEthByShares(shares));
        wstETH.transfer(address(accounting), amountWstETH);
        vm.stopPrank();

        vm.prank(recoverer);
        accounting.recoverERC20(address(wstETH), amountWstETH);

        assertEq(wstETH.balanceOf(recoverer), amountWstETH);
    }

    function test_recoverETH_fromFeeDistributor() public {
        assertEq(recoverer.balance, 0);

        uint256 contractBalance = address(feeDistributor).balance;

        uint256 amount = 1 ether;
        vm.deal(address(feeDistributor), amount);

        vm.prank(recoverer);
        feeDistributor.recoverEther();

        assertEq(recoverer.balance, contractBalance + amount);
    }

    function test_recoverWstETH_fromFeeDistributor() public {
        assertEq(wstETH.balanceOf(recoverer), 0);

        uint256 amount = 1 ether;
        vm.startPrank(user);
        vm.deal(user, amount);
        uint256 shares = lido.submit{ value: amount }({ _referal: address(0) });
        lido.approve(address(wstETH), type(uint256).max);
        uint256 amountWstETH = wstETH.wrap(lido.getPooledEthByShares(shares));
        wstETH.transfer(address(feeDistributor), amountWstETH);
        vm.stopPrank();

        vm.prank(recoverer);
        feeDistributor.recoverERC20(address(wstETH), amountWstETH);

        assertEq(wstETH.balanceOf(recoverer), amountWstETH);
    }

    function test_recoverETH_fromOracle() public {
        assertEq(recoverer.balance, 0);

        uint256 contractBalance = address(oracle).balance;

        uint256 amount = 1 ether;
        vm.deal(address(oracle), amount);

        vm.prank(recoverer);
        oracle.recoverEther();

        assertEq(recoverer.balance, contractBalance + amount);
    }

    function test_recoverWstETH_fromOracle() public {
        assertEq(wstETH.balanceOf(recoverer), 0);

        uint256 amount = 1 ether;
        vm.startPrank(user);
        vm.deal(user, amount);
        uint256 shares = lido.submit{ value: amount }({ _referal: address(0) });
        lido.approve(address(wstETH), type(uint256).max);
        uint256 amountWstETH = wstETH.wrap(lido.getPooledEthByShares(shares));
        wstETH.transfer(address(oracle), amountWstETH);
        vm.stopPrank();

        vm.prank(recoverer);
        oracle.recoverERC20(address(wstETH), amountWstETH);

        assertEq(wstETH.balanceOf(recoverer), amountWstETH);
    }
}
