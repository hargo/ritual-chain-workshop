// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/**
 * @title SealedBountyJudge
 * @author hargo
 * @notice Advanced-track solution: a Ritual-native bounty where plaintext
 *         answers are NEVER published on-chain, not even in a reveal phase.
 *
 *         How privacy is achieved:
 *           - Each participant encrypts their answer to the bounty's Ritual TEE
 *             executor key off-chain and submits only the CIPHERTEXT.
 *           - The contract stores ciphertext (+ its keccak digest) and emits it,
 *             so the owner can gather every sealed submission for one batch call.
 *           - judgeAll forwards the ciphertexts as the LLM request's
 *             `encryptedSecrets` private inputs. The Ritual block builder
 *             decrypts them *inside the TEE*, runs one batch judging prompt, and
 *             returns a signed completion. The public chain never sees plaintext.
 *           - After judging, the owner publishes a revealed-answers BUNDLE
 *             off-chain (e.g. IPFS) and commits only its reference + keccak hash
 *             on-chain, so anyone can verify the post-judging reveal matches what
 *             was judged — without bloating on-chain storage with plaintext.
 *
 *         Where plaintext exists:  on the participant's device (pre-encryption)
 *                                  and inside the TEE (during judging) — nowhere
 *                                  else. See ARCHITECTURE.md for the full model.
 *
 * @dev The AI review is advisory; the owner finalizes the winner (human in the
 *      loop). The LLM is called once per bounty (batch), never per submission.
 */
