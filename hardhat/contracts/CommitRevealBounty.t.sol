// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitRevealBounty} from "./CommitRevealBounty.sol";

/**
 * @dev Deterministic stand-in for the Ritual LLM precompile (0x0802) used ONLY
 *      to unit-test judgeAll's decode/store/emit path. It returns the exact
 *      wire shape the real precompile does for short-running async calls:
 *      abi.encode(bytes simmedInput, bytes actualOutput), where actualOutput =
 *      abi.encode(bool hasError, bytes completion, bytes, string err, Convo).
 *      The genuine precompile is exercised for real on Ritual testnet at deploy
 *      time; this stub never ships in the product.
 */
contract LLMSuccessStub {
    struct Convo {
        string storageType;
        string path;
        string secretsName;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        bytes memory completion = bytes('{"winnerIndex":0,"summary":"ok"}');
        bytes memory actualOutput = abi.encode(
            false, // hasError
            completion, // completionData
            bytes(""), // (unused middle field)
            string(""), // errorMessage
            Convo("", "", "")
        );
        return abi.encode(bytes(""), actualOutput);
    }
}

/// @dev Same wire shape but signals an inference error.
contract LLMErrorStub {
    struct Convo {
        string storageType;
        string path;
        string secretsName;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        bytes memory actualOutput = abi.encode(
            true, // hasError
            bytes(""), // completionData
            bytes(""),
            string("llm failed"), // errorMessage
            Convo("", "", "")
        );
        return abi.encode(bytes(""), actualOutput);
    }
}

