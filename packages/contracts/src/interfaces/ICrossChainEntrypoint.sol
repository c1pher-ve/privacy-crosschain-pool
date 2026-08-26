// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from '@oz/interfaces/IERC20.sol';

import {CrossChainProofLib} from '../contracts/lib/CrossChainProofLib.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

/**
 * @title ICrossChainVerifier
 * @notice Interface for the Groth16 verifier for CrossChainBurn proofs (9 public signals)
 */
interface ICrossChainVerifier {
  /**
   * @notice Verifies a CrossChainBurn proof
   * @param _pA First elliptic curve point (π_A)
   * @param _pB Second elliptic curve point (π_B)
   * @param _pC Third elliptic curve point (π_C)
   * @param _pubSignals The 9 public signals
   * @return _valid Whether the proof is valid
   */
  function verifyProof(
    uint256[2] memory _pA,
    uint256[2][2] memory _pB,
    uint256[2] memory _pC,
    uint256[9] memory _pubSignals
  ) external returns (bool _valid);
}

/**
 * @title ICrossChainEntrypoint
 * @notice Interface for cross-chain privacy pool operations
 * @dev Extends the existing Entrypoint with burn/mint cross-chain flow.
 *      Amount is a public signal. Identity is fully private.
 */
interface ICrossChainEntrypoint {
  /*///////////////////////////////////////////////////////////////
                              STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Tracks a cross-chain burn intent for timeout/reclaim purposes
   * @param amount The amount burned (from proof public signal)
   * @param newCommitmentHash The commitment hash to be minted on the destination chain
   * @param nullifierHash The nullifier hash spent on the source chain
   * @param dstChainId The intended destination chain ID
   * @param scope The source pool scope
   * @param expiry Block timestamp after which the intent can be reclaimed
   * @param delivered Whether the mint has been confirmed on the destination chain
   */
  struct CrossChainIntent {
    uint256 amount;
    uint256 newCommitmentHash;
    uint256 nullifierHash;
    uint256 dstChainId;
    uint256 scope;
    uint256 expiry;
    bool delivered;
  }

  /*///////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a commitment is burned for cross-chain transfer
   * @dev NOTE: No depositor address is emitted — this is by design for privacy.
   * @param _intentId Unique identifier for this cross-chain intent
   * @param _nullifierHash Hash of the spent nullifier (cannot be traced to identity)
   * @param _newCommitmentHash Hash of the commitment to mint on destination (cannot be traced to recipient)
   * @param _amount The transfer amount (publicly visible)
   * @param _dstChainId The destination chain ID
   * @param _scope The source pool scope
   */
  event CrossChainBurnExecuted(
    bytes32 indexed _intentId,
    uint256 _nullifierHash,
    uint256 _newCommitmentHash,
    uint256 _amount,
    uint256 _dstChainId,
    uint256 _scope
  );

  /**
   * @notice Emitted when a cross-chain commitment is minted on the destination chain
   * @param _deliveryHash Unique hash for this delivery
   * @param _newCommitmentHash The commitment hash inserted into the destination pool
   * @param _amount The minted amount
   * @param _srcChainId The source chain ID
   */
  event CrossChainMintExecuted(
    bytes32 indexed _deliveryHash,
    uint256 _newCommitmentHash,
    uint256 _amount,
    uint256 _srcChainId
  );

  /**
   * @notice Emitted when an expired cross-chain intent is reclaimed
   * @param _intentId The intent that was reclaimed
   * @param _amount The amount refunded
   */
  event CrossChainReclaimed(bytes32 indexed _intentId, uint256 _amount);

  /**
   * @notice Emitted when a source chain state root is synced
   * @param _srcChainId The source chain ID
   * @param _root The synced state root
   * @param _index The storage index
   */
  event SourceRootSynced(uint256 _srcChainId, uint256 _root, uint256 _index);

  /**
   * @notice Emitted when a cross-chain peer is registered
   * @param _chainId The peer chain ID
   * @param _entrypoint The peer entrypoint address
   */
  event PeerRegistered(uint256 _chainId, address _entrypoint);

  /**
   * @notice Emitted when a remote scope mapping is registered
   * @param _srcChainId The source chain ID
   * @param _srcScope The scope ID on the source chain
   * @param _localScope The scope ID on this local chain
   */
  event PeerScopeRegistered(uint256 _srcChainId, uint256 _srcScope, uint256 _localScope);

