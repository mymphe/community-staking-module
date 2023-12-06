// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.21;

import { AccessControlEnumerable } from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

import { CSBondCurve } from "./CSBondCurve.sol";
import { CSBondLock } from "./CSBondLock.sol";

import { ILidoLocator } from "./interfaces/ILidoLocator.sol";
import { ICSModule } from "./interfaces/ICSModule.sol";
import { ILido } from "./interfaces/ILido.sol";
import { IWstETH } from "./interfaces/IWstETH.sol";
import { ICSFeeDistributor } from "./interfaces/ICSFeeDistributor.sol";
import { IWithdrawalQueue } from "./interfaces/IWithdrawalQueue.sol";

contract CSAccountingBase {
    event ETHBondDeposited(
        uint256 indexed nodeOperatorId,
        address from,
        uint256 amount
    );
    event StETHBondDeposited(
        uint256 indexed nodeOperatorId,
        address from,
        uint256 amount
    );
    event WstETHBondDeposited(
        uint256 indexed nodeOperatorId,
        address from,
        uint256 amount
    );
    event StETHRewardsClaimed(
        uint256 indexed nodeOperatorId,
        address to,
        uint256 amount
    );
    event WstETHRewardsClaimed(
        uint256 indexed nodeOperatorId,
        address to,
        uint256 amount
    );
    event ETHRewardsRequested(
        uint256 indexed nodeOperatorId,
        address to,
        uint256 amount
    );
    event BondPenalized(
        uint256 indexed nodeOperatorId,
        uint256 penaltyETH,
        uint256 coveringETH
    );
    event ELRewardsStealingPenaltyInitiated(
        uint256 indexed nodeOperatorId,
        uint256 proposedBlockNumber,
        uint256 stolenAmount
    );
    event BondLockCompensated(uint256 indexed nodeOperatorId, uint256 amount);
    event BondLockReleased(uint256 indexed nodeOperatorId, uint256 amount);

    error NotOwnerToClaim(address msgSender, address owner);
    error InvalidSender();
}

