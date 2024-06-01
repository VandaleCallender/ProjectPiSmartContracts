// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.20;

import {Base} from "./Base.sol";
import {IWithdrawer} from "../interface/IWithdrawer.sol";
import {MinipoolStatus} from "../types/MinipoolStatus.sol";
import {MultisigManager} from "./MultisigManager.sol";
import {Oracle} from "./Oracle.sol";
import {ProtocolDAO} from "./ProtocolDAO.sol";
import {Staking} from "./Staking.sol";
import {Storage} from "./Storage.sol";
import {TokenstPLS} from "./tokens/TokenstPLS.sol";
import {Vault} from "./Vault.sol";
import {FixedPointMathLib} from "./FixedPointMathLib.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {SafeTransferLib} from "./SafeTransferLib.sol";
import {NodeIDGenerator} from "./NodeIDGenerator.sol";
import {EarlyStaking} from "./EarlyStaking.sol";
import {IDepositContract} from "../interface/IDepositContract.sol";
import {ClaimProtocolDAO} from "./ClaimProtocolDAO.sol";
import "./ValidatorRegistration.sol";


/*
	Data Storage Schema
	NodeIDAddress are 20 bytes so can use Solidity 'address' as storage type for them
	NodeIDAddress can be added, but never removed. If a nodeIDAddress submits another validation request,
		it will overwrite the old one (only allowed for specific statuses).

	MinipoolManager.TotalPLSLiquidStakerAmt = total for all active minipools (Prelaunch/Launched/Staking)

	minipool.count = Starts at 0 and counts up by 1 after a node is added.

	minipool.index<nodeID> = <index> of nodeIDAddress
	minipool.item<index>.nodeID = nodeIDAddress used as primary key (NOT the ascii "Node-123..." but the actual 20 bytes)
	minipool.item<index>.status = enum
	minipool.item<index>.duration = requested validation duration in seconds (performed as 14 day cycles)
	minipool.item<index>.delegationFee = node operator specified fee (must be between 0 and 1 ether) 2% is 0.2 ether
	minipool.item<index>.owner = owner address
	minipool.item<index>.multisigAddr = which Rialto multisig is assigned to manage this validation
	minipool.item<index>.plsNodeOpAmt = pls deposited by node operator (for this cycle)
	minipool.item<index>.plsNodeOpInitialAmt = pls deposited by node operator for the **first** validation cycle
	minipool.item<index>.plsLiquidStakerAmt = pls deposited by users and assigned to this nodeIDAddress
	minipool.item<index>.creationTime = actual time the minipool was created

	// Submitted by the Rialto oracle
	minipool.item<index>.initialStartTime = actual time the **first** validation cycle was started
	minipool.item<index>.startTime = actual time validation was started
	minipool.item<index>.endTime = actual time validation was finished
	minipool.item<index>.plsTotalRewardAmt = Actual total pls rewards paid by avalanchego to the TSS P-chain addr
	minipool.item<index>.errorCode = bytes32 that encodes an error msg if something went wrong during launch of minipool

	// Calculated in recordStakingEnd()
	minipool.item<index>.plsNodeOpRewardAmt
	minipool.item<index>.plsLiquidStakerRewardAmt
	minipool.item<index>.ppySlashAmt = amt of ppy bond that was slashed if necessary (expected reward amt = plsLiquidStakerAmt * x%/yr / ppyPriceInPls)
*/

	/// @title Minipool creation and management
	contract MinipoolManager is Base, ReentrancyGuard, IWithdrawer {
	using FixedPointMathLib for uint256;
	using SafeTransferLib for address;

    NodeIDGenerator nodeIDGenerator;
	ValidatorRegistration private validatorRegistration;

	error CancellationTooEarly();
	error DurationOutOfBounds();
	error DelegationFeeOutOfBounds();
	error InsufficientPPYCollateralization();
	error InsufficientPLSForMinipoolCreation();
	error InvalidAmount();
	error InvalidPLSAssignmentRequest();
	error InvalidStartTime();
	error InvalidEndTime();
	error InvalidMultisigAddress();
	error InvalidNodeID();
	error InvalidStateTransition();
	error MinipoolNotFound();
	error MinipoolDurationExceeded();
	error NegativeCycleDuration();
	error OnlyOwner();
	error WithdrawAmountTooLarge();
	error WithdrawForDelegationDisabled();

    event Received(address sender, uint256 amount);
	event PPYSlashed(address indexed nodeID, uint256 ppy);
	event MinipoolStatusChanged(address indexed nodeID, MinipoolStatus indexed status);
	event DepositFromRewards(uint256 depositAmount, address depositor);

	// Event declaration
	event RewardsWithdrawn(address indexed operator, uint256 rewardAmount);

	/// @dev Not used for storage, just for returning data from view functions
struct Minipool {
    int256 index;
    address nodeID;
    uint256 status;
    uint256 duration;
    uint256 delegationFee;
    address owner;
    address multisigAddr;
    uint256 plsNodeOpAmt;
    uint256 plsNodeOpInitialAmt;
    uint256 plsLiquidStakerAmt;
    // Submitted by the Rialto Oracle
    uint256 creationTime;
    uint256 initialStartTime;
    uint256 startTime;
    uint256 endTime;
    uint256 plsTotalRewardAmt;
    bytes32 errorCode;
    // Calculated in recordStakingEnd
    uint256 ppySlashAmt;
    uint256 plsNodeOpRewardAmt;
    uint256 plsLiquidStakerRewardAmt;
    // Fields for managing rewards dynamically
    uint256 lastRewardTime;  // Time of the last reward withdrawal
    uint256 plsRewardsAmt;  // Current available rewards yet to be withdrawn
    uint256 rewardsWithdrawn;  // Cumulative amount of rewards withdrawn
    // Adding fields for partial rewards management
    uint256 plsNodeOpPartialRewards;  // Partial rewards for node operators
    uint256 plsLiquidStakerPartialRewards;  // Partial rewards for liquid stakers
	}

	uint256 public minStakingDuration;
	uint32 public rewardsCycleEnd;
    bool private locked = false;


	constructor(Storage _storageAddress, address _nodeIDGeneratorAddress, address validatorRegistrationAddress) 
        Base(_storageAddress) 
    {
        nodeIDGenerator = NodeIDGenerator(_nodeIDGeneratorAddress);
    	validatorRegistration = ValidatorRegistration(validatorRegistrationAddress);
    }

	function receiveWithdrawalPLS() external payable {}
  	
	receive() external payable {
        emit Received(msg.sender, msg.value);
    }

	function safeCastTo32(uint256 value) internal pure returns (uint32) {
    require(value <= type(uint32).max, "Value exceeds uint32 limits");
    return uint32(value);
	}

	//
	// GUARDS
	//

	/// @notice Look up minipool owner by minipool index
	/// @param minipoolIndex A valid minipool index
	/// @return minipool owner or revert
	function onlyOwner(int256 minipoolIndex) private view returns (address) {
		address owner = getAddress(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".owner")));
		if (msg.sender != owner) {
			revert OnlyOwner();
		}
		return owner;
	}

	/// @notice Verifies the multisig trying to use the given node ID is valid
	/// @dev Look up multisig index by minipool nodeID
	/// @param nodeID 20-byte PulseChain node ID
	/// @return minipool index or revert
	function onlyValidMultisig(address nodeID) private view returns (int256) {
		int256 minipoolIndex = requireValidMinipool(nodeID);

		address assignedMultisig = getAddress(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".multisigAddr")));
		if (msg.sender != assignedMultisig) {
			revert InvalidMultisigAddress();
		}
		return minipoolIndex;
	}

	/// @notice Look up minipool index by minipool nodeID
	/// @param nodeID 20-byte node ID
	/// @return minipool index or revert
	function requireValidMinipool(address nodeID) private view returns (int256) {
		int256 minipoolIndex = getIndexOf(nodeID);
		if (minipoolIndex == -1) {
			revert MinipoolNotFound();
		}

		return minipoolIndex;
	}

	/// @notice Ensure a minipool is allowed to move to the "to" state
	/// @param minipoolIndex A valid minipool index
	/// @param to New status
	function requireValidStateTransition(int256 minipoolIndex, MinipoolStatus to) private view {
		bytes32 statusKey = keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".status"));
		MinipoolStatus currentStatus = MinipoolStatus(getUint(statusKey));
		bool isValid;

		if (currentStatus == MinipoolStatus.Prelaunch) {
			isValid = (to == MinipoolStatus.Launched || to == MinipoolStatus.Canceled);
		} else if (currentStatus == MinipoolStatus.Launched) {
			isValid = (to == MinipoolStatus.Staking || to == MinipoolStatus.Error);
		} else if (currentStatus == MinipoolStatus.Staking) {
			isValid = (to == MinipoolStatus.Withdrawable);
		} else if (currentStatus == MinipoolStatus.Withdrawable || currentStatus == MinipoolStatus.Error) {
			isValid = (to == MinipoolStatus.Finished);
		} else if (currentStatus == MinipoolStatus.Finished || currentStatus == MinipoolStatus.Canceled) {
			// Once a node is finished/canceled, if they re-validate they go back to beginning state
			isValid = (to == MinipoolStatus.Prelaunch);
		} else {
			isValid = false;
		}

		if (!isValid) {
			revert InvalidStateTransition();
		}
	}

	//
	// OWNER FUNCTIONS
	//

	/// @notice Accept PLS deposit from node operator to create a Minipool. Node Operator must be staking PPY. Open to public.
	/// @param nodeID 20-byte PulseChain node ID
	/// @param duration Requested validation period in seconds
	/// @param delegationFee Percentage delegation fee in units of ether (2% is 20_000)
	/// @param plsAssignmentRequest Amount of requested PLS to be matched for this Minipool
	function createMinipool(address nodeID, uint256 duration, uint256 delegationFee, uint256 plsAssignmentRequest) external payable whenNotPaused {
    if (nodeID == address(0)) {
        revert("InvalidNodeID");
    }

    ProtocolDAO dao = ProtocolDAO(getContractAddress("ProtocolDAO"));
    (bool eligibleForReducedStaking, uint256 requiredStakingAmount) = canUseReducedStakingAmount(msg.sender);

    if (msg.value < requiredStakingAmount) {
        revert("Node operator staking amount does not meet the required staking amount.");
    }

   if (eligibleForReducedStaking) {
    if (msg.value < 8_000_000 ether) { // Ensure early staker minimum contribution
        revert("Node operator staking amount does not meet the required early staker amount.");
    }
    // Ensure the combined contribution meets the minimum requirement and plsAssignmentRequest does not exceed the max allowed
    if (msg.value + plsAssignmentRequest != dao.getMinipoolMinPLSStakingAmt() || 
        plsAssignmentRequest != dao.getMinipoolMaxPLSAssignment()) {
        revert("Combined staking amount does not meet the minimum required or plsAssignmentRequest does not match the max assignment for early stakers.");
    }
	} else {
    // Logic for non-early stakers
    if (msg.value != plsAssignmentRequest ||
        plsAssignmentRequest > dao.getMinipoolMaxPLSAssignment() ||
        plsAssignmentRequest < dao.getMinipoolMinPLSAssignment()) {
        revert("InvalidPLSAssignmentRequest.");
    }
    if (msg.value + plsAssignmentRequest < dao.getMinipoolMinPLSStakingAmt()) {
        revert("InsufficientPLSForMinipoolCreation");
    }
	}

    if (duration < dao.getMinipoolMinDuration() || duration > dao.getMinipoolMaxDuration()) {
        revert("DurationOutOfBounds");
    }

    if (delegationFee < 20_000 || delegationFee > 1_000_000) {
        revert("DelegationFeeOutOfBounds");
    }

    Staking staking = Staking(getContractAddress("Staking"));
    staking.increasePLSStake(msg.sender, msg.value);
    staking.increasePLSAssigned(msg.sender, plsAssignmentRequest);

    if (staking.getRewardsStartTime(msg.sender) == 0) {
        staking.setRewardsStartTime(msg.sender, block.timestamp);
    }

    uint256 ratio = staking.getCollateralizationRatio(msg.sender);
    if (ratio < dao.getMinCollateralizationRatio()) {
        revert InsufficientPPYCollateralization();
    }

    MultisigManager multisigManager = MultisigManager(getContractAddress("MultisigManager"));
    address multisig = multisigManager.requireNextActiveMultisig();

    int256 minipoolIndex = handleMinipoolRecord(nodeID);

    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".status")), uint256(MinipoolStatus.Prelaunch));
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".duration")), duration);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".delegationFee")), delegationFee);
    setAddress(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".owner")), msg.sender);
    setAddress(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".multisigAddr")), multisig);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpInitialAmt")), msg.value);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpAmt")), msg.value);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsLiquidStakerAmt")), plsAssignmentRequest);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".creationTime")), block.timestamp);

    emit MinipoolStatusChanged(nodeID, MinipoolStatus.Prelaunch);

    Vault vault = Vault(getContractAddress("Vault"));
    vault.depositPLS{value: msg.value}();
	}


	function handleMinipoolRecord(address nodeID) internal returns (int256 minipoolIndex) {
    minipoolIndex = getIndexOf(nodeID);
    if (minipoolIndex != -1) {
        requireValidStateTransition(minipoolIndex, MinipoolStatus.Prelaunch);
        resetMinipoolData(minipoolIndex);
        setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".initialStartTime")), 0);
    } else {
        minipoolIndex = int256(getUint(keccak256("minipool.count")));
        setUint(keccak256(abi.encodePacked("minipool.index", nodeID)), uint256(minipoolIndex + 1));
        setAddress(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".nodeID")), nodeID);
        addUint(keccak256("minipool.count"), 1);
    }
    return minipoolIndex;
	}

	/// @notice Owner of a minipool can cancel the (prelaunch) minipool
	/// @param nodeID 32-byte node ID the Owner registered with
	function cancelMinipool(address nodeID) external nonReentrant {
    ProtocolDAO dao = ProtocolDAO(getContractAddress("ProtocolDAO"));
    int256 index = requireValidMinipool(nodeID);
    onlyOwner(index);
    // make sure the minipool meets the wait period requirement
    uint256 creationTime = getUint(keccak256(abi.encodePacked("minipool.item", index, ".creationTime")));
    if (block.timestamp - creationTime < dao.getMinipoolCancelMoratoriumSeconds()) {
        revert CancellationTooEarly();
    }
    _cancelMinipoolAndReturnFunds(nodeID, index);
	}

	/// @notice Withdraw function for a Node Operator to claim all PLS funds they are due (original PLS staked, plus any PLS rewards)
	/// @param nodeID 32-byte node ID the Node Operator registered with
	function withdrawMinipoolFunds(address nodeID) external nonReentrant {
		int256 minipoolIndex = requireValidMinipool(nodeID);
		address owner = onlyOwner(minipoolIndex);
		requireValidStateTransition(minipoolIndex, MinipoolStatus.Finished);
		setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".status")), uint256(MinipoolStatus.Finished));

		uint256 plsNodeOpAmt = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpAmt")));
		uint256 plsNodeOpRewardAmt = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpRewardAmt")));
		uint256 totalPlsAmt = plsNodeOpAmt + plsNodeOpRewardAmt;

		Staking staking = Staking(getContractAddress("Staking"));
		staking.decreasePLSStake(owner, plsNodeOpAmt);

		Vault vault = Vault(getContractAddress("Vault"));
		vault.withdrawPLS(totalPlsAmt);
		owner.safeTransferETH(totalPlsAmt);
	}

	/// @notice Allows node operators to withdraw their partial rewards
	function withdrawPartialRewards(address nodeID) external nonReentrant {
    int256 minipoolIndex = requireValidMinipool(nodeID);
    
    address owner = onlyOwner(minipoolIndex);
    require(msg.sender == owner, "Only owner can withdraw");

    // Fetch the partial rewards for node operators
    uint256 rewardsAmt = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpPartialRewards")));
    require(rewardsAmt > 0, "No rewards available");

    // Withdraw the rewards from the vault
    Vault vault = Vault(getContractAddress("Vault"));
    vault.withdrawPLS(rewardsAmt);
    owner.safeTransferETH(rewardsAmt);

    // Update the rewards withdrawn and reset the node operator rewards amount
    uint256 currentWithdrawn = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".rewardsWithdrawn")));
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".rewardsWithdrawn")), currentWithdrawn + rewardsAmt);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpPartialRewards")), 0);

    emit RewardsWithdrawn(nodeID, rewardsAmt);
	}

	
	function depositUsingNodeID(address nodeID, uint256 depositAmount) internal {
    (bytes memory pubkey, bytes memory withdrawalCredentials, bytes memory signature, bytes32 depositDataRoot) = extractValidatorCredentials(nodeID);
     validatorRegistration.registerValidator{value: depositAmount}(
         pubkey,
         withdrawalCredentials,
         signature,
         depositDataRoot
     );
	}


	// RIALTO FUNCTIONS

	/// @notice Verifies that the minipool related the the given node ID is able to a validator
	/// @dev Rialto calls this to see if a claim would succeed. Does not change state.
	/// @param nodeID 32-byte node ID
	/// @return boolean representing if the minipool can become a validator
	function canClaimAndInitiateStaking(address nodeID) external view returns (bool) {
		int256 minipoolIndex = onlyValidMultisig(nodeID);
		requireValidStateTransition(minipoolIndex, MinipoolStatus.Launched);

		TokenstPLS stPLS = TokenstPLS(payable(getContractAddress("TokenstPLS")));
		uint256 plsLiquidStakerAmt = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsLiquidStakerAmt")));
		return plsLiquidStakerAmt <= stPLS.amountAvailableForStaking();
	}

	/// @notice Withdraws minipool's PLS for staking
	/// @param nodeID 32-byte node ID
	/// @dev Rialto calls this to claim a minipool for staking and validation on the P-chain.
	function claimAndInitiateStaking(address nodeID) public {
		_claimAndInitiateStaking(nodeID, false);
	}

	/// @notice Withdraws minipool's PLS for staking on PulseChain while that minipool is cycling
	/// @param nodeID 32-byte node ID
	/// @dev Rialto calls this to claim a minipool for staking and validation
	function claimAndInitiateStakingCycle(address nodeID) internal {
		_claimAndInitiateStaking(nodeID, true);
	}

	function _claimAndInitiateStaking(address nodeID, bool isCycling) internal {
    int256 minipoolIndex = onlyValidMultisig(nodeID);
    requireValidStateTransition(minipoolIndex, MinipoolStatus.Launched);

    // Withdraw from TokenstPLS
    uint256 plsLiquidStakerAmt = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsLiquidStakerAmt")));
    TokenstPLS stPLS = TokenstPLS(payable(getContractAddress("TokenstPLS")));
    if (!isCycling && (plsLiquidStakerAmt > stPLS.amountAvailableForStaking())) {
        revert WithdrawAmountTooLarge();
    }
    stPLS.withdrawForStaking(plsLiquidStakerAmt);
	addUint(keccak256("MinipoolManager.TotalPLSLiquidStakerAmt"), plsLiquidStakerAmt);

    // Withdraw from Vault
    uint256 plsNodeOpAmt = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpAmt")));
    Vault vault = Vault(getContractAddress("Vault"));
    vault.withdrawPLS(plsNodeOpAmt);

    // Confirm funds
    uint256 totalPlsAmt = plsNodeOpAmt + plsLiquidStakerAmt;
    require(address(this).balance >= totalPlsAmt, "Insufficient funds in contract after withdrawal.");

	depositUsingNodeID(nodeID, totalPlsAmt);

    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".status")), uint256(MinipoolStatus.Launched));
    emit MinipoolStatusChanged(nodeID, MinipoolStatus.Launched);
	}

	/// @notice Rialto calls this after successfully registering the minipool as a validator for PulseChain
	/// @param nodeID 32-byte node ID
	/// @param startTime Time the node became a validator
	function recordStakingStart(address nodeID, uint256 startTime) external {
    int256 minipoolIndex = onlyValidMultisig(nodeID);
    requireValidStateTransition(minipoolIndex, MinipoolStatus.Staking);
    if (startTime > block.timestamp) {
        revert("InvalidStartTime");
    }

    // Setting the status and start time of the minipool
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".status")), uint256(MinipoolStatus.Staking));
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".startTime")), startTime);

    uint256 duration = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".duration")));
    uint256 endTime = startTime + duration;
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".endTime")), endTime);

    // Retrieve and possibly initialize the initial start time if this is the first cycle
    uint256 initialStartTime = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".initialStartTime")));
    if (initialStartTime == 0) {
        setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".initialStartTime")), startTime);
    }

    // Initialize or reset the lastRewardTime and rewardsWithdrawn at the start of new staking
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".lastRewardTime")), startTime);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".rewardsWithdrawn")), 0);

    // Retrieve the owner and increase their PLS validating amount
    address owner = getAddress(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".owner")));
    Staking staking = Staking(getContractAddress("Staking"));
    uint256 plsLiquidStakerAmt = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsLiquidStakerAmt")));
    staking.increasePLSValidating(owner, plsLiquidStakerAmt);

    // Update the high water mark if necessary
    if (staking.getPLSValidatingHighWater(owner) < staking.getPLSValidating(owner)) {
        staking.setPLSValidatingHighWater(owner, staking.getPLSValidating(owner));
    }

    // Emit an event indicating the status change of the minipool
    emit MinipoolStatusChanged(nodeID, MinipoolStatus.Staking);
	}

	/// @notice Distributes nodeOp rewards incrementally to the Vault and updates reward tracking
	/// @param nodeID 32-byte node ID to identify the minipool
	function distributeRewards(address nodeID, uint256 plsEarnedThisCycle) public {
    int256 minipoolIndex = onlyValidMultisig(nodeID);
	requireValidStateTransition(minipoolIndex, MinipoolStatus.Withdrawable);

    Minipool memory mp = getMinipool(minipoolIndex);

    ProtocolDAO dao = ProtocolDAO(getContractAddress("ProtocolDAO"));
    uint256 rewardInterval = dao.getPartialRewardsInterval();

    uint256 currentTime = block.timestamp;
    require(currentTime >= mp.lastRewardTime + rewardInterval, "RewardIntervalNotMet");

    if (plsEarnedThisCycle == 0) {
        slash(minipoolIndex);
        return;
    }

    uint256 commissionFee = dao.getMinipoolNodeCommissionFeePct();

    // Calculate the node operators' and liquid stakers' reward
    uint256 halfReward = plsEarnedThisCycle / 2; 
    uint256 commissionAmount = halfReward.mulWadDown(commissionFee); 
    uint256 plsLiquidStakerRewardAmt = halfReward - commissionAmount; 
    uint256 plsNodeOpRewardAfterCommission = plsEarnedThisCycle - plsLiquidStakerRewardAmt; 

    // Accumulate the partial rewards in their respective fields
    mp.plsNodeOpPartialRewards += plsNodeOpRewardAfterCommission;
    mp.plsLiquidStakerPartialRewards += plsLiquidStakerRewardAmt;

    // Perform actual payouts
    Vault vault = Vault(getContractAddress("Vault"));
    if (plsNodeOpRewardAfterCommission > 0) {
        vault.depositPLS{value: plsNodeOpRewardAfterCommission}();
    }

    TokenstPLS stPLS = TokenstPLS(payable(getContractAddress("TokenstPLS")));
    if (plsLiquidStakerRewardAmt > 0) {
        stPLS.depositFromStaking{value: plsLiquidStakerRewardAmt}(0, plsLiquidStakerRewardAmt);
    }

    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".lastRewardTime")), currentTime);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsTotalRewardAmt")), mp.plsTotalRewardAmt + plsEarnedThisCycle);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpPartialRewards")), mp.plsNodeOpPartialRewards);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsLiquidStakerPartialRewards")), mp.plsLiquidStakerPartialRewards);

    emit RewardsWithdrawn(nodeID, plsEarnedThisCycle);
	}

	/// @notice Records the nodeID's validation period end
	/// @param nodeID 32-byte node ID
	/// @param endTime The time the node ID stopped validating PulseChain
	/// @param plsTotalRewardAmt The rewards the node received from PulseChain for being a validator
	function recordStakingEnd(address nodeID, uint256 endTime, uint256 plsTotalRewardAmt) public {
    int256 minipoolIndex = onlyValidMultisig(nodeID);
    requireValidStateTransition(minipoolIndex, MinipoolStatus.Withdrawable);

    Minipool memory mp = getMinipool(minipoolIndex);
    if (endTime <= mp.startTime || endTime > block.timestamp) {
        revert("InvalidEndTime");
    }

    uint256 totalPlsAmt = mp.plsNodeOpAmt + mp.plsLiquidStakerAmt + plsTotalRewardAmt;
	require(address(this).balance >= totalPlsAmt, "InsufficientFunds: Contract lacks funds to cover payouts");

    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".status")), uint256(MinipoolStatus.Withdrawable));
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".endTime")), endTime);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsTotalRewardAmt")), plsTotalRewardAmt);

    uint256 plsHalfRewards = plsTotalRewardAmt / 2;
    ProtocolDAO dao = ProtocolDAO(getContractAddress("ProtocolDAO"));
    uint256 commissionFee = dao.getMinipoolNodeCommissionFeePct();
    uint256 plsLiquidStakerRewardAmt = plsHalfRewards - plsHalfRewards.mulWadDown(commissionFee);
    uint256 plsNodeOpRewardAmt = plsTotalRewardAmt - plsLiquidStakerRewardAmt;

    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpRewardAmt")), plsNodeOpRewardAmt);
    setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsLiquidStakerRewardAmt")), plsLiquidStakerRewardAmt);

    if (plsTotalRewardAmt == 0) {
        slash(minipoolIndex);
    }

    Vault vault = Vault(getContractAddress("Vault"));
    vault.depositPLS{value: mp.plsNodeOpAmt + plsNodeOpRewardAmt}();

    TokenstPLS stPLS = TokenstPLS(payable(getContractAddress("TokenstPLS")));
    stPLS.depositFromStaking{value: mp.plsLiquidStakerAmt + plsLiquidStakerRewardAmt}(mp.plsLiquidStakerAmt, plsLiquidStakerRewardAmt);

    subUint(keccak256("MinipoolManager.TotalPLSLiquidStakerAmt"), mp.plsLiquidStakerAmt);
    Staking staking = Staking(getContractAddress("Staking"));
    staking.decreasePLSAssigned(mp.owner, mp.plsLiquidStakerAmt);
    staking.decreasePLSValidating(mp.owner, mp.plsLiquidStakerAmt);

    emit MinipoolStatusChanged(nodeID, MinipoolStatus.Withdrawable);
	}


	/// @notice Records the nodeID's validation period end
	/// @param nodeID 32-byte node ID
	/// @param endTime The time the node ID stopped validating PulseChain
	/// @param plsTotalRewardAmt The rewards the node received from PulseChain for being a validator
	/// @dev Rialto will xfer back all staked pls + pls rewards. Also handles the slashing of node ops PPY bond.
	/// @dev We call recordStakingEnd,recreateMinipool,claimAndInitiateStaking in one tx to prevent liq staker funds from being sniped
	function recordStakingEndThenMaybeCycle(address nodeID, uint256 endTime, uint256 plsTotalRewardAmt) external payable whenNotPaused {
		int256 minipoolIndex = onlyValidMultisig(nodeID);

		uint256 initialStartTime = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".initialStartTime")));
		uint256 duration = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".duration")));

		recordStakingEnd(nodeID, endTime, plsTotalRewardAmt);
		ProtocolDAO dao = ProtocolDAO(getContractAddress("ProtocolDAO"));

		uint256 minipoolEnd = initialStartTime + duration;
		uint256 minipoolEndWithTolerance = minipoolEnd + dao.getMinipoolCycleDelayTolerance();

		uint256 nextCycleEnd = block.timestamp + dao.getMinipoolCycleDuration();

		if (nextCycleEnd <= minipoolEndWithTolerance) {
			recreateMinipool(nodeID);
			claimAndInitiateStakingCycle(nodeID);
		} else {
			// if difference is less than a cycle, the minipool was meant to validate again
			//    set an errorCode the front-end can decode
			if (nextCycleEnd - minipoolEnd < dao.getMinipoolCycleDuration()) {
				bytes32 errorCode = "EC1";
				setBytes32(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".errorCode")), errorCode);
			}
		}
	}

	/// @notice Re-stake a minipool, compounding all rewards recvd
	/// @param nodeID 32-byte node ID
	function recreateMinipool(address nodeID) internal whenNotPaused {
		int256 minipoolIndex = onlyValidMultisig(nodeID);
		Minipool memory mp = getMinipool(minipoolIndex);
		MinipoolStatus currentStatus = MinipoolStatus(mp.status);

		if (currentStatus != MinipoolStatus.Withdrawable) {
			revert InvalidStateTransition();
		}

		// Compound the pls plus rewards
		// NOTE Assumes a 1:1 nodeOp:liqStaker funds ratio
		uint256 compoundedPlsAmt = mp.plsNodeOpAmt + mp.plsLiquidStakerRewardAmt;
		setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpAmt")), compoundedPlsAmt);
		setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsLiquidStakerAmt")), compoundedPlsAmt);

		Staking staking = Staking(getContractAddress("Staking"));
		// Only increase PLS stake by rewards amount we are compounding
		// since PLS stake is only decreased by withdrawMinipool()
		staking.increasePLSStake(mp.owner, mp.plsLiquidStakerRewardAmt);
		staking.increasePLSAssigned(mp.owner, compoundedPlsAmt);

		ProtocolDAO dao = ProtocolDAO(getContractAddress("ProtocolDAO"));
		uint256 ratio = staking.getCollateralizationRatio(mp.owner);
		if (ratio < dao.getMinCollateralizationRatio()) {
			revert InsufficientPPYCollateralization();
		}

		resetMinipoolData(minipoolIndex);

		setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".status")), uint256(MinipoolStatus.Prelaunch));

		emit MinipoolStatusChanged(nodeID, MinipoolStatus.Prelaunch);
	}

	/// @notice A staking error occurred while registering the node as a validator
	/// @param nodeID 32-byte node ID
	/// @param errorCode The code that represents the reason for failure
	/// @dev Rialto was unable to start the validation period, so cancel and refund all money
	function recordStakingError(address nodeID, bytes32 errorCode) external payable {
		int256 minipoolIndex = onlyValidMultisig(nodeID);
		requireValidStateTransition(minipoolIndex, MinipoolStatus.Error);

		address owner = getAddress(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".owner")));
		uint256 plsNodeOpAmt = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpAmt")));
		uint256 plsLiquidStakerAmt = getUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsLiquidStakerAmt")));

		if (msg.value != (plsNodeOpAmt + plsLiquidStakerAmt)) {
			revert InvalidAmount();
		}

		setBytes32(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".errorCode")), errorCode);
		setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".status")), uint256(MinipoolStatus.Error));
		setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsTotalRewardAmt")), 0);
		setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsNodeOpRewardAmt")), 0);
		setUint(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".plsLiquidStakerRewardAmt")), 0);

		// Send the nodeOps PLS to vault so they can claim later
		Vault vault = Vault(getContractAddress("Vault"));
		vault.depositPLS{value: plsNodeOpAmt}();

		// Return Liq stakers funds
		TokenstPLS stPLS = TokenstPLS(payable(getContractAddress("TokenstPLS")));
		stPLS.depositFromStaking{value: plsLiquidStakerAmt}(plsLiquidStakerAmt, 0);

		Staking staking = Staking(getContractAddress("Staking"));
		staking.decreasePLSAssigned(owner, plsLiquidStakerAmt);

		subUint(keccak256("MinipoolManager.TotalPLSLiquidStakerAmt"), plsLiquidStakerAmt);

		emit MinipoolStatusChanged(nodeID, MinipoolStatus.Error);
	}


	/// @notice Multisig can cancel a minipool if a problem was encountered *before* claimAndInitiateStaking() was called
	/// @param nodeID 32-byte node ID
	/// @param errorCode The code that represents the reason for failure
	function cancelMinipoolByMultisig(address nodeID, bytes32 errorCode) external {
		int256 minipoolIndex = onlyValidMultisig(nodeID);
		setBytes32(keccak256(abi.encodePacked("minipool.item", minipoolIndex, ".errorCode")), errorCode);
		_cancelMinipoolAndReturnFunds(nodeID, minipoolIndex);
	}
	

	/// @notice Deposits accumulated rewards from MinipoolManager to TokenstPLS
	/// @dev This function should be called periodically, aligned with the TokenstPLS rewards cycle.
	function depositFromRewards() public {
    uint32 rewardsCycleLength = 12 hours; 
    uint32 lastRewardsCycleEnd = safeCastTo32(rewardsCycleEnd);

    if (block.timestamp < lastRewardsCycleEnd + rewardsCycleLength) {
        revert("Too early to trigger this function.");
    }

    uint256 totalAvailableRewards = address(this).balance;
    uint256 rewardsDistributionRate = getUint(keccak256("ProtocolDAO.RewardsDepositRate"));
    uint256 depositAmount = (totalAvailableRewards * rewardsDistributionRate) / 1 ether; 

    require(depositAmount > 0, "No sufficient rewards available to transfer");
    TokenstPLS stPLS = TokenstPLS(payable(getContractAddress("TokenstPLS")));
    stPLS.depositFromMinipoolManager{value: depositAmount}(depositAmount);

    rewardsCycleEnd = (safeCastTo32(block.timestamp) / rewardsCycleLength) * rewardsCycleLength + rewardsCycleLength;
	}


	//
	// VIEW FUNCTIONS
	//

	function canUseReducedStakingAmount(address stakerAddress) public view returns (bool eligible, uint256 requiredStakingAmount) {
    EarlyStaking earlyStaking = EarlyStaking(payable(getContractAddress("EarlyStaking")));
    int256 stakerIndex = earlyStaking.getIndexOf(stakerAddress);
    bool isEarlyStaker = stakerIndex >= 0; // True if stakerIndex is not -1, meaning the staker exists

    // Assuming the first early staker gets a special treatment and should use the reduced amount
    if (isEarlyStaker) {
        if (stakerIndex == 99) {
            // First 100 early stakers, eligible for reduced amount
            return (true, 8_000_000 ether); 
        } else {
            return (false, 16_000_000 ether); 
        }
    }
    // Default case for non-early stakers
    return (false, 16_000_000 ether);
	}

	function getExpectedLiquidStakerAmount(address stakerAddress) public view returns (uint256) {
    // Determine the staker's eligibility and required staking amount
    (bool eligibleForReducedStaking, uint256 requiredNodeOperatorStakingAmount) = canUseReducedStakingAmount(stakerAddress);
    uint256 totalStakingRequirement = 32_000_000 ether;

    if (eligibleForReducedStaking && requiredNodeOperatorStakingAmount == 8_000_000 ether) {
        return totalStakingRequirement - requiredNodeOperatorStakingAmount;
    } else {
        // For all other cases, including non-early stakers and early stakers not eligible for the reduced amount
        return totalStakingRequirement - 16_000_000 ether; 
    }
	}

	function extractValidatorCredentials(address nodeID) public view returns (bytes memory pubkey, bytes memory withdrawalCredentials, bytes memory signature, bytes32 depositDataRoot) {
    	NodeIDGenerator.ValidatorCredentials memory creds = nodeIDGenerator.getValidatorCredentials(nodeID);
    	return (creds.pubkey, creds.withdrawalCredentials, creds.signature, creds.depositDataRoot);
	}

	/// @notice Calculates how much PPY should be slashed given an expected plsRewardAmt
	/// @param plsRewardAmt The amount of PLS that should have been awarded to the validator by PulseChain
	/// @return The amount of PPY that should be slashed
	function calculatePPYSlashAmt(uint256 plsRewardAmt) public view returns (uint256) {
		Oracle oracle = Oracle(getContractAddress("Oracle"));
		(uint256 ppyPriceInPls, ) = oracle.getPPYPriceInPLS();
		return plsRewardAmt.divWadDown(ppyPriceInPls);
	}

	/// @notice Given a duration and an PLS amt, calculate how much PLS should be earned via validation rewards
	/// @param duration The length of validation in seconds
	/// @param plsAmt The amount of PLS the node staked for their validation period
	/// @return The approximate rewards the node should receive from PulseChain for being a validator
	function getExpectedPLSRewardsAmt(uint256 duration, uint256 plsAmt) public view returns (uint256) {
		ProtocolDAO dao = ProtocolDAO(getContractAddress("ProtocolDAO"));
		uint256 rate = dao.getExpectedPLSRewardsRate();
		return (plsAmt.mulWadDown(rate) * duration) / 365 days;
	}

	/// @notice The index of a minipool. Returns -1 if the minipool is not found
	/// @param nodeID 32-byte node ID
	/// @return The index for the given minipool
	function getIndexOf(address nodeID) public view returns (int256) {
		return int256(getUint(keccak256(abi.encodePacked("minipool.index", nodeID)))) - 1;
	}

	/// @notice Gets the minipool information from the node ID
	/// @param nodeID 32-byte node ID
	/// @return mp struct containing the minipool's properties
	function getMinipoolByNodeID(address nodeID) public view returns (Minipool memory mp) {
		int256 index = getIndexOf(nodeID);
		return getMinipool(index);
	}

	/// @notice Gets the minipool information using the minipool's index
	/// @param index Index of the minipool
	/// @return mp struct containing the minipool's properties
	function getMinipool(int256 index) public view returns (Minipool memory mp) {
    mp.index = index;
    mp.nodeID = getAddress(keccak256(abi.encodePacked("minipool.item", index, ".nodeID")));
    mp.status = getUint(keccak256(abi.encodePacked("minipool.item", index, ".status")));
    mp.duration = getUint(keccak256(abi.encodePacked("minipool.item", index, ".duration")));
    mp.delegationFee = getUint(keccak256(abi.encodePacked("minipool.item", index, ".delegationFee")));
    mp.owner = getAddress(keccak256(abi.encodePacked("minipool.item", index, ".owner")));
    mp.multisigAddr = getAddress(keccak256(abi.encodePacked("minipool.item", index, ".multisigAddr")));
    mp.plsNodeOpAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsNodeOpAmt")));
    mp.plsLiquidStakerAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsLiquidStakerAmt")));
    mp.creationTime = getUint(keccak256(abi.encodePacked("minipool.item", index, ".creationTime")));
    mp.initialStartTime = getUint(keccak256(abi.encodePacked("minipool.item", index, ".initialStartTime")));
    mp.startTime = getUint(keccak256(abi.encodePacked("minipool.item", index, ".startTime")));
    mp.endTime = getUint(keccak256(abi.encodePacked("minipool.item", index, ".endTime")));
    mp.plsTotalRewardAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsTotalRewardAmt")));
    mp.errorCode = getBytes32(keccak256(abi.encodePacked("minipool.item", index, ".errorCode")));
    mp.plsNodeOpInitialAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsNodeOpInitialAmt")));
    mp.plsNodeOpRewardAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsNodeOpRewardAmt")));
    mp.plsLiquidStakerRewardAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsLiquidStakerRewardAmt")));
    mp.ppySlashAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".ppySlashAmt")));
    mp.lastRewardTime = getUint(keccak256(abi.encodePacked("minipool.item", index, ".lastRewardTime")));
	mp.plsRewardsAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsRewardsAmt")));  
    mp.rewardsWithdrawn = getUint(keccak256(abi.encodePacked("minipool.item", index, ".rewardsWithdrawn")));
    mp.plsNodeOpPartialRewards = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsNodeOpPartialRewards")));
    mp.plsLiquidStakerPartialRewards = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsLiquidStakerPartialRewards")));
	}

	/// @notice Get minipools in a certain status (limit=0 means no pagination)
	/// @param status The MinipoolStatus to be used as a filter
	/// @param offset The number the result should be offset by
	/// @param limit The limit to the amount of minipools that should be returned
	/// @return minipools in the protocol that adhere to the parameters
	function getMinipools(MinipoolStatus status, uint256 offset, uint256 limit) public view returns (Minipool[] memory minipools) {
		uint256 totalMinipools = getUint(keccak256("minipool.count"));
		uint256 max = offset + limit;
		if (max > totalMinipools || limit == 0) {
			max = totalMinipools;
		}
		minipools = new Minipool[](max - offset);
		uint256 total = 0;
		for (uint256 i = offset; i < max; i++) {
			Minipool memory mp = getMinipool(int256(i));
			if (mp.status == uint256(status)) {
				minipools[total] = mp;
				total++;
			}
		}
		// Dirty hack to cut unused elements off end of return value (from RP)
		// solhint-disable-next-line no-inline-assembly
		assembly {
			mstore(minipools, total)
		}
	}

	/// @notice The total count of minipools in the protocol
	function getMinipoolCount() public view returns (uint256) {
		return getUint(keccak256("minipool.count"));
	}

	//
	// PRIVATE FUNCTIONS
	//

	/// @notice Cancels the minipool and returns the funds related to it
	/// @dev At this point we don't have any liq staker funds withdrawn from stPLS so no need to return them
	/// @param nodeID 32-byte node ID
	/// @param index Index of the minipool
	function _cancelMinipoolAndReturnFunds(address nodeID, int256 index) private {
		requireValidStateTransition(index, MinipoolStatus.Canceled);
		setUint(keccak256(abi.encodePacked("minipool.item", index, ".status")), uint256(MinipoolStatus.Canceled));

		address owner = getAddress(keccak256(abi.encodePacked("minipool.item", index, ".owner")));
		uint256 plsNodeOpAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsNodeOpAmt")));
		uint256 plsLiquidStakerAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsLiquidStakerAmt")));

		Staking staking = Staking(getContractAddress("Staking"));
		staking.decreasePLSStake(owner, plsNodeOpAmt);
		staking.decreasePLSAssigned(owner, plsLiquidStakerAmt);

		// if they are not due rewards this cycle and do not have any other minipools in queue, reset rewards start time.
		if (staking.getPLSValidatingHighWater(owner) == 0 && staking.getPLSAssigned(owner) == 0) {
			staking.setRewardsStartTime(owner, 0);
		}

		emit MinipoolStatusChanged(nodeID, MinipoolStatus.Canceled);

		Vault vault = Vault(getContractAddress("Vault"));
		vault.withdrawPLS(plsNodeOpAmt);
		owner.safeTransferETH(plsNodeOpAmt);
	}

	/// @notice Slashes the PPY of the minipool with the given index
	/// @dev Extracted this because of "stack too deep" errors.
	/// @param index Index of the minipool
	function slash(int256 index) private {
		address nodeID = getAddress(keccak256(abi.encodePacked("minipool.item", index, ".nodeID")));
		address owner = getAddress(keccak256(abi.encodePacked("minipool.item", index, ".owner")));
		int256 cycleDuration = int256(
			getUint(keccak256(abi.encodePacked("minipool.item", index, ".endTime"))) -
				getUint(keccak256(abi.encodePacked("minipool.item", index, ".startTime")))
		);
		if (cycleDuration < 0) {
			revert NegativeCycleDuration();
		}
		uint256 plsLiquidStakerAmt = getUint(keccak256(abi.encodePacked("minipool.item", index, ".plsLiquidStakerAmt")));
		uint256 expectedPLSRewardsAmt = getExpectedPLSRewardsAmt(uint256(cycleDuration), plsLiquidStakerAmt);
		uint256 slashPPYAmt = calculatePPYSlashAmt(expectedPLSRewardsAmt);

		Staking staking = Staking(getContractAddress("Staking"));
		if (staking.getPPYStake(owner) < slashPPYAmt) {
			slashPPYAmt = staking.getPPYStake(owner);
		}
		setUint(keccak256(abi.encodePacked("minipool.item", index, ".ppySlashAmt")), slashPPYAmt);

		emit PPYSlashed(nodeID, slashPPYAmt);

		staking.slashPPY(owner, slashPPYAmt);
	}

	/// @notice Reset all the data for a given minipool (for a previous validation cycle, so do not reset initial amounts)
	/// @param index Index of the minipool
	function resetMinipoolData(int256 index) private {
    setUint(keccak256(abi.encodePacked("minipool.item", index, ".creationTime")), 0);
    setUint(keccak256(abi.encodePacked("minipool.item", index, ".startTime")), 0);
    setUint(keccak256(abi.encodePacked("minipool.item", index, ".endTime")), 0);
    setUint(keccak256(abi.encodePacked("minipool.item", index, ".plsTotalRewardAmt")), 0);
    setUint(keccak256(abi.encodePacked("minipool.item", index, ".plsNodeOpRewardAmt")), 0);
    setUint(keccak256(abi.encodePacked("minipool.item", index, ".plsLiquidStakerRewardAmt")), 0);
    setUint(keccak256(abi.encodePacked("minipool.item", index, ".ppySlashAmt")), 0);
    setUint(keccak256(abi.encodePacked("minipool.item", index, ".lastRewardTime")), 0);
    setUint(keccak256(abi.encodePacked("minipool.item", index, ".plsNodeOpPartialRewards")), 0);
    setUint(keccak256(abi.encodePacked("minipool.item", index, ".plsLiquidStakerPartialRewards")), 0);
    setBytes32(keccak256(abi.encodePacked("minipool.item", index, ".errorCode")), bytes32(0));
	}
}
