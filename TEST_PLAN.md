# Test Plan

Run everything:

```bash
cd hardhat
npx hardhat test            # 55 Solidity + 2 TypeScript = 57 tests
npx hardhat test solidity   # 55 Solidity only
npx hardhat test nodejs     # 2 TypeScript only
```

`judgeAll` calls the Ritual LLM precompile (`0x0802`), which exists only on Ritual
Chain. In unit tests the precompile is replaced via `vm.etch` with a deterministic
stub returning the **exact wire shape** the real one does — purely to exercise the
contract's decode/store/emit branches. Every guard that reverts *before* the
precompile call is tested with no stub. The genuine precompile is exercised for real
when the deployed contract is used on Ritual testnet (see `DEPLOYMENTS.md`).

## Required track — reveal-case matrix (`CommitRevealBounty.t.sol`, 35 tests)

| Rule from the spec | Test | Expected |
| --- | --- | --- |
| Reward must be escrowed | `test_CreateBounty_EscrowsAndSetsState` | balance held, state set |
| Reject zero reward | `test_CreateBounty_RevertNoReward` | revert `reward required` |
| Submission deadline must be future | `test_CreateBounty_RevertSubmissionInPast` | revert |
| Reveal must follow submission | `test_CreateBounty_RevertRevealBeforeSubmission` | revert |
| Commit stores only a hash | `test_SubmitCommitment_StoresHashOnly` | answer empty on-chain |
| No commits after deadline | `test_SubmitCommitment_RevertAfterDeadline` | revert `submissions closed` |
| One commitment per address | `test_SubmitCommitment_RevertDoubleCommit` | revert `already committed` |
| Reject empty commitment | `test_SubmitCommitment_RevertEmpty` | revert |
| Cap submissions | `test_SubmitCommitment_RevertBountyFull` | revert `bounty full` |
| Unknown bounty | `test_SubmitCommitment_RevertBountyNotFound` | revert |
| **Valid reveal** | `test_Reveal_Valid` | revealed + eligible |
| **Wrong salt** | `test_Reveal_RevertWrongSalt` | revert `commitment mismatch` |
| **Wrong answer** | `test_Reveal_RevertWrongAnswer` | revert `commitment mismatch` |
| **Copycat (stolen hash)** | `test_Reveal_CopycatCannotStealCommitment` | thief reverts; owner reveals |
| Reveal before window | `test_Reveal_RevertBeforeWindow` | revert `reveal not started` |
| Reveal after window | `test_Reveal_RevertAfterWindow` | revert `reveal closed` |
| Reveal without commitment | `test_Reveal_RevertNoCommitment` | revert `no commitment` |
| Double reveal | `test_Reveal_RevertDoubleReveal` | revert `already revealed` |
| Oversized answer | `test_Reveal_RevertAnswerTooLong` | revert `answer too long` |
| Only owner judges | `test_JudgeAll_RevertNotOwner` | revert `not bounty owner` |
| Judge only after reveal deadline | `test_JudgeAll_RevertBeforeRevealDeadline` | revert `reveal not over` |
| No judging without reveals | `test_JudgeAll_RevertNoRevealedAnswers` | revert |
| Judging stores review | `test_JudgeAll_SuccessStoresReview` | judged, `aiReview` set |
| LLM error bubbles up | `test_JudgeAll_RevertOnLlmError` | revert `llm failed` |
| No double judging | `test_JudgeAll_RevertAlreadyJudged` | revert `already judged` |
| Finalize only after judging | `test_Finalize_RevertNotJudged` | revert `not judged` |
| Only owner finalizes | `test_Finalize_RevertNotOwner` | revert `not bounty owner` |
| Winner must have revealed | `test_Finalize_RevertWinnerNotRevealed` | revert `winner not revealed` |
| Bad winner index | `test_Finalize_RevertBadIndex` | revert `bad index` |
| Pay exactly one winner | `test_Finalize_PaysWinnerOnce` | paid once; second call reverts |
| Refund when no reveals | `test_Cancel_RefundsWhenNoReveals` | owner refunded |
| Can't cancel with reveals | `test_Cancel_RevertHasReveals` | revert `has reveals` |
| Can't cancel early | `test_Cancel_RevertBeforeRevealOver` | revert `reveal not over` |
| Commitment parity | `test_ComputeCommitment_MatchesScheme` | on-chain == local keccak |
| Fuzz round-trip | `testFuzz_CommitReveal_RoundTrip` | any valid commit reveals (256 runs) |

## Advanced track (`SealedBountyJudge.t.sol`, 20 tests)

Covers: escrow + executor set, ciphertext-only storage, empty/oversized ciphertext,
one-per-address, post-deadline rejection, owner-only + timing guards on `judgeAll`,
batch-judge success/error via the etched stub, revealed-bundle commitment
(`publishRevealedAnswers`) + its not-judged guard, single-winner payout with
double-finalize protection, bad-index rejection, and the no-submission refund path.

## TypeScript end-to-end (`test/lifecycle.ts`, 2 tests)

1. Deploys to an in-process EVM, runs create → commit → reveal, and asserts the
   off-chain encoder's commitment equals the contract's `computeCommitment`
   byte-for-byte (so honest participants can always reveal).
2. Asserts `buildJudgeAllLlmInput` produces a non-empty ABI-encoded request.
