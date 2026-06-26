// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/**
 * @title CommitRevealBounty
 * @author hargo
 * @notice Required-track solution to the "Privacy-Preserving AI Bounty Judge"
 *         homework. Fixes the workshop's flaw where answers were public the
 *         moment they were submitted, letting later entrants copy earlier work.
 *
 *         Lifecycle:
 *           createBounty      -> owner escrows the reward, sets two deadlines
 *           submitCommitment  -> entrants publish ONLY keccak256(answer,salt,sender,bountyId)
 *           revealAnswer      -> after submission closes, entrants reveal (answer,salt)
 *           judgeAll          -> after reveal closes, owner sends ONE batch LLM request
 *           finalizeWinner    -> owner (a human) picks the winner; reward is paid once
 *
 *         Only answers whose reveal hashes back to the stored commitment become
 *         eligible for judging, so nobody can copy a plaintext answer during the
 *         submission phase (only a hash is on-chain) and a copycat cannot reveal
 *         someone else's commitment (the hash is bound to msg.sender + bountyId).
 *
 * @dev The AI review is ADVISORY. `judgeAll` records the model's output but the
 *      owner still calls `finalizeWinner` explicitly (human-in-the-loop). The
 *      LLM is invoked exactly once per bounty as a batch over all revealed
 *      answers, never once-per-submission. `judgeAll` is interface-agnostic
 *      about `llmInput`: the encoded Ritual LLM request is built off-chain and
 *      forwarded verbatim to the `0x0802` precompile.
 */
