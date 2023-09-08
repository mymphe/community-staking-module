// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.21;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { AccessControlEnumerable } from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

import { FeeOracleBase } from "./FeeOracleBase.sol";

/// @author madlabman
contract FeeOracle is FeeOracleBase, AccessControlEnumerable {
    /// @notice Merkle Tree root
    bytes32 public reportRoot;

    /// @notice CID of the published Merkle tree
    string public treeCid;

    /// @notice Map to track the amount of submissions for the given report hash
    mapping(bytes32 => address[]) public submissions;

    /// @notice Number of reports that must match to consolidate a new report
    /// root (N/M)
    uint64 public quorum;

    uint64 public immutable SECONDS_PER_BLOCK;
    uint64 public immutable BLOCKS_PER_EPOCH;
    uint64 public immutable GENESIS_TIME;

    bytes32 public constant ORACLE_MEMBER_ROLE =
        keccak256("ORACLE_MEMBER_ROLE");

    uint64 public lastConsolidatedEpoch;
    /// @notice Interval between reports
    uint64 public reportIntervalEpochs;

    constructor(
        uint64 secondsPerBlock,
        uint64 blocksPerEpoch,
        uint64 genesisTime,
        uint64 reportInterval,
        address admin
    ) {
        if (admin == address(0)) revert ZeroAddress("admin");
        _setupRole(DEFAULT_ADMIN_ROLE, admin);

        if (genesisTime > block.timestamp) {
            revert GenesisTimeNotReached();
        }

        SECONDS_PER_BLOCK = secondsPerBlock;
        BLOCKS_PER_EPOCH = blocksPerEpoch;
        GENESIS_TIME = genesisTime;

        lastConsolidatedEpoch = currentEpoch();
        _setReportInterval(reportInterval);
    }

    /// @notice Get current epoch
    function currentEpoch() public view returns (uint64) {
        return
            (SafeCast.toUint64(block.timestamp) - GENESIS_TIME) /
            SECONDS_PER_BLOCK /
            BLOCKS_PER_EPOCH;
    }

    /// @notice Returns the next epoch to report
    function nextReportEpoch() public view returns (uint64) {
        uint64 epochsElapsed = currentEpoch() - lastConsolidatedEpoch;
        if (epochsElapsed < reportIntervalEpochs) {
            return lastConsolidatedEpoch + reportIntervalEpochs;
        }

        uint64 fullIntervals = epochsElapsed / reportIntervalEpochs;
        return lastConsolidatedEpoch + reportIntervalEpochs * fullIntervals;
    }

    /// @notice Get the current report frame slots
    function reportFrame() external view returns (uint64, uint64) {
        return (
            lastConsolidatedEpoch * BLOCKS_PER_EPOCH + 1,
            nextReportEpoch() * BLOCKS_PER_EPOCH
        );
    }

    /// @notice Set the report interval
    /// @param _reportInterval Interval between reports in epochs
    function setReportInterval(
        uint64 _reportInterval
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setReportInterval(_reportInterval);
        emit ReportIntervalSet(_reportInterval);
    }

    function _setReportInterval(uint64 _reportInterval) internal {
        if (_reportInterval == 0) revert ZeroInterval();
        reportIntervalEpochs = _reportInterval;
    }

    /// @notice Submit a report for a new report root
    /// If the quorum is reached, consolidate the report root
    /// @param epoch Epoch number
    /// @param newRoot Proposed report root
    /// @param _treeCid CID of the published Merkle tree
    function submitReport(
        uint64 epoch,
        bytes32 newRoot,
        string memory _treeCid
    ) external onlyRole(ORACLE_MEMBER_ROLE) whenNotPaused {
        uint64 _currentEpoch = currentEpoch();
        if (_currentEpoch < epoch) {
            revert ReportTooEarly();
        }

        if (epoch <= lastConsolidatedEpoch) {
            revert ReportTooLate();
        }

        if (epoch != nextReportEpoch()) {
            revert InvalidEpoch(epoch, nextReportEpoch());
        }

        // Get the current report
        bytes32 reportHash = _getReportHash(epoch, newRoot);

        // Check for double vote
        for (uint64 i; i < submissions[reportHash].length; ) {
            if (msg.sender == submissions[reportHash][i]) {
                revert DoubleVote();
            }

            unchecked {
                i++;
            }
        }

        // Emit Submit report before check the quorum
        emit ReportSubmitted(epoch, msg.sender, newRoot, _treeCid);
        // Store submitted report with a new added vote
        submissions[reportHash].push(msg.sender);

        // Check if it reaches the quorum
        if (submissions[reportHash].length == quorum) {
            delete submissions[reportHash];

            // Consolidate report
            lastConsolidatedEpoch = epoch;
            reportRoot = newRoot;
            _treeCid = _treeCid;

            emit ReportConsolidated(epoch, newRoot, _treeCid);
        }
    }

    /// @notice Get the report hash given the report root and slot
    /// @param _slot Slot
    /// @param _reportRoot Report Merkle tree root
    function _getReportHash(
        uint64 _slot,
        bytes32 _reportRoot
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_slot, _reportRoot));
    }

    /// @notice Get a hash of a leaf
    /// @param noIndex NO index
    /// @param shares Amount of shares
    /// @dev Double hash the leaf to prevent second preimage attacks
    function hashLeaf(
        uint64 noIndex,
        uint64 shares
    ) public pure returns (bytes32) {
        return
            keccak256(
                bytes.concat(keccak256(abi.encodePacked(noIndex, shares)))
            );
    }

    /// @notice Add a new oracle member
    /// @param _member Address of the new member
    /// @param _quorum New quorum
    function addMember(
        address _member,
        uint64 _quorum
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // NOTE: check for the member existence?
        grantRole(ORACLE_MEMBER_ROLE, _member);
        emit MemberAdded(_member);
        _setQuorum(_quorum);
    }

    /// @notice Remove an oracle member
    /// @param _member Address of the member to remove
    /// @param _quorum New quorum
    function removeMember(
        address _member,
        uint64 _quorum
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!hasRole(ORACLE_MEMBER_ROLE, _member)) revert NotMember(_member);
        revokeRole(ORACLE_MEMBER_ROLE, _member);
        emit MemberRemoved(_member);
        _setQuorum(_quorum);
    }

    /// @notice Set the quorum
    /// @param _quorum New quorum
    function setQuorum(uint64 _quorum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setQuorum(_quorum);
    }

    /// @notice Set the quorum
    /// @param _quorum New quorum
    function _setQuorum(uint64 _quorum) internal {
        if (_quorum <= getRoleMemberCount(ORACLE_MEMBER_ROLE) / 2) {
            revert QuorumTooSmall();
        }

        quorum = _quorum;
        emit QuorumSet(_quorum);
    }

    /// @notice Unpause the contract
    function unpause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Pause the contract
    function pause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
}
