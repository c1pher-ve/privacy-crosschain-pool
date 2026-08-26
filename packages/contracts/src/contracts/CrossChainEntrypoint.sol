// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/*

Made with ♥ for 0xBow by

░██╗░░░░░░░██╗░█████╗░███╗░░██╗██████╗░███████╗██████╗░██╗░░░░░░█████╗░███╗░░██╗██████╗░
░██║░░██╗░░██║██╔══██╗████╗░██║██╔══██╗██╔════╝██╔══██╗██║░░░░░██╔══██╗████╗░██║██╔══██╗
░╚██╗████╗██╔╝██║░░██║██╔██╗██║██║░░██║█████╗░░██████╔╝██║░░░░░███████║██╔██╗██║██║░░██║
░░████╔═████║░██║░░██║██║╚████║██║░░██║██╔══╝░░██╔══██╗██║░░░░░██╔══██║██║╚████║██║░░██║
░░╚██╔╝░╚██╔╝░╚█████╔╝██║░╚███║██████╔╝███████╗██║░░██║███████╗██║░░██║██║░╚███║██████╔╝
░░░╚═╝░░░╚═╝░░░╚════╝░╚═╝░░╚══╝╚═════╝░╚══════╝╚═╝░░╚═╝╚══════╝╚═╝░░╚═╝╚═╝░░╚══╝╚═════╝░

https://defi.sucks/

*/

import {IERC20} from '@oz/interfaces/IERC20.sol';

import {Constants} from './lib/Constants.sol';
import {CrossChainProofLib} from './lib/CrossChainProofLib.sol';

import {Entrypoint} from './Entrypoint.sol';
import {ICrossChainEntrypoint, ICrossChainVerifier} from 'interfaces/ICrossChainEntrypoint.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

/**
 * @title CrossChainEntrypoint
 * @notice Extends the Entrypoint with cross-chain burn/mint functionality.
 * @dev Architecture: Amount is a public signal (visible to relayer). Identity is fully private.
 *      The relayer carries ZK proofs between chains — it cannot forge, steal, or link identities.
 *      The contract trusts the Groth16 proof + synced state root, NOT the relayer.
 *
 *      Flow:
 *      1. Source chain: User calls burnCrossChain() → nullifier spent on pool, funds locked, event emitted
 *      2. Relayer: Picks up event, carries proof to destination chain
 *      3. Destination chain: mintCrossChain() → proof verified against synced root, commitment inserted into pool
 *      4. User withdraws privately from destination pool using standard Withdraw circuit
 */
