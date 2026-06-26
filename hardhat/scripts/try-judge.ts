/**
 * Retry judgeAll on an EXISTING revealed-but-unjudged bounty (no deadline wait).
 * Used to iterate on the real Ritual LLM precompile encoding.
 *
 *   set -a; source ../.ritual-secrets.env; set +a
 *   BOUNTY_ID=2 CONVO="inline,," node --experimental-strip-types scripts/try-judge.ts
 */
import { createPublicClient, createWalletClient, defineChain, http, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { buildJudgeAllLlmInput, type JudgeSubmission, type StorageRef } from "./judge.ts";

const RPC = "https://rpc.ritualfoundation.org";
const BOUNTY = (process.env.BOUNTY_ADDRESS ?? "0xFeFD74b301b41F9b67f17Db307f68527Db57a319") as Address;
const BOUNTY_ID = BigInt(process.env.BOUNTY_ID ?? "2");
const EXECUTOR = (process.env.EXECUTOR ?? "0xB42e435c4252A5a2E7440e37B609F00c61a0c91B") as Address;
const convo = (process.env.CONVO ?? "inline,,").split(",") as StorageRef;

const ritual = defineChain({
  id: 1979, name: "Ritual",
  nativeCurrency: { name: "Ritual", symbol: "RITUAL", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});

const abi = [
  { type: "function", name: "judgeAll", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "bytes" }], outputs: [] },
  { type: "function", name: "submissionCount", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "getBounty", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [
    { type: "address" }, { type: "string" }, { type: "string" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "bool" }, { type: "bool" }, { type: "bool" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "bytes" },
  ] },
  { type: "function", name: "getSubmission", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [
    { type: "address" }, { type: "bytes32" }, { type: "bool" }, { type: "string" },
  ] },
] as const;

async function main() {
  const account = privateKeyToAccount(process.env.DEPLOYER_PRIVATE_KEY as `0x${string}`);
  const wallet = createWalletClient({ account, chain: ritual, transport: http(RPC) });
  const pub = createPublicClient({ chain: ritual, transport: http(RPC) });

  const b = await pub.readContract({ address: BOUNTY, abi, functionName: "getBounty", args: [BOUNTY_ID] });
  const [, title, rubric, , , , judged] = b;
  console.log(`bounty ${BOUNTY_ID}: judged=${judged} convo=${JSON.stringify(convo)}`);
  if (judged) { console.log("already judged"); return; }

  const count = await pub.readContract({ address: BOUNTY, abi, functionName: "submissionCount", args: [BOUNTY_ID] });
  const subs: JudgeSubmission[] = [];
  for (let i = 0n; i < count; i++) {
    const [submitter, , revealed, answer] = await pub.readContract({ address: BOUNTY, abi, functionName: "getSubmission", args: [BOUNTY_ID, i] });
    if (revealed) subs.push({ index: Number(i), submitter, answer });
  }
  console.log(`revealed submissions: ${subs.length}`);

  const llmInput = buildJudgeAllLlmInput({ executorAddress: EXECUTOR, title, rubric, submissions: subs, convoHistory: convo });

  try {
    const hash = await wallet.writeContract({ address: BOUNTY, abi, functionName: "judgeAll", args: [BOUNTY_ID, llmInput] });
    const r = await pub.waitForTransactionReceipt({ hash });
    console.log(`judgeAll: ${hash} status=${r.status} block=${r.blockNumber}`);
    if (r.status === "success") {
      const after = await pub.readContract({ address: BOUNTY, abi, functionName: "getBounty", args: [BOUNTY_ID] });
      console.log(`aiReview bytes: ${((after[12] as string).length - 2) / 2}`);
    }
  } catch (e) {
    console.error("judgeAll reverted:", e instanceof Error ? e.message.split("\n")[0] : e);
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
