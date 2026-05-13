// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title TaskEscrow
 * @notice Escrow contract for Helizium freelance platform.
 *         Lifecycle: Nonexistent → Funded → Completed | Cancelled | Disputed → Completed | Cancelled
 */
contract TaskEscrow is ReentrancyGuard, Ownable, Pausable {

    // ─────────────────────────────── enums ───────────────────────────────

    enum TaskState {
        Nonexistent,  // 0
        Funded,       // 1
        Completed,    // 2
        Cancelled,    // 3
        Disputed      // 4
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
    uint16  public feeBasisPoints;
    uint16  public constant MAX_FEE_BP = 1000;
    uint8   public constant MAX_ID_LEN  = 64;

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

    receive() external payable { revert("Use fundTask()"); }
    fallback() external payable { revert("Use fundTask()"); }

    // ──────────────────────────── internal helpers ────────────────────────

    function _key(string calldata id) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(id));
    }

    function _keyBytes(bytes32 id) internal pure returns (bytes32) {
        return id;
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        // Use call with explicit gas limit to prevent stack-too-deep in
        // nested calls and avoid reentrancy-via-fallback patterns.
        (bool ok,) = payable(to).call{ value: amount, gas: 30_000 }("");
        if (!ok) {
            // Fallback: store as pull-payment so the recipient can withdraw.
            pendingWithdrawals[to] += amount;
        }
    }

    function _calcFee(uint256 amount) internal view returns (uint256 fee, uint256 payout) {
        fee    = (amount * feeBasisPoints) / 10_000;
        payout = amount - fee;
    }

    function _accrueFee(uint256 fee) internal {
        if (fee > 0) pendingWithdrawals[feeRecipient] += fee;
    }

    // ─────────────────────────── external functions ───────────────────────

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

        _accrueFee(fee);
        _sendEth(freelancer, payout);
    }

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
        _sendEth(msg.sender, refund);
    }

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

        _accrueFee(fee);
        _sendEth(recipient, payout);
    }

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
        _sendEth(recipient, amount);
    }

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        _sendEth(msg.sender, amount);
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
