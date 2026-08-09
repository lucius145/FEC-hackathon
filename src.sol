// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//interface to use semaphore contract
interface ISemaphore {
    struct SemaphoreProof {
        uint256 merkleTreeDepth;
        uint256 merkleTreeRoot;
        uint256 nullifier;
        uint256 message;
        uint256 scope;
        uint256[8] points;
    }

    function createGroup(address admin) external returns (uint256 groupId);//to create a group which inlcudes a sponser and member workers
    function addMember(uint256 groupId, uint256 identityCommitment) external;//to add a member to a group
    function verifyProof(uint256 groupId, SemaphoreProof calldata proof) external returns (bool);//to verify the proof of work submitted by any worker
}

//actual program begins
contract BlindGrantEscrow {
    
    ISemaphore public immutable semaphore;

    enum GrantStatus { Created, WorkSubmitted, Completed, Cancelled }//to track the state of a bounty

    //data structure to store info of any bounty created
    struct Grant {
        uint256 id;
        address sponsor;// The person funding the grant
        uint256 amount;// Escrow balance in Wei
        uint256 groupId;// Semaphore Group ID for eligible contributors
        GrantStatus status;
        uint256 submissionNullifier;// Nullifier used when work was submitted 
        uint256 proofMessage;// Hash/Identifier of the submitted work 
        address payable workerPayoutAddress; // Shielded or stealth payout address via Kohaku
    }

    uint256 public grantCount;
    //to map a grant created in a collection
    mapping(uint256 => Grant) private grants;

    // Track used nullifiers on-chain to prevent double-submissions or replaying proofs
    mapping(uint256 => bool) private usedNullifiers;

    //tracking events
    event GrantCreated(
        uint256 indexed grantId,
        address indexed sponsor,
        uint256 amount,
        uint256 groupId
    );
    event WorkerJoinedGroup(uint256 indexed grantId, uint256 identityCommitment);
    event WorkSubmittedAnonymously(
        uint256 indexed grantId,
        uint256 nullifier,
        uint256 proofMessage
    );
    event FundsReleased(
        uint256 indexed grantId,
        address indexed payoutAddress,
        uint256 amount
    );
    event GrantCancelled(uint256 indexed grantId, uint256 refundAmount);

    //some errors which help in handling exceptional cases
    error InvalidAmount();
    error GrantNotFound();
    error Unauthorized();
    error InvalidStatus();
    error NullifierAlreadyUsed();
    error InvalidZKProof();
    error TransferFailed();

    //to check if the sponsor of any grant is the one calling any function
    modifier onlySponsor(uint256 _grantId) {
        if (grants[_grantId].sponsor != msg.sender) revert Unauthorized();
        _;
    }

    constructor(address _semaphoreAddress) {
        semaphore = ISemaphore(_semaphoreAddress);
    }

    //fucntion to deploy a new bounty
    function createGrant() external payable returns (uint256 grantId) 
    {
        //to check if the sponsor gave some eth in escrow 
        if (msg.value == 0) revert InvalidAmount();

        grantCount++;
        grantId = grantCount;

        // Create a new Semaphore group for this specific grant
        uint256 groupId = semaphore.createGroup(address(this));

        grants[grantId] = Grant({
            id: grantId,
            sponsor: msg.sender,
            amount: msg.value,
            groupId: groupId,
            status: GrantStatus.Created,
            submissionNullifier: 0,
            proofMessage: 0,
            workerPayoutAddress: payable(address(0))
        });

        emit GrantCreated(grantId, msg.sender, msg.value, groupId);
    }

    //function to enable a member worker to join a grant group and work on it
    function joinGrantGroup(uint256 _grantId, uint256 _identityCommitment) external {
        Grant storage grant = grants[_grantId];
        if (grant.id == 0) revert GrantNotFound();
        if (grant.status != GrantStatus.Created) revert InvalidStatus();

        // Add member commitment into Semaphore tree
        semaphore.addMember(grant.groupId, _identityCommitment);

        emit WorkerJoinedGroup(_grantId, _identityCommitment);
    }

    //function to enable a member worker to submit their work
    function submitWork(
        uint256 _grantId,
        ISemaphore.SemaphoreProof calldata _proof,
        address payable _payoutAddress
    ) external {
        Grant storage grant = grants[_grantId];
        if (grant.id == 0) revert GrantNotFound();
        if (grant.status != GrantStatus.Created) revert InvalidStatus();

        // 1. Check scope matches grantId to prevent cross-poll submission attacks
        if (_proof.scope != _grantId) revert InvalidZKProof();

        // 2. Prevent replay attacks using nullifiers
        if (usedNullifiers[_proof.nullifier]) revert NullifierAlreadyUsed();

        // 3. Verify ZK Proof via Semaphore protocol contract
        bool isValid = semaphore.verifyProof(grant.groupId, _proof);
        if (!isValid) revert InvalidZKProof();

        // Mark nullifier as used
        usedNullifiers[_proof.nullifier] = true;

        // Update grant state
        grant.status = GrantStatus.WorkSubmitted;
        grant.submissionNullifier = _proof.nullifier;
        grant.proofMessage = _proof.message;
        grant.workerPayoutAddress = _payoutAddress;

        emit WorkSubmittedAnonymously(_grantId, _proof.nullifier, _proof.message);
    }

    //function to give the proofed worker the eth on grant
    function approveAndReleaseFunds(uint256 _grantId) external onlySponsor(_grantId) {
        Grant storage grant = grants[_grantId];
        if (grant.status != GrantStatus.WorkSubmitted) revert InvalidStatus();

        uint256 payoutAmount = grant.amount;
        address payable recipient = grant.workerPayoutAddress;

        grant.amount = 0;
        grant.status = GrantStatus.Completed;

        // Transfer funds directly to worker's shielded / stealth address
        (bool success, ) = recipient.call{value: payoutAmount}("");
        if (!success) revert TransferFailed();

        emit FundsReleased(_grantId, recipient, payoutAmount);
    }

    //function to enable any sponser to take back the grant he issued
    function cancelGrant(uint256 _grantId) external onlySponsor(_grantId) {
        Grant storage grant = grants[_grantId];
        if (grant.status != GrantStatus.Created) revert InvalidStatus();

        uint256 refundAmount = grant.amount;
        grant.amount = 0;
        grant.status = GrantStatus.Cancelled;

        (bool success, ) = msg.sender.call{value: refundAmount}("");
        if (!success) revert TransferFailed();

        emit GrantCancelled(_grantId, refundAmount);
    }

    //function to get a grant's details
    function getGrant(uint256 _grantId) external view returns (Grant memory) {
        return grants[_grantId];
    }
}