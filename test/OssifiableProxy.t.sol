// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/lib/proxy/OssifiableProxy.sol";
import { Utilities } from "./helpers/Utilities.sol";

contract InitializableImplementationStub {
    uint256 public version;

    event Initialized(uint256 version);
    event FallbackIsFired();

    function initialize(uint256 _version) public {
        version = _version;
        emit Initialized(_version);
    }

    fallback() external payable {
        emit FallbackIsFired();
    }
}

contract OssifiableProxyTest is Test, Utilities {
    InitializableImplementationStub currentImpl;
    InitializableImplementationStub nextImpl;
    OssifiableProxy proxy;
    address deployer;
    address admin;
    address stranger;

    function setUp() public {
        deployer = address(this);
        admin = nextAddress("admin");
        stranger = nextAddress("stranger");

        currentImpl = new InitializableImplementationStub();
        nextImpl = new InitializableImplementationStub();

        proxy = new OssifiableProxy(address(currentImpl), admin, "0x");
    }

    function test_getAdmin() public {
        assertEq(proxy.proxy__getAdmin(), admin);
    }

    function test_getImplementation() public {
        assertEq(proxy.proxy__getImplementation(), address(currentImpl));
    }

    function test_getIsOssified() public {
        assertFalse(proxy.proxy__getIsOssified());
    }

    function test_ossify_RevertWhenNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(OssifiableProxy.NotAdmin.selector);
        proxy.proxy__ossify();
    }

    function test_ossify() public {
        vm.prank(admin);
        proxy.proxy__ossify();
        assertTrue(proxy.proxy__getIsOssified());
    }

    function test_ossify_RevertWhenOssified() public {
        vm.prank(admin);
        proxy.proxy__ossify();

        vm.expectRevert(OssifiableProxy.ProxyIsOssified.selector);
        proxy.proxy__ossify();
    }

    function test_changeAdmin_RevertWhenNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(OssifiableProxy.NotAdmin.selector);
        proxy.proxy__changeAdmin(stranger);
    }

    function test_changeAdmin_RevertWhenOssified() public {
        vm.prank(admin);
        proxy.proxy__ossify();
        assertTrue(proxy.proxy__getIsOssified());

        vm.expectRevert(OssifiableProxy.ProxyIsOssified.selector);
        proxy.proxy__changeAdmin(stranger);
    }

    function test_changeAdmin() public {
        vm.prank(admin);
        proxy.proxy__changeAdmin(stranger);
        assertEq(proxy.proxy__getAdmin(), stranger);
    }

    function test_upgradeTo_RevertWhenNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(OssifiableProxy.NotAdmin.selector);
        proxy.proxy__upgradeTo(address(nextImpl));
    }

    function test_upgradeTo_RevertWhenOssified() public {
        vm.prank(admin);
        proxy.proxy__ossify();
        assertTrue(proxy.proxy__getIsOssified());

        vm.expectRevert(OssifiableProxy.ProxyIsOssified.selector);
        proxy.proxy__upgradeTo(address(nextImpl));
    }

    function test_upgradeTo() public {
        vm.prank(admin);
        proxy.proxy__upgradeTo(address(nextImpl));
        assertEq(proxy.proxy__getImplementation(), address(nextImpl));
    }

    function test_upgradeToAndCall_RevertWhenNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(OssifiableProxy.NotAdmin.selector);
        proxy.proxy__upgradeToAndCall(
            address(nextImpl),
            abi.encodeWithSelector(nextImpl.initialize.selector, 1)
        );
    }

    function test_upgradeToAndCall_RevertWhenOssified() public {
        vm.prank(admin);
        proxy.proxy__ossify();
        assertTrue(proxy.proxy__getIsOssified());

        vm.expectRevert(OssifiableProxy.ProxyIsOssified.selector);
        proxy.proxy__upgradeToAndCall(
            address(nextImpl),
            abi.encodeWithSelector(nextImpl.initialize.selector, 1)
        );
    }

    function test_upgradeToAndCall() public {
        vm.prank(admin);
        proxy.proxy__upgradeToAndCall(
            address(nextImpl),
            abi.encodeWithSelector(nextImpl.initialize.selector, 1)
        );
        assertEq(proxy.proxy__getImplementation(), address(nextImpl));
        assertEq(
            InitializableImplementationStub(payable(address(proxy))).version(),
            1
        );
    }

    function test_receive() public {
        vm.deal(admin, 2 ether);
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit InitializableImplementationStub.FallbackIsFired();
        payable(address(proxy)).call{ value: 1 ether }("");
        assertEq(address(proxy).balance, 1 ether);
    }

    function test_fallback() public {
        vm.prank(admin);
        uint256 version = InitializableImplementationStub(
            payable(address(proxy))
        ).version();
        assertEq(version, 0);
    }
}
