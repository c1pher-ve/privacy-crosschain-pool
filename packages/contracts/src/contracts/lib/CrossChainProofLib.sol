// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @title CrossChainProofLib
 * @notice Facilitates accessing the public signals of a CrossChainBurn Groth16 proof.
 * @dev Mirrors ProofLib but supports 9 public signals (adds dstChainId).
 */
library CrossChainProofLib {
  /*///////////////////////////////////////////////////////////////
                       CROSS-CHAIN BURN PROOF 
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Struct containing Groth16 proof elements and public signals for cross-chain burn verification
   * @dev The public signals array must match the order of public inputs/outputs in the CrossChainBurn circuit
   * @param pA First elliptic curve point (π_A) of the Groth16 proof
   * @param pB Second elliptic curve point (π_B) of the Groth16 proof
   * @param pC Third elliptic curve point (π_C) of the Groth16 proof
   * @param pubSignals Array of public inputs and outputs:
   *        - [0] newCommitmentHash: Hash of the new commitment for the destination chain
   *        - [1] existingNullifierHash: Hash of the nullifier being spent on source chain
   *        - [2] withdrawnValue: Amount being transferred cross-chain (PUBLIC)
   *        - [3] stateRoot: Source chain state root at time of proof generation
   *        - [4] stateTreeDepth: Source chain state tree depth
   *        - [5] ASPRoot: Source chain ASP root
   *        - [6] ASPTreeDepth: Source chain ASP tree depth
   *        - [7] context: Context binding the proof to specific withdrawal data
   *        - [8] dstChainId: Destination chain ID (prevents cross-chain replay)
   */
  struct CrossChainBurnProof {
    uint256[2] pA;
    uint256[2][2] pB;
    uint256[2] pC;
    uint256[9] pubSignals;
  }

  /**
   * @notice Retrieves the new commitment hash from the proof's public signals
   * @dev This commitment will be inserted into the destination chain's state tree
   * @param _p The proof containing the public signals
   * @return The hash of the new commitment for the destination chain
   */
  function newCommitmentHash(CrossChainBurnProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[0];
  }

  /**
   * @notice Retrieves the existing nullifier hash from the proof's public signals
   * @dev This nullifier is marked as spent on the source chain
   * @param _p The proof containing the public signals
   * @return The hash of the nullifier being spent
   */
  function existingNullifierHash(CrossChainBurnProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[1];
  }

  /**
   * @notice Retrieves the withdrawn value from the proof's public signals
   * @dev This is the amount being transferred cross-chain (publicly visible)
   * @param _p The proof containing the public signals
   * @return The amount being transferred
   */
  function withdrawnValue(CrossChainBurnProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[2];
  }

  /**
   * @notice Retrieves the source chain state root from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The source chain state root at time of proof generation
   */
  function stateRoot(CrossChainBurnProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[3];
  }

  /**
   * @notice Retrieves the state tree depth from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The depth of the source chain state tree
   */
  function stateTreeDepth(CrossChainBurnProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[4];
  }

  /**
   * @notice Retrieves the ASP root from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The source chain ASP root
   */
  function ASPRoot(CrossChainBurnProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[5];
  }

  /**
   * @notice Retrieves the ASP tree depth from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The depth of the source chain ASP tree
   */
  function ASPTreeDepth(CrossChainBurnProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[6];
  }

  /**
   * @notice Retrieves the context value from the proof's public signals
   * @param _p The proof containing the public signals
   * @return The context value binding the proof to specific withdrawal data
   */
  function context(CrossChainBurnProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[7];
  }

  /**
   * @notice Retrieves the destination chain ID from the proof's public signals
   * @dev Used to prevent replay attacks — proof can only be used on the intended destination chain
   * @param _p The proof containing the public signals
   * @return The destination EVM chain ID
   */
  function dstChainId(CrossChainBurnProof memory _p) internal pure returns (uint256) {
    return _p.pubSignals[8];
  }
}
