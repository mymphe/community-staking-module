// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

import "forge-std/Test.sol";

import { OssifiableProxy } from "../../../src/lib/proxy/OssifiableProxy.sol";
import { CSModule } from "../../../src/CSModule.sol";
import { CSAccounting } from "../../../src/CSAccounting.sol";
import { CSFeeDistributor } from "../../../src/CSFeeDistributor.sol";
import { CSFeeOracle } from "../../../src/CSFeeOracle.sol";
import { Utilities } from "../../helpers/Utilities.sol";
import { DeploymentFixtures } from "../../helpers/Fixtures.sol";

contract UpgradabilityTest is Test, Utilities, DeploymentFixtures {
    constructor() {
        Env memory env = envVars();
        vm.createSelectFork(env.RPC_URL);
        initializeFromDeployment(env.DEPLOY_CONFIG);
    }

    function test_CSModuleUpgradeTo() public {
        OssifiableProxy proxy = OssifiableProxy(payable(address(csm)));
        CSModule newModule = new CSModule({
            moduleType: "CSMv2",
            minSlashingPenaltyQuotient: 32,
            elRewardsStealingFine: csm.EL_REWARDS_STEALING_FINE(),
            maxKeysPerOperatorEA: csm
                .MAX_SIGNING_KEYS_PER_OPERATOR_BEFORE_PUBLIC_RELEASE(),
            lidoLocator: address(csm.LIDO_LOCATOR())
        });
        vm.prank(proxy.proxy__getAdmin());
        proxy.proxy__upgradeTo(address(newModule));
        assertEq(csm.getType(), "CSMv2");
    }

    function test_CSAccountingUpgradeTo() public {
        OssifiableProxy proxy = OssifiableProxy(payable(address(accounting)));
        uint256 currentMaxCurveLength = accounting.MAX_CURVE_LENGTH();
        CSAccounting newAccounting = new CSAccounting({
            lidoLocator: address(accounting.LIDO_LOCATOR()),
            communityStakingModule: address(csm),
            maxCurveLength: currentMaxCurveLength + 10,
            minBondLockRetentionPeriod: accounting
                .MIN_BOND_LOCK_RETENTION_PERIOD(),
            maxBondLockRetentionPeriod: accounting
                .MAX_BOND_LOCK_RETENTION_PERIOD()
        });
        vm.prank(proxy.proxy__getAdmin());
        proxy.proxy__upgradeTo(address(newAccounting));
        assertEq(accounting.MAX_CURVE_LENGTH(), currentMaxCurveLength + 10);
    }

    function test_CSFeeOracleUpgradeTo() public {
        OssifiableProxy proxy = OssifiableProxy(payable(address(oracle)));
        CSFeeOracle newFeeOracle = new CSFeeOracle({
            secondsPerSlot: oracle.SECONDS_PER_SLOT(),
            genesisTime: block.timestamp
        });
        vm.prank(proxy.proxy__getAdmin());
        proxy.proxy__upgradeTo(address(newFeeOracle));
        assertEq(oracle.GENESIS_TIME(), block.timestamp);
    }

    function test_CSFeeDistributorUpgradeTo() public {
        OssifiableProxy proxy = OssifiableProxy(
            payable(address(feeDistributor))
        );
        CSFeeDistributor newFeeDistributor = new CSFeeDistributor({
            stETH: locator.lido(),
            accounting: address(1337),
            oracle: address(oracle)
        });
        vm.prank(proxy.proxy__getAdmin());
        proxy.proxy__upgradeTo(address(newFeeDistributor));
        assertEq(feeDistributor.ACCOUNTING(), address(1337));
    }
}
