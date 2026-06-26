# Privacy-Preserving AI Bounty Judge

A bounty system where **submissions stay hidden until judging is complete**, then
every answer is scored in a **single batch call** to an AI judge running inside
Ritual's TEE-backed LLM precompile. Built on the
[`cozfuttu/ritual-chain-workshop`](https://github.com/cozfuttu/ritual-chain-workshop)
starter and deployed live on **Ritual testnet (chain `1979`)**.

> **The flaw we fix.** The workshop's `AIJudge` took answers in **plaintext**
> (`submitAnswer(bountyId, answer)`) and even had its submission-deadline check
> commented out. Anyone could read a pending answer, copy the good ideas, and
> submit a better version before the deadline — unfair when only one entrant can
> win. This repo closes that hole two ways.

| Track | Contract | What is hidden | Until |
| --- | --- | --- | --- |
| **Required** — Commit-Reveal | [`CommitRevealBounty.sol`](hardhat/contracts/CommitRevealBounty.sol) | the answer (only a hash is on-chain) | the reveal phase |
| **Advanced** — Ritual-native Sealed | [`SealedBountyJudge.sol`](hardhat/contracts/SealedBountyJudge.sol) | the plaintext entirely (only ciphertext on-chain) | decrypted inside the TEE at judging; audited afterwards |

Live addresses + transaction hashes: [`DEPLOYMENTS.md`](DEPLOYMENTS.md).

---

## Required track lifecycle

```
 createBounty        submitCommitment      revealAnswer         judgeAll           finalizeWinner
 (escrow reward)     (hash only)           (answer + salt)      (1 batch LLM)      (human picks)
      │                    │                    │                    │                   │
      ▼                    ▼                    ▼                    ▼                   ▼
┌──────────┐ commit  ┌──────────┐ reveal  ┌──────────┐ judge  ┌──────────┐        ┌───────────┐
│ CREATED  │─phase──▶│  COMMIT  │─phase──▶│  REVEAL  │─phase─▶│  JUDGED  │───────▶│ FINALIZED │
└──────────┘ t<S     └──────────┘ S≤t<R   └──────────┘ t≥R    └──────────┘        └───────────┘
                                                                    │
                                                        no reveals  ▼
                                                              ┌───────────┐
                                                              │ CANCELLED │ (refund owner)
                                                              └───────────┘
```

1. **`createBounty(title, rubric, submissionDeadline, revealDeadline)`** *(payable)* —
   the owner escrows the prize and sets the two deadlines (`submission < reveal`).
2. **`submitCommitment(bountyId, commitment)`** — during the commit phase each
   entrant publishes **only** a hash. One commitment per address.
3. **`revealAnswer(bountyId, answer, salt)`** — during the reveal phase the entrant
   reveals the plaintext and salt. The contract recomputes the hash and accepts the
   reveal only if it matches. **Only matching reveals are eligible for judging.**
4. **`judgeAll(bountyId, llmInput)`** — after the reveal phase the owner sends **one**
   LLM precompile call that scores all revealed answers as a batch. The completion is
   stored as advisory `aiReview`.
5. **`finalizeWinner(bountyId, winnerIndex)`** — the owner (a human) selects the
   winning revealed answer and the reward is paid. `cancelBounty` refunds the owner
   if nobody revealed.

### The commitment scheme

```solidity
commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
```

- **`salt`** makes short answers impossible to brute-force.
- **`msg.sender`** binds the commitment to one address, so a copycat who reposts
  your hash cannot reveal it — the hash recomputes under *their* address and fails.
  (Tested: `test_Reveal_CopycatCannotStealCommitment`.)
- **`bountyId`** stops a commitment being replayed across bounties.

Clients MUST hash identically. The contract exposes `computeCommitment(...)` as a
`pure` helper and [`scripts/judge.ts`](hardhat/scripts/judge.ts) provides the
matching off-chain encoder; a test asserts the two agree byte-for-byte.

---

## Advanced track (Ritual-native)

`SealedBountyJudge` never stores plaintext on-chain at all:

- Each entrant **encrypts** their answer to the bounty's Ritual TEE executor and
  submits only the **ciphertext** (`submitSealed`).
- `judgeAll` forwards the sealed blobs as the LLM request's `encryptedSecrets`
  private inputs; the **TEE decrypts them privately**, batch-judges, and returns a
  signed completion. The public chain never sees plaintext.
- After judging, the owner publishes a revealed-answers **bundle** off-chain and
  commits only its reference + keccak hash on-chain (`publishRevealedAnswers`), so
  anyone can verify the post-judging reveal without bloating on-chain storage.

Full data-flow, trust model, and "where does plaintext exist" analysis are in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## Quick start

```bash
cd hardhat
pnpm install
npx hardhat compile
npx hardhat test          # 55 Solidity + 2 TypeScript tests
```

### Deploy to Ritual testnet

```bash
# set a funded chain-1979 key (never commit it)
export DEPLOYER_PRIVATE_KEY=0x...
npx hardhat ignition deploy --network ritual ignition/modules/CommitRevealBounty.ts
npx hardhat ignition deploy --network ritual ignition/modules/SealedBountyJudge.ts
```

---

## Repository layout

```
hardhat/
  contracts/
    CommitRevealBounty.sol      Required track: commit-reveal bounty judge
    CommitRevealBounty.t.sol    35 Solidity tests (reveal cases + lifecycle + fuzz)
    SealedBountyJudge.sol       Advanced track: Ritual-native sealed submissions
    SealedBountyJudge.t.sol     20 Solidity tests
    AIJudge.sol                 v1 starter, kept to show the flaw being fixed
    utils/PrecompileConsumer.sol  Ritual precompile addresses + call helper
  scripts/judge.ts              off-chain commitment + batch-prompt + LLM-request encoder
  test/lifecycle.ts             TypeScript end-to-end + commitment-parity test
  ignition/modules/             deployment modules
web/                            starter Next.js frontend (unchanged)
ARCHITECTURE.md                 data-flow, trust model, both tracks compared
TEST_PLAN.md                    reveal-case test matrix
DEPLOYMENTS.md                  live addresses + tx hashes + verification commands
REFLECTION.md                   reflection answer
```

## Docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — on-chain vs off-chain, where plaintext lives, how the LLM gets the batch.
- [`TEST_PLAN.md`](TEST_PLAN.md) — every reveal case and the test that covers it.
- [`DEPLOYMENTS.md`](DEPLOYMENTS.md) — verified live deployment record.
- [`REFLECTION.md`](REFLECTION.md) — public vs hidden, AI vs human.
