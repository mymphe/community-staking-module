// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import { StdCheats } from "forge-std/StdCheats.sol";
import { LidoMock } from "./mocks/LidoMock.sol";
import { WstETHMock } from "./mocks/WstETHMock.sol";
import { LidoLocatorMock } from "./mocks/LidoLocatorMock.sol";
import { BurnerMock } from "./mocks/BurnerMock.sol";
import { WithdrawalQueueMock } from "./mocks/WithdrawalQueueMock.sol";
import { Stub } from "./mocks/Stub.sol";
import "forge-std/Test.sol";
import { IStakingRouter } from "../../src/interfaces/IStakingRouter.sol";
import { ILido } from "../../src/interfaces/ILido.sol";
import { ILidoLocator } from "../../src/interfaces/ILidoLocator.sol";
import { IWstETH } from "../../src/interfaces/IWstETH.sol";
import { IGateSeal } from "../../src/interfaces/IGateSeal.sol";
import { HashConsensus } from "../../src/lib/base-oracle/HashConsensus.sol";
import { IWithdrawalQueue } from "../../src/interfaces/IWithdrawalQueue.sol";
import { CSModule } from "../../src/CSModule.sol";
import { CSAccounting } from "../../src/CSAccounting.sol";
import { CSFeeOracle } from "../../src/CSFeeOracle.sol";
import { CSFeeDistributor } from "../../src/CSFeeDistributor.sol";
import { CSVerifier } from "../../src/CSVerifier.sol";
import { CSEarlyAdoption } from "../../src/CSEarlyAdoption.sol";
import { DeployParams } from "../../script/DeployBase.s.sol";
import { IACL } from "../../src/interfaces/IACL.sol";
import { IKernel } from "../../src/interfaces/IKernel.sol";

contract Fixtures is StdCheats, Test {
    bytes32 public constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function initLido()
        public
        returns (
            LidoLocatorMock locator,
            WstETHMock wstETH,
            LidoMock stETH,
            BurnerMock burner,
            WithdrawalQueueMock wq
        )
    {
        stETH = new LidoMock({ _totalPooledEther: 8013386371917025835991984 });
        stETH.mintShares({
            _account: address(stETH),
            _sharesAmount: 7059313073779349112833523
        });
        burner = new BurnerMock();
        Stub elVault = new Stub();
        wstETH = new WstETHMock(address(stETH));
        wq = new WithdrawalQueueMock(address(wstETH), address(stETH));
        Stub treasury = new Stub();
        Stub stakingRouter = new Stub();
        locator = new LidoLocatorMock(
            address(stETH),
            address(burner),
            address(wq),
            address(elVault),
            address(treasury),
            address(stakingRouter)
        );
        vm.label(address(stETH), "lido");
        vm.label(address(wstETH), "wstETH");
        vm.label(address(locator), "locator");
        vm.label(address(burner), "burner");
        vm.label(address(wq), "wq");
        vm.label(address(elVault), "elVault");
        vm.label(address(treasury), "treasury");
        vm.label(address(stakingRouter), "stakingRouter");
    }

    function _enableInitializers(address implementation) internal {
        // cheat to allow implementation initialisation
        vm.store(implementation, INITIALIZABLE_STORAGE, bytes32(0));
    }
}