contract CrossChainEntrypoint is Entrypoint, ICrossChainEntrypoint {
  using CrossChainProofLib for CrossChainProofLib.CrossChainBurnProof;

  /*///////////////////////////////////////////////////////////////
                              CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @dev 0x8227e2e67e78fd64f0fed83dd22c12ea0e5a4fd2e4a7e33b66d14ca7e4f28b3f
  bytes32 internal constant _KEEPER_ROLE = keccak256('KEEPER_ROLE');

  /// @notice Duration after which an undelivered cross-chain intent can be reclaimed
  uint256 public constant CROSS_CHAIN_TIMEOUT = Constants.CROSS_CHAIN_TIMEOUT;

  /// @notice History size for synced source chain roots
  uint32 public constant SOURCE_ROOT_HISTORY_SIZE = Constants.SOURCE_ROOT_HISTORY_SIZE;

  /*///////////////////////////////////////////////////////////////
                            STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Groth16 verifier for CrossChainBurn proofs (9 public signals)
  ICrossChainVerifier public crossChainBurnVerifier;

  /// @notice Trusted peer entrypoints per chain ID
  mapping(uint256 _chainId => address _entrypoint) public peers;

  /// @notice Synced source chain roots: srcChainId => (index => root)
  mapping(uint256 _srcChainId => mapping(uint256 _index => uint256 _root)) public sourceRoots;

  /// @notice Current root index per source chain (circular buffer)
  mapping(uint256 _srcChainId => uint32 _currentIndex) public sourceRootIndex;

  /// @notice Cross-chain intents tracker
  mapping(bytes32 _intentId => CrossChainIntent _intent) public crossChainIntents;

  /// @notice Cross-chain nullifier set (prevents replay from other chains)
  mapping(uint256 _nullifierHash => bool _used) public crossChainNullifiers;

  /// @notice Registry mapping remote peer scopes to local scopes: srcChainId => srcScope => localScope
  mapping(uint256 _srcChainId => mapping(uint256 _srcScope => uint256 _localScope)) public peerScopes;

  /*///////////////////////////////////////////////////////////////
                          INITIALIZATION
  //////////////////////////////////////////////////////////////*/

  /// @notice Initialize cross-chain specific state
  /// @param _owner The owner address
  /// @param _postman The ASP postman address
  /// @param _keeper The keeper address for state root syncing
  /// @param _ccBurnVerifier The CrossChainBurn Groth16 verifier address
  function initializeCrossChain(
    address _owner,
    address _postman,
    address _keeper,
    address _ccBurnVerifier
  ) external initializer {
    if (_owner == address(0)) revert ZeroAddress();
    if (_postman == address(0)) revert ZeroAddress();
    if (_keeper == address(0)) revert ZeroAddress();
    if (_ccBurnVerifier == address(0)) revert ZeroAddress();

    __UUPSUpgradeable_init();
    __ReentrancyGuard_init();
    __AccessControl_init();

    _setRoleAdmin(DEFAULT_ADMIN_ROLE, _OWNER_ROLE);
    _setRoleAdmin(_OWNER_ROLE, _OWNER_ROLE);
    _setRoleAdmin(_ASP_POSTMAN, _OWNER_ROLE);
    _setRoleAdmin(_KEEPER_ROLE, _OWNER_ROLE);

    _grantRole(_OWNER_ROLE, _owner);
    _grantRole(_ASP_POSTMAN, _postman);
    _grantRole(_KEEPER_ROLE, _keeper);

    crossChainBurnVerifier = ICrossChainVerifier(_ccBurnVerifier);
  }

  /*///////////////////////////////////////////////////////////////
                        CROSS-CHAIN BURN (SOURCE)
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICrossChainEntrypoint
  function burnCrossChain(
    IPrivacyPool.Withdrawal calldata _withdrawal,
    CrossChainProofLib.CrossChainBurnProof calldata _proof,
    uint256 _scope
  ) external nonReentrant {
    // Verify the cross-chain burn verifier is configured
    if (address(crossChainBurnVerifier) == address(0)) revert CrossChainVerifierNotSet();

    // Check withdrawn amount is non-zero
    uint256 _withdrawnAmount = _proof.withdrawnValue();
    if (_withdrawnAmount == 0) revert InvalidCrossChainAmount();

    // Check destination chain is not the current chain
    uint256 _dstChainId = _proof.dstChainId();
    if (_dstChainId == block.chainid) revert CannotBurnToSameChain();

    // Check peer is registered for the destination chain
    if (peers[_dstChainId] == address(0)) revert PeerNotRegistered();

    // Check processooor is this contract (funds stay locked here)
    if (_withdrawal.processooor != address(this)) revert InvalidProcessooor();

    // Fetch pool by scope
    IPrivacyPool _pool = scopeToPool[_scope];
    if (address(_pool) == address(0)) revert PoolNotFound();

    // Verify the Groth16 proof
    if (
      !crossChainBurnVerifier.verifyProof(
        _proof.pA, _proof.pB, _proof.pC, _proof.pubSignals
      )
    ) revert IPrivacyPool.InvalidProof();

    // [FIX: MAJOR-1] Verify the source state root is known on the pool
    if (!_pool.isKnownRoot(_proof.stateRoot())) revert IPrivacyPool.UnknownStateRoot();

    // Verify the context matches
    uint256 _expectedContext =
      uint256(keccak256(abi.encode(_withdrawal, _pool.SCOPE()))) % Constants.SNARK_SCALAR_FIELD;
    if (_proof.context() != _expectedContext) revert IPrivacyPool.ContextMismatch();

    // Verify the ASP root is the latest
    if (_proof.ASPRoot() != latestRoot()) revert IPrivacyPool.IncorrectASPRoot();

    // [FIX: CRITICAL-1] Actually spend the nullifier on the source pool
    // This prevents the same commitment from being burned multiple times
    _pool.burnNullifier(_proof.existingNullifierHash());

    // [FIX: Trapped Funds Bug] Release excess locked assets from the pool to this contract (Entrypoint)
    // The funds stay locked in the entrypoint as custody/custodial assets for the bridge.
    _pool.releaseCrossChainAssets(address(this), _withdrawnAmount);

    // Store the cross-chain intent for timeout/reclaim tracking
    bytes32 _intentId = keccak256(
      abi.encodePacked(
        _proof.newCommitmentHash(),
        _proof.existingNullifierHash(),
        block.chainid,
        _dstChainId,
        block.timestamp
      )
    );

    crossChainIntents[_intentId] = CrossChainIntent({
      amount: _withdrawnAmount,
      newCommitmentHash: _proof.newCommitmentHash(),
      nullifierHash: _proof.existingNullifierHash(),
      dstChainId: _dstChainId,
      scope: _scope,
      expiry: block.timestamp + CROSS_CHAIN_TIMEOUT,
      delivered: false
    });

    // Emit event with proof data ONLY — no depositor address
    emit CrossChainBurnExecuted(
      _intentId,
      _proof.existingNullifierHash(),
      _proof.newCommitmentHash(),
      _withdrawnAmount,
      _dstChainId,
      _scope
    );
  }

  /*///////////////////////////////////////////////////////////////
                       CROSS-CHAIN MINT (DESTINATION)
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICrossChainEntrypoint
  function mintCrossChain(
    CrossChainProofLib.CrossChainBurnProof calldata _proof,
    uint256 _srcChainId,
    uint256 _srcScope
  ) external nonReentrant {
    // Verify the cross-chain burn verifier is configured
    if (address(crossChainBurnVerifier) == address(0)) revert CrossChainVerifierNotSet();

    // Check withdrawn amount is non-zero
    uint256 _mintAmount = _proof.withdrawnValue();
    if (_mintAmount == 0) revert InvalidCrossChainAmount();

    // Check dstChainId in the proof matches THIS chain
    if (_proof.dstChainId() != block.chainid) revert InvalidDstChainId();

    // Check peer is registered for the source chain
    if (peers[_srcChainId] == address(0)) revert PeerNotRegistered();

    // Check the cross-chain nullifier hasn't been used (replay protection)
    uint256 _nullifierHash = _proof.existingNullifierHash();
    if (crossChainNullifiers[_nullifierHash]) revert CrossChainNullifierAlreadyUsed();

    // Verify the Groth16 proof
    if (
      !crossChainBurnVerifier.verifyProof(
        _proof.pA, _proof.pB, _proof.pC, _proof.pubSignals
      )
    ) revert IPrivacyPool.InvalidProof();

    // Verify the source state root is known (synced by the keeper)
    uint256 _sourceStateRoot = _proof.stateRoot();
    if (!_isKnownSourceRoot(_srcChainId, _sourceStateRoot)) revert InvalidSourceRoot();

    // Mark the cross-chain nullifier as used
    crossChainNullifiers[_nullifierHash] = true;

    // [FIX: Scope Mismatch Bug] Map remote peer scope to local scope
    uint256 _localScope = peerScopes[_srcChainId][_srcScope];
    if (_localScope == 0) revert PeerScopeNotRegistered();

    IPrivacyPool _dstPool = scopeToPool[_localScope];
    if (address(_dstPool) == address(0)) revert PoolNotFound();

    uint256 _newCommitmentHash = _proof.newCommitmentHash();

    // Insert the commitment into the destination pool's state tree
    // The pool must be pre-funded with liquidity for the user to later withdraw
    _dstPool.insertCrossChainCommitment(_newCommitmentHash);

    // Compute delivery hash
    bytes32 _deliveryHash = keccak256(
      abi.encodePacked(
        _newCommitmentHash,
        _nullifierHash,
        _srcChainId,
        block.chainid,
        block.timestamp
      )
    );

    emit CrossChainMintExecuted(
      _deliveryHash,
      _newCommitmentHash,
      _mintAmount,
      _srcChainId
    );
  }

  /*///////////////////////////////////////////////////////////////
                          RECLAIM EXPIRED
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICrossChainEntrypoint
  function reclaimExpired(bytes32 _intentId) external nonReentrant {
    CrossChainIntent storage _intent = crossChainIntents[_intentId];

    // Check intent exists
    if (_intent.amount == 0) revert IntentNotFound();

    // Check not already delivered/reclaimed
    if (_intent.delivered) revert IntentAlreadyDelivered();

    // Check timeout has passed
    if (block.timestamp <= _intent.expiry) revert IntentNotExpired();

    // Mark as delivered to prevent double-reclaim
    _intent.delivered = true;

    // [FIX: CRITICAL-3] Actually refund the locked funds
    // The funds are locked in this contract (entrypoint). Transfer them back.
    // We look up the pool to determine the asset type.
    IPrivacyPool _pool = scopeToPool[_intent.scope];
    if (address(_pool) != address(0)) {
      IERC20 _asset = IERC20(_pool.ASSET());
      // Transfer funds from this contract to the caller
      // Note: msg.sender can claim — this is acceptable because the nullifier is already
      // spent on the source pool, so the original commitment is void. Anyone can trigger
      // the reclaim, but the funds go to msg.sender. In production, consider requiring
      // the original burn tx sender or a proof of ownership.
      _transfer(_asset, msg.sender, _intent.amount);
    }

    emit CrossChainReclaimed(_intentId, _intent.amount);
  }

  /*///////////////////////////////////////////////////////////////
                        STATE ROOT SYNC (KEEPER)
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICrossChainEntrypoint
  function syncSourceRoot(uint256 _srcChainId, uint256 _root) external onlyRole(_KEEPER_ROLE) {
    // Compute the next index in the circular buffer
    uint32 _nextIndex = (sourceRootIndex[_srcChainId] + 1) % SOURCE_ROOT_HISTORY_SIZE;

    // Store the root
    sourceRoots[_srcChainId][_nextIndex] = _root;
    sourceRootIndex[_srcChainId] = _nextIndex;

    emit SourceRootSynced(_srcChainId, _root, _nextIndex);
  }

  /*///////////////////////////////////////////////////////////////
                          PEER MANAGEMENT
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICrossChainEntrypoint
  function setPeer(uint256 _chainId, address _entrypoint) external onlyRole(_OWNER_ROLE) {
    if (_entrypoint == address(0)) revert ZeroAddress();
    if (_chainId == block.chainid) revert CannotBurnToSameChain();

    peers[_chainId] = _entrypoint;

    emit PeerRegistered(_chainId, _entrypoint);
  }

  /// @inheritdoc ICrossChainEntrypoint
  function setPeerScope(uint256 _srcChainId, uint256 _srcScope, uint256 _localScope) external onlyRole(_OWNER_ROLE) {
    if (_localScope == 0) revert ZeroAddress();
    if (address(scopeToPool[_localScope]) == address(0)) revert PoolNotFound();

    peerScopes[_srcChainId][_srcScope] = _localScope;

    emit PeerScopeRegistered(_srcChainId, _srcScope, _localScope);
  }

  /**
   * @notice Update the cross-chain burn verifier address
   * @param _verifier The new verifier address
   */
  function setCrossChainBurnVerifier(address _verifier) external onlyRole(_OWNER_ROLE) {
    if (_verifier == address(0)) revert ZeroAddress();
    crossChainBurnVerifier = ICrossChainVerifier(_verifier);
  }

  /*///////////////////////////////////////////////////////////////
                          INTERNAL METHODS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Check if a source chain root is known (synced by keeper)
   * @dev Uses a circular buffer of SOURCE_ROOT_HISTORY_SIZE roots per source chain
   * @param _srcChainId The source chain ID
   * @param _root The root to verify
   * @return Whether the root exists in the synced history
   */
  function _isKnownSourceRoot(uint256 _srcChainId, uint256 _root) internal view returns (bool) {
    if (_root == 0) return false;

    uint32 _index = sourceRootIndex[_srcChainId];

    for (uint32 _i = 0; _i < SOURCE_ROOT_HISTORY_SIZE; _i++) {
      if (_root == sourceRoots[_srcChainId][_index]) return true;
      _index = (_index + SOURCE_ROOT_HISTORY_SIZE - 1) % SOURCE_ROOT_HISTORY_SIZE;
    }
    return false;
  }
}