  /*///////////////////////////////////////////////////////////////
                              ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the cross-chain intent has already been delivered
  error IntentAlreadyDelivered();

  /// @notice Thrown when trying to reclaim before the intent has expired
  error IntentNotExpired();

  /// @notice Thrown when the intent does not exist
  error IntentNotFound();

  /// @notice Thrown when the synced source root does not match the proof
  error InvalidSourceRoot();

  /// @notice Thrown when dstChainId in the proof does not match the current chain
  error InvalidDstChainId();

  /// @notice Thrown when the peer is not registered for a given chain ID
  error PeerNotRegistered();

  /// @notice Thrown when a remote scope is not mapped to a local scope
  error PeerScopeNotRegistered();

  /// @notice Thrown when the caller is not an authorized keeper
  error OnlyKeeper();

  /// @notice Thrown when the destination pool lacks sufficient liquidity
  error InsufficientPoolLiquidity();

  /// @notice Thrown when the cross-chain nullifier has already been used (replay)
  error CrossChainNullifierAlreadyUsed();

  /// @notice Thrown when trying to burn to the same chain
  error CannotBurnToSameChain();

  /// @notice Thrown when the cross-chain burn verifier is not configured
  error CrossChainVerifierNotSet();

  /// @notice Thrown when the withdrawn value is zero
  error InvalidCrossChainAmount();

  /*///////////////////////////////////////////////////////////////
                              LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Burns a commitment on this chain for cross-chain transfer
   * @dev The proof is verified, nullifier is marked as spent, and an intent is created.
   *      The relayer will pick up the emitted event and carry the proof to the destination chain.
   *      No depositor address is included in the event — identity stays private.
   * @param _withdrawal The withdrawal data structure (processooor must be this contract)
   * @param _proof The CrossChainBurn proof with 9 public signals
   * @param _scope The source pool scope
   */
  function burnCrossChain(
    IPrivacyPool.Withdrawal calldata _withdrawal,
    CrossChainProofLib.CrossChainBurnProof calldata _proof,
    uint256 _scope
  ) external;

  /**
   * @notice Mints a commitment on this chain from a verified cross-chain burn
   * @dev Called by the relayer with the same proof that was submitted on the source chain.
   *      The contract verifies the proof against the synced source chain state root.
   *      The relayer cannot forge proofs — they are verified on-chain.
   * @param _proof The CrossChainBurn proof (same as used on source chain)
   * @param _srcChainId The source chain ID where the burn occurred
   * @param _srcScope The source pool scope
   */
  function mintCrossChain(
    CrossChainProofLib.CrossChainBurnProof calldata _proof,
    uint256 _srcChainId,
    uint256 _srcScope
  ) external;

  /**
   * @notice Reclaim funds from an expired cross-chain intent
   * @dev Only callable after the timeout period if the intent was not delivered.
   *      The caller must be able to prove ownership (submit the proof again or be the original caller).
   * @param _intentId The intent ID to reclaim
   */
  function reclaimExpired(bytes32 _intentId) external;

  /**
   * @notice Sync a source chain state root (called by keeper)
   * @param _srcChainId The source chain ID
   * @param _root The state root to sync
   */
  function syncSourceRoot(uint256 _srcChainId, uint256 _root) external;

  /**
   * @notice Register a trusted peer entrypoint on another chain
   * @param _chainId The peer chain ID
   * @param _entrypoint The peer entrypoint address
   */
  function setPeer(uint256 _chainId, address _entrypoint) external;

  /**
   * @notice Maps a remote pool scope to a local pool scope
   * @param _srcChainId The source chain ID
   * @param _srcScope The scope ID on the source chain
   * @param _localScope The scope ID on this local chain
   */
  function setPeerScope(uint256 _srcChainId, uint256 _srcScope, uint256 _localScope) external;

  /*///////////////////////////////////////////////////////////////
                              VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns cross-chain intent data
   * @param _intentId The intent ID
   * @return _amount The intent amount
   * @return _newCommitmentHash The commitment hash
   * @return _nullifierHash The nullifier hash
   * @return _dstChainId The destination chain ID
   * @return _scope The source pool scope
   * @return _expiry The expiry timestamp
   * @return _delivered Whether the intent was delivered
   */
  function crossChainIntents(bytes32 _intentId)
    external
    view
    returns (
      uint256 _amount,
      uint256 _newCommitmentHash,
      uint256 _nullifierHash,
      uint256 _dstChainId,
      uint256 _scope,
      uint256 _expiry,
      bool _delivered
    );

  /**
   * @notice Returns whether a cross-chain nullifier has been used
   * @param _nullifierHash The nullifier hash
   * @return _used Whether it has been used
   */
  function crossChainNullifiers(uint256 _nullifierHash) external view returns (bool _used);

  /**
   * @notice Returns the peer entrypoint for a given chain ID
   * @param _chainId The chain ID
   * @return _entrypoint The peer entrypoint address
   */
  function peers(uint256 _chainId) external view returns (address _entrypoint);

  /**
   * @notice Returns the local scope mapped to a peer's remote scope
   * @param _srcChainId The peer source chain ID
   * @param _srcScope The peer remote scope ID
   * @return _localScope The mapped local scope ID
   */
  function peerScopes(uint256 _srcChainId, uint256 _srcScope) external view returns (uint256 _localScope);
}