contract DeploymentFixtures is StdCheats, Test {
    CSModule public csm;
    CSEarlyAdoption earlyAdoption;
    CSAccounting public accounting;
    CSFeeOracle public oracle;
    CSFeeDistributor public feeDistributor;
    CSVerifier public verifier;
    HashConsensus public hashConsensus;
    ILidoLocator public locator;
    IWstETH public wstETH;
    IStakingRouter public stakingRouter;
    ILido public lido;
    IGateSeal public gateSeal;

    struct Env {
        string RPC_URL;
        string DEPLOY_CONFIG;
    }

    struct DeploymentConfig {
        uint256 chainId;
        address csm;
        address earlyAdoption;
        address accounting;
        address oracle;
        address feeDistributor;
        address verifier;
        address hashConsensus;
        address lidoLocator;
        address gateSeal;
    }

    function envVars() public returns (Env memory) {
        Env memory env = Env(
            vm.envOr("RPC_URL", string("")),
            vm.envOr("DEPLOY_CONFIG", string(""))
        );
        vm.skip(_isEmpty(env.RPC_URL));
        vm.skip(_isEmpty(env.DEPLOY_CONFIG));
        return env;
    }

    function initializeFromDeployment(string memory deployConfigPath) public {
        string memory config = vm.readFile(deployConfigPath);
        DeploymentConfig memory deploymentConfig = parseDeploymentConfig(
            config
        );
        assertEq(deploymentConfig.chainId, block.chainid, "ChainId mismatch");

        csm = CSModule(deploymentConfig.csm);
        earlyAdoption = CSEarlyAdoption(deploymentConfig.earlyAdoption);
        accounting = CSAccounting(deploymentConfig.accounting);
        oracle = CSFeeOracle(deploymentConfig.oracle);
        feeDistributor = CSFeeDistributor(deploymentConfig.feeDistributor);
        verifier = CSVerifier(deploymentConfig.verifier);
        hashConsensus = HashConsensus(deploymentConfig.hashConsensus);
        locator = ILidoLocator(deploymentConfig.lidoLocator);
        lido = ILido(locator.lido());
        stakingRouter = IStakingRouter(locator.stakingRouter());
        wstETH = IWstETH(IWithdrawalQueue(locator.withdrawalQueue()).WSTETH());
        gateSeal = IGateSeal(deploymentConfig.gateSeal);
    }

    function parseDeploymentConfig(
        string memory config
    ) public returns (DeploymentConfig memory deploymentConfig) {
        deploymentConfig.chainId = vm.parseJsonUint(config, ".ChainId");

        deploymentConfig.csm = vm.parseJsonAddress(config, ".CSModule");
        vm.label(deploymentConfig.csm, "csm");

        deploymentConfig.earlyAdoption = vm.parseJsonAddress(
            config,
            ".CSEarlyAdoption"
        );
        vm.label(deploymentConfig.earlyAdoption, "earlyAdoption");

        deploymentConfig.accounting = vm.parseJsonAddress(
            config,
            ".CSAccounting"
        );
        vm.label(deploymentConfig.accounting, "accounting");

        deploymentConfig.oracle = vm.parseJsonAddress(config, ".CSFeeOracle");
        vm.label(deploymentConfig.oracle, "oracle");

        deploymentConfig.feeDistributor = vm.parseJsonAddress(
            config,
            ".CSFeeDistributor"
        );
        vm.label(deploymentConfig.feeDistributor, "feeDistributor");

        deploymentConfig.verifier = vm.parseJsonAddress(config, ".CSVerifier");
        vm.label(deploymentConfig.verifier, "verifier");

        deploymentConfig.hashConsensus = vm.parseJsonAddress(
            config,
            ".HashConsensus"
        );
        vm.label(deploymentConfig.hashConsensus, "hashConsensus");

        deploymentConfig.lidoLocator = vm.parseJsonAddress(
            config,
            ".LidoLocator"
        );
        vm.label(deploymentConfig.lidoLocator, "LidoLocator");

        deploymentConfig.gateSeal = vm.parseJsonAddress(config, ".GateSeal");
        vm.label(deploymentConfig.gateSeal, "GateSeal");
    }

    function parseDeployParams(
        string memory deployConfigPath
    ) internal view returns (DeployParams memory) {
        string memory config = vm.readFile(deployConfigPath);
        return
            abi.decode(
                vm.parseJsonBytes(config, ".DeployParams"),
                (DeployParams)
            );
    }

    function handleStakingLimit() public {
        address agent = stakingRouter.getRoleMember(
            stakingRouter.DEFAULT_ADMIN_ROLE(),
            0
        );
        IACL acl = IACL(IKernel(lido.kernel()).acl());
        bytes32 role = lido.STAKING_CONTROL_ROLE();
        vm.prank(acl.getPermissionManager(address(lido), role));
        acl.grantPermission(agent, address(lido), role);

        vm.prank(agent);
        lido.removeStakingLimit();
    }

    function handleBunkerMode() public {
        IWithdrawalQueue wq = IWithdrawalQueue(locator.withdrawalQueue());
        if (wq.isBunkerModeActive()) {
            vm.prank(wq.getRoleMember(wq.ORACLE_ROLE(), 0));
            wq.onOracleReport(false, 0, 0);
        }
    }

    function _isEmpty(string memory s) internal pure returns (bool) {
        return
            keccak256(abi.encodePacked(s)) == keccak256(abi.encodePacked(""));
    }
}
