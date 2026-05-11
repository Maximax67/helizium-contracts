// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title TaskEscrow
 * @notice Escrow contract for Helizium freelance platform.
 *         Holds ETH while a task is in progress and distributes
 *         funds on completion, with a configurable platform fee.
 */
contract TaskEscrow is ReentrancyGuard, Ownable, Pausable {

    // ─────────────────────────────────────────────────────────── enums ──

    enum TaskState {
        Nonexistent,    // 0 – task not funded yet
        Funded,         // 1 – ETH deposited, waiting for freelancer
        InProgress,     // 2 – freelancer assigned
        WorkSubmitted,  // 3 – freelancer submitted work
        Completed,      // 4 – client approved, funds released
        Cancelled,      // 5 – cancelled, client refunded
        Disputed        // 6 – dispute raised
    }

    // ─────────────────────────────────────────────────────── structs ──

    struct Task {
        address client;
        address freelancer;
        uint256 amount;
        TaskState state;
        uint64  fundedAt;
        uint64  completedAt;
    }

    // ───────────────────────────────────────────────── state variables ──

    /// @dev Maps keccak256(taskDbId) → Task
    mapping(bytes32 => Task) private _tasks;

    address public feeRecipient;
    uint16  public feeBasisPoints;     // 250 = 2.5%
    uint16  public constant MAX_FEE_BP = 1000; // 10% hard cap
    uint8   public constant MAX_TASK_ID_LEN = 64;

    /// @dev Pending withdrawal balances (pull-payment for admin fees)
    mapping(address => uint256) public pendingWithdrawals;

    // ──────────────────────────────────────────────────────── events ──

    event TaskFunded(
        bytes32 indexed taskKey,
        string  indexed taskDbId,
        address indexed client,
        uint256 amount
    );
    event FreelancerAssigned(
        bytes32 indexed taskKey,
        address indexed client,
        address indexed freelancer
    );
    event WorkSubmitted(bytes32 indexed taskKey, address indexed freelancer);
    event TaskCompleted(
        bytes32 indexed taskKey,
        address indexed client,
        address indexed freelancer,
        uint256 freelancerPayout,
        uint256 platformFee
    );
    event TaskCancelled(bytes32 indexed taskKey, address indexed client, uint256 refund);
    event DisputeRaised(bytes32 indexed taskKey, address indexed raisedBy);
    event DisputeResolved(bytes32 indexed taskKey, bool favorFreelancer, address indexed resolvedBy);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeBasisPointsUpdated(uint16 oldBp, uint16 newBp);
    event Withdrawn(address indexed to, uint256 amount);

    // ──────────────────────────────────────────────────────── errors ──

    error Unauthorized();
    error InvalidState(TaskState current, TaskState required);
    error ZeroValue();
    error TaskExists();
    error TaskNotFound();
    error ZeroAddress();
    error TaskIdTooLong();
    error SelfAssignment();
    error TransferFailed();
    error InvalidFee();
    error NothingToWithdraw();

    // ────────────────────────────────────────────────────── modifiers ──

    modifier onlyClient(bytes32 key) {
        if (_tasks[key].client != msg.sender) revert Unauthorized();
        _;
    }

    modifier onlyFreelancer(bytes32 key) {
        if (_tasks[key].freelancer != msg.sender) revert Unauthorized();
        _;
    }

    modifier inState(bytes32 key, TaskState expected) {
        if (_tasks[key].state != expected) revert InvalidState(_tasks[key].state, expected);
        _;
    }

    // ─────────────────────────────────────────────────── constructor ──

    constructor(address _feeRecipient) Ownable(msg.sender) {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
        feeBasisPoints = 250; // 2.5%
    }

    // ────────────────────────────────────── prevent accidental ETH sends ──

    receive() external payable {
        revert("Use fundTask()");
    }

    fallback() external payable {
        revert("Use fundTask()");
    }

    // ──────────────────────────────────────────── internal helpers ──

    function _taskKey(string calldata taskDbId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(taskDbId));
    }

    /// @dev Safe ETH transfer using call; reverts on failure
    function _safeTransfer(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─────────────────────────────────────────────── external functions ──

    /**
     * @notice Fund a task. Client must send exactly the task price in ETH.
     * @param taskDbId MongoDB ObjectId string (max 64 chars)
     */
    function fundTask(string calldata taskDbId)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (msg.value == 0) revert ZeroValue();
        if (bytes(taskDbId).length == 0 || bytes(taskDbId).length > MAX_TASK_ID_LEN)
            revert TaskIdTooLong();

        bytes32 key = _taskKey(taskDbId);
        if (_tasks[key].state != TaskState.Nonexistent) revert TaskExists();

        // Effects before interactions
        _tasks[key] = Task({
            client:      msg.sender,
            freelancer:  address(0),
            amount:      msg.value,
            state:       TaskState.Funded,
            fundedAt:    uint64(block.timestamp),
            completedAt: 0
        });

        emit TaskFunded(key, taskDbId, msg.sender, msg.value);
    }

    /**
     * @notice Client assigns a freelancer to move the task to InProgress.
     */
    function assignFreelancer(string calldata taskDbId, address freelancer)
        external
        nonReentrant
        whenNotPaused
    {
        if (freelancer == address(0)) revert ZeroAddress();
        bytes32 key = _taskKey(taskDbId);
        if (freelancer == _tasks[key].client) revert SelfAssignment();

        Task storage task = _tasks[key];
        if (task.state != TaskState.Funded) revert InvalidState(task.state, TaskState.Funded);
        if (task.client != msg.sender) revert Unauthorized();

        // Effects
        task.freelancer = freelancer;
        task.state      = TaskState.InProgress;

        emit FreelancerAssigned(key, msg.sender, freelancer);
    }

    /**
     * @notice Freelancer signals work is done and ready for review.
     */
    function submitWork(string calldata taskDbId)
        external
        nonReentrant
        whenNotPaused
    {
        bytes32 key = _taskKey(taskDbId);
        Task storage task = _tasks[key];
        if (task.freelancer != msg.sender) revert Unauthorized();
        if (task.state != TaskState.InProgress) revert InvalidState(task.state, TaskState.InProgress);

        // Effects
        task.state = TaskState.WorkSubmitted;

        emit WorkSubmitted(key, msg.sender);
    }

    /**
     * @notice Client approves completed work. Releases funds to freelancer minus fee.
     *         Uses checks-effects-interactions pattern.
     */
    function approveWork(string calldata taskDbId)
        external
        nonReentrant
        whenNotPaused
    {
        bytes32 key = _taskKey(taskDbId);
        Task storage task = _tasks[key];
        if (task.client != msg.sender) revert Unauthorized();
        if (task.state != TaskState.WorkSubmitted)
            revert InvalidState(task.state, TaskState.WorkSubmitted);

        // Read before zeroing
        uint256 amount     = task.amount;
        address freelancer = task.freelancer;

        // Calculate fee with rounding in favour of freelancer
        uint256 fee     = (amount * feeBasisPoints) / 10_000;
        uint256 payout  = amount - fee;

        // Effects FIRST
        task.amount      = 0;
        task.state       = TaskState.Completed;
        task.completedAt = uint64(block.timestamp);

        emit TaskCompleted(key, msg.sender, freelancer, payout, fee);

        // Interactions LAST
        _safeTransfer(freelancer, payout);

        // Fee goes to pull-payment withdrawal to avoid blocking on feeRecipient issues
        if (fee > 0) {
            pendingWithdrawals[feeRecipient] += fee;
        }
    }

    /**
     * @notice Client cancels the task and receives a full refund.
     *         Only allowed before work is submitted to protect freelancer.
     */
    function cancelTask(string calldata taskDbId)
        external
        nonReentrant
        whenNotPaused
    {
        bytes32 key = _taskKey(taskDbId);
        Task storage task = _tasks[key];
        if (task.client != msg.sender) revert Unauthorized();

        TaskState s = task.state;
        if (s != TaskState.Funded && s != TaskState.InProgress)
            revert InvalidState(s, TaskState.Funded);

        uint256 refund = task.amount;

        // Effects
        task.amount = 0;
        task.state  = TaskState.Cancelled;

        emit TaskCancelled(key, msg.sender, refund);

        // Interaction
        _safeTransfer(msg.sender, refund);
    }

    /**
     * @notice Either party raises a dispute after work is submitted.
     */
    function raiseDispute(string calldata taskDbId)
        external
        nonReentrant
        whenNotPaused
    {
        bytes32 key = _taskKey(taskDbId);
        Task storage task = _tasks[key];

        bool isSender = msg.sender == task.client || msg.sender == task.freelancer;
        if (!isSender) revert Unauthorized();
        if (task.state != TaskState.WorkSubmitted)
            revert InvalidState(task.state, TaskState.WorkSubmitted);

        task.state = TaskState.Disputed;

        emit DisputeRaised(key, msg.sender);
    }

    /**
     * @notice Owner resolves a dispute.
     * @param favorFreelancer true → pay freelancer (with fee); false → full refund to client
     */
    function resolveDispute(string calldata taskDbId, bool favorFreelancer)
        external
        nonReentrant
        onlyOwner
    {
        bytes32 key = _taskKey(taskDbId);
        Task storage task = _tasks[key];
        if (task.state != TaskState.Disputed)
            revert InvalidState(task.state, TaskState.Disputed);

        uint256 amount     = task.amount;
        address client     = task.client;
        address freelancer = task.freelancer;

        // Effects
        task.amount      = 0;
        task.completedAt = uint64(block.timestamp);
        task.state       = favorFreelancer ? TaskState.Completed : TaskState.Cancelled;

        emit DisputeResolved(key, favorFreelancer, msg.sender);

        // Interactions
        if (favorFreelancer) {
            uint256 fee    = (amount * feeBasisPoints) / 10_000;
            uint256 payout = amount - fee;
            emit TaskCompleted(key, client, freelancer, payout, fee);
            _safeTransfer(freelancer, payout);
            if (fee > 0) {
                pendingWithdrawals[feeRecipient] += fee;
            }
        } else {
            // Full refund — no platform fee when client wins dispute
            emit TaskCancelled(key, client, amount);
            _safeTransfer(client, amount);
        }
    }

    /**
     * @notice Pull-payment withdrawal for fee recipient (and owner in emergencies).
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        // Effects
        pendingWithdrawals[msg.sender] = 0;

        emit Withdrawn(msg.sender, amount);

        // Interaction
        _safeTransfer(msg.sender, amount);
    }

    // ──────────────────────────────────────────── admin / owner functions ──

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function setFeeBasisPoints(uint16 newBp) external onlyOwner {
        if (newBp > MAX_FEE_BP) revert InvalidFee();
        emit FeeBasisPointsUpdated(feeBasisPoints, newBp);
        feeBasisPoints = newBp;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ────────────────────────────────────────────────── view functions ──

    function getTask(string calldata taskDbId)
        external
        view
        returns (
            address client,
            address freelancer,
            uint256 amount,
            TaskState state,
            uint64  fundedAt,
            uint64  completedAt
        )
    {
        bytes32 key = _taskKey(taskDbId);
        Task storage t = _tasks[key];
        if (t.state == TaskState.Nonexistent && t.client == address(0))
            revert TaskNotFound();
        return (t.client, t.freelancer, t.amount, t.state, t.fundedAt, t.completedAt);
    }

    function getTaskState(string calldata taskDbId) external view returns (TaskState) {
        return _tasks[_taskKey(taskDbId)].state;
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
