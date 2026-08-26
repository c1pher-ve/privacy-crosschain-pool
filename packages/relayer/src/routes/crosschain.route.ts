import { Router } from "express";
import {
  crosschainIntentStatusHandler,
  crosschainReclaimHandler,
  crosschainChainsHandler,
} from "../handlers/crosschain/index.js";

const crosschainRouter = Router();

crosschainRouter.get("/intent/:intentId", crosschainIntentStatusHandler);
crosschainRouter.post("/reclaim", crosschainReclaimHandler);
crosschainRouter.get("/chains", crosschainChainsHandler);

export { crosschainRouter };
