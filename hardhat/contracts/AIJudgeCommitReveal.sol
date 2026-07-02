// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @title AIJudgeCommitReveal
/// @notice Privacy-preserving AI Bounty Judge using a commit-reveal flow.
///
/// Lifecycle:
///   1. COMMIT  (now < submissionDeadline)   participants submit only a hash
///   2. REVEAL  (submissionDeadline <= now < revealDeadline)
///                                            participants reveal answer + salt
///   3. JUDGE   (now >= revealDeadline)      owner batch-judges revealed
///                                            answers with one Ritual LLM call
///   4. FINALIZE                              owner picks winner, reward paid
///
/// Commitment formula (binds answer to sender and bounty):
///   keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
contract AIJudgeCommitReveal is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    struct Submission {
        address submitter;
        bytes32 commitment;
        bool revealed;
        string answer; // empty until revealed
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline; // commit phase ends
        uint256 revealDeadline; // reveal phase ends
        uint256 revealedCount;
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        Submission[] submissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) private bounties;

    /// bountyId => participant => submission index + 1 (0 = has not committed)
    mapping(uint256 => mapping(address => uint256)) public commitIndexPlusOne;

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
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    event BountyCancelled(uint256 indexed bountyId, uint256 refundedReward);

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    // ---------------------------------------------------------------------
    // 0. Create
    // ---------------------------------------------------------------------

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submissionDeadline > block.timestamp, "submission deadline in past");
        require(revealDeadline > submissionDeadline, "reveal must follow submission");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];

        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    // ---------------------------------------------------------------------
    // 1. Commit phase — only a hash goes on-chain
    // ---------------------------------------------------------------------

    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.submissionDeadline, "commit phase over");
        require(commitment != bytes32(0), "empty commitment");
        require(commitIndexPlusOne[bountyId][msg.sender] == 0, "already committed");
        require(bounty.submissions.length < MAX_SUBMISSIONS, "too many submissions");

        bounty.submissions.push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                revealed: false,
                answer: ""
            })
        );

        uint256 index = bounty.submissions.length - 1;
        commitIndexPlusOne[bountyId][msg.sender] = index + 1;

        emit CommitmentSubmitted(bountyId, index, msg.sender, commitment);
    }

    // ---------------------------------------------------------------------
    // 2. Reveal phase — answer + salt must reproduce the commitment
    // ---------------------------------------------------------------------

    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.submissionDeadline, "reveal not started");
        require(block.timestamp < bounty.revealDeadline, "reveal phase over");
        require(bytes(answer).length > 0, "empty answer");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 indexPlusOne = commitIndexPlusOne[bountyId][msg.sender];
        require(indexPlusOne != 0, "no commitment");

        Submission storage submission = bounty.submissions[indexPlusOne - 1];
        require(!submission.revealed, "already revealed");

        // Binding msg.sender + bountyId prevents commitment copying:
        // an attacker who copies someone else's hash can never reveal it.
        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(expected == submission.commitment, "commitment mismatch");

        submission.revealed = true;
        submission.answer = answer;
        bounty.revealedCount += 1;

        emit AnswerRevealed(bountyId, indexPlusOne - 1, msg.sender);
    }

    // ---------------------------------------------------------------------
    // 3. Judge — ONE batch LLM call for all revealed answers
    // ---------------------------------------------------------------------

    /// @param llmInput ABI-encoded Ritual LLM request built off-chain from
    ///        the rubric + all revealed answers (see getRevealedAnswers).
    ///        One request judges the whole batch — never one call per answer.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal phase not over");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.revealedCount > 0, "no revealed answers");

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

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    // ---------------------------------------------------------------------
    // 4. Finalize — human-in-the-loop; AI recommends, owner decides
    // ---------------------------------------------------------------------

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid index");
        // Unrevealed submissions are never eligible to win.
        require(bounty.submissions[winnerIndex].revealed, "winner not revealed");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0; // effects before interaction (reentrancy safe)

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    /// @notice Escape hatch: if nobody reveals a valid answer, the owner can
    ///         reclaim the reward after the reveal deadline.
    function cancelBounty(
        uint256 bountyId
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal phase not over");
        require(bounty.revealedCount == 0, "answers were revealed");
        require(!bounty.finalized, "already finalized");

        bounty.finalized = true;

        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(bounty.owner).call{value: reward}("");
        require(ok, "refund failed");

        emit BountyCancelled(bountyId, reward);
    }

    // ---------------------------------------------------------------------
    // Views & helpers
    // ---------------------------------------------------------------------

    /// @notice Client-side helper mirroring the on-chain commitment check.
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address sender,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, sender, bountyId));
    }

    struct BountyView {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        uint256 submissionCount;
        uint256 revealedCount;
        uint256 winnerIndex;
        bytes aiReview;
    }

    function getBounty(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (BountyView memory v) {
        Bounty storage bounty = bounties[bountyId];

        v.owner = bounty.owner;
        v.title = bounty.title;
        v.rubric = bounty.rubric;
        v.reward = bounty.reward;
        v.submissionDeadline = bounty.submissionDeadline;
        v.revealDeadline = bounty.revealDeadline;
        v.judged = bounty.judged;
        v.finalized = bounty.finalized;
        v.submissionCount = bounty.submissions.length;
        v.revealedCount = bounty.revealedCount;
        v.winnerIndex = bounty.winnerIndex;
        v.aiReview = bounty.aiReview;
    }

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
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");

        Submission storage submission = bounty.submissions[index];

        return (
            submission.submitter,
            submission.commitment,
            submission.revealed,
            submission.answer
        );
    }

    /// @notice All revealed answers with their original indices.
    ///         The frontend uses this to build ONE batch judging prompt.
    function getRevealedAnswers(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (uint256[] memory indices, string[] memory answers)
    {
        Bounty storage bounty = bounties[bountyId];

        uint256 count = bounty.revealedCount;
        indices = new uint256[](count);
        answers = new string[](count);

        uint256 cursor = 0;
        for (uint256 i = 0; i < bounty.submissions.length; i++) {
            if (bounty.submissions[i].revealed) {
                indices[cursor] = i;
                answers[cursor] = bounty.submissions[i].answer;
                cursor++;
            }
        }
    }
}