contract CommitRevealBounty is PrecompileConsumer {
    // --------------------------------------------------------------------- //
    //                               Limits                                  //
    // --------------------------------------------------------------------- //

    /// @notice Hard cap on entrants per bounty (keeps the batch prompt bounded).
    uint256 public constant MAX_SUBMISSIONS = 50;
    /// @notice Hard cap on a revealed answer's length (bounds gas + prompt size).
    uint256 public constant MAX_ANSWER_LENGTH = 4_000;

    // --------------------------------------------------------------------- //
    //                                Types                                  //
    // --------------------------------------------------------------------- //

    struct Submission {
        address submitter; // who committed
        bytes32 commitment; // keccak256(answer, salt, submitter, bountyId)
        bool revealed; // true once a valid reveal lands
        string answer; // plaintext, populated only on a valid reveal
    }

    struct Bounty {
        address owner; // creator; escrows reward, judges, finalizes
        string title; // human-readable bounty title
        string rubric; // judging criteria handed to the LLM
        uint256 reward; // escrowed prize (wei); zeroed on payout/refund
        uint256 submissionDeadline; // commits allowed strictly before this
        uint256 revealDeadline; // reveals allowed in [submissionDeadline, revealDeadline)
        bool judged; // judgeAll has run
        bool finalized; // a winner was paid
        bool cancelled; // refunded to owner (no eligible reveals)
        uint256 winnerIndex; // index into submissions; max = unset
        uint256 revealedCount; // number of valid reveals (judging-eligible)
        bytes aiReview; // raw LLM completion bytes (advisory)
    }

    /// @dev Mirrors the LLM precompile's decoded conversation-history tuple.
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    // --------------------------------------------------------------------- //
    //                               Storage                                 //
    // --------------------------------------------------------------------- //

    uint256 public nextBountyId = 1;

    mapping(uint256 => Bounty) private _bounties;
    mapping(uint256 => Submission[]) private _submissions;
    // bountyId => submitter => 1-based index into _submissions (0 == none).
    mapping(uint256 => mapping(address => uint256)) private _commitmentSlot;

    // Minimal reentrancy guard (payout sends ETH to an arbitrary address).
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    // --------------------------------------------------------------------- //
    //                                Events                                 //
    // --------------------------------------------------------------------- //

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );
    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        uint256 indexed submissionIndex,
        bytes32 commitment
    );
    event AnswerRevealed(
        uint256 indexed bountyId,
        address indexed submitter,
        uint256 indexed submissionIndex
    );
    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);
    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );
    event BountyCancelled(uint256 indexed bountyId, uint256 refund);

    // --------------------------------------------------------------------- //
    //                               Modifiers                               //
    // --------------------------------------------------------------------- //

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

    // --------------------------------------------------------------------- //
    //                              Lifecycle                                //
    // --------------------------------------------------------------------- //

    /**
     * @notice Create a bounty and escrow its reward.
     * @param title Human-readable title.
     * @param rubric Criteria the AI judge must score against.
     * @param submissionDeadline Commitments accepted strictly before this timestamp.
     * @param revealDeadline Reveals accepted in [submissionDeadline, revealDeadline).
     * @return bountyId The new bounty id.
     */
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(
            submissionDeadline > block.timestamp,
            "submission deadline in past"
        );
        require(
            revealDeadline > submissionDeadline,
            "reveal must follow submission"
        );

        bountyId = nextBountyId++;

        Bounty storage b = _bounties[bountyId];
        b.owner = msg.sender;
        b.title = title;
        b.rubric = rubric;
        b.reward = msg.value;
        b.submissionDeadline = submissionDeadline;
        b.revealDeadline = revealDeadline;
        b.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    /**
     * @notice Submit a commitment hash during the submission phase.
     * @dev One commitment per address per bounty. The plaintext answer is NOT
     *      revealed here — only its hash. Owners may also enter.
     * @param bountyId Target bounty.
     * @param commitment keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)).
     */
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage b = _bounties[bountyId];

        require(block.timestamp < b.submissionDeadline, "submissions closed");
        require(commitment != bytes32(0), "empty commitment");
        require(
            _commitmentSlot[bountyId][msg.sender] == 0,
            "already committed"
        );
        require(
            _submissions[bountyId].length < MAX_SUBMISSIONS,
            "bounty full"
        );

        _submissions[bountyId].push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                revealed: false,
                answer: ""
            })
        );
        uint256 index = _submissions[bountyId].length - 1;
        _commitmentSlot[bountyId][msg.sender] = index + 1; // 1-based

        emit CommitmentSubmitted(bountyId, msg.sender, index, commitment);
    }

    /**
     * @notice Reveal a previously committed answer during the reveal phase.
     * @dev Accepted only if keccak256(abi.encodePacked(answer,salt,sender,bountyId))
     *      equals the stored commitment. Only revealed answers are judging-eligible.
     * @param bountyId Target bounty.
     * @param answer The plaintext answer.
     * @param salt The salt used when committing.
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage b = _bounties[bountyId];

        require(
            block.timestamp >= b.submissionDeadline,
            "reveal not started"
        );
        require(block.timestamp < b.revealDeadline, "reveal closed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 slot = _commitmentSlot[bountyId][msg.sender];
        require(slot != 0, "no commitment");
        uint256 index = slot - 1;

        Submission storage s = _submissions[bountyId][index];
        require(!s.revealed, "already revealed");

        bytes32 recomputed = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(recomputed == s.commitment, "commitment mismatch");

        s.revealed = true;
        s.answer = answer;
        unchecked {
            b.revealedCount++;
        }

        emit AnswerRevealed(bountyId, msg.sender, index);
    }

    /**
     * @notice Batch-judge every revealed answer with one Ritual LLM call.
     * @dev Owner-only, only after the reveal phase has ended, and only when at
     *      least one answer was revealed. `llmInput` is the off-chain-encoded
     *      Ritual LLM request (system+user messages built from the rubric and
     *      all revealed answers). It is forwarded verbatim to the `0x0802`
     *      precompile; the resulting completion is stored as advisory `aiReview`.
     * @param bountyId Target bounty.
     * @param llmInput ABI-encoded Ritual LLM inference request.
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = _bounties[bountyId];

        require(block.timestamp >= b.revealDeadline, "reveal not over");
        require(!b.judged, "already judged");
        require(!b.finalized, "already finalized");
        require(!b.cancelled, "cancelled");
        require(b.revealedCount > 0, "no revealed answers");

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
     * @notice Finalize the winner and pay the reward. Human-in-the-loop: the AI
     *         review is advisory; the owner explicitly chooses the winner.
     * @dev Only after judging. The chosen submission must be a valid reveal.
     * @param bountyId Target bounty.
     * @param winnerIndex Index (into the bounty's submissions) of the winner.
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

        Submission storage win = _submissions[bountyId][winnerIndex];
        require(win.revealed, "winner not revealed");

        // Effects before interaction.
        b.finalized = true;
        b.winnerIndex = winnerIndex;
        uint256 reward = b.reward;
        b.reward = 0;

        (bool ok, ) = payable(win.submitter).call{value: reward}("");
        require(ok, "reward transfer failed");

        emit WinnerFinalized(bountyId, winnerIndex, win.submitter, reward);
    }

    /**
     * @notice Refund the owner if nobody produced a valid reveal.
     * @dev Callable only after the reveal deadline, when revealedCount == 0,
     *      and the bounty is neither judged nor finalized.
     * @param bountyId Target bounty.
     */
    function cancelBounty(
        uint256 bountyId
    ) external bountyExists(bountyId) onlyOwner(bountyId) nonReentrant {
        Bounty storage b = _bounties[bountyId];

        require(block.timestamp >= b.revealDeadline, "reveal not over");
        require(b.revealedCount == 0, "has reveals");
        require(!b.finalized, "already finalized");
        require(!b.cancelled, "already cancelled");

        b.cancelled = true;
        uint256 refund = b.reward;
        b.reward = 0;

        (bool ok, ) = payable(b.owner).call{value: refund}("");
        require(ok, "refund failed");

        emit BountyCancelled(bountyId, refund);
    }

    // --------------------------------------------------------------------- //
    //                                Views                                  //
    // --------------------------------------------------------------------- //

    /**
     * @notice Off-chain/on-chain parity helper for the commitment scheme.
     * @dev Clients MUST hash identically. Used by tests and the encoder script.
     */
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            bool cancelled,
            uint256 totalSubmissions,
            uint256 revealedCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage b = _bounties[bountyId];
        return (
            b.owner,
            b.title,
            b.rubric,
            b.reward,
            b.submissionDeadline,
            b.revealDeadline,
            b.judged,
            b.finalized,
            b.cancelled,
            _submissions[bountyId].length,
            b.revealedCount,
            b.winnerIndex,
            b.aiReview
        );
    }

    function submissionCount(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (uint256) {
        return _submissions[bountyId].length;
    }

    /**
     * @notice Read a submission. Before a valid reveal, `answer` is empty and
     *         only the commitment hash is visible — that is the privacy property.
     */
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitment,
            bool revealed,
            string memory answer
        )
    {
        require(index < _submissions[bountyId].length, "bad index");
        Submission storage s = _submissions[bountyId][index];
        return (s.submitter, s.commitment, s.revealed, s.answer);
    }
}
