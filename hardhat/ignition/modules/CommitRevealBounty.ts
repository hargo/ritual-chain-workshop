import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Deploys the required-track CommitRevealBounty.
 *   npx hardhat ignition deploy --network ritual ignition/modules/CommitRevealBounty.ts
 */
export default buildModule("CommitRevealBountyModule", (m) => {
  const commitRevealBounty = m.contract("CommitRevealBounty");
  return { commitRevealBounty };
});
