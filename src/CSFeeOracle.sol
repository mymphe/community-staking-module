// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

import { PausableUntil } from "./lib/utils/PausableUntil.sol";
import { BaseOracle } from "./lib/base-oracle/BaseOracle.sol";

import { ICSFeeDistributor } from "./interfaces/ICSFeeDistributor.sol";
import { AssetRecoverer } from "./abstract/AssetRecoverer.sol";

contract CSFeeOracle is BaseOracle, PausableUntil, AssetRecoverer {
    /// @notice No assets are stored in the contract

    struct ReportData {
        /// @dev Version of the oracle consensus rules. Current version expected
        /// by the oracle can be obtained by calling getConsensusVersion().
        uint256 consensusVersion;
        /// @dev Reference slot for which the report was calculated. If the slot
        /// contains a block, the state being reported should include all state
        /// changes resulting from that block. The epoch containing the slot
        /// should be finalized prior to calculating the report.
        uint256 refSlot;
        /// @notice Merkle Tree root
        bytes32 treeRoot;
        /// @notice CID of the published Merkle tree
        string treeCid;
        /// @notice Total amount of fees distributed
        uint256 distributed;
    }

    /// @notice An ACL role granting the permission to manage the contract (update variables).
    bytes32 public constant CONTRACT_MANAGER_ROLE =
        keccak256("CONTRACT_MANAGER_ROLE");

    /// @notice An ACL role granting the permission to submit the data for a committee report.
    bytes32 public constant SUBMIT_DATA_ROLE = keccak256("SUBMIT_DATA_ROLE");

    /// @notice An ACL role granting the permission to pause accepting oracle reports
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    /// @notice An ACL role granting the permission to resume accepting oracle reports
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE");

    /// @notice An ACL role granting the permission to recover assets
    bytes32 public constant RECOVERER_ROLE = keccak256("RECOVERER_ROLE");

    uint256 internal constant MAX_BP = 10000;

    ICSFeeDistributor public feeDistributor;

    /// @notice Threshold in basis points used to determine the underperforming validators (by comparing with the
    /// network average).
    uint256 public perfThresholdBP;

    /// @dev Emitted when a new fee distributor contract is set
    event FeeDistributorContractSet(address feeDistributorContract);

    event PerformanceThresholdSet(uint256 valueBP);

    /// @dev Emitted when a report is consolidated
    event ReportConsolidated(
        uint256 indexed refSlot,
        uint256 distributed,
        bytes32 newRoot,
        string treeCid
    );

    error InvalidPerfThreshold();
    error AdminCannotBeZero();
    error SenderNotAllowed();

    constructor(
        uint256 secondsPerSlot,
        uint256 genesisTime
    ) BaseOracle(secondsPerSlot, genesisTime) {}

    function initialize(
        address admin,
        address feeDistributorContract,
        address consensusContract,
        uint256 consensusVersion,
        uint256 _perfThresholdBP
    ) external {
        if (admin == address(0)) revert AdminCannotBeZero();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        BaseOracle._initialize(consensusContract, consensusVersion, 0);
        /// @dev _setFeeDistributorContract() reverts if zero address
        _setFeeDistributorContract(feeDistributorContract);
        _setPerformanceThreshold(_perfThresholdBP);
    }

    /// @notice Sets a new fee distributor contract
    /// @param feeDistributorContract Address of the new fee distributor contract
    function setFeeDistributorContract(
        address feeDistributorContract
    ) external onlyRole(CONTRACT_MANAGER_ROLE) {
        _setFeeDistributorContract(feeDistributorContract);
    }

    /// @notice Sets a new performance threshold value in basis points.
    /// @param valueBP performance threshold in basis points.
    function setPerformanceThreshold(
        uint256 valueBP
    ) external onlyRole(CONTRACT_MANAGER_ROLE) {
        _setPerformanceThreshold(valueBP);
    }

    /// @notice Submits the data for a committee report
    /// @param data Data for a committee report
    /// @param contractVersion Version of the oracle consensus rules
    function submitReportData(
        ReportData calldata data,
        uint256 contractVersion
    ) external whenResumed {
        _checkMsgSenderIsAllowedToSubmitData();
        _checkContractVersion(contractVersion);
        _checkConsensusData(
            data.refSlot,
            data.consensusVersion,
            // it's a waste of gas to copy the whole calldata into mem but seems there's no way around
            keccak256(abi.encode(data))
        );
        _startProcessing();
        _handleConsensusReportData(data);
    }

    /// @notice Resume accepting oracle reports
    function resume() external whenPaused onlyRole(RESUME_ROLE) {
        _resume();
    }

    /// @notice Pause accepting oracle reports for a duration
    /// @param duration Duration of the pause
    function pauseFor(uint256 duration) external onlyRole(PAUSE_ROLE) {
        _pauseFor(duration);
    }

    /// @notice Pause accepting oracle reports until a timestamp
    /// @param pauseUntilInclusive Timestamp until which the oracle reports are paused
    function pauseUntil(
        uint256 pauseUntilInclusive
    ) external onlyRole(PAUSE_ROLE) {
        _pauseUntil(pauseUntilInclusive);
    }

    function _setFeeDistributorContract(
        address feeDistributorContract
    ) internal {
        if (feeDistributorContract == address(0)) revert AddressCannotBeZero();
        feeDistributor = ICSFeeDistributor(feeDistributorContract);
        emit FeeDistributorContractSet(feeDistributorContract);
    }

    function _setPerformanceThreshold(uint256 valueBP) internal {
        if (valueBP > MAX_BP) {
            revert InvalidPerfThreshold();
        }

        perfThresholdBP = valueBP;
        emit PerformanceThresholdSet(valueBP);
    }

    function _handleConsensusReport(
        ConsensusReport memory /* report */,
        uint256 /* prevSubmittedRefSlot */,
        uint256 /* prevProcessingRefSlot */
    ) internal override {
        // solhint-disable-previous-line no-empty-blocks
        // TODO: Implement me
        // NOTE: if we implement sending all leafs directly, we probably will need to support the sending in batches,
        // which means, we'll be ought to check the processing state and revert if not all data was send so far.
        // For reference look at the ValidatorExitBusOracle.
    }

    function _handleConsensusReportData(ReportData calldata data) internal {
        emit ReportConsolidated(
            data.refSlot,
            data.distributed,
            data.treeRoot,
            data.treeCid
        );

        feeDistributor.processOracleReport(
            data.treeRoot,
            data.treeCid,
            data.distributed
        );
    }

    function _checkMsgSenderIsAllowedToSubmitData() internal view {
        address sender = _msgSender();
        if (!hasRole(SUBMIT_DATA_ROLE, sender) && !_isConsensusMember(sender)) {
            revert SenderNotAllowed();
        }
    }

    function _onlyRecoverer() internal view override {
        _checkRole(RECOVERER_ROLE, msg.sender);
    }
}
