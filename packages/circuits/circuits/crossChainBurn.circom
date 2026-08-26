pragma circom 2.2.0;

include "./commitment.circom";
include "./merkleTree.circom";
include "../../../node_modules/circomlib/circuits/comparators.circom";

/**
 * @title CrossChainBurn template
 * @dev Template for burning a commitment on the source chain for cross-chain transfer.
 *      Identical to Withdraw but adds dstChainId as a public signal to prevent
 *      replay attacks across chains. The proof can be verified on the destination
 *      chain to authorize minting a mirrored commitment.
 * @param maxTreeDepth The maximum depth of the Merkle trees
 */
template CrossChainBurn(maxTreeDepth) {

  //////////////////////// PUBLIC SIGNALS ////////////////////////

  // Signals to compute commitments
  signal input withdrawnValue;                   // Value being transferred cross-chain (PUBLIC — visible to relayer)

  // Signals for merkle tree inclusion proofs
  signal input stateRoot;                        // A known state root on the source chain
  signal input stateTreeDepth;                   // Current state tree depth
  signal input ASPRoot;                          // Latest ASP root
  signal input ASPTreeDepth;                     // Current ASP tree depth
  signal input context;                          // keccak256(IPrivacyPool.Withdrawal, scope) % SNARK_SCALAR_FIELD

  // Cross-chain binding signal
  signal input dstChainId;                       // Destination EVM chain ID — prevents replay on wrong chain

  //////////////////// END OF PUBLIC SIGNALS ////////////////////


  /////////////////////// PRIVATE SIGNALS ///////////////////////

  // Signals to compute commitments
  signal input label;                            // keccak256(scope, nonce) % SNARK_SCALAR_FIELD
  signal input existingValue;                    // Value of the existing commitment
  signal input existingNullifier;                // Nullifier of the existing commitment
  signal input existingSecret;                   // Secret of the existing commitment
  signal input newNullifier;                     // Nullifier for the new commitment (on destination chain)
  signal input newSecret;                        // Secret for the new commitment (on destination chain)

  // Signals for merkle tree inclusion proofs
  signal input stateSiblings[maxTreeDepth];      // Siblings of the state tree
  signal input stateIndex;                       // Indices for the state tree
  signal input ASPSiblings[maxTreeDepth];        // Siblings of the ASP tree
  signal input ASPIndex;                         // Indices for the ASP tree

  /////////////////// END OF PRIVATE SIGNALS ///////////////////


  /////////////////////// OUTPUT SIGNALS ///////////////////////

  signal output newCommitmentHash;               // Hash of new commitment (to be inserted on destination chain)
  signal output existingNullifierHash;           // Hash of the existing commitment nullifier (spent on source chain)

  /////////////////// END OF OUTPUT SIGNALS ///////////////////

  // 1. Compute existing commitment
  component existingCommitmentHasher = CommitmentHasher();
  existingCommitmentHasher.value <== existingValue;
  existingCommitmentHasher.label <== label;
  existingCommitmentHasher.nullifier <== existingNullifier;
  existingCommitmentHasher.secret <== existingSecret;
  signal existingCommitment <== existingCommitmentHasher.commitment;

  // 2. Output existing nullifier hash
  existingNullifierHash <== existingCommitmentHasher.nullifierHash;

  // 3. Verify existing commitment is in state tree
  component stateRootChecker = LeanIMTInclusionProof(maxTreeDepth);
  stateRootChecker.leaf <== existingCommitment;
  stateRootChecker.leafIndex <== stateIndex;
  stateRootChecker.siblings <== stateSiblings;
  stateRootChecker.actualDepth <== stateTreeDepth;

  stateRoot === stateRootChecker.out;

  // 4. Verify label is in ASP tree
  component ASPRootChecker = LeanIMTInclusionProof(maxTreeDepth);
  ASPRootChecker.leaf <== label;
  ASPRootChecker.leafIndex <== ASPIndex;
  ASPRootChecker.siblings <== ASPSiblings;
  ASPRootChecker.actualDepth <== ASPTreeDepth;

  ASPRoot === ASPRootChecker.out;

  // 5. Enforce full transfer: the entire commitment value must be transferred cross-chain.
  //    Partial cross-chain burns are not supported because the "change" commitment would
  //    need to remain on the source chain, but the nullifier is already spent.
  //    For partial transfers, users should first do a regular withdrawal to split their
  //    commitment, then burn the desired amount cross-chain.
  signal remainingValue <== existingValue - withdrawnValue;
  remainingValue === 0;

  // 6. Range check withdrawnValue to ensure it fits in 128 bits
  component withdrawnValueRangeCheck = Num2Bits(128);
  withdrawnValueRangeCheck.in <== withdrawnValue;
  _ <== withdrawnValueRangeCheck.out;

  // 7. Check existing and new nullifier don't match
  component nullifierEqualityCheck = IsEqual();
  nullifierEqualityCheck.in[0] <== existingNullifier; 
  nullifierEqualityCheck.in[1] <== newNullifier; 
  nullifierEqualityCheck.out === 0;

  // 8. Compute new commitment for the DESTINATION chain using withdrawnValue (= existingValue)
  component newCommitmentHasher = CommitmentHasher();
  newCommitmentHasher.value <== withdrawnValue;
  newCommitmentHasher.label <== label;
  newCommitmentHasher.nullifier <== newNullifier;
  newCommitmentHasher.secret <== newSecret;

  // 9. Output new commitment hash
  newCommitmentHash <== newCommitmentHasher.commitment;
  _ <== newCommitmentHasher.nullifierHash;

  // 10. Bind context for integrity (same as Withdraw)
  signal contextSquared <== context * context;

  // 11. Bind dstChainId into the proof — prevents replaying this proof on a different destination chain
  signal dstChainIdSquared <== dstChainId * dstChainId;
}
