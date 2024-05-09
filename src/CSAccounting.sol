// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

import { PausableUntil } from "./lib/utils/PausableUntil.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { CSBondCore } from "./abstract/CSBondCore.sol";
import { CSBondCurve } from "./abstract/CSBondCurve.sol";
import { CSBondLock } from "./abstract/CSBondLock.sol";

import { ICSModule } from "./interfaces/ICSModule.sol";
import { ICSFeeDistributor } from "./interfaces/ICSFeeDistributor.sol";
import { AssetRecoverer } from "./abstract/AssetRecoverer.sol";
import { AssetRecovererLib } from "./lib/AssetRecovererLib.sol";

/// @author vgorkavenko
contract CSAccounting is
    CSBondCore,
    CSBondCurve,
    CSBondLock,
    PausableUntil,
    AccessControlEnumerableUpgradeable,
    AssetRecoverer
{
    /// @notice This contract stores the Node Operators' bonds in the form of stETH shares,
    ///         so it should be considered in the recovery process
    using SafeERC20 for IERC20;

    struct PermitInput {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE"); // 0x139c2898040ef16910dc9f44dc697df79363da767d8bc92f2e310312b816e46d
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE"); // 0x2fc10cc8ae19568712f7a176fb4978616a610650813c9d05326c34abb62749c7
    bytes32 public constant ACCOUNTING_MANAGER_ROLE =
        keccak256("ACCOUNTING_MANAGER_ROLE"); // 0x40579467dba486691cc62fd8536d22c6d4dc9cdc7bc716ef2518422aa554c098
    bytes32 public constant ADD_BOND_CURVE_ROLE =
        keccak256("ADD_BOND_CURVE_ROLE"); // 0xd2becf7ae0eafe4edadee8d89582631d5922eccd2ac7b3fdf4afbef7595f4512
    bytes32 public constant SET_DEFAULT_BOND_CURVE_ROLE =
        keccak256("SET_DEFAULT_BOND_CURVE_ROLE"); // 0xb96689e168af25a79300d9b242da3d0653f6030e5c7a93192007dbd3f520875b
    bytes32 public constant SET_BOND_CURVE_ROLE =
        keccak256("SET_BOND_CURVE_ROLE"); // 0x645c9e6d2a86805cb5a28b1e4751c0dab493df7cf935070ce405489ba1a7bf72
    bytes32 public constant RESET_BOND_CURVE_ROLE =
        keccak256("RESET_BOND_CURVE_ROLE"); // 0xb5dffea014b759c493d63b1edaceb942631d6468998125e1b4fe427c99082134
    bytes32 public constant RECOVERER_ROLE = keccak256("RECOVERER_ROLE"); // 0xb3e25b5404b87e5a838579cb5d7481d61ad96ee284d38ec1e97c07ba64e7f6fc

    ICSModule public immutable CSM;
    ICSFeeDistributor public feeDistributor;
    address public chargeRecipient;

    event BondLockCompensated(uint256 indexed nodeOperatorId, uint256 amount);
    event ChargeRecipientSet(address chargeRecipient);

    error AlreadyInitialized();
    error InvalidSender();
    error SenderIsNotCSM();

    modifier onlyCSM() {
        if (msg.sender != address(CSM)) {
            revert SenderIsNotCSM();
        }
        _;
    }

    /// @param lidoLocator Lido locator contract address
    /// @param communityStakingModule Community Staking Module contract address
    constructor(
        address lidoLocator,
        address communityStakingModule
    ) CSBondCore(lidoLocator) {
        if (communityStakingModule == address(0)) {
            revert ZeroAddress("communityStakingModule");
        }
        CSM = ICSModule(communityStakingModule);
    }

    /// @param bondCurve Initial bond curve
    /// @param admin Admin role member address
    /// @param bondLockRetentionPeriod Retention period for locked bond in seconds
    /// @param _chargeRecipient Recipient of the charge penalty type
    /// @param _feeDistributor Fee Distributor contract address
    function initialize(
        uint256[] memory bondCurve,
        address admin,
        address _feeDistributor,
        uint256 bondLockRetentionPeriod,
        address _chargeRecipient
    ) external initializer {
        __AccessControlEnumerable_init();
        __CSBondCurve_init(bondCurve);
        __CSBondLock_init(bondLockRetentionPeriod);

        if (admin == address(0)) {
            revert ZeroAddress("admin");
        }
        if (_feeDistributor == address(0)) {
            revert ZeroAddress("feeDistributor");
        }
        if (_chargeRecipient == address(0)) {
            revert ZeroAddress("chargeRecipient");
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SET_BOND_CURVE_ROLE, address(CSM));
        _grantRole(RESET_BOND_CURVE_ROLE, address(CSM));

        feeDistributor = ICSFeeDistributor(_feeDistributor);

        chargeRecipient = _chargeRecipient;
        emit ChargeRecipientSet(_chargeRecipient);

        LIDO.approve(address(WSTETH), type(uint256).max);
        LIDO.approve(address(WITHDRAWAL_QUEUE), type(uint256).max);
        LIDO.approve(address(BURNER), type(uint256).max);
    }

    /// @notice Resume accounting
    function resume() external onlyRole(RESUME_ROLE) {
        _resume();
    }

    /// @notice Pause accounting for `duration` seconds
    /// @dev Must be called together with `CSModule.pauseFor`
    /// @param duration Duration of the pause in seconds
    function pauseFor(uint256 duration) external onlyRole(PAUSE_ROLE) {
        _pauseFor(duration);
    }

    /// @notice Set charge recipient address
    /// @param _chargeRecipient Charge recipient address
    function setChargeRecipient(
        address _chargeRecipient
    ) external onlyRole(ACCOUNTING_MANAGER_ROLE) {
        if (_chargeRecipient == address(0)) {
            revert ZeroAddress("chargeRecipient");
        }
        chargeRecipient = _chargeRecipient;
        emit ChargeRecipientSet(_chargeRecipient);
    }

    /// @notice Set bond lock retention period
    /// @param retention Period in seconds to retain bond lock
    function setLockedBondRetentionPeriod(
        uint256 retention
    ) external onlyRole(ACCOUNTING_MANAGER_ROLE) {
        CSBondLock._setBondLockRetentionPeriod(retention);
    }

    /// @notice Add a new bond curve
    /// @param bondCurve Bond curve definition to add
    function addBondCurve(
        uint256[] memory bondCurve
    ) external onlyRole(ADD_BOND_CURVE_ROLE) returns (uint256) {
        return CSBondCurve._addBondCurve(bondCurve);
    }

    /// @notice Set default bond curve
    /// @param curveId ID of the bond curve to set as default
    function setDefaultBondCurve(
        uint256 curveId
    ) external onlyRole(SET_DEFAULT_BOND_CURVE_ROLE) {
        CSBondCurve._setDefaultBondCurve(curveId);
    }

    /// @notice Set the bond curve for the given Node Operator
    /// @param nodeOperatorId ID of the Node Operator
    /// @param curveId ID of the bond curve to set
    function setBondCurve(
        uint256 nodeOperatorId,
        uint256 curveId
    ) external onlyRole(SET_BOND_CURVE_ROLE) {
        CSBondCurve._setBondCurve(nodeOperatorId, curveId);
    }

    /// @notice Reset bond curve to the default one for the given Node Operator
    /// @param nodeOperatorId ID of the Node Operator
    function resetBondCurve(
        uint256 nodeOperatorId
    ) external onlyRole(RESET_BOND_CURVE_ROLE) {
        CSBondCurve._resetBondCurve(nodeOperatorId);
    }

    /// @notice Stake user's ETH with Lido and deposit stETH to the bond
    /// @dev Called by CSM exclusively
    /// @param from Address to stake ETH and deposit stETH from
    /// @param nodeOperatorId ID of the Node Operator
    /// @return shares stETH shares amount
    function depositETH(
        address from,
        uint256 nodeOperatorId
    ) external payable whenResumed onlyCSM returns (uint256 shares) {
        shares = CSBondCore._depositETH(from, nodeOperatorId);
    }

    /// @notice Deposit user's stETH to the bond for the given Node Operator
    /// @dev Called by CSM exclusively
    /// @param from Address to deposit stETH from
    /// @param nodeOperatorId ID of the Node Operator
    /// @param stETHAmount Amount of stETH to deposit
    /// @param permit stETH permit for the contract
    /// @return shares stETH shares amount
    function depositStETH(
        address from,
        uint256 nodeOperatorId,
        uint256 stETHAmount,
        PermitInput calldata permit
    ) external whenResumed onlyCSM returns (uint256 shares) {
        // preventing revert for already used permit or avoid permit usage in case of value == 0
        if (
            permit.value > 0 &&
            LIDO.allowance(from, address(this)) < permit.value
        ) {
            // solhint-disable-next-line func-named-parameters
            LIDO.permit(
                from,
                address(this),
                permit.value,
                permit.deadline,
                permit.v,
                permit.r,
                permit.s
            );
        }
        // TODO: Return is unused
        shares = CSBondCore._depositStETH(from, nodeOperatorId, stETHAmount);
    }

    /// @notice Unwrap the user's wstETH and deposit stETH to the bond for the given Node Operator
    /// @dev Called by CSM exclusively
    /// @param from Address to unwrap wstETH from
    /// @param nodeOperatorId ID of the Node Operator
    /// @param wstETHAmount Amount of wstETH to deposit
    /// @param permit wstETH permit for the contract
    /// @return shares stETH shares amount
    function depositWstETH(
        address from,
        uint256 nodeOperatorId,
        uint256 wstETHAmount,
        PermitInput calldata permit
    ) external whenResumed onlyCSM returns (uint256 shares) {
        // preventing revert for already used permit or avoid permit usage in case of value == 0
        if (
            permit.value > 0 &&
            WSTETH.allowance(from, address(this)) < permit.value
        ) {
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
        // TODO: Return is unused
        shares = CSBondCore._depositWstETH(from, nodeOperatorId, wstETHAmount);
    }

    /// @notice Claim full reward (fee + bond) in stETH for the given Node Operator with desirable value.
    ///         `rewardsProof` and `cumulativeFeeShares` might be empty in order to claim only excess bond
    /// @dev Called by CSM exclusively
    /// @param nodeOperatorId ID of the Node Operator
    /// @param stETHAmount Amount of stETH to claim
    /// @param cumulativeFeeShares Cumulative fee stETH shares for the Node Operator
    /// @param rewardsProof Merkle proof of the rewards
    function claimRewardsStETH(
        uint256 nodeOperatorId,
        uint256 stETHAmount,
        uint256 cumulativeFeeShares,
        bytes32[] memory rewardsProof
    ) external whenResumed onlyCSM {
        if (rewardsProof.length != 0) {
            _pullFeeRewards(nodeOperatorId, cumulativeFeeShares, rewardsProof);
        }
        if (stETHAmount == 0) return;
        CSBondCore._claimStETH(
            nodeOperatorId,
            _getExcessBondShares(
                nodeOperatorId,
                CSM.getNodeOperatorNonWithdrawnKeys(nodeOperatorId)
            ),
            stETHAmount,
            CSM.getNodeOperatorRewardAddress(nodeOperatorId)
        );
    }

    /// @notice Claim full reward (fee + bond) in wstETH for the given Node Operator available for this moment.
    ///         `rewardsProof` and `cumulativeFeeShares` might be empty in order to claim only excess bond
    /// @dev Called by CSM exclusively
    /// @param nodeOperatorId ID of the Node Operator
    /// @param wstETHAmount Amount of wstETH to claim
    /// @param cumulativeFeeShares Cumulative fee stETH shares for the Node Operator
    /// @param rewardsProof Merkle proof of the rewards
    function claimRewardsWstETH(
        uint256 nodeOperatorId,
        uint256 wstETHAmount,
        uint256 cumulativeFeeShares,
        bytes32[] memory rewardsProof
    ) external whenResumed onlyCSM {
        if (rewardsProof.length != 0) {
            _pullFeeRewards(nodeOperatorId, cumulativeFeeShares, rewardsProof);
        }
        CSBondCore._claimWstETH(
            nodeOperatorId,
            _getExcessBondShares(
                nodeOperatorId,
                CSM.getNodeOperatorNonWithdrawnKeys(nodeOperatorId)
            ),
            wstETHAmount,
            CSM.getNodeOperatorRewardAddress(nodeOperatorId)
        );
    }

    /// @notice Request full reward (fee + bond) in Withdrawal NFT (unstETH) for the given Node Operator available for this moment.
    ///         `rewardsProof` and `cumulativeFeeShares` might be empty in order to claim only excess bond
    /// @dev Reverts if amount isn't between `MIN_STETH_WITHDRAWAL_AMOUNT` and `MAX_STETH_WITHDRAWAL_AMOUNT`
    /// @dev Called by CSM exclusively
    /// @param nodeOperatorId ID of the Node Operator
    /// @param ethAmount Amount of ETH to request
    /// @param cumulativeFeeShares Cumulative fee stETH shares for the Node Operator
    /// @param rewardsProof Merkle proof of the rewards
    function requestRewardsETH(
        uint256 nodeOperatorId,
        uint256 ethAmount,
        uint256 cumulativeFeeShares,
        bytes32[] memory rewardsProof
    ) external whenResumed onlyCSM {
        if (rewardsProof.length != 0) {
            _pullFeeRewards(nodeOperatorId, cumulativeFeeShares, rewardsProof);
        }
        if (ethAmount == 0) return;
        CSBondCore._requestETH(
            nodeOperatorId,
            _getExcessBondShares(
                nodeOperatorId,
                CSM.getNodeOperatorNonWithdrawnKeys(nodeOperatorId)
            ),
            ethAmount,
            CSM.getNodeOperatorRewardAddress(nodeOperatorId)
        );
    }

    /// @notice Lock bond in ETH for the given Node Operator
    /// @dev Called by CSM exclusively
    /// @param nodeOperatorId ID of the Node Operator
    /// @param amount Amount to lock in ETH (stETH)
    function lockBondETH(
        uint256 nodeOperatorId,
        uint256 amount
    ) external onlyCSM {
        CSBondLock._lock(nodeOperatorId, amount);
    }

    /// @notice Release locked bond in ETH for the given Node Operator
    /// @dev Called by CSM exclusively
    /// @param nodeOperatorId ID of the Node Operator
    /// @param amount Amount to release in ETH (stETH)
    function releaseLockedBondETH(
        uint256 nodeOperatorId,
        uint256 amount
    ) external onlyCSM {
        CSBondLock._reduceAmount(nodeOperatorId, amount);
    }

    /// @notice Compensate locked bond ETH for the given Node Operator
    //// @dev Called by CSM exclusively
    /// @param nodeOperatorId ID of the Node Operator
    function compensateLockedBondETH(
        uint256 nodeOperatorId
    ) external payable onlyCSM {
        payable(LIDO_LOCATOR.elRewardsVault()).transfer(msg.value);
        CSBondLock._reduceAmount(nodeOperatorId, msg.value);
        emit BondLockCompensated(nodeOperatorId, msg.value);
    }

    /// @notice Settle locked bond ETH for the given Node Operator
    /// @dev Called by CSM exclusively
    /// @param nodeOperatorId ID of the Node Operator
    function settleLockedBondETH(
        uint256 nodeOperatorId
    ) external onlyCSM returns (uint256 lockedAmount) {
        lockedAmount = CSBondLock.getActualLockedBond(nodeOperatorId);
        if (lockedAmount > 0) {
            CSBondCore._burn(nodeOperatorId, lockedAmount);
        }
        // reduce all locked bond even if bond isn't covered lock fully
        CSBondLock._remove(nodeOperatorId);
    }

    /// @notice Penalize bond by burning stETH shares of the given Node Operator
    /// @dev Called by CSM exclusively
    /// @param nodeOperatorId ID of the Node Operator
    /// @param amount Amount to penalize in ETH (stETH)
    function penalize(uint256 nodeOperatorId, uint256 amount) external onlyCSM {
        CSBondCore._burn(nodeOperatorId, amount);
    }

    /// @notice Charge fee from bond by transferring stETH shares of the given Node Operator to the charge recipient
    /// @dev Called by CSM exclusively
    /// @param nodeOperatorId ID of the Node Operator
    /// @param amount Amount to charge in ETH (stETH)
    function chargeFee(
        uint256 nodeOperatorId,
        uint256 amount
    ) external onlyCSM {
        CSBondCore._charge(nodeOperatorId, amount, chargeRecipient);
    }

    /// @notice Recover ERC20 tokens from the contract
    /// @param token Address of the ERC20 token to recover
    /// @param amount Amount of the ERC20 token to recover
    function recoverERC20(address token, uint256 amount) external override {
        _onlyRecoverer();
        if (token == address(LIDO)) {
            revert NotAllowedToRecover();
        }
        AssetRecovererLib.recoverERC20(token, amount);
    }

    /// @notice Recover all stETH shares from the contract
    /// @dev Accounts for the bond funds stored during recovery
    function recoverStETHShares() external {
        _onlyRecoverer();
        uint256 shares = LIDO.sharesOf(address(this)) - totalBondShares();
        AssetRecovererLib.recoverStETHShares(address(LIDO), shares);
    }

    /// @notice Get current and required bond amounts in ETH (stETH) for the given Node Operator
    /// @dev To calculate excess bond amount subtract `required` from `current` value.
    ///      To calculate missed bond amount subtract `current` from `required` value
    /// @param nodeOperatorId ID of the Node Operator
    /// @return current Current bond amount in ETH
    /// @return required Required bond amount in ETH
    function getBondSummary(
        uint256 nodeOperatorId
    ) public view returns (uint256 current, uint256 required) {
        return
            _getBondSummary(
                nodeOperatorId,
                CSM.getNodeOperatorNonWithdrawnKeys(nodeOperatorId)
            );
    }

    /// @notice Get current and required bond amounts in stETH shares for the given Node Operator
    /// @dev To calculate excess bond amount subtract `required` from `current` value.
    ///      To calculate missed bond amount subtract `current` from `required` value
    /// @param nodeOperatorId ID of the Node Operator
    /// @return current Current bond amount in stETH shares
    /// @return required Required bond amount in stETH shares
    function getBondSummaryShares(
        uint256 nodeOperatorId
    ) public view returns (uint256 current, uint256 required) {
        return
            _getBondSummaryShares(
                nodeOperatorId,
                CSM.getNodeOperatorNonWithdrawnKeys(nodeOperatorId)
            );
    }

    /// @notice Get the number of the unbonded keys
    /// @param nodeOperatorId ID of the Node Operator
    /// @return unbonded Unbonded keys count
    function getUnbondedKeysCount(
        uint256 nodeOperatorId
    ) public view returns (uint256) {
        return
            _getUnbondedKeysCount({
                nodeOperatorId: nodeOperatorId,
                accountLockedBond: true
            });
    }

    /// @notice Get the number of the unbonded keys to be ejected using a forcedTargetLimit
    /// @param nodeOperatorId ID of the Node Operator
    /// @return unbonded Unbonded keys count
    function getUnbondedKeysCountToEject(
        uint256 nodeOperatorId
    ) public view returns (uint256) {
        return
            _getUnbondedKeysCount({
                nodeOperatorId: nodeOperatorId,
                accountLockedBond: false
            });
    }

    /// @notice Get the required bond in ETH (inc. missed and excess) for the given Node Operator to upload new deposit data
    /// @param nodeOperatorId ID of the Node Operator
    /// @param additionalKeys Number of new keys to add
    /// @return required Required bond amount in ETH
    function getRequiredBondForNextKeys(
        uint256 nodeOperatorId,
        uint256 additionalKeys
    ) public view returns (uint256) {
        uint256 nonWithdrawnKeys = CSM.getNodeOperatorNonWithdrawnKeys(
            nodeOperatorId
        );
        (uint256 current, uint256 required) = _getBondSummary(
            nodeOperatorId,
            nonWithdrawnKeys
        );
        CSBondCurve.BondCurve memory bondCurve = CSBondCurve.getBondCurve(
            nodeOperatorId
        );
        uint256 requiredForNextKeys = CSBondCurve.getBondAmountByKeysCount(
            nonWithdrawnKeys + additionalKeys,
            bondCurve
        ) - CSBondCurve.getBondAmountByKeysCount(nonWithdrawnKeys, bondCurve);

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

    /// @notice Get the bond amount in wstETH required for the `keysCount` keys using the default bond curve
    /// @param keysCount Keys count to calculate the required bond amount
    function getBondAmountByKeysCountWstETH(
        uint256 keysCount
    ) public view returns (uint256) {
        return
            WSTETH.getWstETHByStETH(
                CSBondCurve.getBondAmountByKeysCount(keysCount)
            );
    }

    /// @notice Get the bond amount in wstETH required for the `keysCount` keys using the custom bond curve
    /// @param keysCount Keys count to calculate the required bond amount
    /// @param curve Bond curve definition.
    ///              Use CSBondCurve.getBondCurve(id) method to get the definition for the exiting curve
    function getBondAmountByKeysCountWstETH(
        uint256 keysCount,
        BondCurve memory curve
    ) public view returns (uint256) {
        return
            WSTETH.getWstETHByStETH(
                CSBondCurve.getBondAmountByKeysCount(keysCount, curve)
            );
    }

    /// @notice Get the required bond in wstETH (inc. missed and excess) for the given Node Operator to upload new keys
    /// @param nodeOperatorId ID of the Node Operator
    /// @param additionalKeys Number of new keys to add
    /// @return required Required bond in wstETH
    function getRequiredBondForNextKeysWstETH(
        uint256 nodeOperatorId,
        uint256 additionalKeys
    ) public view returns (uint256) {
        return
            WSTETH.getWstETHByStETH(
                getRequiredBondForNextKeys(nodeOperatorId, additionalKeys)
            );
    }

    function _pullFeeRewards(
        uint256 nodeOperatorId,
        uint256 cumulativeFeeShares,
        bytes32[] memory rewardsProof
    ) internal {
        uint256 distributed = feeDistributor.distributeFees(
            nodeOperatorId,
            cumulativeFeeShares,
            rewardsProof
        );
        _increaseBond(nodeOperatorId, distributed);
    }

    function _getBondSummary(
        uint256 nodeOperatorId,
        uint256 nonWithdrawnKeys
    ) internal view returns (uint256 current, uint256 required) {
        current = CSBondCore.getBond(nodeOperatorId);
        required =
            CSBondCurve.getBondAmountByKeysCount(
                nonWithdrawnKeys,
                CSBondCurve.getBondCurve(nodeOperatorId)
            ) +
            CSBondLock.getActualLockedBond(nodeOperatorId);
    }

    function _getBondSummaryShares(
        uint256 nodeOperatorId,
        uint256 nonWithdrawnKeys
    ) internal view returns (uint256 current, uint256 required) {
        current = CSBondCore.getBondShares(nodeOperatorId);
        required = _sharesByEth(
            CSBondCurve.getBondAmountByKeysCount(
                nonWithdrawnKeys,
                CSBondCurve.getBondCurve(nodeOperatorId)
            ) + CSBondLock.getActualLockedBond(nodeOperatorId)
        );
    }

    /// @dev Unbonded stands for the amount of the keys not fully covered with the bond
    function _getUnbondedKeysCount(
        uint256 nodeOperatorId,
        bool accountLockedBond
    ) internal view returns (uint256) {
        uint256 nonWithdrawnKeys = CSM.getNodeOperatorNonWithdrawnKeys(
            nodeOperatorId
        );
        /// 10 wei added to account for possible stETH rounding errors
        /// https://github.com/lidofinance/lido-dao/issues/442#issuecomment-1182264205.
        /// Should be sufficient for ~ 40 years
        uint256 currentBond = CSBondCore._ethByShares(
            getBondShares(nodeOperatorId)
        ) + 10 wei;
        if (accountLockedBond) {
            uint256 lockedBond = CSBondLock.getActualLockedBond(nodeOperatorId);
            if (currentBond <= lockedBond) return nonWithdrawnKeys;
            currentBond -= lockedBond;
        }
        CSBondCurve.BondCurve memory bondCurve = CSBondCurve.getBondCurve(
            nodeOperatorId
        );
        uint256 bondedKeys = CSBondCurve.getKeysCountByBondAmount(
            currentBond,
            bondCurve
        );
        if (bondedKeys >= nonWithdrawnKeys) return 0;
        return nonWithdrawnKeys - bondedKeys;
    }

    function _getExcessBondShares(
        uint256 nodeOperatorId,
        uint256 nonWithdrawnKeys
    ) internal view returns (uint256) {
        (uint256 current, uint256 required) = _getBondSummaryShares(
            nodeOperatorId,
            nonWithdrawnKeys
        );
        return current > required ? current - required : 0;
    }

    function _onlyRecoverer() internal view override {
        _checkRole(RECOVERER_ROLE);
    }
}
