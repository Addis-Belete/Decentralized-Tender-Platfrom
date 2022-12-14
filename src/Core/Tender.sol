// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.7;

import "openzeppelin-contracts/interfaces/IERC721.sol";
import "../Interfaces/IVerifier.sol";
import "forge-std/console.sol";
/**
 * @notice Is contract that contains a logic to create and bid to tender
 * @title Tenders contract
 * @author Addis Belete
 */

contract Tenders {
    enum Stages {
        open, // is when bidding finished and bidder can verify his proof
        closed // is when proposal closed
    }

    // status of suppleir bid. Organization can look at there profile and approve or decline the bid from supplier
    enum Status {
        pending,
        approved,
        declined
    }

    struct Tender {
        uint256 organizationId; //The Id of the orginization who creates the tender
        string tenderURI; //The URI of the tender
        uint256 Id; // The Id of this tender
        Stages stage; // The stage of the tender
        uint256 bidStartTime; //The time where bidding started;
        uint256 bidEndTime; // The time where bidding ends
        uint256 verifyingTime; // the duration where bidders verify there proofs
        Winner winner; // The Id of the winner
        bool isPaused; //Is true if the tender owner paused the tender
        uint256 fee; //Fee payed to post create the tender
    }
    //Suppleir bid information

    struct Bid {
        uint256 proof; //Proof of the bid
        uint256 value; // The price/value of bid
        Status status; // status of the bid
        bool claimable; // true if claimable
        uint256 fee; //fee paid to bid
    }

    struct Winner {
        uint256 suppleirId; //The Id of the winner
        uint256 winningValue; //The price at which the winner was won
    }

    uint256 public postPlatformFee; //Platform fee payed by Tender Poster
    uint256 public bidPlatformFee; //Platform fee payed by Bidder
    uint256 private profit; //Total profit the platform collects
    uint256 internal tenderId;
    address public owner; // deployer address

    IERC721 Org; // Interface for Organization contract
    IERC721 supp; // Interface for suppleir contract
    IVerifier verifier;
    mapping(uint256 => Tender) private tenders; // tenderId -> Tender
    mapping(uint256 => mapping(uint256 => Bid)) private bidding; // tenderId -> tokenId -> Bid
    mapping(uint256 => uint256[]) private biddersId; // tenderId -> bidders(suppliers) Id
    mapping(uint256 => uint256[]) private suppBid; // mapping that stores Ids of all tenders that suppleir can bids
    mapping(uint256 => mapping(address => bool)) private isBidded;
    /**
     * @notice Emitted when a new tender created.
     * @param orgId The Id of the organization who created the tender
     * @param tenderId The Id of the created tender
     * @param bidEndDate The Date where bidding ends
     */

    event NewTenderCreated(
        uint256 indexed orgId, uint256 indexed tenderId, uint256 indexed bidEndDate, uint256 verifyingEndDate
    );

    /**
     * @notice Emitted when there is new bid for a particular tender
     * @param tenderId The Id of the tender
     * @param suppleirId The Id of the suppleir who bids
     */
    event NewBidAdded(uint256 indexed tenderId, uint256 indexed suppleirId);

    /**
     * @notice Emitted when the status of the bid changed. wether approved or declined
     * @param tenderId The Id of the tender where the suppleir bids
     * @param suppleirId The Id of suppleir who bids
     */
    event BidStatusChanged(uint256 indexed tenderId, uint256 indexed suppleirId, Status status);

    /**
     * @notice Emitted When Fund is returned to a user
     * @param tenderId The Id of tender
     * @param suppleirId The Id of the suppleir
     */
    event FundReturned(uint256 indexed tenderId, uint256 indexed suppleirId);

    /**
     * @notice Emittes when suppleir can verify the bid
     * @param tenderId Id of a particular tender
     * @param suppleirId The Id of the suppleir who verifies the bid
     */
    event BidVerified(uint256 indexed tenderId, uint256 indexed suppleirId);

    /**
     * @notice Emitted when tender owner announces the winner
     * @param tenderId The Id of the tender
     * @param suppleirId The Id of the suppleir who wins the bid
     * @param winningValue winning value
     */
    event WinnerAnnounced(uint256 indexed tenderId, uint256 indexed suppleirId, uint256 indexed winningValue);
    /**
     * @notice Emitted when paused or restarted
     * @param tenderId The Id of the tender
     * @param isPaused true if paused else false
     */
    event TenderStatus(uint256 indexed tenderId, bool isPaused);

    /**
     * @notice Emitted when Platfrom fee updated
     * @param type_ The type of fee updated bid or post platfrom fee
     * @param fee The updated number of fee
     */
    event PlatformFeeUpdated(uint8 type_, uint256 fee);

    modifier isTenderAvailable(uint256 tenderId_) {
        require(tenderId_ > 0 && tenderId_ <= tenderId, "tender not found");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == owner, "Only called by owner");
        _;
    }

    constructor(address organizationAddress_, address suppleirAddress_, address verifierAddress_) {
        Org = IERC721(organizationAddress_);
        supp = IERC721(suppleirAddress_);
        verifier = IVerifier(verifierAddress_);
        owner = msg.sender;
        bidPlatformFee = 0.0000000005 ether;
        postPlatformFee = 0.0000000005 ether;
    }
    /**
     * @notice Add's new tender to the contract
     * @dev The creator can pay 2gwei to list his tender and only registered organization or company call this function
     * @param orgId_ The Id of the organization or company
     * @param tenderURI_ The metadata of the tender
     * @param bidPeriod The duration of the bid
     * @param verifyingPeriod The duration of verifying the proof
     */

    function createNewTender(uint256 orgId_, string memory tenderURI_, uint256 bidPeriod, uint256 verifyingPeriod)
        external
        payable
    {
        isAllowed_(1, orgId_);
        require(msg.value == postPlatformFee, "fee != postPlatformFee");
        tenderId++;
        uint256 bidEnd_ = (bidPeriod * 1 minutes) + block.timestamp;
        uint256 verifyingEndDate_ = bidEnd_ + verifyingPeriod * 1 minutes;
        tenders[tenderId] = Tender({
            organizationId: orgId_,
            tenderURI: tenderURI_,
            Id: tenderId,
            stage: Stages.open,
            bidStartTime: block.timestamp,
            bidEndTime: bidEnd_,
            verifyingTime: verifyingEndDate_,
            winner: Winner(0, 0),
            isPaused: false,
            fee: postPlatformFee
        });

        emit NewTenderCreated(orgId_, tenderId, bidEnd_, verifyingEndDate_);
    }

    /**
     * @notice User can bid for tender using this function and pay 0.5 eth for bidding.
     * @dev The eth deducted from winner only. other bidder can claim there funds after bidding closed
     * @param suppleirId_ The Id of the suppleir
     * @param tenderId_ The Id of the tender
     * @param proof_ The proof a user can provide
     */
    function bid(uint256 suppleirId_, uint256 tenderId_, uint256 proof_)
        external
        payable
        isTenderAvailable(tenderId_)
    {
        isAllowed_(0, suppleirId_);
        address suppleirOwner = supp.ownerOf(suppleirId_);
        require(!isBidded[tenderId_][suppleirOwner], "You already bidded on this tender");
        require(msg.value == bidPlatformFee, "fee != bidPlatformFee");
        Tender memory tender_ = tenders[tenderId_];
        require(tender_.stage == Stages.open, "Tender already closed");
        uint256 endDate = tender_.bidEndTime;
        require(block.timestamp < endDate, "Bidding period finished");
        require(!tender_.isPaused, "Tender paused!");
        isBidded[tenderId_][suppleirOwner] = true;
        bidding[tenderId][suppleirId_] =
            Bid({proof: proof_, value: 0, status: Status.pending, claimable: true, fee: bidPlatformFee});

        biddersId[tenderId].push(suppleirId_);
        suppBid[suppleirId_].push(tenderId);

        emit NewBidAdded(tenderId_, suppleirId_);
    }

    /**
     * @notice Changes the status of the bid from pending to approve or decline
     * @dev only called by tender owner
     * @param tenderId_ The id of the tender
     * @param suppleirId_ The Id of the suppleir
     * @param status_ The Status of the bid to be changed
     */

    function approveOrDeclineBid(uint256 tenderId_, uint256 suppleirId_, Status status_)
        external
        isTenderAvailable(tenderId_)
    {
        Tender memory tender_ = tenders[tenderId_];
        uint256 tenderOwner_ = tender_.organizationId;
        Bid storage bid_ = bidding[tenderId_][suppleirId_];
        isAllowed_(1, tenderOwner_);
        require(!tender_.isPaused, "Tender paused!");
        require(tender_.stage == Stages.open, "Tender closed");
        require(tender_.bidEndTime >= block.timestamp, "verifying period");

        bid_.status = status_;

        emit BidStatusChanged(tenderId_, suppleirId_, status_);
    }
    /**
     * @notice Verifies the proof and set the winner;
     * @dev If two bidders bid same amount the one who verified first can win the bid
     * @param a a
     * @param b b
     * @param c c
     * @param input input
     */

    function verifyBid(uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[4] memory input)
        external
    {
        require(verifier.verifyProof(a, b, c, input), "Proof not valid");

        uint256 tenderId_ = uint256(input[1]);
        uint256 suppleirId_ = uint256(input[2]);
        uint256 bidValue_ = uint256(input[3]);

        Bid storage bid_ = bidding[tenderId_][suppleirId_];
        Tender storage tender_ = tenders[tenderId_];
        require(!tender_.isPaused, "Tender paused!");
        require(tender_.stage == Stages.open, "Tender closed");
        require(block.timestamp > tender_.bidEndTime, "Verifying period not started ");
        require(bid_.proof == input[0], "Proof not same");
        require(bid_.status == Status(1), "bid declined");
        require(bid_.value == 0, "Already Verified");

        bid_.value = bidValue_;

        if (tender_.winner.winningValue == 0) {
            tender_.winner = Winner(suppleirId_, bidValue_);
        } else if (tender_.winner.winningValue > 0 && tender_.winner.winningValue > bidValue_) {
            tender_.winner = Winner(suppleirId_, bidValue_);
        }

        emit BidVerified(tenderId_, suppleirId_);
    }

    /**
     * @notice Used to announce the winner and only called once
     * @param tenderId_ The Id of the tender
     */
    function announceWinner(uint256 tenderId_) external isTenderAvailable(tenderId_) {
        Tender storage tender_ = tenders[tenderId_];
        require(!tender_.isPaused, "Tender paused");
        uint256 tenderOwner_ = tender_.organizationId;
        isAllowed_(1, tenderOwner_);
        require(block.timestamp > tender_.verifyingTime, "Verifying period not ended");
        require(tender_.stage == Stages.open, "Winner already announced");
        tender_.stage = Stages.closed;
        Bid storage bid_ = bidding[tenderId_][tender_.winner.suppleirId];
        bid_.claimable = false;
        profit += (bid_.fee + tender_.fee);
        emit WinnerAnnounced(tenderId_, tender_.winner.suppleirId, tender_.winner.winningValue);
    }

    /**
     * @notice Pause the tender for certain period of time
     */
    function pauseTender(uint256 tenderId_) external isTenderAvailable(tenderId_) {
        Tender storage tender_ = tenders[tenderId_];
        require(!tender_.isPaused, "Tender paused");
        uint256 tenderOwner_ = tender_.organizationId;
        isAllowed_(1, tenderOwner_);
        tender_.isPaused = true;

        emit TenderStatus(tenderId_, true);
    }

    /**
     * @notice used to restart the paused tender
     */
    function restartTender(uint256 tenderId_, uint256 bidPeriod, uint256 verifyingPeriod)
        external
        isTenderAvailable(tenderId_)
    {
        Tender storage tender_ = tenders[tenderId_];
        require(tender_.isPaused, "Tender not paused");
        uint256 tenderOwner_ = tender_.organizationId;
        isAllowed_(1, tenderOwner_);

        uint256 bidEnd_ = (bidPeriod * 1 days) + block.timestamp;
        uint256 verifyingEndDate_ = bidEnd_ + verifyingPeriod * 1 days;

        tender_.isPaused = false;
        tender_.bidEndTime = bidEnd_;
        tender_.verifyingTime = verifyingEndDate_;
        emit TenderStatus(tenderId_, false);
    }
    /**
     * @notice Used to return funds of user who not won the bid for a particular tenders
     * @param tenderId_ The Id of the tender
     * @param suppleirId_ The Id of the suppleir
     */

    function returnFunds(uint256 tenderId_, uint256 suppleirId_) external isTenderAvailable(tenderId_) {
        isAllowed_(0, suppleirId_); // check if the msg sender is a supplier or have allowance to claim a funds
        Tender memory tender_ = tenders[tenderId_];

        require(tender_.stage == Stages.closed, "Tender not closed");
        Bid storage bid_ = bidding[tenderId_][suppleirId_];

        // require(bid_.proof != bytes32(0x0), "Bid not found");
        require(bid_.claimable, "Winner or already fund returned");

        bid_.claimable = false;
        (bool success,) = msg.sender.call{value: bid_.fee}("");
        require(success, "fund return failed");

        emit FundReturned(tenderId_, suppleirId_);
    }
    /**
     * @notice Withdraws profit from the platform
     * @dev only called by the admin
     * @param amount The number needed to withdraw
     */

    function withdrawProfit(uint256 amount) external onlyAdmin {
        require(profit >= amount, "Not enough profit");
        unchecked {
            profit -= amount;
        }

        (bool success,) = owner.call{value: amount}("");
        require(success, "withdraw failed!");
    }

    /**
     * @notice Update the platforms fee
     * @dev only called by the admin
     * @param type_ The type of platform fee we want to update. 0 for bidPlatform Fee or 1 for postPlatformfee
     */
    function updatePlatformFee(uint8 type_, uint256 fee) external onlyAdmin {
        require(type_ == 0 || type_ == 1, "O for bid fee || 1 for post fee");
        type_ == 0 ? bidPlatformFee = fee : postPlatformFee = fee;
        emit PlatformFeeUpdated(type_, fee);
    }

    /**
     * @notice Used to get the profit generated
     */
    function getProfitGenerated() external view onlyAdmin returns (uint256) {
        return profit;
    }
    /**
     * @notice Used to get the winner for a particular tender
     */

    function getWinner(uint256 tenderId_) external view isTenderAvailable(tenderId_) returns (Winner memory) {
        require(tenders[tenderId_].stage == Stages.closed, "Winner not announced");
        return tenders[tenderId_].winner;
    }

    /**
     * @notice Used to get the bidders Id for a particular tender
     * @param tenderId_ The Id of a tender
     */

    function getListOfbidders(uint256 tenderId_) external view returns (uint256[] memory) {
        return biddersId[tenderId_];
    }

    /**
     * @notice Used to get tender
     * @param tenderId_ The Id of a particular tender
     */
    function getTender(uint256 tenderId_) external view returns (Tender memory) {
        return tenders[tenderId_];
    }

    function getAllTenders() external view returns (Tender[] memory) {
        Tender[] memory tenders_ = new Tender[](tenderId);
        for (uint256 i = 1; i <= tenderId; i++) {
            Tender memory tender_ = tenders[i];
            tenders_[i - 1] = tender_;
        }
        return tenders_;
    }

    /**
     * @notice Used to get the bid of suppleir for particular tender
     * @param tenderId_ The Id of the tender
     * @param suppleirId_ The Id of the suppleir
     */

    function getYourBid(uint256 tenderId_, uint256 suppleirId_) external view returns (Bid memory) {
        isAllowed_(0, suppleirId_);
        return bidding[tenderId_][suppleirId_];
    }

    function getAllYourBids(uint256 suppleirId_) external view returns (uint256[] memory) {
        return suppBid[suppleirId_];
    }

    /**
     * @notice 0 for to check for suppleir and 1 for organization
     */
    function isAllowed_(uint8 type_, uint256 Id_) private view {
        require(type_ == 0 || type_ == 1);
        if (type_ == 0) {
            require(
                supp.ownerOf(Id_) == msg.sender || supp.getApproved(Id_) == msg.sender
                    || supp.isApprovedForAll(supp.ownerOf(Id_), msg.sender),
                "Not allowed for you!"
            );
        }
        if (type_ == 1) {
            require(
                Org.ownerOf(Id_) == msg.sender || Org.getApproved(Id_) == msg.sender
                    || Org.isApprovedForAll(Org.ownerOf(Id_), msg.sender),
                "Not allowed for you!"
            );
        }
    }
}
