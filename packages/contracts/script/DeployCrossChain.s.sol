// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script, console} from 'forge-std/Script.sol';
import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';

import {CrossChainEntrypoint} from 'contracts/CrossChainEntrypoint.sol';

/**
 * @title DeployCrossChain
 * @notice Foundry deployment script for the CrossChainEntrypoint
 * @dev Deploys a UUPS proxy with the CrossChainEntrypoint implementation.
 *
 * Usage:
 *   forge script script/DeployCrossChain.s.sol:DeployCrossChainScript \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 *
 * Required environment variables:
 *   DEPLOYER_PRIVATE_KEY     - Private key for deployment
 *   OWNER_ADDRESS            - Owner address (gets OWNER_ROLE)
 *   POSTMAN_ADDRESS          - ASP postman address (gets ASP_POSTMAN role)
 *   KEEPER_ADDRESS           - Keeper address for state root syncing (gets KEEPER_ROLE)
 *   CC_BURN_VERIFIER_ADDRESS - Address of the deployed CrossChainBurn Groth16 verifier
 *
 * Optional environment variables (for peer registration):
 *   PEER_CHAIN_IDS           - Comma-separated chain IDs (e.g., "1,42161,10,137,56")
 *   PEER_ENTRYPOINTS         - Comma-separated entrypoint addresses (same order as chain IDs)
 */
contract DeployCrossChainScript is Script {
  function run() external {
    // Read deployment parameters from environment
    uint256 _deployerKey = vm.envUint('DEPLOYER_PRIVATE_KEY');
    address _owner = vm.envAddress('OWNER_ADDRESS');
    address _postman = vm.envAddress('POSTMAN_ADDRESS');
    address _keeper = vm.envAddress('KEEPER_ADDRESS');
    address _ccBurnVerifier = vm.envAddress('CC_BURN_VERIFIER_ADDRESS');

    vm.startBroadcast(_deployerKey);

    // 1. Deploy implementation
    CrossChainEntrypoint _implementation = new CrossChainEntrypoint();
    console.log('CrossChainEntrypoint implementation deployed at:', address(_implementation));

    // 2. Encode initializer calldata
    bytes memory _initData = abi.encodeCall(
      CrossChainEntrypoint.initializeCrossChain,
      (_owner, _postman, _keeper, _ccBurnVerifier)
    );

    // 3. Deploy UUPS proxy
    ERC1967Proxy _proxy = new ERC1967Proxy(address(_implementation), _initData);
    console.log('CrossChainEntrypoint proxy deployed at:', address(_proxy));

    // 4. Optionally register peers
    try vm.envString('PEER_CHAIN_IDS') returns (string memory _chainIdsStr) {
      // If PEER_CHAIN_IDS is set, register peers
      // Note: In production, use a more robust parsing approach
      console.log('Peer registration should be done manually via setPeer() calls');
      console.log('PEER_CHAIN_IDS provided:', _chainIdsStr);
    } catch {
      console.log('No PEER_CHAIN_IDS set, skipping peer registration');
    }

    vm.stopBroadcast();

    // Log summary
    console.log('\n=== Deployment Summary ===');
    console.log('Chain ID:        ', block.chainid);
    console.log('Implementation:  ', address(_implementation));
    console.log('Proxy:           ', address(_proxy));
    console.log('Owner:           ', _owner);
    console.log('Postman:         ', _postman);
    console.log('Keeper:          ', _keeper);
    console.log('Burn Verifier:   ', _ccBurnVerifier);
  }
}
