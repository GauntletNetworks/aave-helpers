// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {Vm} from 'forge-std/Vm.sol';
import {ChainIds, ChainHelpers} from './ChainIds.sol';
import {IpfsUtils} from './IpfsUtils.sol';
import {console2} from 'forge-std/console2.sol';
import {PayloadsControllerUtils, IGovernancePowerStrategy, IPayloadsControllerCore, IGovernanceCore} from 'aave-address-book/GovernanceV3.sol';
import {IVotingMachineWithProofs} from 'aave-address-book/governance-v3/IVotingMachineWithProofs.sol';
import {IVotingPortal} from 'aave-address-book/governance-v3/IVotingPortal.sol';
import {GovernanceV3Arbitrum} from 'aave-address-book/GovernanceV3Arbitrum.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {GovernanceV3Polygon} from 'aave-address-book/GovernanceV3Polygon.sol';
import {GovernanceV3Optimism} from 'aave-address-book/GovernanceV3Optimism.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Metis} from 'aave-address-book/GovernanceV3Metis.sol';
import {GovernanceV3Base} from 'aave-address-book/GovernanceV3Base.sol';
import {GovernanceV3BNB} from 'aave-address-book/GovernanceV3BNB.sol';
import {GovernanceV3Gnosis} from 'aave-address-book/GovernanceV3Gnosis.sol';
import {MiscEthereum} from 'aave-address-book/MiscEthereum.sol';
import {Address} from 'solidity-utils/contracts/oz-common/Address.sol';
import {StorageHelpers} from './StorageHelpers.sol';
import {ProxyHelpers} from './ProxyHelpers.sol';
import {GovHelpers, IAaveGovernanceV2} from './GovHelpers.sol';

interface IGovernance_V2_5 {
  /**
   * @notice emitted when gas limit gets updated
   * @param gasLimit the new gas limit
   */
  event GasLimitUpdated(uint256 indexed gasLimit);

  /**
   * @notice method to get the CrossChainController contract address of the currently deployed address
   * @return address of CrossChainController contract
   */
  function CROSS_CHAIN_CONTROLLER() external view returns (address);

  /**
   * @notice method to get the name of the contract
   * @return name string
   */
  function NAME() external view returns (string memory);

  /**
   * @notice method to get the gas limit used on destination chain to execute bridged message
   * @return gas limit
   * @dev this gas limit is assuming that the messages to forward are only payload execution messages
   */
  function GAS_LIMIT() external view returns (uint256);

  /**
   * @notice method to send a payload to execution chain
   * @param payload object with the information needed for execution
   */
  function forwardPayloadForExecution(PayloadsControllerUtils.Payload memory payload) external;

  /**
   * @notice method to initialize governance v2.5
   */
  function initialize() external;
}

