/**
 * Cross-chain relayer service.
 * Monitors CrossChainBurnExecuted events on source chains,
 * delivers proofs to destination chains, and tracks intent status.
 *
 * Privacy guarantee: The relayer sees only ZK proof + public signals.
 * It does NOT know who deposited or who will withdraw.
 */
import { Address, Abi, getAddress, Log, decodeEventLog } from "viem";
import {
  getChainConfig,
  getCrossChainEntrypointAddress,
  getSignerPrivateKey,
} from "../config/index.js";
import { web3Provider } from "../providers/index.js";
import { CrossChainIntentStatus, CrossChainIntentRecord } from "../types.js";

// ABI fragment for CrossChainEntrypoint events and functions
const CROSS_CHAIN_ABI = [
  {
    type: "event",
    name: "CrossChainBurnExecuted",
    inputs: [
      { name: "_intentId", type: "bytes32", indexed: true },
      { name: "_nullifierHash", type: "uint256", indexed: false },
      { name: "_newCommitmentHash", type: "uint256", indexed: false },
      { name: "_amount", type: "uint256", indexed: false },
      { name: "_dstChainId", type: "uint256", indexed: false },
      { name: "_scope", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "CrossChainMintExecuted",
    inputs: [
      { name: "_deliveryHash", type: "bytes32", indexed: true },
      { name: "_newCommitmentHash", type: "uint256", indexed: false },
      { name: "_amount", type: "uint256", indexed: false },
      { name: "_srcChainId", type: "uint256", indexed: false },
    ],
  },
  {
    type: "function",
    name: "crossChainIntents",
    inputs: [{ name: "_intentId", type: "bytes32" }],
    outputs: [
      { name: "_amount", type: "uint256" },
      { name: "_newCommitmentHash", type: "uint256" },
      { name: "_nullifierHash", type: "uint256" },
      { name: "_dstChainId", type: "uint256" },
      { name: "_scope", type: "uint256" },
      { name: "_expiry", type: "uint256" },
      { name: "_delivered", type: "bool" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "mintCrossChain",
    inputs: [
      {
        name: "_proof",
        type: "tuple",
        components: [
          { name: "pA", type: "uint256[2]" },
          { name: "pB", type: "uint256[2][2]" },
          { name: "pC", type: "uint256[2]" },
          { name: "pubSignals", type: "uint256[9]" },
        ],
      },
      { name: "_srcChainId", type: "uint256" },
      { name: "_srcScope", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "reclaimExpired",
    inputs: [{ name: "_intentId", type: "bytes32" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

/**
 * Cross-chain relayer service.
 * Monitors burn events and delivers proofs across chains.
 */
export class CrossChainRelayerService {
  private activeListeners: Map<number, () => void> = new Map();

  /**
   * Starts monitoring CrossChainBurnExecuted events on a source chain.
   * When a burn event is detected, the service automatically delivers the proof
   * to the destination chain.
   *
   * @param srcChainId - The source chain ID to monitor
   */
  async monitorBurns(srcChainId: number): Promise<void> {
    const ccEntrypoint = getCrossChainEntrypointAddress(srcChainId);
    if (!ccEntrypoint) {
      console.warn(`[CrossChain] No cross-chain entrypoint configured for chain ${srcChainId}`);
      return;
    }

    const client = web3Provider.client(srcChainId);

    console.log(`[CrossChain] Starting burn monitor on chain ${srcChainId} at ${ccEntrypoint}`);

    const unwatch = client.watchEvent({
      address: ccEntrypoint as Address,
      event: {
        type: "event",
        name: "CrossChainBurnExecuted",
        inputs: [
          { name: "_intentId", type: "bytes32", indexed: true },
          { name: "_nullifierHash", type: "uint256", indexed: false },
          { name: "_newCommitmentHash", type: "uint256", indexed: false },
          { name: "_amount", type: "uint256", indexed: false },
          { name: "_dstChainId", type: "uint256", indexed: false },
          { name: "_scope", type: "uint256", indexed: false },
        ],
      },
      onLogs: async (logs) => {
        for (const log of logs) {
          try {
            await this.handleBurnEvent(srcChainId, log);
          } catch (error) {
            console.error(`[CrossChain] Error handling burn event:`, error);
          }
        }
      },
    });

    this.activeListeners.set(srcChainId, unwatch);
  }

  /**
   * Stops monitoring burns on a specific chain.
   *
   * @param srcChainId - The chain ID to stop monitoring
   */
  stopMonitoring(srcChainId: number): void {
    const unwatch = this.activeListeners.get(srcChainId);
    if (unwatch) {
      unwatch();
      this.activeListeners.delete(srcChainId);
      console.log(`[CrossChain] Stopped burn monitor on chain ${srcChainId}`);
    }
  }

  /**
   * Reads a cross-chain intent's status from the source chain contract.
   *
   * @param intentId - The intent ID (bytes32 hex string)
   * @param chainId - The chain ID where the intent was created
   * @returns The intent status
   */
  async getIntentStatus(intentId: string, chainId: number): Promise<CrossChainIntentRecord> {
    const ccEntrypoint = getCrossChainEntrypointAddress(chainId);
    if (!ccEntrypoint) {
      throw new Error(`No cross-chain entrypoint configured for chain ${chainId}`);
    }

    const client = web3Provider.client(chainId);

    const result = await client.readContract({
      address: ccEntrypoint as Address,
      abi: CROSS_CHAIN_ABI as Abi,
      functionName: "crossChainIntents",
      args: [intentId as `0x${string}`],
    });

    const [amount, newCommitmentHash, nullifierHash, dstChainId, scope, expiry, delivered] =
      result as [bigint, bigint, bigint, bigint, bigint, bigint, boolean];

    // Determine status
    let status: CrossChainIntentStatus;
    if (amount === 0n) {
      status = "pending"; // Intent not found or zero — treat as pending
    } else if (delivered) {
      status = "delivered";
    } else if (BigInt(Math.floor(Date.now() / 1000)) > expiry) {
      status = "expired";
    } else {
      status = "pending";
    }

    return {
      intentId,
      nullifierHash: nullifierHash.toString(),
      newCommitmentHash: newCommitmentHash.toString(),
      amount: amount.toString(),
      srcChainId: chainId,
      dstChainId: Number(dstChainId),
      expiry: Number(expiry),
      status,
    };
  }

  /**
   * Delivers a cross-chain burn proof to the destination chain.
   * Called by the relayer when a CrossChainBurnExecuted event is detected.
   *
   * @param proof - The CrossChainBurnProof struct (pA, pB, pC, pubSignals)
   * @param srcChainId - Source chain where the burn occurred
   * @param dstChainId - Destination chain where the mint should happen
   * @param srcScope - Source pool scope
   * @returns Transaction hash of the mint transaction
   */
  async deliverProof(
    proof: {
      pA: [bigint, bigint];
      pB: [[bigint, bigint], [bigint, bigint]];
      pC: [bigint, bigint];
      pubSignals: bigint[];
    },
    srcChainId: number,
    dstChainId: number,
    srcScope: bigint,
  ): Promise<{ hash: string }> {
    const ccEntrypoint = getCrossChainEntrypointAddress(dstChainId);
    if (!ccEntrypoint) {
      throw new Error(`No cross-chain entrypoint configured for chain ${dstChainId}`);
    }

    const signer = web3Provider.signer(dstChainId);

    console.log(
      `[CrossChain] Delivering proof from chain ${srcChainId} to chain ${dstChainId}`,
    );

    const hash = await signer.writeContract({
      address: ccEntrypoint as Address,
      abi: CROSS_CHAIN_ABI as Abi,
      functionName: "mintCrossChain",
      args: [proof, BigInt(srcChainId), srcScope],
    });

    console.log(`[CrossChain] Mint tx submitted: ${hash}`);

    // Wait for confirmation
    await web3Provider.client(dstChainId).waitForTransactionReceipt({ hash });

    console.log(`[CrossChain] Mint tx confirmed: ${hash}`);

    return { hash };
  }

  /**
   * Triggers reclaim of an expired cross-chain intent.
   *
   * @param intentId - The intent ID to reclaim
   * @param chainId - The chain where the intent exists
   * @returns Transaction hash
   */
  async triggerReclaim(intentId: string, chainId: number): Promise<{ hash: string }> {
    const ccEntrypoint = getCrossChainEntrypointAddress(chainId);
    if (!ccEntrypoint) {
      throw new Error(`No cross-chain entrypoint configured for chain ${chainId}`);
    }

    const signer = web3Provider.signer(chainId);

    const hash = await signer.writeContract({
      address: ccEntrypoint as Address,
      abi: CROSS_CHAIN_ABI as Abi,
      functionName: "reclaimExpired",
      args: [intentId as `0x${string}`],
    });

    await web3Provider.client(chainId).waitForTransactionReceipt({ hash });

    console.log(`[CrossChain] Reclaim tx confirmed: ${hash}`);

    return { hash };
  }

  /**
   * Handles a single CrossChainBurnExecuted event.
   * Extracts the proof from the transaction and delivers it to the destination.
   *
   * @param srcChainId - Source chain ID
   * @param log - The event log
   */
  private async handleBurnEvent(srcChainId: number, log: Log): Promise<void> {
    const decoded = decodeEventLog({
      abi: CROSS_CHAIN_ABI,
      data: log.data,
      topics: log.topics,
    });

    const args = decoded.args as {
      _intentId: string;
      _nullifierHash: bigint;
      _newCommitmentHash: bigint;
      _amount: bigint;
      _dstChainId: bigint;
      _scope: bigint;
    };

    console.log(
      `[CrossChain] Burn detected on chain ${srcChainId}: intent=${args._intentId}, ` +
        `amount=${args._amount}, dst=${args._dstChainId}`,
    );

    // NOTE: To deliver the proof, we need the full proof data (pA, pB, pC, pubSignals).
    // The event only contains public signals. The full proof must be retrieved from
    // the transaction input data. This requires decoding the original burnCrossChain() call.
    //
    // For now, we log the event. A full implementation would:
    // 1. Read the transaction input from log.transactionHash
    // 2. Decode the calldata to extract the full proof
    // 3. Call deliverProof() with the extracted data
    //
    // This is left as a TODO because the exact calldata decoding depends on the ABI.

    if (log.transactionHash) {
      console.log(
        `[CrossChain] Source tx: ${log.transactionHash}. ` +
          `Proof delivery to chain ${args._dstChainId} requires tx calldata decoding.`,
      );
    }
  }
}