contract CommitRevealBountyTest is Test {
    CommitRevealBounty internal bounty;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    address internal constant LLM = address(0x0802);

    uint256 internal constant REWARD = 1 ether;
    uint256 internal subDeadline;
    uint256 internal revDeadline;

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

    function setUp() public {
        bounty = new CommitRevealBounty();
        subDeadline = block.timestamp + 1 days;
        revDeadline = block.timestamp + 2 days;
        vm.deal(owner, 10 ether);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(carol, 1 ether);
    }

    // ----------------------------- helpers ------------------------------- //

    function _create() internal returns (uint256 id) {
        vm.prank(owner);
        id = bounty.createBounty{value: REWARD}(
            "Best gas optimization",
            "Most gas saved wins.",
            subDeadline,
            revDeadline
        );
    }

    function _commitHash(
        string memory answer,
        bytes32 salt,
        address sender,
        uint256 id
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, sender, id));
    }

    function _installSuccessStub() internal {
        LLMSuccessStub stub = new LLMSuccessStub();
        vm.etch(LLM, address(stub).code);
    }

    function _installErrorStub() internal {
        LLMErrorStub stub = new LLMErrorStub();
        vm.etch(LLM, address(stub).code);
    }

    // ----------------------------- create -------------------------------- //

    function test_CreateBounty_EscrowsAndSetsState() public {
        uint256 id = _create();
        (
            address bOwner,
            ,
            ,
            uint256 reward,
            uint256 sd,
            uint256 rd,
            bool judged,
            bool finalized,
            bool cancelled,
            uint256 total,
            uint256 revealed,
            ,

        ) = bounty.getBounty(id);
        assertEq(bOwner, owner);
        assertEq(reward, REWARD);
        assertEq(sd, subDeadline);
        assertEq(rd, revDeadline);
        assertFalse(judged);
        assertFalse(finalized);
        assertFalse(cancelled);
        assertEq(total, 0);
        assertEq(revealed, 0);
        assertEq(address(bounty).balance, REWARD);
    }

    function test_CreateBounty_RevertNoReward() public {
        vm.prank(owner);
        vm.expectRevert(bytes("reward required"));
        bounty.createBounty("t", "r", subDeadline, revDeadline);
    }

    function test_CreateBounty_RevertSubmissionInPast() public {
        vm.prank(owner);
        vm.expectRevert(bytes("submission deadline in past"));
        bounty.createBounty{value: REWARD}(
            "t",
            "r",
            block.timestamp,
            revDeadline
        );
    }

    function test_CreateBounty_RevertRevealBeforeSubmission() public {
        vm.prank(owner);
        vm.expectRevert(bytes("reveal must follow submission"));
        bounty.createBounty{value: REWARD}("t", "r", subDeadline, subDeadline);
    }

    // --------------------------- submit commit --------------------------- //

    function test_SubmitCommitment_StoresHashOnly() public {
        uint256 id = _create();
        bytes32 c = _commitHash("ans", bytes32("s"), alice, id);

        vm.expectEmit(true, true, true, true);
        emit CommitmentSubmitted(id, alice, 0, c);
        vm.prank(alice);
        bounty.submitCommitment(id, c);

        (address submitter, bytes32 commitment, bool revealed, string memory answer) =
            bounty.getSubmission(id, 0);
        assertEq(submitter, alice);
        assertEq(commitment, c);
        assertFalse(revealed);
        assertEq(bytes(answer).length, 0); // plaintext hidden during submission
    }

    function test_SubmitCommitment_RevertAfterDeadline() public {
        uint256 id = _create();
        vm.warp(subDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("submissions closed"));
        bounty.submitCommitment(id, _commitHash("a", bytes32("s"), alice, id));
    }

    function test_SubmitCommitment_RevertDoubleCommit() public {
        uint256 id = _create();
        vm.startPrank(alice);
        bounty.submitCommitment(id, _commitHash("a", bytes32("s"), alice, id));
        vm.expectRevert(bytes("already committed"));
        bounty.submitCommitment(id, _commitHash("b", bytes32("t"), alice, id));
        vm.stopPrank();
    }

    function test_SubmitCommitment_RevertEmpty() public {
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(bytes("empty commitment"));
        bounty.submitCommitment(id, bytes32(0));
    }

    function test_SubmitCommitment_RevertBountyFull() public {
        uint256 id = _create();
        uint256 max = bounty.MAX_SUBMISSIONS();
        for (uint256 i = 0; i < max; i++) {
            address u = address(uint160(1000 + i));
            vm.prank(u);
            bounty.submitCommitment(id, _commitHash("a", bytes32("s"), u, id));
        }
        vm.prank(alice);
        vm.expectRevert(bytes("bounty full"));
        bounty.submitCommitment(id, _commitHash("a", bytes32("s"), alice, id));
    }

    function test_SubmitCommitment_RevertBountyNotFound() public {
        vm.prank(alice);
        vm.expectRevert(bytes("bounty not found"));
        bounty.submitCommitment(999, _commitHash("a", bytes32("s"), alice, 999));
    }

    // ------------------------------ reveal ------------------------------- //

    function test_Reveal_Valid() public {
        uint256 id = _create();
        bytes32 salt = keccak256("salt-alice");
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash("my answer", salt, alice, id));

        vm.warp(subDeadline);
        vm.expectEmit(true, true, true, true);
        emit AnswerRevealed(id, alice, 0);
        vm.prank(alice);
        bounty.revealAnswer(id, "my answer", salt);

        (, , bool revealed, string memory answer) = bounty.getSubmission(id, 0);
        assertTrue(revealed);
        assertEq(answer, "my answer");
        (, , , , , , , , , , uint256 revealedCount, , ) = bounty.getBounty(id);
        assertEq(revealedCount, 1);
    }

    function test_Reveal_RevertWrongSalt() public {
        uint256 id = _create();
        bytes32 salt = keccak256("right");
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash("answer", salt, alice, id));
        vm.warp(subDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        bounty.revealAnswer(id, "answer", keccak256("wrong"));
    }

    function test_Reveal_RevertWrongAnswer() public {
        uint256 id = _create();
        bytes32 salt = keccak256("s");
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash("real answer", salt, alice, id));
        vm.warp(subDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        bounty.revealAnswer(id, "tampered answer", salt);
    }

    /// @notice Copycat protection: binding the hash to msg.sender means a thief
    ///         who reposts someone else's commitment cannot reveal it.
    function test_Reveal_CopycatCannotStealCommitment() public {
        uint256 id = _create();
        bytes32 salt = keccak256("alice-salt");
        bytes32 aliceCommit = _commitHash("alice answer", salt, alice, id);

        // Alice commits; Bob copies the exact same hash.
        vm.prank(alice);
        bounty.submitCommitment(id, aliceCommit);
        vm.prank(bob);
        bounty.submitCommitment(id, aliceCommit);

        vm.warp(subDeadline);

        // Bob tries to reveal Alice's answer+salt; recompute uses Bob's address.
        vm.prank(bob);
        vm.expectRevert(bytes("commitment mismatch"));
        bounty.revealAnswer(id, "alice answer", salt);

        // Alice can still reveal her own.
        vm.prank(alice);
        bounty.revealAnswer(id, "alice answer", salt);
        (, , bool revealed, ) = bounty.getSubmission(id, 0);
        assertTrue(revealed);
    }

    function test_Reveal_RevertBeforeWindow() public {
        uint256 id = _create();
        bytes32 salt = keccak256("s");
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash("a", salt, alice, id));
        // still in submission phase
        vm.prank(alice);
        vm.expectRevert(bytes("reveal not started"));
        bounty.revealAnswer(id, "a", salt);
    }

    function test_Reveal_RevertAfterWindow() public {
        uint256 id = _create();
        bytes32 salt = keccak256("s");
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash("a", salt, alice, id));
        vm.warp(revDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("reveal closed"));
        bounty.revealAnswer(id, "a", salt);
    }

    function test_Reveal_RevertNoCommitment() public {
        uint256 id = _create();
        vm.warp(subDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("no commitment"));
        bounty.revealAnswer(id, "a", bytes32("s"));
    }

    function test_Reveal_RevertDoubleReveal() public {
        uint256 id = _create();
        bytes32 salt = keccak256("s");
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash("a", salt, alice, id));
        vm.warp(subDeadline);
        vm.startPrank(alice);
        bounty.revealAnswer(id, "a", salt);
        vm.expectRevert(bytes("already revealed"));
        bounty.revealAnswer(id, "a", salt);
        vm.stopPrank();
    }

    function test_Reveal_RevertAnswerTooLong() public {
        uint256 id = _create();
        uint256 max = bounty.MAX_ANSWER_LENGTH();
        bytes memory big = new bytes(max + 1);
        for (uint256 i = 0; i < big.length; i++) big[i] = "a";
        string memory answer = string(big);
        bytes32 salt = keccak256("s");
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash(answer, salt, alice, id));
        vm.warp(subDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("answer too long"));
        bounty.revealAnswer(id, answer, salt);
    }

    // ------------------------------ judge -------------------------------- //

    function _commitAndReveal(
        uint256 id,
        address who,
        string memory answer,
        bytes32 salt
    ) internal {
        vm.prank(who);
        bounty.submitCommitment(id, _commitHash(answer, salt, who, id));
        // caller warps to reveal window before invoking when needed
        vm.prank(who);
        bounty.revealAnswer(id, answer, salt);
    }

    function _setupRevealed() internal returns (uint256 id) {
        id = _create();
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash("alice", keccak256("a"), alice, id));
        vm.prank(bob);
        bounty.submitCommitment(id, _commitHash("bob", keccak256("b"), bob, id));
        vm.warp(subDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "alice", keccak256("a"));
        vm.prank(bob);
        bounty.revealAnswer(id, "bob", keccak256("b"));
    }

    function test_JudgeAll_RevertNotOwner() public {
        uint256 id = _setupRevealed();
        vm.warp(revDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        bounty.judgeAll(id, hex"00");
    }

    function test_JudgeAll_RevertBeforeRevealDeadline() public {
        uint256 id = _setupRevealed();
        // still before revDeadline
        vm.prank(owner);
        vm.expectRevert(bytes("reveal not over"));
        bounty.judgeAll(id, hex"00");
    }

    function test_JudgeAll_RevertNoRevealedAnswers() public {
        uint256 id = _create();
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash("a", keccak256("a"), alice, id));
        vm.warp(revDeadline); // nobody revealed
        vm.prank(owner);
        vm.expectRevert(bytes("no revealed answers"));
        bounty.judgeAll(id, hex"00");
    }

    function test_JudgeAll_SuccessStoresReview() public {
        uint256 id = _setupRevealed();
        vm.warp(revDeadline);
        _installSuccessStub();

        vm.expectEmit(true, false, false, true);
        emit AllAnswersJudged(id, bytes('{"winnerIndex":0,"summary":"ok"}'));
        vm.prank(owner);
        bounty.judgeAll(id, hex"deadbeef");

        (, , , , , , bool judged, , , , , , bytes memory review) =
            bounty.getBounty(id);
        assertTrue(judged);
        assertEq(review, bytes('{"winnerIndex":0,"summary":"ok"}'));
    }

    function test_JudgeAll_RevertOnLlmError() public {
        uint256 id = _setupRevealed();
        vm.warp(revDeadline);
        _installErrorStub();
        vm.prank(owner);
        vm.expectRevert(bytes("llm failed"));
        bounty.judgeAll(id, hex"deadbeef");
    }

    function test_JudgeAll_RevertAlreadyJudged() public {
        uint256 id = _setupRevealed();
        vm.warp(revDeadline);
        _installSuccessStub();
        vm.startPrank(owner);
        bounty.judgeAll(id, hex"deadbeef");
        vm.expectRevert(bytes("already judged"));
        bounty.judgeAll(id, hex"deadbeef");
        vm.stopPrank();
    }

    // ----------------------------- finalize ------------------------------ //

    function test_Finalize_RevertNotJudged() public {
        uint256 id = _setupRevealed();
        vm.warp(revDeadline);
        vm.prank(owner);
        vm.expectRevert(bytes("not judged"));
        bounty.finalizeWinner(id, 0);
    }

    function test_Finalize_RevertNotOwner() public {
        uint256 id = _setupRevealed();
        vm.warp(revDeadline);
        _installSuccessStub();
        vm.prank(owner);
        bounty.judgeAll(id, hex"de");
        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        bounty.finalizeWinner(id, 0);
    }

    function test_Finalize_RevertWinnerNotRevealed() public {
        uint256 id = _create();
        // alice reveals, carol only commits (never reveals)
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash("alice", keccak256("a"), alice, id));
        vm.prank(carol);
        bounty.submitCommitment(id, _commitHash("carol", keccak256("c"), carol, id));
        vm.warp(subDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "alice", keccak256("a"));
        vm.warp(revDeadline);
        _installSuccessStub();
        vm.startPrank(owner);
        bounty.judgeAll(id, hex"de");
        vm.expectRevert(bytes("winner not revealed"));
        bounty.finalizeWinner(id, 1); // carol's slot, unrevealed
        vm.stopPrank();
    }

    function test_Finalize_RevertBadIndex() public {
        uint256 id = _setupRevealed();
        vm.warp(revDeadline);
        _installSuccessStub();
        vm.startPrank(owner);
        bounty.judgeAll(id, hex"de");
        vm.expectRevert(bytes("bad index"));
        bounty.finalizeWinner(id, 99);
        vm.stopPrank();
    }

    function test_Finalize_PaysWinnerOnce() public {
        uint256 id = _setupRevealed();
        vm.warp(revDeadline);
        _installSuccessStub();

        uint256 bobBefore = bob.balance;
        vm.startPrank(owner);
        bounty.judgeAll(id, hex"de");

        vm.expectEmit(true, true, true, true);
        emit WinnerFinalized(id, 1, bob, REWARD);
        bounty.finalizeWinner(id, 1); // bob is index 1

        assertEq(bob.balance, bobBefore + REWARD);
        assertEq(address(bounty).balance, 0);

        vm.expectRevert(bytes("already finalized"));
        bounty.finalizeWinner(id, 1);
        vm.stopPrank();
    }

    // ------------------------------ cancel ------------------------------- //

    function test_Cancel_RefundsWhenNoReveals() public {
        uint256 id = _create();
        vm.prank(alice);
        bounty.submitCommitment(id, _commitHash("a", keccak256("a"), alice, id));
        vm.warp(revDeadline); // nobody revealed
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        bounty.cancelBounty(id);
        assertEq(owner.balance, ownerBefore + REWARD);
        assertEq(address(bounty).balance, 0);
    }

    function test_Cancel_RevertHasReveals() public {
        uint256 id = _setupRevealed();
        vm.warp(revDeadline);
        vm.prank(owner);
        vm.expectRevert(bytes("has reveals"));
        bounty.cancelBounty(id);
    }

    function test_Cancel_RevertBeforeRevealOver() public {
        uint256 id = _create();
        vm.prank(owner);
        vm.expectRevert(bytes("reveal not over"));
        bounty.cancelBounty(id);
    }

    // --------------------------- parity / fuzz --------------------------- //

    function test_ComputeCommitment_MatchesScheme() public view {
        bytes32 onchain = bounty.computeCommitment("answer", bytes32("salt"), alice, 1);
        bytes32 local = keccak256(abi.encodePacked("answer", bytes32("salt"), alice, uint256(1)));
        assertEq(onchain, local);
    }

    function testFuzz_CommitReveal_RoundTrip(string calldata answer, bytes32 salt) public {
        vm.assume(bytes(answer).length <= bounty.MAX_ANSWER_LENGTH());
        uint256 id = _create();
        bytes32 c = bounty.computeCommitment(answer, salt, alice, id);
        vm.prank(alice);
        bounty.submitCommitment(id, c);
        vm.warp(subDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, answer, salt);
        (, , bool revealed, string memory stored) = bounty.getSubmission(id, 0);
        assertTrue(revealed);
        assertEq(stored, answer);
    }
}