library GovV3Helpers {
  error CanNotFindPayload();
  error CannotFindPayloadsController();
  error ExecutorNotFound();
  error LongBytesNotSupportedYet();
  error FfiFailed();

  struct StorageRootResponse {
    address account;
    bytes32 blockHash;
    bytes blockHeaderRLP;
    bytes accountStateProofRLP;
  }

  function ipfsHashFile(Vm vm, string memory filePath) internal returns (bytes32) {
    return IpfsUtils.ipfsHashFile(vm, filePath, false);
  }

  /**
   * @dev fetching storage proofs via js helpers on the rpc
   * @param vm Vm
   * @param proposalId id of the payload
   * @param voter address voting, to generate the proofs for
   */
  function getVotingProofs(
    Vm vm,
    uint256 proposalId,
    address voter
  ) internal returns (IVotingMachineWithProofs.VotingBalanceProof[] memory) {
    string[] memory inputs = new string[](8);
    inputs[0] = 'npx';
    inputs[1] = '@bgd-labs/aave-cli@0.1.0';
    inputs[2] = 'governance';
    inputs[3] = 'getVotingProofs';
    inputs[4] = '--proposalId';
    inputs[5] = vm.toString(proposalId);
    inputs[6] = '--voter';
    inputs[7] = vm.toString(voter);
    Vm.FfiResult memory f = vm.tryFfi(inputs);
    if (f.exitCode != 0) {
      console2.logString(string(f.stderr));
      revert FfiFailed();
    }
    return abi.decode(f.stdout, (IVotingMachineWithProofs.VotingBalanceProof[]));
  }

  /**
   * @dev fetching storage root via js helpers on the rpc
   * @param vm Vm
   * @param proposalId id of the payload
   */
  function getStorageRoots(
    Vm vm,
    uint256 proposalId
  ) internal returns (StorageRootResponse[] memory) {
    string[] memory inputs = new string[](6);
    inputs[0] = 'npx';
    inputs[1] = '@bgd-labs/aave-cli@0.1.0';
    inputs[2] = 'governance';
    inputs[3] = 'getStorageRoots';
    inputs[4] = '--proposalId';
    inputs[5] = vm.toString(proposalId);
    Vm.FfiResult memory f = vm.tryFfi(inputs);
    if (f.exitCode != 0) {
      console2.logString(string(f.stderr));
      revert FfiFailed();
    }
    return abi.decode(f.stdout, (StorageRootResponse[]));
  }

  /**
   * @dev votes on a proposal via proofs
   * @param vm Vm
   * @param proposalId id of the payload
   * @param votingBalanceProofs proofs
   * @param support true if voting in support, false if voting against
   */
  function vote(
    Vm vm,
    uint256 proposalId,
    IVotingMachineWithProofs.VotingBalanceProof[] memory votingBalanceProofs,
    bool support
  ) internal {
    IGovernanceCore.Proposal memory proposal = GovernanceV3Ethereum.GOVERNANCE.getProposal(
      proposalId
    );
    address machine = IVotingPortal(proposal.votingPortal).VOTING_MACHINE();
    uint256 chainId = IVotingPortal(proposal.votingPortal).VOTING_MACHINE_CHAIN_ID();
    ChainHelpers.selectChain(vm, chainId);
    IVotingMachineWithProofs(machine).submitVote(proposalId, support, votingBalanceProofs);
  }

  /**
   * @dev builds a action to be registered on a payloadsController
   * - assumes accesscontrol level 1
   * - assumes delegateCall true
   * - assumes standard `execute()` signature on the payload contract
   * - assumes eth value 0
   * - assumes no calldata being necessary
   * @param payloadAddress address of the payload to be executed
   */
  function buildAction(
    address payloadAddress
  ) internal pure returns (IPayloadsControllerCore.ExecutionAction memory) {
    return
      buildAction({
        payloadAddress: payloadAddress,
        accessLevel: PayloadsControllerUtils.AccessControl.Level_1,
        value: 0,
        withDelegateCall: true,
        signature: 'execute()',
        callData: ''
      });
  }

  /**
   * @dev builds a action to be registered on a payloadsController
   * @param payloadAddress address of the payload to be executed
   * @param accessLevel accessLevel required by the payload
   * @param value eth value to be sent to the payload
   * @param withDelegateCall determines if payload thould be executed via delgatecall
   * @param signature signature to be executed on the payload
   * @param callData calldata for the signature
   */
  function buildAction(
    address payloadAddress,
    PayloadsControllerUtils.AccessControl accessLevel,
    uint256 value,
    bool withDelegateCall,
    string memory signature,
    bytes memory callData
  ) internal pure returns (IPayloadsControllerCore.ExecutionAction memory) {
    require(payloadAddress != address(0), 'INVALID_PAYLOAD_ADDRESS');
    require(
      accessLevel != PayloadsControllerUtils.AccessControl.Level_null,
      'INVALID_ACCESS_LEVEL'
    );

    return
      IPayloadsControllerCore.ExecutionAction({
        target: payloadAddress,
        withDelegateCall: withDelegateCall,
        accessLevel: accessLevel,
        value: value,
        signature: signature,
        callData: callData
      });
  }

  /**
   * Registers a payload with the provided actions on the network PayloadsController
   * @param actions actions
   * @return uint40 payloadId
   */
  function createPayload(
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (uint40) {
    IPayloadsControllerCore payloadsController = getPayloadsController(block.chainid);
    require(actions.length > 0, 'INVALID ACTIONS');

    return payloadsController.createPayload(actions);
  }

  function createPayload(
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (uint40) {
    IPayloadsControllerCore.ExecutionAction[]
      memory actions = new IPayloadsControllerCore.ExecutionAction[](1);
    actions[0] = action;
    return createPayload(actions);
  }

  /**
   * @dev This method allows you to directly execute a payloadId, no matter the state of the payload
   * @notice This method is for test purposes only.
   * @param vm Vm
   * @param payloadId id of the payload
   */
  function executePayload(Vm vm, uint40 payloadId) internal {
    IPayloadsControllerCore payloadsController = getPayloadsController(block.chainid);
    IPayloadsControllerCore.Payload memory payload = payloadsController.getPayloadById(payloadId);
    require(payload.state != IPayloadsControllerCore.PayloadState.None, 'PAYLOAD DOES NOT EXIST');

    GovV3StorageHelpers.readyPayloadId(vm, payloadsController, payloadId);

    payloadsController.executePayload(payloadId);
  }

  /**
   * @dev executes a payloadAddress via payloadsController by injecting it into storage and executing it afterwards.
   * Injecting into storage is a convinience method to reduce the txs executed from 2 to 1, this allows awaiting emitted events on the payloadsController.
   * @notice This method is for test purposes only.
   * @param vm Vm
   * @param payloadAddress address of the payload to execute
   */
  function executePayload(Vm vm, address payloadAddress) internal {
    require(Address.isContract(payloadAddress), 'PAYLOAD_ADDRESS_HAS_NO_CODE');
    IPayloadsControllerCore payloadsController = getPayloadsController(block.chainid);
    IPayloadsControllerCore.ExecutionAction[]
      memory actions = new IPayloadsControllerCore.ExecutionAction[](1);
    actions[0] = buildAction(payloadAddress);
    uint40 payloadId = GovV3StorageHelpers.injectPayload(vm, payloadsController, actions);
    GovV3StorageHelpers.readyPayloadId(vm, payloadsController, payloadId);
    payloadsController.executePayload(payloadId);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param actions actions array
   */
  function buildMainnetPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.MAINNET, actions);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param action actions array
   */
  function buildMainnetPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.MAINNET, action);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param actions actions array
   */
  function buildPolygonPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.POLYGON, actions);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param action actions array
   */
  function buildPolygonPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.POLYGON, action);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param actions actions array
   */
  function buildAvalanchePayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.AVALANCHE, actions);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param action actions array
   */
  function buildAvalanchePayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.AVALANCHE, action);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param actions actions array
   */
  function buildArbitrumPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.ARBITRUM, actions);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param action actions array
   */
  function buildArbitrumPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.ARBITRUM, action);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param actions actions array
   */
  function buildOptimismPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.OPTIMISM, actions);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param action actions array
   */
  function buildOptimismPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.OPTIMISM, action);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param actions actions array
   */
  function buildMetisPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.METIS, actions);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param action actions array
   */
  function buildMetisPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.METIS, action);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param actions actions array
   */
  function buildBasePayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.BASE, actions);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param action actions array
   */
  function buildBasePayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.BASE, action);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param actions actions array
   */
  function buildGnosisPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.GNOSIS, actions);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param action actions array
   */
  function buildGnosisPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.GNOSIS, action);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param actions actions array
   */
  function buildBNBPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.BNB, actions);
  }

  /**
   * Builds a payload to be executed via governance
   * @param vm Vm
   * @param action actions array
   */
  function buildBNBPayload(
    Vm vm,
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    return _buildPayload(vm, ChainIds.BNB, action);
  }

  /**
   * @dev creates a proposal with multiple payloads
   * @param vm Vm
   * @param payloads payloads array
   * @param ipfsHash ipfs hash
   */
  function createProposal(
    Vm vm,
    PayloadsControllerUtils.Payload[] memory payloads,
    bytes32 ipfsHash
  ) internal returns (uint256) {
    return createProposal(vm, payloads, GovernanceV3Ethereum.VOTING_PORTAL_ETH_POL, ipfsHash);
  }

  // temporarily patched create proposal for governance v2.5
  function createProposal2_5(
    Vm vm,
    PayloadsControllerUtils.Payload[] memory payloads,
    bytes32 ipfsHash
  ) internal returns (uint256) {
    require(block.chainid == ChainIds.MAINNET, 'MAINNET_ONLY');
    require(payloads.length != 0, 'MINIMUM_ONE_PAYLOAD');
    require(ipfsHash != bytes32(0), 'NON_ZERO_IPFS_HASH');

    generateProposalPreviewLink(vm, payloads, ipfsHash, address(0));
    GovHelpers.Payload[] memory gov2Payloads = new GovHelpers.Payload[](payloads.length);
    for (uint256 i = 0; i < payloads.length; i++) {
      gov2Payloads[i] = GovHelpers.Payload({
        target: address(GovernanceV3Ethereum.GOVERNANCE),
        value: 0,
        signature: 'forwardPayloadForExecution((uint256,uint8,address,uint40))',
        callData: abi.encode(payloads[i]),
        withDelegatecall: false
      });
    }
    return GovHelpers.createProposal(gov2Payloads, ipfsHash, true);
  }

  /**
   * @dev creates a proposal with a single payload
   * @param vm Vm
   * @param payload payload
   * @param ipfsHash ipfs hash
   */
  function createProposal(
    Vm vm,
    PayloadsControllerUtils.Payload memory payload,
    bytes32 ipfsHash
  ) internal returns (uint256) {
    PayloadsControllerUtils.Payload[] memory payloads = new PayloadsControllerUtils.Payload[](1);
    payloads[0] = payload;
    return createProposal(vm, payloads, GovernanceV3Ethereum.VOTING_PORTAL_ETH_POL, ipfsHash);
  }

  /**
   * @dev creates a proposal with a custom voting portal
   * @param vm Vm
   * @param payloads payloads array
   * @param votingPortal address of the voting portal
   * @param ipfsHash ipfs hash
   */
  function createProposal(
    Vm vm,
    PayloadsControllerUtils.Payload[] memory payloads,
    address votingPortal,
    bytes32 ipfsHash
  ) internal returns (uint256) {
    return _createProposal(vm, payloads, ipfsHash, votingPortal);
  }

  function getPayloadsController(uint256 chainId) internal pure returns (IPayloadsControllerCore) {
    if (chainId == ChainIds.MAINNET) {
      return GovernanceV3Ethereum.PAYLOADS_CONTROLLER;
    } else if (chainId == ChainIds.POLYGON) {
      return GovernanceV3Polygon.PAYLOADS_CONTROLLER;
    } else if (chainId == ChainIds.AVALANCHE) {
      return GovernanceV3Avalanche.PAYLOADS_CONTROLLER;
    } else if (chainId == ChainIds.OPTIMISM) {
      return GovernanceV3Optimism.PAYLOADS_CONTROLLER;
    } else if (chainId == ChainIds.ARBITRUM) {
      return GovernanceV3Arbitrum.PAYLOADS_CONTROLLER;
    } else if (chainId == ChainIds.METIS) {
      return GovernanceV3Metis.PAYLOADS_CONTROLLER;
    } else if (chainId == ChainIds.BASE) {
      return GovernanceV3Base.PAYLOADS_CONTROLLER;
    } else if (chainId == ChainIds.BNB) {
      return GovernanceV3BNB.PAYLOADS_CONTROLLER;
    } else if (chainId == ChainIds.GNOSIS) {
      return GovernanceV3Gnosis.PAYLOADS_CONTROLLER;
    }

    revert CannotFindPayloadsController();
  }

  function generateProposalPreviewLink(
    Vm vm,
    PayloadsControllerUtils.Payload[] memory payloads,
    bytes32 ipfsHash,
    address votingPortal
  ) public pure {
    string memory payloadsStr;
    for (uint256 i = 0; i < payloads.length; i++) {
      string memory payloadBase = string.concat('&payload[', vm.toString(i), '].');
      string memory payload = string.concat(
        payloadBase,
        'chainId=',
        vm.toString(payloads[i].chain),
        payloadBase,
        'accessLevel=',
        vm.toString(uint8(payloads[i].accessLevel)),
        payloadBase,
        'payloadsController=',
        vm.toString(payloads[i].payloadsController),
        payloadBase,
        'payloadId=',
        vm.toString(payloads[i].payloadId)
      );
      payloadsStr = string.concat(payloadsStr, payload);
    }
    console2.log(
      'https://aave-governance-v3-interface-git-feat-create-ui-bgd-labs.vercel.app/createByParams?ipfsHash=%s&votingPortal=%s%s',
      vm.toString(ipfsHash),
      votingPortal,
      payloadsStr
    );
  }

  function _createProposal(
    Vm vm,
    PayloadsControllerUtils.Payload[] memory payloads,
    bytes32 ipfsHash,
    address votingPortal
  ) private returns (uint256) {
    require(block.chainid == ChainIds.MAINNET, 'MAINNET_ONLY');
    require(payloads.length != 0, 'MINIMUM_ONE_PAYLOAD');
    require(ipfsHash != bytes32(0), 'NON_ZERO_IPFS_HASH');
    require(votingPortal != address(0), 'INVALID_VOTING_PORTAL');

    generateProposalPreviewLink(vm, payloads, ipfsHash, votingPortal);
    uint256 fee = GovernanceV3Ethereum.GOVERNANCE.getCancellationFee();
    console2.logBytes(
      abi.encodeWithSelector(
        IGovernanceCore.createProposal.selector,
        payloads,
        votingPortal,
        ipfsHash
      )
    );
    return
      GovernanceV3Ethereum.GOVERNANCE.createProposal{value: fee}(payloads, votingPortal, ipfsHash);
  }

  function _buildPayload(
    Vm vm,
    uint256 chainId,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    IPayloadsControllerCore payloadsController = getPayloadsController(chainId);
    (PayloadsControllerUtils.AccessControl accessLevel, uint40 payloadId) = _findAndValidatePayload(
      vm,
      chainId,
      payloadsController,
      actions
    );
    return
      PayloadsControllerUtils.Payload({
        chain: chainId,
        accessLevel: accessLevel,
        payloadsController: address(payloadsController),
        payloadId: payloadId
      });
  }

  function _buildPayload(
    Vm vm,
    uint256 chainId,
    IPayloadsControllerCore.ExecutionAction memory action
  ) internal returns (PayloadsControllerUtils.Payload memory) {
    IPayloadsControllerCore.ExecutionAction[]
      memory actions = new IPayloadsControllerCore.ExecutionAction[](1);
    actions[0] = action;
    return _buildPayload(vm, chainId, actions);
  }

  function _findAndValidatePayload(
    Vm vm,
    uint256 chainId,
    IPayloadsControllerCore payloadsController,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) private returns (PayloadsControllerUtils.AccessControl, uint40) {
    (uint256 prevFork, uint256 currentFork) = ChainHelpers.selectChain(vm, chainId);
    (uint40 payloadId, IPayloadsControllerCore.Payload memory payload) = _findPayloadId(
      payloadsController,
      actions
    );
    require(
      payload.state == IPayloadsControllerCore.PayloadState.Created,
      'MUST_BE_IN_CREATED_STATE'
    );
    require(payload.expirationTime >= block.timestamp, 'EXPIRATION_MUST_BE_IN_THE_FUTURE');
    if (prevFork != currentFork) {
      ChainHelpers.selectChain(vm, ChainIds.MAINNET);
    }
    return (payload.maximumAccessLevelRequired, payloadId);
  }

  function _findPayloadId(
    IPayloadsControllerCore payloadsController,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) private view returns (uint40, IPayloadsControllerCore.Payload memory) {
    uint40 count = payloadsController.getPayloadsCount();
    for (uint40 payloadId = count - 1; payloadId >= 0; payloadId--) {
      IPayloadsControllerCore.Payload memory payload = payloadsController.getPayloadById(payloadId);
      if (_actionsAreEqual(actions, payload.actions)) {
        return (payloadId, payload);
      }
    }
    revert CanNotFindPayload();
  }

  function _actionsAreEqual(
    IPayloadsControllerCore.ExecutionAction[] memory actionsA,
    IPayloadsControllerCore.ExecutionAction[] memory actionsB
  ) private pure returns (bool) {
    // must be equal size for equlity
    if (actionsA.length != actionsB.length) return false;
    for (uint256 actionId = 0; actionId < actionsA.length; actionId++) {
      if (actionsA[actionId].target != actionsB[actionId].target) return false;
      if (actionsA[actionId].withDelegateCall != actionsB[actionId].withDelegateCall) return false;
      if (actionsA[actionId].accessLevel != actionsB[actionId].accessLevel) return false;
      if (actionsA[actionId].value != actionsB[actionId].value) return false;
      if (
        keccak256(abi.encodePacked(actionsA[actionId].signature)) !=
        keccak256(abi.encodePacked(actionsB[actionId].signature))
      ) return false;
      if (keccak256(actionsA[actionId].callData) != keccak256(actionsB[actionId].callData))
        return false;
    }
    return true;
  }
}

