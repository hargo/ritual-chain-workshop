import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { network } from "hardhat";
import { encodePacked, keccak256, parseEther } from "viem";
import { buildJudgeAllLlmInput, computeCommitment } from "../scripts/judge.ts";

/**
 * End-to-end lifecycle test on an in-process EVM, plus the critical guarantee
 * that the off-chain encoder (scripts/judge.ts) reproduces the contract's
 * commitment scheme byte-for-byte. If these ever diverge, honest participants
 * could never reveal — so this is asserted directly against the deployed
 * contract's `computeCommitment`.
 */
describe("CommitRevealBounty lifecycle", async () => {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const testClient = await viem.getTestClient();
  const [owner, alice] = await viem.getWalletClients();

  it("create -> commit -> reveal, with off-chain/on-chain commitment parity", async () => {
    const bounty = await viem.deployContract("CommitRevealBounty");

    const now = (await publicClient.getBlock()).timestamp;
    const submissionDeadline = now + 3_600n;
    const revealDeadline = now + 7_200n;

    await bounty.write.createBounty(
      ["Best gas optimization", "Most gas saved wins.", submissionDeadline, revealDeadline],
      { value: parseEther("1"), account: owner.account },
    );
    const bountyId = 1n;

    const answer = "Use unchecked loops and pack storage slots.";
    const salt = keccak256(encodePacked(["string"], ["alice-salt"]));

    // Parity: the encoder MUST agree with the contract.
    const offchain = computeCommitment({
      answer,
      salt,
      submitter: alice.account.address,
      bountyId,
    });
    const onchain = await bounty.read.computeCommitment([
      answer,
      salt,
      alice.account.address,
      bountyId,
    ]);
    assert.equal(offchain, onchain, "off-chain encoder must match on-chain commitment scheme");

    // Commit (hash only — answer stays hidden).
    await bounty.write.submitCommitment([bountyId, offchain], { account: alice.account });
    const beforeReveal = await bounty.read.getSubmission([bountyId, 0n]);
    assert.equal(beforeReveal[2], false, "should not be revealed yet");
    assert.equal(beforeReveal[3], "", "plaintext must be hidden during submission");

    // Enter the reveal window.
    await testClient.setNextBlockTimestamp({ timestamp: submissionDeadline + 1n });
    await testClient.mine({ blocks: 1 });

    // Reveal and verify.
    await bounty.write.revealAnswer([bountyId, answer, salt], { account: alice.account });
    const afterReveal = await bounty.read.getSubmission([bountyId, 0n]);
    assert.equal(afterReveal[0].toLowerCase(), alice.account.address.toLowerCase());
    assert.equal(afterReveal[2], true, "should be revealed");
    assert.equal(afterReveal[3], answer, "revealed answer should be stored");

    const view = await bounty.read.getBounty([bountyId]);
    assert.equal(view[10], 1n, "revealedCount should be 1");
  });

  it("builds a non-empty batch LLM request payload", () => {
    const input = buildJudgeAllLlmInput({
      executorAddress: owner.account.address,
      title: "Best gas optimization",
      rubric: "Most gas saved wins.",
      submissions: [
        { index: 0, submitter: alice.account.address, answer: "answer A" },
        { index: 1, submitter: owner.account.address, answer: "answer B" },
      ],
    });
    assert.ok(input.startsWith("0x"), "llmInput is hex");
    assert.ok(input.length > 2, "llmInput is non-empty");
  });
});
