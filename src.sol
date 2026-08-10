// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//default interface to implement semaphore
interface ISemaphore {
    function createGroup() external returns (uint256 groupId);
    function addMember(uint256 groupId, uint256 identityCommitment) external;
    function validateProof(uint256 groupId, SemaphoreProof calldata proof) external;
}

struct SemaphoreProof {
    uint256 merkleTreeDepth;
    uint256 merkleTreeRoot;
    uint256 nullifier;
    uint256 message;
    uint256 scope;
    uint256[8] points;
}

contract BlindGrantEscrow {

    // Custom Errors 
    error InvalidAmount();
    error GrantNotFound();
    error NullifierAlreadyUsed();
    error TransferFailed();
    error InvalidGrantStatus();
    error NotSponsor();
    error InvalidScope();
    error InvalidMessage();
    error InvalidPayoutAddress();
    error ReentrantCall();

    ISemaphore public immutable semaphore;

    //states to define grant status
    enum GrantStatus { Created, WorkSubmitted, Completed, Cancelled }

    //data structure to implement a grant
    struct Grant {
        address payable sponsor;
        uint256 amount;
        uint256 groupId;
        string metadataURI; // Task brief provided by sponsor
        GrantStatus status;
        string proofMessage;
        address workerPayoutAddress;
    }

    uint256 private grantCount;
    //to map grant to a unique number
    mapping(uint256 => Grant) private grants;

    mapping(uint256 => bool) public usedNullifiers;

    bool private locked;

    event GrantCreated(
        uint256 indexed grantId,
        address indexed sponsor,
        uint256 amount,
        uint256 groupId,
        string metadataURI
    );
    event WorkerJoined(uint256 indexed grantId, uint256 identityCommitment);
    event WorkSubmitted(uint256 indexed grantId, uint256 nullifier);
    event WorkRejected(uint256 indexed grantId);
    event GrantCompleted(uint256 indexed grantId, address payoutAddress);
    event GrantCancelled(uint256 indexed grantId, address sponsor, uint256 amount);

    modifier nonReentrant() {
        if (locked) revert ReentrantCall();
        locked = true;
        _;
        locked = false;
    }

    //to initialize semaphore by providing on chain address of semaphore V4
    constructor(address _semaphoreAddress) {
        semaphore = ISemaphore(_semaphoreAddress);
    }

    //function to create a new grant 
    function createGrant(string memory _metadataURI) external payable returns (uint256) {
        if (msg.value == 0) revert InvalidAmount();

        grantCount++;
        
        uint256 newGroupId = semaphore.createGroup();

        grants[grantCount] = Grant({
            sponsor: payable(msg.sender),
            amount: msg.value,
            groupId: newGroupId,
            metadataURI: _metadataURI,
            status: GrantStatus.Created,
            proofMessage: "",
            workerPayoutAddress: address(0)
        });

        emit GrantCreated(grantCount, msg.sender, msg.value, newGroupId, _metadataURI);
        return grantCount;
    }

    //function to enable workers to join a grant group
    function joinGrantGroup(uint256 _grantId, uint256 _identityCommitment) external {
        Grant storage grant = grants[_grantId];
        if (grant.amount == 0) revert GrantNotFound();
        if (grant.status != GrantStatus.Created) revert InvalidGrantStatus();

        semaphore.addMember(grant.groupId, _identityCommitment);
        emit WorkerJoined(_grantId, _identityCommitment);
    }

    //function to enable worker to submit their proposed work 
    function submitWork(
        uint256 _grantId,
        SemaphoreProof calldata _proof,
        address _payoutAddress,
        string calldata _workProofURI
    ) external {
        Grant storage grant = grants[_grantId];
        if (grant.amount == 0) revert GrantNotFound();
        if (grant.status != GrantStatus.Created) revert InvalidGrantStatus();
        if (_payoutAddress == address(0)) revert InvalidPayoutAddress();
        if (usedNullifiers[_proof.nullifier]) revert NullifierAlreadyUsed();

        if (_proof.scope != grant.groupId) revert InvalidScope();

        if (_proof.message != uint256(uint160(_payoutAddress))) revert InvalidMessage();

        semaphore.validateProof(grant.groupId, _proof);

        usedNullifiers[_proof.nullifier] = true;
        grant.workerPayoutAddress = _payoutAddress;
        grant.proofMessage = _workProofURI;
        grant.status = GrantStatus.WorkSubmitted;

        emit WorkSubmitted(_grantId, _proof.nullifier);
    }

    //function to transfer funds(eth originally spent by the sponsor)
    function approvePayout(uint256 _grantId) external nonReentrant {
        Grant storage grant = grants[_grantId];
        if (grant.amount == 0) revert GrantNotFound();
        if (msg.sender != grant.sponsor) revert NotSponsor();
        if (grant.status != GrantStatus.WorkSubmitted) revert InvalidGrantStatus();

        uint256 payoutAmount = grant.amount;
        address payoutAddress = grant.workerPayoutAddress;

        grant.status = GrantStatus.Completed;
        grant.amount = 0;

        (bool success, ) = payable(payoutAddress).call{value: payoutAmount}("");
        if (!success) revert TransferFailed();

        emit GrantCompleted(_grantId, payoutAddress);
    }

    function rejectWork(uint256 _grantId) external {
        Grant storage grant = grants[_grantId];
        if (grant.amount == 0) revert GrantNotFound();
        if (msg.sender != grant.sponsor) revert NotSponsor();
        if (grant.status != GrantStatus.WorkSubmitted) revert InvalidGrantStatus();

        grant.status = GrantStatus.Created;
        grant.workerPayoutAddress = address(0);
        grant.proofMessage = "";

        emit WorkRejected(_grantId);
    }

    function cancelGrant(uint256 _grantId) external nonReentrant {
        Grant storage grant = grants[_grantId];
        if (grant.amount == 0) revert GrantNotFound();
        if (msg.sender != grant.sponsor) revert NotSponsor();
        if (grant.status != GrantStatus.Created) revert InvalidGrantStatus();

        uint256 refundAmount = grant.amount;

        grant.status = GrantStatus.Cancelled;
        grant.amount = 0;

        (bool success, ) = grant.sponsor.call{value: refundAmount}("");
        if (!success) revert TransferFailed();

        emit GrantCancelled(_grantId, grant.sponsor, refundAmount);
    }

    //function to get info on a specific grant
    function getGrant(uint256 _grantId) external view returns (
        address sponsor,
        uint256 amount,
        uint256 groupId,
        string memory metadataURI,
        GrantStatus status,
        address workerPayoutAddress,
        string memory proofMessage
    ) {
        Grant memory g = grants[_grantId];
        if (g.sponsor == address(0)) revert GrantNotFound();
        return (g.sponsor, g.amount, g.groupId, g.metadataURI, g.status, g.workerPayoutAddress, g.proofMessage);
    }
}
