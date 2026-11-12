// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PayrollVault
/// @notice Employer-managed SAP payroll allocations, individually claimed by employees in USDC.
/// @dev Amounts are raw six-decimal token units (1 USDC = 1_000_000). SAP exports must be
///      converted to wallet addresses, amounts, and personnel-number hashes off-chain.
///      Only a trusted, non-rebasing, non-fee-on-transfer USDC token is supported.
///      Draft allocations are not reserved until opened. Expired Open allocations remain
///      reserved until explicitly released. Payroll amounts and emitted references are public.
///      SAP control totals cap Draft uploads and must match gross allocations before opening,
///      regardless of revocations. Labels are limited to 128 bytes.
///      Opened allocations are irrevocable; a wrong wallet in an opened run cannot be recovered,
///      so review drafts carefully. Corrections to an opened run require a new payrun.
///      Pauses freeze claim deadlines for at most 30 days, then claims reopen automatically.
///      A new pause is only possible 7 days after the previous pause ended or lapsed.
///      The owner should be a multisig; funds stay reserved while claims are paused.
///      If the USDC issuer pauses the token, the owner should pause the vault to freeze deadlines.
///      USDC issuer blocklisting of the vault would freeze payroll (dependency risk).
contract PayrollVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status { Draft, Open, Cancelled }

    struct Run {
        bytes32 sapRunId;
        string label;
        uint64 claimDeadline;
        uint128 totalAllocated;
        uint128 totalClaimed;
        uint128 totalRevoked;
        uint256 entryCount;
        Status status;
        bool expiredReleased;
        uint256 expectedEntryCount;
        uint128 expectedTotal;
        uint256 pausedBaseline;
    }

    struct Entry {
        uint128 amount;
        bool claimed;
        bool revoked;
    }

    /// @notice The immutable six-decimal payroll token.
    IERC20 public immutable usdc;
    /// @notice Maximum entries accepted in a single upload transaction.
    uint256 public constant MAX_ENTRIES = 200;
    /// @notice Maximum payruns claimable in one atomic batch.
    uint256 public constant MAX_CLAIMS = 50;
    /// @notice Maximum byte length of a payrun label.
    uint256 public constant MAX_LABEL_BYTES = 128;
    /// @notice Maximum duration of a pause before claims automatically reopen.
    uint256 public constant MAX_PAUSE = 30 days;
    /// @notice Minimum claim window after a pause ends or lapses before another pause.
    uint256 public constant PAUSE_COOLDOWN = 7 days;
    /// @notice Reserved unclaimed, unrevoked allocations in Open runs, excluding released runs.
    uint256 public totalOwed;

    uint256 private _runCount;
    mapping(uint256 => Run) private _runs;
    mapping(uint256 => mapping(address => Entry)) private _entries;
    /// @notice Whether a SAP export identifier has ever been assigned to a payrun.
    mapping(bytes32 => bool) public sapRunIdUsed;

    uint256 private _pausedAccrued;
    uint256 private _pausedSince;
    uint256 private _lastPauseEnd;

    error ZeroAddress();
    error InvalidEmployee(address employee);
    error PauseCooldownActive(uint256 availableAt);
    error InvalidToken(address token);
    error InvalidDecimals(uint8 decimals);
    error UnknownRun(uint256 runId);
    error DuplicateSapRunId(bytes32 sapRunId);
    error InvalidDeadline(uint64 deadline);
    error InvalidRunStatus(uint256 runId, Status actual);
    error ArrayLengthMismatch(uint256 employees, uint256 amounts, uint256 refs);
    error BatchTooLarge(uint256 supplied, uint256 maximum);
    error EmptyPayrun(uint256 runId);
    error ZeroAmount();
    error AllocationOverflow(uint256 runId, uint256 current, uint256 attempted);
    error EmptyControlTotals();
    error ControlTotalMismatch(
        uint256 runId,
        uint256 expectedCount,
        uint256 actualCount,
        uint256 expectedTotal,
        uint256 actualTotal
    );
    error ExceedsControlTotals(uint256 runId);
    error LabelTooLong(uint256 length, uint256 maximum);
    error DuplicateEntry(uint256 runId, address employee);
    error MissingEntry(uint256 runId, address employee);
    error EntryAlreadyClaimed(uint256 runId, address employee);
    error EntryAlreadyRevoked(uint256 runId, address employee);
    error ClaimDeadlinePassed(uint256 runId);
    error RunNotExpired(uint256 runId);
    error ExpiryAlreadyReleased(uint256 runId);
    error InsufficientFunding(uint256 needed, uint256 available);
    error InsufficientSurplus(uint256 requested, uint256 available);
    error RenounceOwnershipDisabled();

    event PayrunCreated(
        uint256 indexed runId,
        bytes32 indexed sapRunId,
        string label,
        uint64 claimDeadline,
        uint256 expectedEntryCount,
        uint256 expectedTotal
    );
    event EntryAdded(uint256 indexed runId, address indexed employee, uint256 amount, bytes32 employeeRef);
    event PayrunOpened(uint256 indexed runId, uint256 reservedAmount);
    event PayrunCancelled(uint256 indexed runId);
    event Claimed(uint256 indexed runId, address indexed employee, uint256 amount);
    event EntryRevoked(uint256 indexed runId, address indexed employee, uint256 amount);
    event ExpiredReclaimed(uint256 indexed runId, uint256 releasedAmount);
    event SurplusWithdrawn(address indexed to, uint256 amount);
    event Funded(address indexed funder, uint256 amount);

    /// @param usdc_ Address of the supported six-decimal USDC token.
    /// @param owner_ Initial employer administrator; subsequent transfers require acceptance.
    constructor(address usdc_, address owner_) Ownable(owner_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        if (usdc_.code.length == 0) revert InvalidToken(usdc_);
        uint8 decimals_ = IERC20Metadata(usdc_).decimals();
        if (decimals_ != 6) revert InvalidDecimals(decimals_);
        usdc = IERC20(usdc_);
    }

    /// @notice Creates an unfunded Draft run. SAP identifiers cannot be reused, even after cancellation.
    /// @param sapRunId Unique SAP export identifier.
    /// @param label Payrun label, limited to MAX_LABEL_BYTES bytes.
    /// @param claimDeadline Zero for unlimited claims; otherwise a future Unix timestamp.
    /// @param expectedEntryCount Nonzero gross employee entry count required before opening.
    /// @param expectedTotal Nonzero gross allocation total in raw token units; must fit uint128.
    function createPayrun(
        bytes32 sapRunId,
        string calldata label,
        uint64 claimDeadline,
        uint256 expectedEntryCount,
        uint256 expectedTotal
    ) external onlyOwner returns (uint256 runId) {
        if (sapRunIdUsed[sapRunId]) revert DuplicateSapRunId(sapRunId);
        if (claimDeadline != 0 && claimDeadline <= block.timestamp) {
            revert InvalidDeadline(claimDeadline);
        }
        if (expectedEntryCount == 0 || expectedTotal == 0) revert EmptyControlTotals();
        if (expectedTotal > type(uint128).max) revert AllocationOverflow(0, 0, expectedTotal);
        if (bytes(label).length > MAX_LABEL_BYTES) {
            revert LabelTooLong(bytes(label).length, MAX_LABEL_BYTES);
        }
        runId = ++_runCount;
        Run storage run = _runs[runId];
        run.sapRunId = sapRunId;
        run.label = label;
        run.claimDeadline = claimDeadline;
        run.expectedEntryCount = expectedEntryCount;
        run.expectedTotal = uint128(expectedTotal);
        run.pausedBaseline = _pausedTotal();
        sapRunIdUsed[sapRunId] = true;
        emit PayrunCreated(runId, sapRunId, label, claimDeadline, expectedEntryCount, expectedTotal);
    }

    /// @notice Uploads up to 200 distinct employees into a Draft run.
    /// @dev References are emitted only. Revoked entries cannot be replaced in the same run.
    ///      Gross entry count and allocation total cannot exceed the run's control totals;
    ///      revocations do not restore upload capacity.
    function addEntries(
        uint256 runId,
        address[] calldata employees,
        uint256[] calldata amounts,
        bytes32[] calldata employeeRefs
    ) external onlyOwner {
        Run storage run = _requireRun(runId);
        if (run.status != Status.Draft) revert InvalidRunStatus(runId, run.status);
        uint256 length = employees.length;
        if (length != amounts.length || length != employeeRefs.length) {
            revert ArrayLengthMismatch(length, amounts.length, employeeRefs.length);
        }
        if (length > MAX_ENTRIES) revert BatchTooLarge(length, MAX_ENTRIES);
        for (uint256 i; i < length; ++i) {
            address employee = employees[i];
            uint256 amount = amounts[i];
            if (employee == address(0)) revert ZeroAddress();
            if (employee == address(this) || employee == address(usdc)) {
                revert InvalidEmployee(employee);
            }
            if (amount == 0) revert ZeroAmount();
            if (_entries[runId][employee].amount != 0) revert DuplicateEntry(runId, employee);
            if (amount > type(uint128).max - uint256(run.totalAllocated)) {
                revert AllocationOverflow(runId, run.totalAllocated, amount);
            }
            if (
                run.entryCount >= run.expectedEntryCount
                    || uint256(run.totalAllocated) + amount > run.expectedTotal
            ) revert ExceedsControlTotals(runId);
            run.totalAllocated += uint128(amount);
            ++run.entryCount;
            _entries[runId][employee].amount = uint128(amount);
            emit EntryAdded(runId, employee, amount, employeeRefs[i]);
        }
    }

    /// @notice Opens a Draft run only if gross control totals match and all Open-run obligations are fully funded.
    /// @dev Control totals include revoked entries; only unclaimed, unrevoked amounts are reserved.
    function openPayrun(uint256 runId) external onlyOwner {
        Run storage run = _requireRun(runId);
        if (run.status != Status.Draft) revert InvalidRunStatus(runId, run.status);
        if (run.entryCount == 0) revert EmptyPayrun(runId);
        if (_deadlinePassed(run)) revert ClaimDeadlinePassed(runId);
        if (run.entryCount != run.expectedEntryCount || run.totalAllocated != run.expectedTotal) {
            revert ControlTotalMismatch(
                runId, run.expectedEntryCount, run.entryCount, run.expectedTotal, run.totalAllocated
            );
        }
        uint256 reserved = _unclaimed(run);
        uint256 needed = totalOwed + reserved;
        uint256 available = usdc.balanceOf(address(this));
        if (available < needed) revert InsufficientFunding(needed, available);
        run.status = Status.Open;
        totalOwed = needed;
        emit PayrunOpened(runId, reserved);
    }

    /// @notice Permanently cancels a Draft run; Draft allocations never count in totalOwed.
    function cancelPayrun(uint256 runId) external onlyOwner {
        Run storage run = _requireRun(runId);
        if (run.status != Status.Draft) revert InvalidRunStatus(runId, run.status);
        run.status = Status.Cancelled;
        emit PayrunCancelled(runId);
    }

    /// @notice Claims the caller's salary directly to the caller's wallet.
    function claim(uint256 runId) external nonReentrant {
        if (claimsPaused()) revert EnforcedPause();
        uint256 amount = _recordClaim(runId, msg.sender);
        usdc.safeTransfer(msg.sender, amount);
    }

    /// @notice Atomically claims up to 50 runs, sending a single aggregated transfer to the caller.
    /// @dev Any invalid or duplicate run entry reverts the entire batch. All effects precede transfer.
    function claimMany(uint256[] calldata runIds) external nonReentrant {
        if (claimsPaused()) revert EnforcedPause();
        uint256 length = runIds.length;
        if (length > MAX_CLAIMS) revert BatchTooLarge(length, MAX_CLAIMS);
        uint256 amount;
        for (uint256 i; i < length; ++i) {
            amount += _recordClaim(runIds[i], msg.sender);
        }
        if (amount != 0) usdc.safeTransfer(msg.sender, amount);
    }

    /// @notice Revokes an unclaimed Draft entry, retaining gross allocation history.
    /// @dev totalAllocated stays gross; totalRevoked offsets it. Draft allocations are not
    ///      reserved, so totalOwed is unchanged. Opened allocations are irrevocable.
    function revokeEntry(uint256 runId, address employee) external onlyOwner {
        Run storage run = _requireRun(runId);
        if (run.status != Status.Draft) revert InvalidRunStatus(runId, run.status);
        Entry storage entry = _requireUnclaimedEntry(runId, employee);
        entry.revoked = true;
        run.totalRevoked += entry.amount;
        emit EntryRevoked(runId, employee, entry.amount);
    }

    /// @notice Releases an expired Open run's remaining reservation without transferring tokens.
    /// @dev Claims remain valid at the exact effective deadline, and expire strictly after it.
    function reclaimExpired(uint256 runId) external onlyOwner {
        Run storage run = _requireRun(runId);
        if (run.status != Status.Open) revert InvalidRunStatus(runId, run.status);
        if (run.expiredReleased) revert ExpiryAlreadyReleased(runId);
        if (!_deadlinePassed(run)) revert RunNotExpired(runId);
        uint256 released = _unclaimed(run);
        run.expiredReleased = true;
        totalOwed -= released;
        emit ExpiredReclaimed(runId, released);
    }

    /// @notice Withdraws tokens that are not reserved for Open payroll obligations.
    function withdrawSurplus(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = usdc.balanceOf(address(this));
        uint256 available = balance > totalOwed ? balance - totalOwed : 0;
        if (amount > available) revert InsufficientSurplus(amount, available);
        usdc.safeTransfer(to, amount);
        emit SurplusWithdrawn(to, amount);
    }

    /// @notice Pulls approved USDC from the caller. Direct USDC transfers also fund the vault.
    /// @dev Direct transfers do not emit Funded; the token's Transfer event records them.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice Blocks salary claims and freezes deadlines for at most 30 days; funding and administration remain available.
    /// @dev Claims reopen automatically after MAX_PAUSE. A lapsed pause must be cleared with unpause().
    ///      A new pause is only possible 7 days after the previous pause ended or lapsed.
    function pause() external onlyOwner {
        _requireNotPaused();
        if (_lastPauseEnd != 0 && block.timestamp < _lastPauseEnd + PAUSE_COOLDOWN) {
            revert PauseCooldownActive(_lastPauseEnd + PAUSE_COOLDOWN);
        }
        _pausedSince = block.timestamp;
        _pause();
    }

    /// @notice Clears a pause, extending deadlines by its duration capped at 30 days.
    /// @dev The cooldown starts when the pause ended or automatically lapsed, not when it is cleared.
    function unpause() external onlyOwner {
        _requirePaused();
        uint256 elapsed = block.timestamp - _pausedSince;
        uint256 duration = elapsed < MAX_PAUSE ? elapsed : MAX_PAUSE;
        _pausedAccrued += duration;
        _lastPauseEnd = _pausedSince + duration;
        _pausedSince = 0;
        _unpause();
    }

    /// @notice Returns whether salary claims are blocked; pauses lapse automatically after 30 days.
    /// @dev paused() remains true after a lapse until the owner calls unpause().
    function claimsPaused() public view returns (bool) {
        return paused() && block.timestamp < _pausedSince + MAX_PAUSE;
    }

    /// @notice Ownership cannot be abandoned while the vault may hold funds.
    function renounceOwnership() public override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /// @notice Returns the number of created runs; valid IDs are 1 through runCount().
    function runCount() external view returns (uint256) { return _runCount; }

    /// @notice Returns a run, including gross totals, its release flag, control totals, and pause baseline.
    /// @dev pausedBaseline is appended after expectedEntryCount and expectedTotal in the returned struct.
    function getRun(uint256 runId) external view returns (Run memory) {
        return _requireRun(runId);
    }

    /// @notice Returns the pause-adjusted claim deadline, or zero for unlimited claims.
    function effectiveDeadline(uint256 runId) external view returns (uint256) {
        Run storage run = _requireRun(runId);
        return run.claimDeadline == 0
            ? 0
            : uint256(run.claimDeadline) + (_pausedTotal() - run.pausedBaseline);
    }

    /// @notice Returns an employee's entry; an absent employee has amount zero.
    /// @dev Reverts for an unknown run.
    function getEntry(uint256 runId, address employee) external view returns (Entry memory) {
        _requireRun(runId);
        return _entries[runId][employee];
    }

    /// @notice Returns the currently claimable salary, or zero if any claim condition is unmet.
    /// @dev Unknown runs return zero. Assumes the configured USDC behaves as a standard token.
    function claimable(uint256 runId, address employee) external view returns (uint256) {
        if (runId == 0 || runId > _runCount || claimsPaused()) return 0;
        Run storage run = _runs[runId];
        if (run.status != Status.Open || run.expiredReleased || _deadlinePassed(run)) return 0;
        Entry storage entry = _entries[runId][employee];
        if (entry.claimed || entry.revoked) return 0;
        return entry.amount;
    }

    /// @notice Returns gross allocations minus claimed and revoked amounts, regardless of status.
    /// @dev This historical remainder includes cancelled/released runs, unlike totalOwed;
    ///      it does not imply that an employee can currently claim it.
    function unclaimedOf(uint256 runId) external view returns (uint256) {
        return _unclaimed(_requireRun(runId));
    }

    function _recordClaim(uint256 runId, address employee) private returns (uint256 amount) {
        Run storage run = _requireRun(runId);
        if (run.status != Status.Open) revert InvalidRunStatus(runId, run.status);
        if (run.expiredReleased || _deadlinePassed(run)) revert ClaimDeadlinePassed(runId);
        Entry storage entry = _requireUnclaimedEntry(runId, employee);
        amount = entry.amount;
        entry.claimed = true;
        run.totalClaimed += entry.amount;
        totalOwed -= amount;
        emit Claimed(runId, employee, amount);
    }

    function _requireRun(uint256 runId) private view returns (Run storage run) {
        if (runId == 0 || runId > _runCount) revert UnknownRun(runId);
        return _runs[runId];
    }

    function _requireUnclaimedEntry(uint256 runId, address employee)
        private view returns (Entry storage entry)
    {
        entry = _entries[runId][employee];
        if (entry.amount == 0) revert MissingEntry(runId, employee);
        if (entry.claimed) revert EntryAlreadyClaimed(runId, employee);
        if (entry.revoked) revert EntryAlreadyRevoked(runId, employee);
    }

    function _pausedTotal() private view returns (uint256) {
        uint256 elapsed = paused() ? block.timestamp - _pausedSince : 0;
        return _pausedAccrued + (elapsed < MAX_PAUSE ? elapsed : MAX_PAUSE);
    }

    function _deadlinePassed(Run storage run) private view returns (bool) {
        return run.claimDeadline != 0
            && block.timestamp > uint256(run.claimDeadline) + (_pausedTotal() - run.pausedBaseline);
    }

    function _unclaimed(Run storage run) private view returns (uint256) {
        return uint256(run.totalAllocated) - run.totalClaimed - run.totalRevoked;
    }
}
