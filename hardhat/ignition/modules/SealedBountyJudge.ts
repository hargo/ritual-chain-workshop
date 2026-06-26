import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Deploys the advanced-track SealedBountyJudge.
 *   npx hardhat ignition deploy --network ritual ignition/modules/SealedBountyJudge.ts
 */
export default buildModule("SealedBountyJudgeModule", (m) => {
  const sealedBountyJudge = m.contract("SealedBountyJudge");
  return { sealedBountyJudge };
});
