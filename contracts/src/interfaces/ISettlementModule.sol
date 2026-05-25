// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISettlementModule {
    event BountySettled(
        uint256 indexed bountyId,
        address indexed hunter,
        uint256 hunterPayout,
        uint256 reviewerFee,
        uint256 protocolFeeBurn,
        uint256 protocolFeeKeep
    );
    event BondsReturned(uint256 indexed bountyId, uint256 returnedCount, uint256 totalReturned);
    event BondSlashed(
        uint256 indexed bountyId,
        uint256 indexed submissionId,
        uint256 slashAmount,
        uint256 toReviewer,
        uint256 toTreasury,
        uint256 toBurn
    );
    event HunterClaimed(uint256 indexed bountyId, address indexed hunter, uint256 amount);
    event SponsorRefunded(uint256 indexed bountyId, address indexed sponsor, uint256 amount);
    event VerdictAttested(
        uint256 indexed bountyId,
        address indexed reviewer,
        uint256 winningSubmissionId,
        bytes payload
    );
    event SponsorDiscountApplied(uint256 indexed bountyId, address indexed sponsor, uint256 effectiveFeeBps);

    function settle(uint256 bountyId) external;

    function claim(uint256 bountyId) external;

    function refundSponsor(uint256 bountyId) external;
}
