// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVerdictModule {
    struct Reviewer {
        bool isRegistered;
        uint256 lockedBond;
        uint64 registeredAt;
    }

    struct Verdict {
        uint256 bountyId;
        uint256 winningSubmissionId;
        uint256[] slashedSubmissionIds;
        bytes32 evidenceAnchor;
        uint256 expiresAt;
        uint256 nonce;
    }

    event ReviewerRegistered(address indexed reviewer, uint256 lockedBond);
    event ReviewerUnregistered(address indexed reviewer, uint256 returnedBond);
    event ReviewerBondToppedUp(address indexed reviewer, uint256 added, uint256 newTotal);
    event AssignmentAccepted(uint256 indexed bountyId, address indexed reviewer);
    event AssignmentRejected(uint256 indexed bountyId, address indexed reviewer);
    event PoolBountyClaimed(uint256 indexed bountyId, address indexed reviewer);
    event VerdictSubmitted(
        uint256 indexed bountyId, address indexed reviewer, uint256 winningSubmissionId, uint256 slashedCount
    );

    function registerReviewer(
        uint256 bountyBondAmount
    ) external;

    function unregisterReviewer() external;

    function topUpBond(
        uint256 bountyBondAmount
    ) external;

    function acceptAssignment(
        uint256 bountyId
    ) external;

    function rejectAssignment(
        uint256 bountyId
    ) external;

    function claimPoolBounty(
        uint256 bountyId
    ) external;

    function submitVerdict(
        Verdict calldata verdict,
        bytes calldata signature
    ) external;

    function requiredBondForBounty(
        uint256 payoutMax
    ) external view returns (uint256);

    function getReviewer(
        address reviewer
    ) external view returns (Reviewer memory);

    function reviewerNonce(
        address reviewer
    ) external view returns (uint256);

    function isAssigned(
        uint256 bountyId,
        address reviewer
    ) external view returns (bool);
}
