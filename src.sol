// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
    ISemaphore public immutable semaphore;

    enum GrantStatus { Created, WorkSubmitted, Completed }

    struct Grant {
        address payable sponsor;
        uint256 amount;
        uint256 groupId;
        string metadataURI; // Task brief or IPFS link provided by sponsor
        GrantStatus status;
        string proofMessage;
        address workerPayoutAddress;
    }

    uint256 public grantCount;
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

    constructor(address _semaphoreAddress) {
        semaphore = ISemaphore(_semaphoreAddress);
    }

    /// @notice Sponsor creates an escrowed grant with an attached task link/URI
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

    /// @notice Worker registers into the Semaphore group for a grant
    function joinGrantGroup(uint256 _grantId, uint256 _identityCommitment) external {
        Grant storage grant = grants[_grantId];
        require(grant.amount > 0, "Grant does not exist");
        require(grant.status == GrantStatus.Created, "Grant not accepting registrations");

        semaphore.addMember(grant.groupId, _identityCommitment);
        emit WorkerJoined(_grantId, _identityCommitment);
    }

    /// @notice Submit ZK Proof of completed work
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

    /// @notice Sponsor approves payout to worker's address
    function approvePayout(uint256 _grantId) external {
        Grant storage grant = grants[_grantId];
        require(msg.sender == grant.sponsor, "Only sponsor can approve");
        require(grant.status == GrantStatus.WorkSubmitted, "No work submitted yet");

        grant.status = GrantStatus.Completed;
        payable(grant.workerPayoutAddress).transfer(grant.amount);

        emit GrantCompleted(_grantId, grant.workerPayoutAddress);
    }

    /// @notice Public getter for grant details including metadataURI
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