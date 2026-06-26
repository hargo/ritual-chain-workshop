/**
 * Real end-to-end demo of CommitRevealBounty on Ritual testnet (chain 1979).
 * Nothing is mocked: it deploys nothing new (uses the live contract), funds the
 * caller's RitualWallet, and triggers the genuine LLM precompile (0x0802) for
 * batch judging.
 *
 * Usage:
 *   set -a; source ../.ritual-secrets.env; set +a
 *   node --experimental-strip-types scripts/demo.ts
 *
 * Env overrides: BOUNTY_ADDRESS, SUBMIT_SECS, REVEAL_SECS, REWARD_ETH.
 */
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodePacked,
  http,
  keccak256,
  parseEther,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { buildJudgeAllLlmInput, computeCommitment } from "./judge.ts";

const RPC = "https://rpc.ritualfoundation.org";
const BOUNTY_ADDRESS = (process.env.BOUNTY_ADDRESS ??
  "0xFeFD74b301b41F9b67f17Db307f68527Db57a319") as Address;
const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948" as Address;
// Registered Ritual TEE executor (overridable). Live judging needs a currently
// online registered executor; see DEPLOYMENTS.md "Live run".
const EXECUTOR = (process.env.EXECUTOR ??
  "0xB42e435c4252A5a2E7440e37B609F00c61a0c91B") as Address;
const SUBMIT_SECS = BigInt(process.env.SUBMIT_SECS ?? "30");
const REVEAL_SECS = BigInt(process.env.REVEAL_SECS ?? "30");
const REWARD = parseEther(process.env.REWARD_ETH ?? "0.001");
const MIN_LLM_BALANCE = parseEther("0.05");
const LOCK_BLOCKS = 100_000n;

const ritual = defineChain({
  id: 1979,
  name: "Ritual",
  nativeCurrency: { name: "Ritual", symbol: "RITUAL", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});

const bountyAbi = [
  { type: "function", name: "createBounty", stateMutability: "payable", inputs: [{ type: "string" }, { type: "string" }, { type: "uint256" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "submitCommitment", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "bytes32" }], outputs: [] },
  { type: "function", name: "revealAnswer", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "string" }, { type: "bytes32" }], outputs: [] },
  { type: "function", name: "judgeAll", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "bytes" }], outputs: [] },
  { type: "function", name: "finalizeWinner", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [] },
  { type: "function", name: "nextBountyId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "getBounty", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [
    { type: "address" }, { type: "string" }, { type: "string" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "bool" }, { type: "bool" }, { type: "bool" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "bytes" },
  ] },
] as const;

