/**
 * Root synchronization service.
 * Periodically reads state roots from source chains and pushes them
 * to destination chains via the CrossChainEntrypoint.syncSourceRoot() function.
 *
 * This is public data — no privacy leak. The roots are already publicly
 * available on-chain. We're just syncing them cross-chain so the destination
 * contract can verify proofs against the source chain state.
 */
import { Address, Abi } from "viem";
import { CONFIG, getCrossChainEntrypointAddress } from "../config/index.js";
import { web3Provider } from "../providers/index.js";

// ABI fragment for reading roots and syncing
const ROOT_SYNC_ABI = [
  {
    type: "function",
    name: "currentRoot",
    inputs: [],
    outputs: [{ name: "_root", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "syncSourceRoot",
    inputs: [
      { name: "_srcChainId", type: "uint256" },
      { name: "_root", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
] as const;

// ABI for reading from the PrivacyPool (state root)
const PRIVACY_POOL_ABI = [
  {
    type: "function",
    name: "currentRoot",
    inputs: [],
    outputs: [{ name: "_root", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

/**
 * Service that synchronizes state roots across chains.
 * Runs on a timer (cron-like) to keep destination chains updated.
 */
export class RootSyncService {
  private intervalHandle: ReturnType<typeof setInterval> | null = null;
  private syncIntervalMs: number;

  /**
   * @param syncIntervalMs - How often to sync roots (default: 15 minutes)
   */
  constructor(syncIntervalMs: number = 15 * 60 * 1000) {
    this.syncIntervalMs = syncIntervalMs;
  }

  /**
   * Starts the periodic root sync process.
   * For each chain pair, reads the source chain's current root
   * and pushes it to all other chains.
   */
  start(): void {
    console.log(
      `[RootSync] Starting root sync service (interval: ${this.syncIntervalMs / 1000}s)`,
    );

    // Run immediately on start
    this.syncAllRoots().catch((err) =>
      console.error("[RootSync] Initial sync failed:", err),
    );

    // Then run on interval
    this.intervalHandle = setInterval(async () => {
      try {
        await this.syncAllRoots();
      } catch (err) {
        console.error("[RootSync] Periodic sync failed:", err);
      }
    }, this.syncIntervalMs);
  }

  /**
   * Stops the periodic root sync process.
   */
  stop(): void {
    if (this.intervalHandle) {
      clearInterval(this.intervalHandle);
      this.intervalHandle = null;
      console.log("[RootSync] Root sync service stopped");
    }
  }

  /**
   * Performs a single round of root synchronization.
   * For each configured chain, reads its current root and pushes it
   * to all other configured chains.
   */
  async syncAllRoots(): Promise<void> {
    const chainConfigs = CONFIG.chains;

    // Gather all chain IDs that have cross-chain entrypoints configured
    const crossChainIds: number[] = [];
    for (const chain of chainConfigs) {
      const ccAddress = getCrossChainEntrypointAddress(chain.chain_id);
      if (ccAddress) {
        crossChainIds.push(chain.chain_id);
      }
    }

    if (crossChainIds.length < 2) {
      console.log("[RootSync] Less than 2 cross-chain enabled chains, skipping sync");
      return;
    }

    console.log(`[RootSync] Syncing roots across ${crossChainIds.length} chains: [${crossChainIds.join(", ")}]`);

    // For each source chain, read its root and push to all destinations
    for (const srcChainId of crossChainIds) {
      try {
        const root = await this.readCurrentRoot(srcChainId);
        if (root === 0n) {
          console.log(`[RootSync] Chain ${srcChainId} has zero root, skipping`);
          continue;
        }

        // Push to all other chains
        for (const dstChainId of crossChainIds) {
          if (dstChainId === srcChainId) continue;

          try {
            await this.pushRoot(srcChainId, dstChainId, root);
            console.log(
              `[RootSync] Synced root from chain ${srcChainId} → chain ${dstChainId}: ${root}`,
            );
          } catch (err) {
            console.error(
              `[RootSync] Failed to sync root from ${srcChainId} → ${dstChainId}:`,
              err,
            );
          }
        }
      } catch (err) {
        console.error(`[RootSync] Failed to read root from chain ${srcChainId}:`, err);
      }
    }
  }

  /**
   * Reads the current state root from a chain's CrossChainEntrypoint (or pool).
   */
  private async readCurrentRoot(chainId: number): Promise<bigint> {
    const ccEntrypoint = getCrossChainEntrypointAddress(chainId);
    if (!ccEntrypoint) {
      throw new Error(`No cross-chain entrypoint for chain ${chainId}`);
    }

    const client = web3Provider.client(chainId);

    // Read the latest root from the entrypoint
    const root = await client.readContract({
      address: ccEntrypoint as Address,
      abi: ROOT_SYNC_ABI as Abi,
      functionName: "currentRoot",
    });

    return BigInt(root as string);
  }

  /**
   * Pushes a source chain root to a destination chain.
   */
  private async pushRoot(
    srcChainId: number,
    dstChainId: number,
    root: bigint,
  ): Promise<void> {
    const ccEntrypoint = getCrossChainEntrypointAddress(dstChainId);
    if (!ccEntrypoint) {
      throw new Error(`No cross-chain entrypoint for chain ${dstChainId}`);
    }

    const signer = web3Provider.signer(dstChainId);

    const hash = await signer.writeContract({
      address: ccEntrypoint as Address,
      abi: ROOT_SYNC_ABI as Abi,
      functionName: "syncSourceRoot",
      args: [BigInt(srcChainId), root],
    });

    // Wait for confirmation
    await web3Provider.client(dstChainId).waitForTransactionReceipt({ hash });
  }
}
