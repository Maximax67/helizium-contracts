// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title TaskEscrow
 * @notice Escrow contract for Helizium freelance platform.
 *         Lifecycle: Nonexistent → Funded → Completed | Cancelled | Disputed → Completed | Cancelled
 *
 * Simplified flow (no on-chain freelancer registration required):
 *  1. Client calls fundTask()  — ETH locked.
 *  2. Off-chain: freelancer found, work done.
 *  3a. Happy path: client calls releaseToFreelancer(taskId, freelancerAddr) — funds sent.
 *  3b. Cancel:    client calls cancelTask()              — full refund.
 *  3c. Dispute:   client OR owner calls raiseDispute()  — funds frozen.
 *       Admin then calls resolveDispute(taskId, recipient) — funds sent to winner.
 *  Emergency: owner calls adminRelease(taskId, recipient) at any non-final state.
 */
contract TaskEscrow is ReentrancyGuard, Ownable, Pausable {

    // ─────────────────────────────── enums ───────────────────────────────

    enum TaskState {
        Nonexistent,  // 0 – not funded
        Funded,       // 1 – ETH locked, awaiting completion
        Completed,    // 2 – funds released to freelancer
        Cancelled,    // 3 – funds refunded to client
        Disputed      // 4 – dispute raised, awaiting admin resolution
    }

    // ─────────────────────────────── structs ─────────────────────────────

    struct Task {
        address client;
        uint256 amount;
        TaskState state;
        uint64  fundedAt;
        uint64  settledAt;
    }

    // ─────────────────────────── state variables ──────────────────────────

    mapping(bytes32 => Task) private _tasks;

    address public feeRecipient;
    uint16  public feeBasisPoints;          // 250 = 2.5 %
    uint16  public constant MAX_FEE_BP = 1000; // 10 % hard cap
    uint8   public constant MAX_ID_LEN  = 64;

    /// @dev Pull-payment balances for accumulated platform fees.
    mapping(address => uint256) public pendingWithdrawals;

    // ──────────────────────────────── events ─────────────────────────────

    event TaskFunded(bytes32 indexed taskKey, string taskDbId, address indexed client, uint256 amount);
    event TaskCompleted(bytes32 indexed taskKey, address indexed freelancer, uint256 payout, uint256 fee);
    event TaskCancelled(bytes32 indexed taskKey, address indexed client, uint256 refund);
    event DisputeRaised(bytes32 indexed taskKey, address indexed raisedBy);
    event DisputeResolved(bytes32 indexed taskKey, address indexed recipient, uint256 amount);
    event AdminReleased(bytes32 indexed taskKey, address indexed recipient, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeBasisPointsUpdated(uint16 oldBp, uint16 newBp);
    event Withdrawn(address indexed to, uint256 amount);

    // ──────────────────────────────── errors ─────────────────────────────

    error Unauthorized();
    error InvalidState(TaskState current);
    error ZeroValue();
    error TaskExists();
    error TaskNotFound();
    error ZeroAddress();
    error TaskIdTooLong();
    error TransferFailed();
    error InvalidFee();
    error NothingToWithdraw();

    // ────────────────────────────── constructor ───────────────────────────

    constructor(address _feeRecipient) Ownable(msg.sender) {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
        feeBasisPoints = 250;
    }

    // ────────────────── prevent accidental direct ETH sends ───────────────

    receive() external payable { revert("Use fundTask()"); }
    fallback() external payable { revert("Use fundTask()"); }

    // ──────────────────────────── internal helpers ────────────────────────

    function _key(string calldata id) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(id));
    }

    function _transfer(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _calcFee(uint256 amount) internal view returns (uint256 fee, uint256 payout) {
        fee    = (amount * feeBasisPoints) / 10_000;
        payout = amount - fee;
    }

    function _accrueFee(uint256 fee) internal {
        if (fee > 0) pendingWithdrawals[feeRecipient] += fee;
    }

    // ─────────────────────────── external functions ───────────────────────

    /**
     * @notice Client locks ETH in escrow for a task.
     * @param taskDbId  MongoDB ObjectId of the task (max 64 bytes).
     */
    function fundTask(string calldata taskDbId)
        external payable nonReentrant whenNotPaused
    {
        if (msg.value == 0) revert ZeroValue();
        uint256 len = bytes(taskDbId).length;
        if (len == 0 || len > MAX_ID_LEN) revert TaskIdTooLong();

        bytes32 key = _key(taskDbId);
        if (_tasks[key].state != TaskState.Nonexistent) revert TaskExists();

        _tasks[key] = Task({
            client:    msg.sender,
            amount:    msg.value,
            state:     TaskState.Funded,
            fundedAt:  uint64(block.timestamp),
            settledAt: 0
        });

        emit TaskFunded(key, taskDbId, msg.sender, msg.value);
    }

    /**
     * @notice Client approves work and releases funds to the freelancer (minus fee).
     * @param taskDbId    MongoDB ObjectId of the task.
     * @param freelancer  Freelancer's wallet address that will receive payment.
     */
    function releaseToFreelancer(string calldata taskDbId, address freelancer)
        external nonReentrant whenNotPaused
    {
        if (freelancer == address(0)) revert ZeroAddress();
        bytes32 key = _key(taskDbId);
        Task storage task = _tasks[key];

        if (task.client != msg.sender) revert Unauthorized();
        if (task.state != TaskState.Funded) revert InvalidState(task.state);

        uint256 amount = task.amount;
        (uint256 fee, uint256 payout) = _calcFee(amount);

        task.amount    = 0;
        task.state     = TaskState.Completed;
        task.settledAt = uint64(block.timestamp);

        emit TaskCompleted(key, freelancer, payout, fee);

        _transfer(freelancer, payout);
        _accrueFee(fee);
    }

    /**
     * @notice Client cancels the task and receives a full refund.
     *         Only allowed while task is still in Funded state (i.e., not disputed).
     * @param taskDbId  MongoDB ObjectId of the task.
     */
    function cancelTask(string calldata taskDbId)
        external nonReentrant whenNotPaused
    {
        bytes32 key = _key(taskDbId);
        Task storage task = _tasks[key];

        if (task.client != msg.sender) revert Unauthorized();
        if (task.state != TaskState.Funded) revert InvalidState(task.state);

        uint256 refund = task.amount;
        task.amount    = 0;
        task.state     = TaskState.Cancelled;
        task.settledAt = uint64(block.timestamp);

        emit TaskCancelled(key, msg.sender, refund);
        _transfer(msg.sender, refund);
    }

    /**
     * @notice Freeze escrow funds when a dispute arises.
     *         Can be called by the task's client or the contract owner (platform admin).
     *         Once disputed, only resolveDispute() or adminRelease() can unlock funds.
     * @param taskDbId  MongoDB ObjectId of the task.
     */
    function raiseDispute(string calldata taskDbId)
        external nonReentrant whenNotPaused
    {
        bytes32 key = _key(taskDbId);
        Task storage task = _tasks[key];

        bool isClient = msg.sender == task.client;
        bool isAdmin  = msg.sender == owner();
        if (!isClient && !isAdmin) revert Unauthorized();
        if (task.state != TaskState.Funded) revert InvalidState(task.state);

        task.state = TaskState.Disputed;
        emit DisputeRaised(key, msg.sender);
    }

    /**
     * @notice Owner (platform admin) resolves a dispute by directing funds to one party.
     *         If recipient == client   → treated as cancellation (no platform fee).
     *         If recipient != client   → treated as completion (platform fee deducted).
     * @param taskDbId   MongoDB ObjectId of the task.
     * @param recipient  Address that will receive the funds (client or freelancer).
     */
    function resolveDispute(string calldata taskDbId, address recipient)
        external nonReentrant onlyOwner
    {
        if (recipient == address(0)) revert ZeroAddress();
        bytes32 key = _key(taskDbId);
        Task storage task = _tasks[key];

        if (task.state != TaskState.Disputed) revert InvalidState(task.state);

        uint256 amount = task.amount;
        bool favorFreelancer = recipient != task.client;

        uint256 fee;
        uint256 payout;
        if (favorFreelancer) {
            (fee, payout) = _calcFee(amount);
        } else {
            fee    = 0;
            payout = amount;
        }

        task.amount    = 0;
        task.state     = favorFreelancer ? TaskState.Completed : TaskState.Cancelled;
        task.settledAt = uint64(block.timestamp);

        emit DisputeResolved(key, recipient, payout);

        _transfer(recipient, payout);
        _accrueFee(fee);
    }

    /**
     * @notice Emergency release by the owner for stuck tasks (any non-final state).
     *         No platform fee is charged — this is an admin override.
     * @param taskDbId   MongoDB ObjectId of the task.
     * @param recipient  Address that will receive the full balance.
     */
    function adminRelease(string calldata taskDbId, address recipient)
        external nonReentrant onlyOwner
    {
        if (recipient == address(0)) revert ZeroAddress();
        bytes32 key = _key(taskDbId);
        Task storage task = _tasks[key];

        if (task.state == TaskState.Nonexistent) revert TaskNotFound();
        if (task.state == TaskState.Completed || task.state == TaskState.Cancelled)
            revert InvalidState(task.state);

        uint256 amount = task.amount;
        task.amount    = 0;
        task.state     = TaskState.Cancelled;
        task.settledAt = uint64(block.timestamp);

        emit AdminReleased(key, recipient, amount);
        _transfer(recipient, amount);
    }

    /**
     * @notice Pull-payment withdrawal for the accumulated platform fee.
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        _transfer(msg.sender, amount);
    }

    // ──────────────────────────── admin setters ───────────────────────────

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

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ──────────────────────────── view functions ──────────────────────────

    function getTask(string calldata taskDbId)
        external view
        returns (
            address client,
            uint256 amount,
            TaskState state,
            uint64  fundedAt,
            uint64  settledAt
        )
    {
        bytes32 key = _key(taskDbId);
        Task storage t = _tasks[key];
        if (t.state == TaskState.Nonexistent && t.client == address(0)) revert TaskNotFound();
        return (t.client, t.amount, t.state, t.fundedAt, t.settledAt);
    }

    function getTaskState(string calldata taskDbId) external view returns (TaskState) {
        return _tasks[_key(taskDbId)].state;
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
