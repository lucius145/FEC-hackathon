// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//default interface to implement semaphore
interface ISemaphore {
    function createGroup(address admin) external returns (uint256 groupId);
    function addMember(uint256 groupId, uint256 identityCommitment) external;
    function verifyProof(uint256 groupId, SemaphoreProof calldata proof) external returns (bool);
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

    ISemaphore public immutable semaphore;

    //states to define grant status
    enum GrantStatus { Created, WorkSubmitted, Completed }

    //data structure to implement a grant
    struct Grant {
        address payable sponsor;
        uint256 amount;
        uint256 groupId;
        string metadataURI; // Task brief or IPFS link provided by sponsor
        GrantStatus status;
        string proofMessage;
        address workerPayoutAddress;
    }

    uint256 private grantCount;
    //to map grant to a unique number
    mapping(uint256 => Grant) private grants;

    mapping(uint256 => bool) public usedNullifiers;

    event GrantCreated(
        uint256 indexed grantId,
        address indexed sponsor,
        uint256 amount,
        uint256 groupId,
        string metadataURI
    );
    event WorkerJoined(uint256 indexed grantId, uint256 identityCommitment);
    event WorkSubmitted(uint256 indexed grantId, uint256 nullifier);
    event GrantCompleted(uint256 indexed grantId, address payoutAddress);

    //to initialize semaphore by providing on chain address of semaphore V4
    constructor(address _semaphoreAddress) {
        semaphore = ISemaphore(_semaphoreAddress);
    }

    //function to create a new grant 
    function createGrant(string memory _metadataURI) external payable returns (uint256) {
        require(msg.value > 0, "Grant amount must be greater than 0");

        grantCount++;
        uint256 newGroupId = semaphore.createGroup(address(this));

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
        require(grant.amount > 0, "Grant does not exist");
        require(grant.status == GrantStatus.Created, "Grant not accepting registrations");

        semaphore.addMember(grant.groupId, _identityCommitment);
        emit WorkerJoined(_grantId, _identityCommitment);
    }

    //function to enable worker to submit their proposed work 
    function submitWork(
        uint256 _grantId,
        SemaphoreProof calldata _proof,
        address _payoutAddress
    ) external {
        Grant storage grant = grants[_grantId];
        require(grant.status == GrantStatus.Created, "Grant not accepting submissions");
        require(!usedNullifiers[_proof.nullifier], "Proof already used");

        bool isValid = semaphore.verifyProof(grant.groupId, _proof);
        require(isValid, "Invalid Semaphore ZK Proof");

        usedNullifiers[_proof.nullifier] = true;
        grant.workerPayoutAddress = _payoutAddress;
        grant.status = GrantStatus.WorkSubmitted;

        emit WorkSubmitted(_grantId, _proof.nullifier);
    }

    //function to transfer funds(eth originally spent by the sponsor)
    function approvePayout(uint256 _grantId) external {
        Grant storage grant = grants[_grantId];
        require(msg.sender == grant.sponsor, "Only sponsor can approve");
        require(grant.status == GrantStatus.WorkSubmitted, "No work submitted yet");

        grant.status = GrantStatus.Completed;
        (bool success, ) = payable(grant.workerPayoutAddress).call{value: grant.amount}("");
        if (!success) revert TransferFailed();

        emit GrantCompleted(_grantId, grant.workerPayoutAddress);
    }

    //function to get info on a specific grant
    function getGrant(uint256 _grantId) external view returns (
        address sponsor,
        uint256 amount,
        uint256 groupId,
        string memory metadataURI,
        GrantStatus status,
        address workerPayoutAddress
    ) {
        Grant memory g = grants[_grantId];
        return (g.sponsor, g.amount, g.groupId, g.metadataURI, g.status, g.workerPayoutAddress);
    }
}