library GovV3StorageHelpers {
  error LongBytesNotSupportedYet();

  uint256 constant PROPOSALS_COUNT_SLOT = 3;
  uint256 constant PROPOSALS_SLOT = 7;

  uint256 constant PAYLOADS_COUNT_SLOT = 1;
  uint256 constant ACCESS_LEVEL_TO_EXECUTOR_SLOT = 2;
  uint256 constant PAYLOADS_SLOT = 3;

  // enum State {
  //     Null, // proposal does not exists
  //     Created, // created, waiting for a cooldown to initiate the balances snapshot
  //     Active, // balances snapshot set, voting in progress
  //     Queued, // voting results submitted, but proposal is under grace period when guardian can cancel it
  //     Executed, // results sent to the execution chain(s)
  //     Failed, // voting was not successful
  //     Cancelled, // got cancelled by guardian, or because proposition power of creator dropped below allowed minimum
  //     Expired
  //   }
  // struct Proposal {
  //   State state; 0: 0-8
  //   PayloadsControllerUtils.AccessControl accessLevel; 0: 8-16
  //   uint40 creationTime; 0: 16-56
  //   uint24 votingDuration; 0: 56-96
  //   uint40 votingActivationTime; 0: 96-136
  //   uint40 queuingTime; 0: 136-176
  //   uint40 cancelTimestamp; 0: 176-216
  //   address creator; 1
  //   address votingPortal; 2
  //   bytes32 snapshotBlockHash; 3
  //   bytes32 ipfsHash; 4
  //   uint128 forVotes; 5: 0-128
  //   uint128 againstVotes; 5: 128-256
  //   uint256 cancellationFee; 6
  //   PayloadsControllerUtils.Payload[] payloads; 7
  // }
  // struct Payload {
  //   uint256 chain; 0
  //   AccessControl accessLevel; 1: 0-8
  //   address payloadsController; 1: 8-168 // address which holds the logic to execute after success proposal voting
  //   uint40 payloadId; 1: 168-208 // number of the payload placed to payloadsController, max is: ~10¹²
  // }

  function injectProposal(
    Vm vm,
    PayloadsControllerUtils.Payload[] memory payloads,
    address votingPortal
  ) internal returns (uint256) {
    uint256 count = GovernanceV3Ethereum.GOVERNANCE.getProposalsCount();
    uint256 proposalBaseSlot = StorageHelpers.getStorageSlotUintMapping(PROPOSALS_SLOT, count);

    // overwrite proposals count
    vm.store(
      address(GovernanceV3Ethereum.GOVERNANCE),
      bytes32(PROPOSALS_COUNT_SLOT),
      bytes32(uint256(count + 1))
    );
    // overwrite creator as creator porposition power is checked on execution
    vm.store(
      address(GovernanceV3Ethereum.GOVERNANCE),
      bytes32(proposalBaseSlot + 1),
      bytes32(uint256(uint160(MiscEthereum.ECOSYSTEM_RESERVE)))
    );
    // overwrite array size
    vm.store(
      address(GovernanceV3Ethereum.GOVERNANCE),
      bytes32(proposalBaseSlot + 7),
      bytes32(uint256(payloads.length))
    );
    // overwrite single array slots
    for (uint256 i = 0; i < payloads.length; i++) {
      bytes32 slot = bytes32(StorageHelpers.arrLocation(proposalBaseSlot + 7, i, 2));
      vm.store(address(GovernanceV3Ethereum.GOVERNANCE), slot, bytes32(payloads[i].chain));
      bytes32 storageBefore = vm.load(
        address(GovernanceV3Ethereum.GOVERNANCE),
        bytes32(uint256(slot) + 1)
      );
      // write target
      storageBefore = StorageHelpers.maskValueToBitsAtPosition(
        0,
        8,
        storageBefore,
        bytes32(uint256(uint8(payloads[i].accessLevel)))
      );
      // write delegateCall
      storageBefore = StorageHelpers.maskValueToBitsAtPosition(
        8,
        168,
        storageBefore,
        bytes32(uint256(uint160(payloads[i].payloadsController)))
      );
      // write accesslevel
      storageBefore = StorageHelpers.maskValueToBitsAtPosition(
        168,
        208,
        storageBefore,
        bytes32(uint256(payloads[i].payloadId))
      );
      // persist
      vm.store(address(GovernanceV3Ethereum.GOVERNANCE), bytes32(uint256(slot) + 1), storageBefore);
    }
    return count;
  }

  function readyProposal(Vm vm, uint256 proposalId) internal {
    uint256 proposalBaseSlot = StorageHelpers.getStorageSlotUintMapping(PROPOSALS_SLOT, proposalId);
    bytes32 storageBefore = vm.load(
      address(GovernanceV3Ethereum.GOVERNANCE),
      bytes32(proposalBaseSlot)
    );
    // set state
    storageBefore = StorageHelpers.maskValueToBitsAtPosition(
      0,
      8,
      storageBefore,
      bytes32(uint256(IGovernanceCore.State.Queued))
    );
    // set creation time
    storageBefore = StorageHelpers.maskValueToBitsAtPosition(
      16,
      56,
      storageBefore,
      bytes32(uint256(block.timestamp - GovernanceV3Ethereum.GOVERNANCE.PROPOSAL_EXPIRATION_TIME()))
    );
    vm.store(address(GovernanceV3Ethereum.GOVERNANCE), bytes32(proposalBaseSlot), storageBefore);
  }

  // ### PayoadsController Storage ###
  // struct Payload {
  //   address creator; 0: 160
  //   PayloadsControllerUtils.AccessControl maximumAccessLevelRequired; 0: 160-168
  //   PayloadState state; 0: 168-176
  //   uint40 createdAt; 0: 176-216
  //   uint40 queuedAt; 0: 216-256
  //   uint40 executedAt; 1: 40
  //   uint40 cancelledAt; 1: 40-80
  //   uint40 expirationTime; 1: 80-120
  //   uint40 delay; 1: 120-160
  //   uint40 gracePeriod; 1: 160-200
  //   ExecutionAction[] actions; 2: 0
  // }
  //
  // struct ExecutionAction {
  //   address target; 0: 160
  //   bool withDelegateCall; 0: 160-168
  //   PayloadsControllerUtils.AccessControl accessLevel; 0: 168-176
  //   uint256 value; 1:
  //   string signature; 2:
  //   bytes callData; 3:
  // }
  /**
   * Injects the payload into storage
   * @param vm Vm
   * @param payloadsController address
   * @param actions array of actions
   */
  function injectPayload(
    Vm vm,
    IPayloadsControllerCore payloadsController,
    IPayloadsControllerCore.ExecutionAction[] memory actions
  ) internal returns (uint40) {
    uint40 count = payloadsController.getPayloadsCount();
    uint256 payloadBaseSlot = StorageHelpers.getStorageSlotUintMapping(PAYLOADS_SLOT, count);

    // overwrite payloads count
    StorageHelpers.writeBitsInStorageSlot(
      vm,
      address(payloadsController),
      bytes32(PAYLOADS_COUNT_SLOT),
      176,
      216,
      bytes32(uint256(count + 1))
    );

    // overwrite payload state
    StorageHelpers.writeBitsInStorageSlot(
      vm,
      address(payloadsController),
      bytes32(payloadBaseSlot),
      168,
      176,
      bytes32(uint256(IPayloadsControllerCore.PayloadState.Created))
    );

    // overwrite expiration
    StorageHelpers.writeBitsInStorageSlot(
      vm,
      address(payloadsController),
      bytes32(payloadBaseSlot + 1),
      80,
      120,
      bytes32(uint256(block.timestamp + payloadsController.EXPIRATION_DELAY()))
    );

    // overwrite gracePeriod
    StorageHelpers.writeBitsInStorageSlot(
      vm,
      address(payloadsController),
      bytes32(payloadBaseSlot + 1),
      160,
      200,
      bytes32(uint256(payloadsController.GRACE_PERIOD()))
    );

    // overwrite array size
    vm.store(
      address(payloadsController),
      bytes32(payloadBaseSlot + 2),
      bytes32(uint256(actions.length))
    );

    // overwrite single array slots
    for (uint256 i = 0; i < actions.length; i++) {
      bytes32 slot = bytes32(StorageHelpers.arrLocation(payloadBaseSlot + 2, i, 4));
      bytes32 storageBefore = vm.load(address(payloadsController), slot);
      // write target
      storageBefore = StorageHelpers.maskValueToBitsAtPosition(
        0,
        160,
        storageBefore,
        bytes32(uint256(uint160(actions[i].target)))
      );
      // write delegateCall
      storageBefore = StorageHelpers.maskValueToBitsAtPosition(
        160,
        168,
        storageBefore,
        bytes32(toUInt256(actions[i].withDelegateCall))
      );
      // write accesslevel
      storageBefore = StorageHelpers.maskValueToBitsAtPosition(
        168,
        176,
        storageBefore,
        bytes32(uint256(actions[i].accessLevel))
      );
      // persist
      vm.store(address(payloadsController), slot, storageBefore);
      // write signatures
      if (bytes(actions[i].signature).length > 31) revert LongBytesNotSupportedYet();
      vm.store(
        address(payloadsController),
        bytes32(uint256(slot) + 2),
        bytes32(
          bytes.concat(
            bytes31(bytes(actions[i].signature)),
            bytes1(uint8(bytes(actions[i].signature).length * 2))
          )
        )
      );
    }
    return count;
  }

  /**
   * Alters storage in a way that makes the payload executable
   * @param vm Vm
   * @param payloadsController address
   * @param payloadId id of the payload
   */
  function readyPayloadId(
    Vm vm,
    IPayloadsControllerCore payloadsController,
    uint40 payloadId
  ) internal {
    IPayloadsControllerCore.Payload memory payload = payloadsController.getPayloadById(payloadId);
    require(payload.state != IPayloadsControllerCore.PayloadState.None, 'PAYLOAD DOES NOT EXIST');
    uint256 payloadBaseSlot = StorageHelpers.getStorageSlotUintMapping(PAYLOADS_SLOT, payloadId);
    bytes32 storageBefore = vm.load(address(payloadsController), bytes32(payloadBaseSlot));
    // write state
    storageBefore = StorageHelpers.maskValueToBitsAtPosition(
      168,
      176,
      storageBefore,
      bytes32(uint256(uint8(IPayloadsControllerCore.PayloadState.Queued)))
    );
    // write queuedAt
    storageBefore = StorageHelpers.maskValueToBitsAtPosition(
      216,
      256,
      storageBefore,
      bytes32(uint256(uint40(block.timestamp - payload.delay - 1)))
    );
    // persist
    vm.store(address(payloadsController), bytes32(payloadBaseSlot), storageBefore);
  }

  function toUInt256(bool x) internal pure returns (uint r) {
    assembly {
      r := x
    }
  }
}
