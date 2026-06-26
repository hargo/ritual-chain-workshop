# Architecture

Two designs solve the same fairness problem — *answers must stay hidden until
judging* — with different trust assumptions.

## 1. Required track — Commit-Reveal (`CommitRevealBounty`)

### Data flow

```
 entrant (off-chain)                 chain                         owner (off-chain)
 ───────────────────                 ─────                         ─────────────────
 answer + random salt
 commitment = keccak256(
   answer,salt,sender,id) ──submitCommitment──▶ store hash only
                                                (answer NOT on chain)

           ...submission deadline passes...

 reveal (answer, salt) ─────revealAnswer─────▶ recompute hash; if it
                                                matches, store plaintext
                                                + mark eligible

           ...reveal deadline passes...

                                   judgeAll(llmInput) ◀── build ONE batch prompt
                                   forwards to 0x0802        from all revealed answers
                                   LLM precompile (TEE)
                                   store advisory aiReview ──▶ read ranking
                                   finalizeWinner(idx) ◀────── owner picks winner
                                   pay reward
```

### What is on-chain vs off-chain

| Data | Where | When visible |
| --- | --- | --- |
| Commitment hash | on-chain | always (reveals nothing) |
| Plaintext answer | off-chain (entrant) → on-chain at reveal | only after the reveal phase |
| Salt | off-chain → on-chain at reveal | only at reveal |
| Batch prompt / `llmInput` | built off-chain, passed as calldata | at judging |
| AI review | on-chain (`aiReview`) | after judging |

### Where plaintext exists
On the entrant's machine, and on-chain **only after** they choose to reveal. During
the submission phase the chain holds nothing but a hash, so no one can copy an answer.

### Trust model
Trust-minimised and portable: works on **any EVM chain**. The only Ritual-specific
part is `judgeAll`, which calls the LLM precompile. Limitation: by design, answers
become public at reveal time, *before* the AI scores them — acceptable because the
submission window is already closed, so no one can still copy and enter.

---

## 2. Advanced track — Ritual-native Sealed (`SealedBountyJudge`)

Removes the commit-reveal limitation: plaintext is **never** published on-chain.

### Data flow

```
 entrant (off-chain)                         chain (public)                 Ritual TEE executor
 ───────────────────                         ──────────────                 ───────────────────
 answer
 ciphertext = Encrypt(answer, executorPubKey)
        │
        └────────── submitSealed(ciphertext) ──▶ store ciphertext + digest
                                                  (plaintext NEVER on chain)

            ...submission deadline passes...

 owner: judgeAll(llmInput)  ───────────────────▶ forward ciphertexts as the
   (llmInput carries the sealed blobs as          LLM request's encryptedSecrets ──▶ decrypt INSIDE TEE
    encryptedSecrets private inputs)                                                  batch-judge all answers
                                                  store advisory aiReview ◀────────── signed completion
 owner: publishRevealedAnswers(ref, hash) ─────▶ commit bundle ref + keccak hash
                                                  (audit without on-chain plaintext)
 owner: finalizeWinner(idx) ───────────────────▶ pay reward
```

### Answers the advanced-track questions

- **Where does plaintext exist, and who can read it?** Only on the entrant's device
  (before encryption) and inside the Ritual TEE (during judging). The public chain
  and other entrants never see it.
- **On-chain vs off-chain?** On-chain: ciphertext, its keccak digest, the advisory
  AI review, and the post-judging bundle reference + hash. Off-chain: plaintext, the
  encryption keys, and the revealed-answers bundle itself.
- **How does the LLM receive all submissions together?** The owner builds a single
  `llmInput` whose `encryptedSecrets` array carries every sealed blob; the TEE
  decrypts them and the model judges them in **one** batch request (never one call
  per answer).
- **How does the final reveal happen?** After judging, the owner publishes the
  decrypted answers as an off-chain bundle (e.g. IPFS) and records only its reference
  and `keccak256` on-chain, so anyone can fetch the bundle and verify the hash.
- **How does the contract commit to the revealed bundle?** `publishRevealedAnswers`
  stores `revealedAnswersRef` + `revealedAnswersHash`; the digest of each sealed
  submission is already on-chain, linking ciphertext → revealed plaintext.

### Trust model
Stronger privacy, but you now trust Ritual's TEE attestation and key management for
confidentiality. The on-chain digests + bundle hash keep the executor **honest about
integrity** even though it is trusted for **confidentiality**.

---

## Shared safety properties (both contracts)

- **Access control:** only the bounty owner can `judgeAll` / `finalizeWinner` / cancel.
- **Phase gating:** commits before the submission deadline; reveals only in the reveal
  window; judging only after it; finalize only after judging.
- **Escrow & payout:** the reward is escrowed on creation, paid exactly once, with a
  reentrancy guard and checks-effects-interactions ordering on the ETH transfer.
- **Human-in-the-loop:** the AI review is advisory; a human owner finalizes the payout.
  The contract never auto-pays from parsed AI output.
- **One batch call:** the LLM is invoked once per bounty, never inside a loop.
- **Refund path:** if nobody produces an eligible answer, the owner is refunded.

## The Ritual LLM precompile call

`judgeAll` calls `_executePrecompile(LLM_INFERENCE_PRECOMPILE /* 0x0802 */, llmInput)`.
For short-running async precompiles the raw return is `abi.encode(bytes simmedInput,
bytes actualOutput)`; the helper returns `actualOutput`, which decodes to
`(bool hasError, bytes completion, bytes, string errorMessage, ConvoHistory)`. A
non-zero `hasError` reverts with the model's error string. `llmInput` itself is built
off-chain by [`scripts/judge.ts`](hardhat/scripts/judge.ts) as the real Ritual request
ABI (model `zai-org/GLM-4.7-FP8`), so the contract stays agnostic to prompt formatting.
