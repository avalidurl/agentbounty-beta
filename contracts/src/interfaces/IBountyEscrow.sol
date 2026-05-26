// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBountyEscrow {
    enum BountyState {
        Draft,
        Funded,
        InReview,
        Queued,
        Settled,
        Claimed,
        Refunded,
        Disputed
    }

    struct Bounty {
        address sponsor;
        address proposedReviewer;
        address assignedReviewer;
        uint96 reviewerProposedAt;
        uint256 payoutMax;
        uint256 baseBond;
        uint64 reviewWindow;
        uint64 challengeWindow;
        uint64 fundedAt;
        uint64 verdictedAt;
        bytes32 specHash;
        BountyState state;
        uint256 winningSubmissionId;
        uint256[] submissionIds;
    }

    struct Submission {
        uint256 bountyId;
        address submitter;
        uint64 submittedAt;
        uint256 paidBond;
        bytes32 artifactHash;
        bytes32 evidenceHash;
        bool isSlashed;
    }

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed sponsor,
        address indexed proposedReviewer,
        uint256 payoutMax,
        uint256 baseBond,
        bytes32 specHash
    );
    event BountyFunded(uint256 indexed bountyId, uint256 usdcAmount);
    event BountyCancelled(uint256 indexed bountyId);
    event BountyRefunded(uint256 indexed bountyId, uint256 usdcAmount);
    event ReviewerAssigned(uint256 indexed bountyId, address indexed reviewer);
    event ReviewerRejected(uint256 indexed bountyId, address indexed reviewer);
    event SubmissionCreated(
        uint256 indexed bountyId,
        uint256 indexed submissionId,
        address indexed submitter,
        uint256 paidBond,
        uint256 burnedBond,
        bytes32 artifactHash
    );
    event VerdictRecorded(
        uint256 indexed bountyId,
        uint256 indexed winningSubmissionId,
        uint256[] slashedSubmissionIds,
        bytes32 evidenceAnchor
    );
    event BountySettled(uint256 indexed bountyId);
    event BountyClaimed(uint256 indexed bountyId, address indexed hunter);
    event Disputed(uint256 indexed bountyId, address indexed challenger, uint256 challengerBond);
    event DisputeResolved(uint256 indexed bountyId, bool awardHunter);

    function createBounty(
        uint256 payoutMax,
        uint256 baseBond,
        uint64 reviewWindow,
        uint64 challengeWindow,
        bytes32 specHash,
        address proposedReviewer
    ) external returns (uint256 bountyId);

    function fundBounty(
        uint256 bountyId
    ) external;

    function cancel(
        uint256 bountyId
    ) external;

    function refund(
        uint256 bountyId
    ) external;

    function submit(
        uint256 bountyId,
        bytes32 artifactHash,
        bytes32 evidenceHash
    ) external returns (uint256 submissionId);

    function dispute(
        uint256 bountyId
    ) external;

    function resolveDispute(
        uint256 bountyId,
        bool awardHunter
    ) external;

    function markAssigned(
        uint256 bountyId,
        address reviewer
    ) external;

    function markRejectedAndPooled(
        uint256 bountyId
    ) external;

    function markVerdicted(
        uint256 bountyId,
        uint256 winningSubmissionId,
        uint256[] calldata slashedSubmissionIds,
        bytes32 evidenceAnchor
    ) external;

    function markSettled(
        uint256 bountyId
    ) external;

    function markClaimed(
        uint256 bountyId
    ) external;

    function markRefundedFromQueued(
        uint256 bountyId
    ) external;

    function withdrawUSDC(
        address to,
        uint256 amount
    ) external;

    function withdrawBounty(
        address to,
        uint256 amount
    ) external;

    function withdrawBountyToBurn(
        uint256 amount
    ) external;

    function getBounty(
        uint256 bountyId
    ) external view returns (Bounty memory);

    function getSubmission(
        uint256 submissionId
    ) external view returns (Submission memory);

    function getSubmissionIds(
        uint256 bountyId
    ) external view returns (uint256[] memory);

    function currentBondCost(
        uint256 bountyId
    ) external view returns (uint256 totalCost, uint256 baseBond, uint256 burnAmount);

    function bountyExists(
        uint256 bountyId
    ) external view returns (bool);

    function getCurrentMultiplierBps(
        uint256 bountyId
    ) external view returns (uint256);

    function disputeResolved(
        uint256 bountyId
    ) external view returns (bool resolved, bool awardHunter);

    function REVIEWER_REJECT_WINDOW() external view returns (uint64);

    function MAX_SUBMISSIONS() external view returns (uint256);

    function BOND_MULTIPLIER_BPS() external view returns (uint256);

    function BOND_CAP_MULTIPLIER() external view returns (uint256);

    function BPS_DENOMINATOR() external view returns (uint256);

    function BURN_ADDRESS() external view returns (address);

    function feeRecipient() external view returns (address);

    function challengeContract() external view returns (address);
}