contract SealedBountyJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 50;
    /// @notice Upper bound on a single ciphertext blob (bounds gas).
    uint256 public constant MAX_CIPHERTEXT_LENGTH = 8_000;

    struct SealedSubmission {
        address submitter; // who submitted
        bytes ciphertext; // answer encrypted to the TEE executor key
        bytes32 digest; // keccak256(ciphertext) for integrity references
    }

    struct Bounty {
        address owner;
        address executor; // Ritual TEE executor answers are encrypted to
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        bool judged;
        bool finalized;
        bool cancelled;
        uint256 winnerIndex;
        bytes aiReview; // advisory LLM completion
        string revealedAnswersRef; // off-chain bundle location (e.g. ipfs://)
        bytes32 revealedAnswersHash; // keccak256 of that bundle, for audit
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    uint256 public nextBountyId = 1;
    mapping(uint256 => Bounty) private _bounties;
    mapping(uint256 => SealedSubmission[]) private _submissions;
    mapping(uint256 => mapping(address => uint256)) private _slot; // 1-based

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        address indexed executor,
        string title,
        uint256 reward,
        uint256 submissionDeadline
    );
    event SealedSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        uint256 indexed submissionIndex,
        bytes32 digest,
        bytes ciphertext
    );
    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);
    event AnswersRevealed(
        uint256 indexed bountyId,
        string revealedAnswersRef,
        bytes32 revealedAnswersHash
    );
    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );
    event BountyCancelled(uint256 indexed bountyId, uint256 refund);

    modifier nonReentrant() {
        require(_status == _NOT_ENTERED, "reentrancy");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier bountyExists(uint256 bountyId) {
        require(_bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == _bounties[bountyId].owner, "not bounty owner");
        _;
    }

    /**
     * @notice Create a sealed bounty.
     * @param executor The Ritual TEE executor address participants encrypt to.
     */
    function createBounty(
        address executor,
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(executor != address(0), "executor required");
        require(submissionDeadline > block.timestamp, "deadline in past");

        bountyId = nextBountyId++;
        Bounty storage b = _bounties[bountyId];
        b.owner = msg.sender;
        b.executor = executor;
        b.title = title;
        b.rubric = rubric;
        b.reward = msg.value;
        b.submissionDeadline = submissionDeadline;
        b.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            executor,
            title,
            msg.value,
            submissionDeadline
        );
    }

    /**
     * @notice Submit a sealed (encrypted) answer. Plaintext is never on-chain.
     * @param ciphertext Answer encrypted off-chain to the bounty executor key.
     */
    function submitSealed(
        uint256 bountyId,
        bytes calldata ciphertext
    ) external bountyExists(bountyId) {
        Bounty storage b = _bounties[bountyId];
        require(block.timestamp < b.submissionDeadline, "submissions closed");
        require(ciphertext.length > 0, "empty ciphertext");
        require(ciphertext.length <= MAX_CIPHERTEXT_LENGTH, "ciphertext too long");
        require(_slot[bountyId][msg.sender] == 0, "already submitted");
        require(_submissions[bountyId].length < MAX_SUBMISSIONS, "bounty full");

        bytes32 digest = keccak256(ciphertext);
        _submissions[bountyId].push(
            SealedSubmission({
                submitter: msg.sender,
                ciphertext: ciphertext,
                digest: digest
            })
        );
        uint256 index = _submissions[bountyId].length - 1;
        _slot[bountyId][msg.sender] = index + 1;

        emit SealedSubmitted(bountyId, msg.sender, index, digest, ciphertext);
    }

    /**
     * @notice Batch-judge all sealed answers in a single TEE-backed LLM call.
     * @dev Owner-only, after the submission deadline. `llmInput` is built
     *      off-chain and MUST carry the sealed submissions as the request's
     *      `encryptedSecrets` private inputs; the TEE decrypts them privately,
     *      judges the batch, and returns a signed completion. No plaintext is
     *      revealed to the public chain by this call.
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = _bounties[bountyId];
        require(block.timestamp >= b.submissionDeadline, "submissions open");
        require(!b.judged, "already judged");
        require(!b.finalized, "already finalized");
        require(!b.cancelled, "cancelled");
        require(_submissions[bountyId].length > 0, "no submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));
        require(!hasError, errorMessage);

        b.judged = true;
        b.aiReview = completionData;
        emit AllAnswersJudged(bountyId, completionData);
    }

    /**
     * @notice Publish the revealed-answers bundle reference + hash after judging.
     * @dev Commits to the post-judging reveal without storing plaintext on-chain.
     *      Anyone can fetch `revealedAnswersRef` and check keccak256 == hash.
     */
    function publishRevealedAnswers(
        uint256 bountyId,
        string calldata revealedAnswersRef,
        bytes32 revealedAnswersHash
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = _bounties[bountyId];
        require(b.judged, "not judged");
        require(revealedAnswersHash != bytes32(0), "empty hash");
        b.revealedAnswersRef = revealedAnswersRef;
        b.revealedAnswersHash = revealedAnswersHash;
        emit AnswersRevealed(bountyId, revealedAnswersRef, revealedAnswersHash);
    }

    /**
     * @notice Finalize and pay the winner (human-in-the-loop).
     */
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) nonReentrant {
        Bounty storage b = _bounties[bountyId];
        require(b.judged, "not judged");
        require(!b.finalized, "already finalized");
        require(!b.cancelled, "cancelled");
        require(winnerIndex < _submissions[bountyId].length, "bad index");

        b.finalized = true;
        b.winnerIndex = winnerIndex;
        uint256 reward = b.reward;
        b.reward = 0;
        address winner = _submissions[bountyId][winnerIndex].submitter;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "reward transfer failed");
        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    /**
     * @notice Refund the owner if nobody submitted before the deadline.
     */
    function cancelBounty(
        uint256 bountyId
    ) external bountyExists(bountyId) onlyOwner(bountyId) nonReentrant {
        Bounty storage b = _bounties[bountyId];
        require(block.timestamp >= b.submissionDeadline, "submissions open");
        require(_submissions[bountyId].length == 0, "has submissions");
        require(!b.finalized && !b.cancelled, "settled");

        b.cancelled = true;
        uint256 refund = b.reward;
        b.reward = 0;
        (bool ok, ) = payable(b.owner).call{value: refund}("");
        require(ok, "refund failed");
        emit BountyCancelled(bountyId, refund);
    }

    // -------------------------------- views ------------------------------ //

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            address executor,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            bool judged,
            bool finalized,
            bool cancelled,
            uint256 totalSubmissions,
            uint256 winnerIndex,
            string memory revealedAnswersRef,
            bytes32 revealedAnswersHash,
            bytes memory aiReview
        )
    {
        Bounty storage b = _bounties[bountyId];
        return (
            b.owner,
            b.executor,
            b.title,
            b.rubric,
            b.reward,
            b.submissionDeadline,
            b.judged,
            b.finalized,
            b.cancelled,
            _submissions[bountyId].length,
            b.winnerIndex,
            b.revealedAnswersRef,
            b.revealedAnswersHash,
            b.aiReview
        );
    }

    function submissionCount(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (uint256) {
        return _submissions[bountyId].length;
    }

    function getSealedSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, bytes32 digest, bytes memory ciphertext)
    {
        require(index < _submissions[bountyId].length, "bad index");
        SealedSubmission storage s = _submissions[bountyId][index];
        return (s.submitter, s.digest, s.ciphertext);
    }
}
