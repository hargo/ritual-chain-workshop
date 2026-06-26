// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SealedBountyJudge} from "./SealedBountyJudge.sol";
import {LLMSuccessStub, LLMErrorStub} from "./CommitRevealBounty.t.sol";

contract SealedBountyJudgeTest is Test {
    SealedBountyJudge internal bounty;

    address internal owner = makeAddr("owner");
    address internal executor = makeAddr("teeExecutor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal constant LLM = address(0x0802);
    uint256 internal constant REWARD = 1 ether;
    uint256 internal deadline;

    event SealedSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        uint256 indexed submissionIndex,
        bytes32 digest,
        bytes ciphertext
    );
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

    function setUp() public {
        bounty = new SealedBountyJudge();
        deadline = block.timestamp + 1 days;
        vm.deal(owner, 10 ether);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(owner);
        id = bounty.createBounty{value: REWARD}(
            executor,
            "Sealed bounty",
            "Best answer wins.",
            deadline
        );
    }

    function _installSuccessStub() internal {
        LLMSuccessStub stub = new LLMSuccessStub();
        vm.etch(LLM, address(stub).code);
    }

    function _installErrorStub() internal {
        LLMErrorStub stub = new LLMErrorStub();
        vm.etch(LLM, address(stub).code);
    }

    function _seed() internal returns (uint256 id) {
        id = _create();
        vm.prank(alice);
        bounty.submitSealed(id, hex"a11ce0");
        vm.prank(bob);
        bounty.submitSealed(id, hex"b0bb1e");
        vm.warp(deadline);
    }

    // ------------------------------ create ------------------------------- //

    function test_Create_EscrowsAndSetsExecutor() public {
        uint256 id = _create();
        (
            address bOwner,
            address bExecutor,
            ,
            ,
            uint256 reward,
            uint256 sd,
            ,
            ,
            ,
            uint256 total,
            ,
            ,
            ,

        ) = bounty.getBounty(id);
        assertEq(bOwner, owner);
        assertEq(bExecutor, executor);
        assertEq(reward, REWARD);
        assertEq(sd, deadline);
        assertEq(total, 0);
        assertEq(address(bounty).balance, REWARD);
    }

    function test_Create_RevertNoExecutor() public {
        vm.prank(owner);
        vm.expectRevert(bytes("executor required"));
        bounty.createBounty{value: REWARD}(address(0), "t", "r", deadline);
    }

    function test_Create_RevertNoReward() public {
        vm.prank(owner);
        vm.expectRevert(bytes("reward required"));
        bounty.createBounty(executor, "t", "r", deadline);
    }

    // --------------------------- submitSealed ---------------------------- //

    function test_Submit_StoresCiphertextOnly() public {
        uint256 id = _create();
        bytes memory ct = hex"deadbeefcafe";
        vm.expectEmit(true, true, true, true);
        emit SealedSubmitted(id, alice, 0, keccak256(ct), ct);
        vm.prank(alice);
        bounty.submitSealed(id, ct);

        (address submitter, bytes32 digest, bytes memory ciphertext) =
            bounty.getSealedSubmission(id, 0);
        assertEq(submitter, alice);
        assertEq(digest, keccak256(ct));
        assertEq(ciphertext, ct);
    }

    function test_Submit_RevertEmpty() public {
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(bytes("empty ciphertext"));
        bounty.submitSealed(id, "");
    }

    function test_Submit_RevertTooLong() public {
        uint256 id = _create();
        bytes memory big = new bytes(bounty.MAX_CIPHERTEXT_LENGTH() + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("ciphertext too long"));
        bounty.submitSealed(id, big);
    }

    function test_Submit_RevertDouble() public {
        uint256 id = _create();
        vm.startPrank(alice);
        bounty.submitSealed(id, hex"01");
        vm.expectRevert(bytes("already submitted"));
        bounty.submitSealed(id, hex"02");
        vm.stopPrank();
    }

    function test_Submit_RevertAfterDeadline() public {
        uint256 id = _create();
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(bytes("submissions closed"));
        bounty.submitSealed(id, hex"01");
    }

    // ------------------------------ judge -------------------------------- //

    function test_Judge_RevertNotOwner() public {
        uint256 id = _seed();
        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        bounty.judgeAll(id, hex"00");
    }

    function test_Judge_RevertBeforeDeadline() public {
        uint256 id = _create();
        vm.prank(alice);
        bounty.submitSealed(id, hex"01");
        vm.prank(owner);
        vm.expectRevert(bytes("submissions open"));
        bounty.judgeAll(id, hex"00");
    }

    function test_Judge_RevertNoSubmissions() public {
        uint256 id = _create();
        vm.warp(deadline);
        vm.prank(owner);
        vm.expectRevert(bytes("no submissions"));
        bounty.judgeAll(id, hex"00");
    }

    function test_Judge_SuccessStoresReview() public {
        uint256 id = _seed();
        _installSuccessStub();
        vm.prank(owner);
        bounty.judgeAll(id, hex"deadbeef");
        (, , , , , , bool judged, , , , , , , bytes memory review) =
            bounty.getBounty(id);
        assertTrue(judged);
        assertEq(review, bytes('{"winnerIndex":0,"summary":"ok"}'));
    }

    function test_Judge_RevertOnLlmError() public {
        uint256 id = _seed();
        _installErrorStub();
        vm.prank(owner);
        vm.expectRevert(bytes("llm failed"));
        bounty.judgeAll(id, hex"deadbeef");
    }

    // -------------------------- revealed bundle -------------------------- //

    function test_PublishRevealed_StoresRefAndHash() public {
        uint256 id = _seed();
        _installSuccessStub();
        vm.startPrank(owner);
        bounty.judgeAll(id, hex"de");

        bytes32 h = keccak256("bundle");
        vm.expectEmit(true, false, false, true);
        emit AnswersRevealed(id, "ipfs://bundle", h);
        bounty.publishRevealedAnswers(id, "ipfs://bundle", h);
        vm.stopPrank();

        (, , , , , , , , , , , string memory ref, bytes32 hash, ) =
            bounty.getBounty(id);
        assertEq(ref, "ipfs://bundle");
        assertEq(hash, h);
    }

    function test_PublishRevealed_RevertNotJudged() public {
        uint256 id = _seed();
        vm.prank(owner);
        vm.expectRevert(bytes("not judged"));
        bounty.publishRevealedAnswers(id, "ipfs://x", keccak256("x"));
    }

    // ----------------------------- finalize ------------------------------ //

    function test_Finalize_RevertNotJudged() public {
        uint256 id = _seed();
        vm.prank(owner);
        vm.expectRevert(bytes("not judged"));
        bounty.finalizeWinner(id, 0);
    }

    function test_Finalize_PaysWinnerOnce() public {
        uint256 id = _seed();
        _installSuccessStub();
        uint256 aliceBefore = alice.balance;
        vm.startPrank(owner);
        bounty.judgeAll(id, hex"de");
        vm.expectEmit(true, true, true, true);
        emit WinnerFinalized(id, 0, alice, REWARD);
        bounty.finalizeWinner(id, 0);
        assertEq(alice.balance, aliceBefore + REWARD);
        assertEq(address(bounty).balance, 0);
        vm.expectRevert(bytes("already finalized"));
        bounty.finalizeWinner(id, 0);
        vm.stopPrank();
    }

    function test_Finalize_RevertBadIndex() public {
        uint256 id = _seed();
        _installSuccessStub();
        vm.startPrank(owner);
        bounty.judgeAll(id, hex"de");
        vm.expectRevert(bytes("bad index"));
        bounty.finalizeWinner(id, 5);
        vm.stopPrank();
    }

    // ------------------------------ cancel ------------------------------- //

    function test_Cancel_RefundsWhenNoSubmissions() public {
        uint256 id = _create();
        vm.warp(deadline);
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        bounty.cancelBounty(id);
        assertEq(owner.balance, ownerBefore + REWARD);
        assertEq(address(bounty).balance, 0);
    }

    function test_Cancel_RevertHasSubmissions() public {
        uint256 id = _seed();
        vm.prank(owner);
        vm.expectRevert(bytes("has submissions"));
        bounty.cancelBounty(id);
    }
}