const walletAbi = [
  { type: "function", name: "deposit", stateMutability: "payable", inputs: [{ type: "uint256" }], outputs: [] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "lockUntil", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const pk = process.env.DEPLOYER_PRIVATE_KEY as `0x${string}`;
  if (!pk) throw new Error("DEPLOYER_PRIVATE_KEY not set (source ../.ritual-secrets.env)");
  const account = privateKeyToAccount(pk);
  const wallet = createWalletClient({ account, chain: ritual, transport: http(RPC) });
  const pub = createPublicClient({ chain: ritual, transport: http(RPC) });
  console.log("caller:", account.address, "bounty:", BOUNTY_ADDRESS);

  const send = async (label: string, hash: `0x${string}`) => {
    const r = await pub.waitForTransactionReceipt({ hash });
    console.log(`  ${label}: ${hash} (block ${r.blockNumber}, status ${r.status})`);
    if (r.status !== "success") throw new Error(`${label} reverted`);
    return r;
  };

  const now = (await pub.getBlock()).timestamp;
  // Ritual reports block.timestamp in milliseconds; most EVMs use seconds. The
  // contract is unit-agnostic (deadlines are just compared to block.timestamp),
  // so detect the unit and express the windows in the chain's native unit.
  const UNIT = now > 1_000_000_000_000n ? 1000n : 1n;
  const submissionDeadline = now + SUBMIT_SECS * UNIT;
  const revealDeadline = now + (SUBMIT_SECS + REVEAL_SECS) * UNIT;

  console.log("1) createBounty");
  const id = await pub.readContract({ address: BOUNTY_ADDRESS, abi: bountyAbi, functionName: "nextBountyId" });
  await send("createBounty", await wallet.writeContract({
    address: BOUNTY_ADDRESS, abi: bountyAbi, functionName: "createBounty",
    args: ["Best gas tip", "Most concrete, correct gas saving wins.", submissionDeadline, revealDeadline],
    value: REWARD,
  }));
  console.log("   bountyId:", id);

  const answer = "Pack storage into one slot and use unchecked counters.";
  const salt = keccak256(encodePacked(["string", "uint256"], ["demo-salt", id]));
  const commitment = computeCommitment({ answer, salt, submitter: account.address, bountyId: id });

  console.log("2) submitCommitment (hash only)");
  await send("submitCommitment", await wallet.writeContract({
    address: BOUNTY_ADDRESS, abi: bountyAbi, functionName: "submitCommitment", args: [id, commitment],
  }));

  console.log(`3) wait for reveal window (~${SUBMIT_SECS}s)`);
  while ((await pub.getBlock()).timestamp < submissionDeadline + 1n) await sleep(3000);

  console.log("4) revealAnswer");
  await send("revealAnswer", await wallet.writeContract({
    address: BOUNTY_ADDRESS, abi: bountyAbi, functionName: "revealAnswer", args: [id, answer, salt],
  }));

  console.log("5) ensure RitualWallet funded AND locked for LLM inference");
  const [bal, lockUntil, curBlock] = await Promise.all([
    pub.readContract({ address: RITUAL_WALLET, abi: walletAbi, functionName: "balanceOf", args: [account.address] }),
    pub.readContract({ address: RITUAL_WALLET, abi: walletAbi, functionName: "lockUntil", args: [account.address] }),
    pub.getBlockNumber(),
  ]);
  const needFunds = bal < MIN_LLM_BALANCE;
  const needLock = lockUntil < curBlock + 300n; // lock must outlive the async callback
  if (needFunds || needLock) {
    const value = needFunds ? MIN_LLM_BALANCE : parseEther("0.001");
    console.log(`   depositing (funds:${needFunds} lock:${needLock})`);
    await send("deposit", await wallet.writeContract({
      address: RITUAL_WALLET, abi: walletAbi, functionName: "deposit", args: [LOCK_BLOCKS], value,
    }));
  } else {
    console.log("   already funded + locked. balance:", bal.toString());
  }

  console.log(`6) wait for reveal deadline (~${REVEAL_SECS}s)`);
  while ((await pub.getBlock()).timestamp < revealDeadline + 1n) await sleep(3000);

  console.log("7) judgeAll (real 0x0802 batch inference)");
  const llmInput = buildJudgeAllLlmInput({
    executorAddress: EXECUTOR,
    title: "Best gas tip",
    rubric: "Most concrete, correct gas saving wins.",
    submissions: [{ index: 0, submitter: account.address, answer }],
  });
  await send("judgeAll", await wallet.writeContract({
    address: BOUNTY_ADDRESS, abi: bountyAbi, functionName: "judgeAll", args: [id, llmInput],
  }));

  const view = await pub.readContract({ address: BOUNTY_ADDRESS, abi: bountyAbi, functionName: "getBounty", args: [id] });
  console.log("   aiReview bytes:", ((view[12] as string).length - 2) / 2);

  console.log("8) finalizeWinner(0)");
  await send("finalizeWinner", await wallet.writeContract({
    address: BOUNTY_ADDRESS, abi: bountyAbi, functionName: "finalizeWinner", args: [id, 0n],
  }));

  console.log("DONE: full create -> commit -> reveal -> judge -> finalize on Ritual.");
}

main().catch((e) => {
  console.error("demo failed:", e instanceof Error ? e.message : e);
  process.exit(1);
});