contract CSAccounting is
    CSAccountingBase,
    CSBondCurve,
    CSBondLock,
    AccessControlEnumerable
{
    struct PermitInput {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE"); // 0x139c2898040ef16910dc9f44dc697df79363da767d8bc92f2e310312b816e46d
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE"); // 0x2fc10cc8ae19568712f7a176fb4978616a610650813c9d05326c34abb62749c7

    bytes32 public constant SEAL_ROLE = keccak256("SEAL_ROLE"); // 0x5561eed4f05defaf62a493aaa0919339d3f352fbf2261adb133a0c3655488b4f

    bytes32 public constant INSTANT_PENALIZE_BOND_ROLE =
        keccak256("INSTANT_PENALIZE_BOND_ROLE"); // 0x9909cf24c2d3bafa8c229558d86a1b726ba57c3ef6350848dcf434a4181b56c7
    bytes32 public constant EL_REWARDS_STEALING_PENALTY_INIT_ROLE =
        keccak256("EL_REWARDS_STEALING_PENALTY_INIT_ROLE"); // 0xcc2e7ce7be452f766dd24d55d87a3d42901c31ffa5b600cd1dff475abec91c1f
    bytes32 public constant EL_REWARDS_STEALING_PENALTY_RELEASE_ROLE =
        keccak256("EL_REWARDS_STEALING_PENALTY_RELEASE_ROLE"); // 0x8d78671045c549f09e0cf6e7e9856c36698f72f93962abf8e1955dc595a592ee
    bytes32 public constant EL_REWARDS_STEALING_PENALTY_SETTLE_ROLE =
        keccak256("EL_REWARDS_STEALING_PENALTY_SETTLE_ROLE"); // 0xdf6226649a1ca132f86d419e46892001284368a8f7445b5eb0d3fadf91329fe6
    bytes32 public constant SET_BOND_CURVE_ROLE =
        keccak256("SET_BOND_CURVE_ROLE"); // 0x645c9e6d2a86805cb5a28b1e4751c0dab493df7cf935070ce405489ba1a7bf72
    bytes32 public constant SET_BOND_MULTIPLIER_ROLE =
        keccak256("SET_BOND_MULTIPLIER_ROLE"); // 0x62131145aee19b18b85aa8ead52ba87f0efb6e61e249155edc68a2c24e8f79b5

    ILidoLocator private immutable LIDO_LOCATOR;
    ICSModule private immutable CSM;
    IWstETH private immutable WSTETH;

    address public FEE_DISTRIBUTOR;
    uint256 public totalBondShares;

    mapping(uint256 => uint256) internal _bondShares;

    /// @param bondCurve initial bond curve
    /// @param admin admin role member address
    /// @param lidoLocator lido locator contract address
    /// @param wstETH wstETH contract address
    /// @param communityStakingModule community staking module contract address
    /// @param bondLockRetentionPeriod retention period for locked bond in seconds
    /// @param bondLockManagementPeriod management period for locked bond in seconds
    constructor(
        uint256[] memory bondCurve,
        address admin,
        address lidoLocator,
        address wstETH,
        address communityStakingModule,
        uint256 bondLockRetentionPeriod,
        uint256 bondLockManagementPeriod
    )
        CSBondCurve(bondCurve)
        CSBondLock(bondLockRetentionPeriod, bondLockManagementPeriod)
    {
        // check zero addresses
        require(admin != address(0), "admin is zero address");
        require(lidoLocator != address(0), "lido locator is zero address");
        require(
            communityStakingModule != address(0),
            "community staking module is zero address"
        );
        require(wstETH != address(0), "wstETH is zero address");
        _setupRole(DEFAULT_ADMIN_ROLE, admin);

        LIDO_LOCATOR = ILidoLocator(lidoLocator);
        CSM = ICSModule(communityStakingModule);
        WSTETH = IWstETH(wstETH);
    }

    /// @notice Sets fee distributor contract address.
    /// @param fdAddress fee distributor contract address.
    function setFeeDistributor(
        address fdAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        FEE_DISTRIBUTOR = fdAddress;
    }

    /// @notice Sets bond lock periods.
    /// @param retention period in seconds to retain bond lock
    /// @param management period in seconds to manage bond lock by node operator
    function setLockedBondPeriods(
        uint256 retention,
        uint256 management
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // todo: is it admin role?
        _setBondLockPeriods(retention, management);
    }

    /// @notice Sets bond curve.
    /// @param bondCurve bond curve to set.
    function setBondCurve(
        uint256[] memory bondCurve
    ) external onlyRole(SET_BOND_CURVE_ROLE) {
        _setBondCurve(bondCurve);
    }

    /// @notice Sets basis points of the bond multiplier for the given node operator.
    /// @param nodeOperatorId id of the node operator to set bond multiplier for.
    /// @param basisPoints basis points of the bond multiplier.
    function setBondMultiplier(
        uint256 nodeOperatorId,
        uint256 basisPoints
    ) external onlyRole(SET_BOND_MULTIPLIER_ROLE) {
        _setBondMultiplier(nodeOperatorId, basisPoints);
    }

    /// @notice Pauses accounting by DAO decision.
    function pauseAccounting() external onlyRole(PAUSE_ROLE) {
        // todo: implement me
    }

    /// @notice Unpauses accounting by DAO decision.
    function resumeAccounting() external onlyRole(RESUME_ROLE) {
        // todo: implement me
    }

    /// @notice Returns the bond shares for the given node operator.
    /// @param nodeOperatorId id of the node operator to get bond for.
    /// @return bond shares.
    function getBondShares(
        uint256 nodeOperatorId
    ) public view returns (uint256) {
        return _bondShares[nodeOperatorId];
    }

    // todo: describe `rewardsProof`

    /// @notice Returns total rewards (bond + fees) in ETH for the given node operator.
    /// @param rewardsProof merkle proof of the rewards.
    /// @param nodeOperatorId id of the node operator to get rewards for.
    /// @param cumulativeFeeShares cumulative fee shares for the node operator.
    /// @return total rewards in ETH
    function getTotalRewardsETH(
        bytes32[] memory rewardsProof,
        uint256 nodeOperatorId,
        uint256 cumulativeFeeShares
    ) public view returns (uint256) {
        (uint256 current, uint256 required) = _bondSharesSummary(
            nodeOperatorId
        );
        current += _feeDistributor().getFeesToDistribute(
            rewardsProof,
            nodeOperatorId,
            cumulativeFeeShares
        );
        uint256 excess = current > required ? current - required : 0;
        return excess > 0 ? _ethByShares(excess) : 0;
    }

    /// @notice Returns total rewards (bond + fees) in stETH for the given node operator.
    /// @param rewardsProof merkle proof of the rewards.
    /// @param nodeOperatorId id of the node operator to get rewards for.
    /// @param cumulativeFeeShares cumulative fee shares for the node operator.
    /// @return total rewards in stETH
    function getTotalRewardsStETH(
        bytes32[] memory rewardsProof,
        uint256 nodeOperatorId,
        uint256 cumulativeFeeShares
    ) public view returns (uint256) {
        return
            getTotalRewardsETH(
                rewardsProof,
                nodeOperatorId,
                cumulativeFeeShares
            );
    }

    /// @notice Returns total rewards (bond + fees) in wstETH for the given node operator.
    /// @param rewardsProof merkle proof of the rewards.
    /// @param nodeOperatorId id of the node operator to get rewards for.
    /// @param cumulativeFeeShares cumulative fee shares for the node operator.
    /// @return total rewards in wstETH
    function getTotalRewardsWstETH(
        bytes32[] memory rewardsProof,
        uint256 nodeOperatorId,
        uint256 cumulativeFeeShares
    ) public view returns (uint256) {
        return
            WSTETH.getWstETHByStETH(
                getTotalRewardsStETH(
                    rewardsProof,
                    nodeOperatorId,
                    cumulativeFeeShares
                )
            );
    }

    /// @notice Returns excess bond in ETH for the given node operator.
    /// @param nodeOperatorId id of the node operator to get excess bond for.
    /// @return excess bond in ETH.
    function getExcessBondETH(
        uint256 nodeOperatorId
    ) public view returns (uint256) {
        (uint256 current, uint256 required) = _bondETHSummary(nodeOperatorId);
        return current > required ? current - required : 0;
    }

    /// @notice Returns excess bond in stETH for the given node operator.
    /// @param nodeOperatorId id of the node operator to get excess bond for.
    /// @return excess bond in stETH.
    function getExcessBondStETH(
        uint256 nodeOperatorId
    ) public view returns (uint256) {
        return getExcessBondETH(nodeOperatorId);
    }

    /// @notice Returns excess bond in wstETH for the given node operator.
    /// @param nodeOperatorId id of the node operator to get excess bond for.
    /// @return excess bond in wstETH.
    function getExcessBondWstETH(
        uint256 nodeOperatorId
    ) public view returns (uint256) {
        return WSTETH.getWstETHByStETH(getExcessBondStETH(nodeOperatorId));
    }

    /// @notice Returns the missing bond in ETH for the given node operator.
    /// @param nodeOperatorId id of the node operator to get missing bond for.
    /// @return missing bond in ETH.
    function getMissingBondETH(
        uint256 nodeOperatorId
    ) public view onlyExistingNodeOperator(nodeOperatorId) returns (uint256) {
        (uint256 current, uint256 required) = _bondETHSummary(nodeOperatorId);
        return required > current ? required - current : 0;
    }

    /// @notice Returns the missing bond in stETH for the given node operator.
    /// @param nodeOperatorId id of the node operator to get missing bond for.
    /// @return missing bond in stETH.
    function getMissingBondStETH(
        uint256 nodeOperatorId
    ) public view returns (uint256) {
        return getMissingBondETH(nodeOperatorId);
    }

    /// @notice Returns the missing bond in wstETH for the given node operator.
    /// @param nodeOperatorId id of the node operator to get missing bond for.
    /// @return missing bond in wstETH.
    function getMissingBondWstETH(
        uint256 nodeOperatorId
    ) public view returns (uint256) {
        return WSTETH.getWstETHByStETH(getMissingBondStETH(nodeOperatorId));
    }

    /// @notice Returns information about the locked bond for the given node operator.
    /// @param nodeOperatorId id of the node operator to get locked bond info for.
    /// @return locked bond info.
    function getLockedBondInfo(
        uint256 nodeOperatorId
    ) public view returns (CSBondLock.BondLock memory) {
        return CSBondLock._get(nodeOperatorId);
    }

    /// @notice Returns the amount of locked bond in ETH by the given node operator.
    /// @param nodeOperatorId id of the node operator to get locked bond amount.
    /// @return amount of locked bond in ETH.
    function getActualLockedBondETH(
        uint256 nodeOperatorId
    ) public view returns (uint256) {
        return CSBondLock._getActualAmount(nodeOperatorId);
    }

    /// @notice Returns the required bond in ETH (inc. missed and excess) for the given node operator to upload new keys.
    /// @param nodeOperatorId id of the node operator to get required bond for.
    /// @param additionalKeysCount number of new keys to add.
    /// @return required bond in ETH.
    function getRequiredBondETH(
        uint256 nodeOperatorId,
        uint256 additionalKeysCount
    ) public view returns (uint256) {
        // todo: can be optimized. get active keys once
        (uint256 current, uint256 required) = _bondETHSummary(nodeOperatorId);
        uint256 currentKeysCount = _getNodeOperatorActiveKeys(nodeOperatorId);
        uint256 multiplier = getBondMultiplier(nodeOperatorId);
        uint256 requiredForNextKeys = _getBondAmountByKeysCount(
            currentKeysCount + additionalKeysCount,
            multiplier
        ) - _getBondAmountByKeysCount(currentKeysCount, multiplier);

        uint256 missing = required > current ? required - current : 0;
        if (missing > 0) {
            return missing + requiredForNextKeys;
        }

        uint256 excess = current - required;
        if (excess >= requiredForNextKeys) {
            return 0;
        }

        return requiredForNextKeys - excess;
    }

    /// @notice Returns the required bond in stETH (inc. missed and excess) for the given node operator to upload new keys.
    /// @param nodeOperatorId id of the node operator to get required bond for.
    /// @return required bond in stETH.
    function getRequiredBondStETH(
        uint256 nodeOperatorId,
        uint256 additionalKeysCount
    ) public view returns (uint256) {
        return getRequiredBondETH(nodeOperatorId, additionalKeysCount);
    }

    /// @notice Returns the required bond in wstETH (inc. missed and excess) for the given node operator to upload new keys.
    /// @param nodeOperatorId id of the node operator to get required bond for.
    /// @param additionalKeysCount number of new keys to add.
    /// @return required bond in wstETH.
    function getRequiredBondWstETH(
        uint256 nodeOperatorId,
        uint256 additionalKeysCount
    ) public view returns (uint256) {
        return
            WSTETH.getWstETHByStETH(
                getRequiredBondStETH(nodeOperatorId, additionalKeysCount)
            );
    }

    /// @notice Returns the required bond in ETH for the given number of keys.
    /// @dev To calculate the amount for the new keys 2 calls are required:
    ///      getRequiredBondETHForKeys(newTotal) - getRequiredBondETHForKeys(currentTotal)
    /// @param keysCount number of keys to get required bond for.
    /// @return required in ETH.
    function getRequiredBondETHForKeys(
        uint256 keysCount
    ) public view returns (uint256) {
        return _getBondAmountByKeysCount(keysCount);
    }

    /// @notice Returns the required bond in stETH for the given number of keys.
    /// @dev To calculate the amount for the new keys 2 calls are required:
    ///      getRequiredBondStETHForKeys(newTotal) - getRequiredBondStETHForKeys(currentTotal)
    /// @param keysCount number of keys to get required bond for.
    /// @return required in stETH.
    function getRequiredBondStETHForKeys(
        uint256 keysCount
    ) public view returns (uint256) {
        return getRequiredBondETHForKeys(keysCount);
    }

    /// @notice Returns the required bond in wstETH for the given number of keys.
    /// @dev To calculate the amount for the new keys 2 calls are required:
    ///      getRequiredBondWstETHForKeys(newTotal) - getRequiredBondWstETHForKeys(currentTotal)
    /// @param keysCount number of keys to get required bond for.
    /// @return required in wstETH.
    function getRequiredBondWstETHForKeys(
        uint256 keysCount
    ) public view returns (uint256) {
        return WSTETH.getWstETHByStETH(getRequiredBondStETHForKeys(keysCount));
    }

    /// @dev unbonded meaning amount of keys with no bond at all
    /// @notice Returns the number of unbonded keys
    /// @param nodeOperatorId id of the node operator to get keys count for.
    /// @return unbonded keys count.
    function getUnbondedKeysCount(
        uint256 nodeOperatorId
    ) public view returns (uint256) {
        uint256 activeKeys = _getNodeOperatorActiveKeys(nodeOperatorId);
        uint256 currentBond = _ethByShares(_bondShares[nodeOperatorId]);
        uint256 lockedBond = getActualLockedBondETH(nodeOperatorId);
        if (currentBond > lockedBond) {
            uint256 multiplier = getBondMultiplier(nodeOperatorId);
            currentBond -= lockedBond;
            uint256 bondedKeys = _getKeysCountByBondAmount(
                currentBond,
                multiplier
            );
            if (
                currentBond > _getBondAmountByKeysCount(bondedKeys, multiplier)
            ) {
                bondedKeys += 1;
            }
            return activeKeys > bondedKeys ? activeKeys - bondedKeys : 0;
        }
        return activeKeys;
    }

    /// @notice Returns the number of keys by the given bond ETH amount
    /// @param ETHAmount bond in ETH
    function getKeysCountByBondETH(
        uint256 ETHAmount
    ) public view returns (uint256) {
        return _getKeysCountByBondAmount(ETHAmount);
    }

    /// @notice Returns the number of keys by the given bond stETH amount
    /// @param stETHAmount bond in stETH
    function getKeysCountByBondStETH(
        uint256 stETHAmount
    ) public view returns (uint256) {
        return getKeysCountByBondETH(stETHAmount);
    }

    /// @notice Returns the number of keys by the given bond wstETH amount
    /// @param wstETHAmount bond in wstETH
    function getKeysCountByBondWstETH(
        uint256 wstETHAmount
    ) public view returns (uint256) {
        return getKeysCountByBondETH(WSTETH.getStETHByWstETH(wstETHAmount));
    }

    /// @notice Stake user's ETH to Lido and make deposit in stETH to the bond
    /// @dev if `from` is not the same as `msg.sender`, then `msg.sender` should be CSM
    /// @param from address to stake ETH and deposit stETH from
    /// @param nodeOperatorId id of the node operator to stake ETH and deposit stETH for
    /// @return stETH shares amount
    function depositETH(
        address from,
        uint256 nodeOperatorId
    ) external payable returns (uint256) {
        from = _validateDepositSender(from);
        return _depositETH(from, nodeOperatorId);
    }

    function _depositETH(
        address from,
        uint256 nodeOperatorId
    ) internal onlyExistingNodeOperator(nodeOperatorId) returns (uint256) {
        uint256 shares = _lido().submit{ value: msg.value }(address(0));
        _bondShares[nodeOperatorId] += shares;
        totalBondShares += shares;
        emit ETHBondDeposited(nodeOperatorId, from, msg.value);
        return shares;
    }

    /// @notice Deposit user's stETH to the bond for the given Node Operator
    /// @dev if `from` is not the same as `msg.sender`, then `msg.sender` should be CSM
    /// @param from address to deposit stETH from
    /// @param nodeOperatorId id of the node operator to deposit stETH for
    /// @param stETHAmount amount of stETH to deposit
    /// @return stETH shares amount
    function depositStETH(
        address from,
        uint256 nodeOperatorId,
        uint256 stETHAmount
    ) external returns (uint256) {
        // todo: can it be two functions rather than one with `from` param and condition?
        from = _validateDepositSender(from);
        return _depositStETH(from, nodeOperatorId, stETHAmount);
    }

    /// @notice Deposit user's stETH to the bond for the given Node Operator using the proper permit for the contract
    /// @dev if `from` is not the same as `msg.sender`, then `msg.sender` should be CSM
    /// @param from address to deposit stETH from
    /// @param nodeOperatorId id of the node operator to deposit stETH for
    /// @param stETHAmount amount of stETH to deposit
    /// @param permit stETH permit for the contract
    /// @return stETH shares amount
    function depositStETHWithPermit(
        address from,
        uint256 nodeOperatorId,
        uint256 stETHAmount,
        PermitInput calldata permit
    ) external returns (uint256) {
        // todo: can it be two functions rather than one with `from` param and condition?
        from = _validateDepositSender(from);
        // preventing revert for already used permit
        if (_lido().allowance(from, address(this)) < permit.value) {
            // solhint-disable-next-line func-named-parameters
            _lido().permit(
                from,
                address(this),
                permit.value,
                permit.deadline,
                permit.v,
                permit.r,
                permit.s
            );
        }
        return _depositStETH(from, nodeOperatorId, stETHAmount);
    }

    function _depositStETH(
        address from,
        uint256 nodeOperatorId,
        uint256 stETHAmount
    ) internal onlyExistingNodeOperator(nodeOperatorId) returns (uint256) {
        // todo: should we check that `from` is manager\reward address ???
        uint256 shares = _sharesByEth(stETHAmount);
        _lido().transferSharesFrom(from, address(this), shares);
        _bondShares[nodeOperatorId] += shares;
        totalBondShares += shares;
        emit StETHBondDeposited(nodeOperatorId, from, stETHAmount);
        return shares;
    }

    /// @notice Unwrap user's wstETH and make deposit in stETH to the bond for the given Node Operator
    /// @dev if `from` is not the same as `msg.sender`, then `msg.sender` should be CSM
    /// @param from address to unwrap wstETH from
    /// @param nodeOperatorId id of the node operator to deposit stETH for
    /// @param wstETHAmount amount of wstETH to deposit
    /// @return stETH shares amount
    function depositWstETH(
        address from,
        uint256 nodeOperatorId,
        uint256 wstETHAmount
    ) external returns (uint256) {
        // todo: can it be two functions rather than one with `from` param and condition?
        from = _validateDepositSender(from);
        return _depositWstETH(from, nodeOperatorId, wstETHAmount);
    }

    /// @notice Unwrap user's wstETH and make deposit in stETH to the bond for the given Node Operator using the proper permit for the contract
    /// @dev if `from` is not the same as `msg.sender`, then `msg.sender` should be CSM
    /// @param from address to unwrap wstETH from
    /// @param nodeOperatorId id of the node operator to deposit stETH for
    /// @param wstETHAmount amount of wstETH to deposit
    /// @param permit wstETH permit for the contract
    /// @return stETH shares amount
    function depositWstETHWithPermit(
        address from,
        uint256 nodeOperatorId,
        uint256 wstETHAmount,
        PermitInput calldata permit
    ) external returns (uint256) {
        // todo: can it be two functions rather than one with `from` param and condition?
        from = _validateDepositSender(from);
        // preventing revert for already used permit
        if (WSTETH.allowance(from, address(this)) < permit.value) {
            // solhint-disable-next-line func-named-parameters
            WSTETH.permit(
                from,
                address(this),
                permit.value,
                permit.deadline,
                permit.v,
                permit.r,
                permit.s
            );
        }
        return _depositWstETH(from, nodeOperatorId, wstETHAmount);
    }

    function _depositWstETH(
        address from,
        uint256 nodeOperatorId,
        uint256 wstETHAmount
    ) internal onlyExistingNodeOperator(nodeOperatorId) returns (uint256) {
        // todo: should we check that `from` is manager\reward address ???
        WSTETH.transferFrom(from, address(this), wstETHAmount);
        uint256 stETHAmount = WSTETH.unwrap(wstETHAmount);
        uint256 shares = _sharesByEth(stETHAmount);
        _bondShares[nodeOperatorId] += shares;
        totalBondShares += shares;
        emit WstETHBondDeposited(nodeOperatorId, from, wstETHAmount);
        return shares;
    }

    /// @dev only CSM can pass `from` != `msg.sender`
    function _validateDepositSender(
        address from
    ) internal view returns (address) {
        if (from == address(0)) from = msg.sender;
        if (from != msg.sender && msg.sender != address(CSM))
            revert InvalidSender();
        return from;
    }

    /// @notice Claims excess bond in ETH for the given node operator with desirable value
    /// @param nodeOperatorId id of the node operator to claim excess bond for.
    /// @param stETHAmount amount of stETH to claim.
    function claimExcessBondStETH(
        uint256 nodeOperatorId,
        uint256 stETHAmount
    ) external onlyExistingNodeOperator(nodeOperatorId) {
        // todo: implement me
    }

    /// @notice Claims excess bond in wstETH for the given node operator with desirable value
    /// @param nodeOperatorId id of the node operator to claim excess bond for.
    /// @param wstETHAmount amount of wstETH to claim.
    function claimExcessBondWstETH(
        uint256 nodeOperatorId,
        uint256 wstETHAmount
    ) external onlyExistingNodeOperator(nodeOperatorId) {
        // todo: implement me
    }

    /// @notice Request excess bond in Withdrawal NFT (unstETH) for the given node operator available for this moment.
    /// @dev reverts if amount isn't between MIN_STETH_WITHDRAWAL_AMOUNT and MAX_STETH_WITHDRAWAL_AMOUNT
    /// @param nodeOperatorId id of the node operator to request rewards for.
    /// @param ETHAmount amount of ETH to request.
    /// @return requestIds an array of the created withdrawal request ids
    function requestExcessBondETH(
        uint256 nodeOperatorId,
        uint256 ETHAmount
    )
        external
        onlyExistingNodeOperator(nodeOperatorId)
        returns (uint256[] memory requestIds)
    {
        // todo: implement me
    }

    /// @notice Claims full reward (fee + bond) in stETH for the given node operator with desirable value
    /// @param rewardsProof merkle proof of the rewards.
    /// @param nodeOperatorId id of the node operator to claim rewards for.
    /// @param cumulativeFeeShares cumulative fee shares for the node operator.
    /// @param stETHAmount amount of stETH to claim.
    function claimRewardsStETH(
        bytes32[] memory rewardsProof,
        uint256 nodeOperatorId,
        uint256 cumulativeFeeShares,
        uint256 stETHAmount
    ) external onlyExistingNodeOperator(nodeOperatorId) {
        (
            address managerAddress,
            address rewardAddress
        ) = _getNodeOperatorAddresses(nodeOperatorId);
        _isSenderEligibleToClaim(managerAddress);
        uint256 claimableShares = _pullFeeRewards(
            rewardsProof,
            nodeOperatorId,
            cumulativeFeeShares
        );
        if (claimableShares == 0) {
            emit StETHRewardsClaimed(nodeOperatorId, rewardAddress, 0);
            return;
        }
        uint256 toClaim = stETHAmount < _ethByShares(claimableShares)
            ? _sharesByEth(stETHAmount)
            : claimableShares;
        _lido().transferSharesFrom(address(this), rewardAddress, toClaim);
        _bondShares[nodeOperatorId] -= toClaim;
        totalBondShares -= toClaim;
        emit StETHRewardsClaimed(
            nodeOperatorId,
            rewardAddress,
            _ethByShares(toClaim)
        );
    }

    /// @notice Claims full reward (fee + bond) in wstETH for the given node operator available for this moment
    /// @param rewardsProof merkle proof of the rewards.
    /// @param nodeOperatorId id of the node operator to claim rewards for.
    /// @param cumulativeFeeShares cumulative fee shares for the node operator.
    /// @param wstETHAmount amount of wstETH to claim.
    function claimRewardsWstETH(
        bytes32[] memory rewardsProof,
        uint256 nodeOperatorId,
        uint256 cumulativeFeeShares,
        uint256 wstETHAmount
    ) external onlyExistingNodeOperator(nodeOperatorId) {
        (
            address managerAddress,
            address rewardAddress
        ) = _getNodeOperatorAddresses(nodeOperatorId);
        _isSenderEligibleToClaim(managerAddress);
        uint256 claimableShares = _pullFeeRewards(
            rewardsProof,
            nodeOperatorId,
            cumulativeFeeShares
        );
        if (claimableShares == 0) {
            emit WstETHRewardsClaimed(nodeOperatorId, rewardAddress, 0);
            return;
        }
        uint256 toClaim = wstETHAmount < claimableShares
            ? wstETHAmount
            : claimableShares;
        wstETHAmount = WSTETH.wrap(_ethByShares(toClaim));
        WSTETH.transferFrom(address(this), rewardAddress, wstETHAmount);
        _bondShares[nodeOperatorId] -= wstETHAmount;
        totalBondShares -= wstETHAmount;
        emit WstETHRewardsClaimed(nodeOperatorId, rewardAddress, wstETHAmount);
    }

    /// @notice Request full reward (fee + bond) in Withdrawal NFT (unstETH) for the given node operator available for this moment.
    /// @dev reverts if amount isn't between MIN_STETH_WITHDRAWAL_AMOUNT and MAX_STETH_WITHDRAWAL_AMOUNT
    /// @param rewardsProof merkle proof of the rewards.
    /// @param nodeOperatorId id of the node operator to request rewards for.
    /// @param cumulativeFeeShares cummulative fee shares for the node operator.
    /// @param ETHAmount amount of ETH to request.
    /// @return requestIds an array of the created withdrawal request ids
    function requestRewardsETH(
        bytes32[] memory rewardsProof,
        uint256 nodeOperatorId,
        uint256 cumulativeFeeShares,
        uint256 ETHAmount
    )
        external
        onlyExistingNodeOperator(nodeOperatorId)
        returns (uint256[] memory requestIds)
    {
        (
            address managerAddress,
            address rewardAddress
        ) = _getNodeOperatorAddresses(nodeOperatorId);
        _isSenderEligibleToClaim(managerAddress);
        uint256 claimableShares = _pullFeeRewards(
            rewardsProof,
            nodeOperatorId,
            cumulativeFeeShares
        );
        if (claimableShares == 0) {
            emit ETHRewardsRequested(nodeOperatorId, rewardAddress, 0);
            return requestIds;
        }
        uint256 toClaim = ETHAmount < _ethByShares(claimableShares)
            ? _sharesByEth(ETHAmount)
            : claimableShares;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _lido().getPooledEthByShares(toClaim);
        requestIds = _withdrawalQueue().requestWithdrawals(
            amounts,
            rewardAddress
        );
        _bondShares[nodeOperatorId] -= toClaim;
        totalBondShares -= toClaim;
        emit ETHRewardsRequested(nodeOperatorId, rewardAddress, amounts[0]);
        return requestIds;
    }

    /// @notice Reports EL rewards stealing for the given node operator.
    /// @param nodeOperatorId id of the node operator to report EL rewards stealing for.
    /// @param blockNumber consensus layer block number of the proposed block with EL rewards stealing.
    /// @param amount amount of stolen EL rewards in ETH.
    function initELRewardsStealingPenalty(
        uint256 nodeOperatorId,
        uint256 blockNumber,
        uint256 amount
    )
        external
        onlyRole(EL_REWARDS_STEALING_PENALTY_INIT_ROLE)
        onlyExistingNodeOperator(nodeOperatorId)
    {
        emit ELRewardsStealingPenaltyInitiated(
            nodeOperatorId,
            blockNumber,
            amount
        );
        CSBondLock._lock(nodeOperatorId, amount);
    }

    /// @notice Releases locked bond in ETH for the given node operator.
    /// @param nodeOperatorId id of the node operator to release locked bond for.
    /// @param amount amount of ETH to release.
    function releaseLockedBondETH(
        uint256 nodeOperatorId,
        uint256 amount
    )
        external
        onlyRole(EL_REWARDS_STEALING_PENALTY_RELEASE_ROLE)
        onlyExistingNodeOperator(nodeOperatorId)
    {
        CSBondLock._reduceAmount(nodeOperatorId, amount);
        emit BondLockReleased(nodeOperatorId, amount);
    }

    /// @notice Compensates locked bond ETH for the given node operator.
    /// @param nodeOperatorId id of the node operator to compensate locked bond for.
    function compensateLockedBondETH(
        uint256 nodeOperatorId
    ) external payable onlyExistingNodeOperator(nodeOperatorId) {
        payable(LIDO_LOCATOR.elRewardsVault()).transfer(msg.value);
        CSBondLock._reduceAmount(nodeOperatorId, msg.value);
        emit BondLockCompensated(nodeOperatorId, msg.value);
    }

    /// @dev Should be called by the committee. Doesn't settle locked bond if it is in the safe frame (1 day)
    /// @notice Settles locked bond for the given node operators.
    /// @param nodeOperatorIds ids of the node operators to settle locked bond for.
    function settleLockedBondETH(
        uint256[] memory nodeOperatorIds
    ) external onlyRole(EL_REWARDS_STEALING_PENALTY_SETTLE_ROLE) {
        CSBondLock._settle(nodeOperatorIds);
    }

    /// @notice Burn all bond and request exits for all node operators' validators.
    /// @dev Called only by DAO. Have lifetime. Once expired can never be called.
    function sealAccounting() external onlyRole(SEAL_ROLE) {
        // todo: implement me
    }

    /// @notice Settles initial slashing penalty for the given node operator.
    /// @param slashingProof merkle proof of the slashing.
    /// @param nodeOperatorId id of the node operator to settle initial slashing penalty for.
    function settleInitialSlashingPenalty(
        bytes32[] memory slashingProof,
        uint256 nodeOperatorId
    ) external onlyExistingNodeOperator(nodeOperatorId) {
        // todo: implement me
    }

    /// @notice Penalize bond by burning shares of the given node operator.
    /// @param nodeOperatorId id of the node operator to penalize bond for.
    /// @param ETHAmount amount of ETH to penalize.
    function penalize(
        uint256 nodeOperatorId,
        uint256 ETHAmount
    ) public onlyRole(INSTANT_PENALIZE_BOND_ROLE) {
        _penalize(nodeOperatorId, ETHAmount);
    }

    function _penalize(
        uint256 nodeOperatorId,
        uint256 amount
    )
        internal
        override
        onlyExistingNodeOperator(nodeOperatorId)
        returns (uint256)
    {
        uint256 penaltyShares = _sharesByEth(amount);
        uint256 currentShares = getBondShares(nodeOperatorId);
        uint256 sharesToBurn = penaltyShares < currentShares
            ? penaltyShares
            : currentShares;
        _lido().transferSharesFrom(
            address(this),
            LIDO_LOCATOR.burner(),
            sharesToBurn
        );
        _bondShares[nodeOperatorId] -= sharesToBurn;
        totalBondShares -= sharesToBurn;
        uint256 penaltyEth = _ethByShares(penaltyShares);
        uint256 coveringEth = _ethByShares(sharesToBurn);
        emit BondPenalized(nodeOperatorId, penaltyEth, coveringEth);
        return penaltyEth - coveringEth;
    }

    function _lido() internal view returns (ILido) {
        return ILido(LIDO_LOCATOR.lido());
    }

    function _feeDistributor() internal view returns (ICSFeeDistributor) {
        return ICSFeeDistributor(FEE_DISTRIBUTOR);
    }

    function _withdrawalQueue() internal view returns (IWithdrawalQueue) {
        return IWithdrawalQueue(LIDO_LOCATOR.withdrawalQueue());
    }

    function _getNodeOperatorActiveKeys(
        uint256 nodeOperatorId
    ) internal view returns (uint256) {
        ICSModule.NodeOperatorInfo memory nodeOperator = CSM.getNodeOperator(
            nodeOperatorId
        );
        return
            nodeOperator.totalAddedValidators -
            nodeOperator.totalWithdrawnValidators;
    }

    function _getNodeOperatorAddresses(
        uint256 nodeOperatorId
    ) internal view returns (address, address) {
        ICSModule.NodeOperatorInfo memory nodeOperator = CSM.getNodeOperator(
            nodeOperatorId
        );
        return (nodeOperator.managerAddress, nodeOperator.rewardAddress);
    }

    function _isSenderEligibleToClaim(address rewardAddress) internal view {
        if (msg.sender != rewardAddress) {
            revert NotOwnerToClaim(msg.sender, rewardAddress);
        }
    }

    function _pullFeeRewards(
        bytes32[] memory rewardsProof,
        uint256 nodeOperatorId,
        uint256 cumulativeFeeShares
    ) internal returns (uint256 claimableShares) {
        uint256 distributed = _feeDistributor().distributeFees(
            rewardsProof,
            nodeOperatorId,
            cumulativeFeeShares
        );
        _bondShares[nodeOperatorId] += distributed;
        totalBondShares += distributed;
        (uint256 current, uint256 required) = _bondSharesSummary(
            nodeOperatorId
        );
        claimableShares = current > required ? current - required : 0;
    }

    function _bondETHSummary(
        uint256 nodeOperatorId
    ) internal view returns (uint256 current, uint256 required) {
        current = _ethByShares(getBondShares(nodeOperatorId));
        required =
            _getBondAmountByKeysCount(
                _getNodeOperatorActiveKeys(nodeOperatorId),
                getBondMultiplier(nodeOperatorId)
            ) +
            getActualLockedBondETH(nodeOperatorId);
    }

    function _bondSharesSummary(
        uint256 nodeOperatorId
    ) internal view returns (uint256 current, uint256 required) {
        current = getBondShares(nodeOperatorId);
        required =
            _sharesByEth(
                _getBondAmountByKeysCount(
                    _getNodeOperatorActiveKeys(nodeOperatorId),
                    getBondMultiplier(nodeOperatorId)
                )
            ) +
            _sharesByEth(getActualLockedBondETH(nodeOperatorId));
    }

    function _sharesByEth(uint256 ethAmount) internal view returns (uint256) {
        return _lido().getSharesByPooledEth(ethAmount);
    }

    function _ethByShares(uint256 shares) internal view returns (uint256) {
        return _lido().getPooledEthByShares(shares);
    }

    modifier onlyExistingNodeOperator(uint256 nodeOperatorId) {
        require(
            nodeOperatorId < CSM.getNodeOperatorsCount(),
            "node operator does not exist"
        );
        _;
    }
}
