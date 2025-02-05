// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

import "forge-std/Script.sol";
import { DeploymentFixtures } from "test/helpers/Fixtures.sol";
import { IStakingRouter } from "../../src/interfaces/IStakingRouter.sol";
import { IBurner } from "../../src/interfaces/IBurner.sol";

contract SimulateVote is Script, DeploymentFixtures {
    function run() external {
        Env memory env = envVars();
        initializeFromDeployment(env.DEPLOY_CONFIG);

        IStakingRouter stakingRouter = IStakingRouter(locator.stakingRouter());
        IBurner burner = IBurner(locator.burner());

        address agent = stakingRouter.getRoleMember(
            stakingRouter.STAKING_MODULE_MANAGE_ROLE(),
            0
        );
        vm.label(agent, "agent");

        address csmAdmin = payable(
            csm.getRoleMember(csm.DEFAULT_ADMIN_ROLE(), 0)
        );
        vm.label(csmAdmin, "csmAdmin");

        address burnerAdmin = payable(
            burner.getRoleMember(burner.DEFAULT_ADMIN_ROLE(), 0)
        );
        vm.label(burnerAdmin, "burnerAdmin");

        _setBalance(csmAdmin, "1000000000000000000");
        _setBalance(burnerAdmin, "1000000000000000000");

        vm.startBroadcast(csmAdmin);
        csm.grantRole(csm.DEFAULT_ADMIN_ROLE(), agent);
        hashConsensus.grantRole(hashConsensus.DEFAULT_ADMIN_ROLE(), agent);
        vm.stopBroadcast();

        vm.startBroadcast(burnerAdmin);
        burner.grantRole(burner.DEFAULT_ADMIN_ROLE(), agent);
        vm.stopBroadcast();

        vm.startBroadcast(agent);
        // 1. Grant manager role
        csm.grantRole(csm.MODULE_MANAGER_ROLE(), agent);

        // 2. Add CommunityStaking module
        stakingRouter.addStakingModule({
            _name: "community-staking-v1",
            _stakingModuleAddress: address(csm),
            _stakeShareLimit: 2000, // 20%
            _priorityExitShareThreshold: 2500, // 25%
            _stakingModuleFee: 800, // 8%
            _treasuryFee: 200, // 2%
            _maxDepositsPerBlock: 30,
            _minDepositBlockDistance: 25
        });
        // 3. burner role
        burner.grantRole(
            burner.REQUEST_BURN_SHARES_ROLE(),
            address(accounting)
        );
        // 4. Grant resume to agent
        csm.grantRole(csm.RESUME_ROLE(), agent);
        // 5. Resume CSM
        csm.resume();
        // 6. Revoke resume
        csm.revokeRole(csm.RESUME_ROLE(), agent);
        // 7. Update initial epoch
        hashConsensus.updateInitialEpoch(47480);
    }

    function _setBalance(address account, string memory balance) internal {
        vm.rpc(
            "anvil_setBalance",
            string.concat('["', vm.toString(account), '", ', balance, "]")
        );
    }
}
