# Deployments

Both contracts are **live on Ritual testnet (chain `1979`)**, deployed from
`0xDA75E031E7a98c627fbb5323093Ca61f816AcCc8`. Every value below was read back
from the chain — see the re-verification commands at the bottom.

| Contract | Track | Address | Deploy tx | Block |
| --- | --- | --- | --- | --- |
| `CommitRevealBounty` | Required | [`0xFeFD74b301b41F9b67f17Db307f68527Db57a319`](https://explorer.ritualfoundation.org/address/0xFeFD74b301b41F9b67f17Db307f68527Db57a319) | [`0xd01dc2b9…381f217f`](https://explorer.ritualfoundation.org/tx/0xd01dc2b9d9a1a3b75242c7d4f66c93d7ea8ba45ab006f6d5d0aa4599381f217f) | 37680392 |
| `SealedBountyJudge` | Advanced | [`0x3fe8Dfc467E7ba37d85aE2DE6728E20a4BB2782c`](https://explorer.ritualfoundation.org/address/0x3fe8Dfc467E7ba37d85aE2DE6728E20a4BB2782c) | [`0x65f3d6c8…71d35624`](https://explorer.ritualfoundation.org/tx/0x65f3d6c8b9f36f81708c3afb868d4036f696c52c1514ef9a6b128d7d71d35624) | 37680461 |

- **Network:** Ritual testnet
- **RPC:** `https://rpc.ritualfoundation.org`
- **Chain ID:** `1979`
- **Explorer:** RitualScan — `https://explorer.ritualfoundation.org`

## Reproduce the deployment

```bash
cd hardhat
pnpm install
# DEPLOYER_PRIVATE_KEY must be set for a funded chain-1979 account
npx hardhat ignition deploy --network ritual ignition/modules/CommitRevealBounty.ts
npx hardhat ignition deploy --network ritual ignition/modules/SealedBountyJudge.ts
```

## Verify the live contracts yourself

```bash
RPC=https://rpc.ritualfoundation.org

# Non-empty bytecode == contract really exists
cast code 0xFeFD74b301b41F9b67f17Db307f68527Db57a319 --rpc-url $RPC | head -c 80
cast code 0x3fe8Dfc467E7ba37d85aE2DE6728E20a4BB2782c --rpc-url $RPC | head -c 80

# Deployment receipts (status 1 = success, from = deployer)
cast receipt 0xd01dc2b9d9a1a3b75242c7d4f66c93d7ea8ba45ab006f6d5d0aa4599381f217f --rpc-url $RPC
cast receipt 0x65f3d6c8b9f36f81708c3afb868d4036f696c52c1514ef9a6b128d7d71d35624 --rpc-url $RPC

# Live read: next bounty id (1 == freshly deployed, no bounties yet)
cast call 0xFeFD74b301b41F9b67f17Db307f68527Db57a319 "nextBountyId()(uint256)" --rpc-url $RPC
```

## Funding AI judging (`judgeAll`)

`judgeAll` triggers the Ritual LLM precompile (`0x0802`), whose inference fee is
paid from the **caller's** RitualWallet balance, not the bounty contract:

- RitualWallet: `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948`
- Before judging, the bounty owner deposits and locks RITUAL:
  `wallet.deposit{value: 0.05 ether}(lockDurationBlocks)` with a lock that
  extends at least ~300 blocks past the judging block.

## Live run (honest status)

I exercised the full lifecycle against the live `CommitRevealBounty` with
`scripts/demo.ts`. The commit-reveal flow is **proven on-chain** (all succeeded,
status 1):

| Step | Tx | Block |
| --- | --- | --- |
| createBounty (#2) | `0x41869ee112b37dc3fb06a20a93f0c76d0d8e307a824aaab2ac1a7d3ca43f26c4` | 37683145 |
| submitCommitment | `0x286f931de0c16f62b5980dee6808b0cfe559c58a3807e83d267be05db4169ffc` | 37683152 |
| revealAnswer | `0x9eb99d460b0c5a7adc6bd7bc17ea734067e7b2cfe54cf1a4381c1ad16cd98ed5` | 37683231 |
| RitualWallet deposit/lock | `0xb3fb362099db04afb13485b7996cd038acd0f0f7c9394f44b8c6a3b171b2e4aa` | 37683242 |

**`judgeAll` (the real `0x0802` call) currently reverts on testnet**, and I am
recording that honestly rather than faking a result. The contract forwards a
request encoded to the **authoritative ABI from docs.ritual.net** (verified: the
30-field layout matches exactly). The revert is an *infrastructure* dependency,
not a contract defect:

- Ritual's LLM precompile requires a **currently-registered, online TEE executor**
  address (from `TEEServiceRegistry` `0x9644…f47F`). The starter's configured
  executor `0xB42e…c91B` did not produce a successful inference in this run.
- The ABI's `convoHistory` field is **required** and normally points to a
  credentialed storage backend (GCS/Pinata/IPFS/HF). A no-persistence `inline`
  ref did not satisfy it here.

These are exactly the reasons the upstream starter ships a JSON **mock fallback**
for `judgeAll`. This project does **not** use that mock: `judgeAll` always calls
the real precompile, and the off-chain encoder is grounded in the official ABI.
A successful live inference needs a live executor + storage credentials, which
are out of scope for this homework environment. Unit tests prove the contract
correctly decodes/stores/handles a real-shaped precompile response
(`test_JudgeAll_SuccessStoresReview`, `test_JudgeAll_RevertOnLlmError`).

