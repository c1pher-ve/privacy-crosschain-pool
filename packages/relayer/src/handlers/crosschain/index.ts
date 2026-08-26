import { Request, Response, NextFunction } from "express";
import { CrossChainRelayerService } from "../../services/crosschain.service.js";

const crosschainService = new CrossChainRelayerService();

/**
 * Handler for GET /crosschain/intent/:intentId
 * Retrieves the status of a cross-chain intent.
 */
export async function crosschainIntentStatusHandler(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<void> {
  try {
    const { intentId } = req.params;
    const chainIdStr = req.query.chainId as string;

    if (!intentId) {
      res.status(400).json({ error: "Missing intentId parameter" });
      return;
    }

    if (!chainIdStr) {
      res.status(400).json({ error: "Missing chainId query parameter" });
      return;
    }

    const chainId = parseInt(chainIdStr, 10);
    if (isNaN(chainId)) {
      res.status(400).json({ error: "Invalid chainId parameter" });
      return;
    }

    const record = await crosschainService.getIntentStatus(intentId, chainId);
    res.json(record);
  } catch (error) {
    next(error);
  }
}

/**
 * Handler for POST /crosschain/reclaim
 * Triggers reclaim for an expired cross-chain intent.
 */
export async function crosschainReclaimHandler(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<void> {
  try {
    const { intentId, chainId } = req.body;

    if (!intentId || !chainId) {
      res.status(400).json({ error: "Missing intentId or chainId in body" });
      return;
    }

    const result = await crosschainService.triggerReclaim(intentId, Number(chainId));
    res.json({ success: true, txHash: result.hash });
  } catch (error) {
    next(error);
  }
}

/**
 * Handler for GET /crosschain/chains
 * Returns supported cross-chain configurations.
 */
export async function crosschainChainsHandler(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<void> {
  try {
    res.json({
      supportedChains: [
        { chainId: 1, name: "Ethereum Mainnet" },
        { chainId: 42161, name: "Arbitrum One" },
        { chainId: 10, name: "OP Mainnet" },
        { chainId: 137, name: "Polygon POS" },
        { chainId: 56, name: "BNB Smart Chain" },
      ],
    });
  } catch (error) {
    next(error);
  }
}
