# Reflection

> What should be public, what should stay hidden, and what should be decided by AI
> versus by a human in a bounty system?

What should be **public** is everything needed to trust the process without exposing
competitors: the bounty terms and rubric, the reward and deadlines, the set of
commitments or ciphertexts, and — after judging — the answers, the AI's ranking, and
the final payout. What should stay **hidden**, and only until the submission window
closes, is each participant's actual answer; publishing it earlier lets latecomers
copy good ideas, which is the exact unfairness this project removes (with a commitment
hash in the required track, and with TEE-decrypted ciphertext in the advanced track).
Encryption keys and salts are the supporting secrets that must never leak, since they
are what keep the hidden data hidden. The **AI** is well suited to the laborious,
consistent part — reading every revealed answer against the rubric in one batch and
proposing a ranking with reasons — because it scales and applies the criteria
uniformly. But the AI's output is advisory only: LLMs can be wrong, gamed by
prompt-injection inside submissions, or non-deterministic, so a **human** owner makes
the final, accountable decision and authorizes the payout. Keeping the money strictly
human-gated also means a manipulated or malfunctioning model can never directly drain
the escrow. In short: make the rules and the outcome transparent, keep the answers
secret until judging, let AI recommend, and let a human decide.
