// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PayrollVaultPauseBase} from "./PayrollVault.PauseBase.t.sol";
import {PayrollVault} from "../PayrollVault.sol";

/// @dev InvalidEmployee, the 30 day pause lapse, and the 7 day pause cooldown.
contract PayrollVaultBoundedTest is PayrollVaultPauseBase {
    uint256 internal ps; // pause start used by most tests

    function setUp() public override {
        super.setUp();
        ps = t0 + 10;
    }

    // ------------------------------------------------------------ InvalidEmployee
    function _addOne(uint256 id, address emp) internal {
        address[] memory e = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes32[] memory r = new bytes32[](1);
        e[0] = emp;
        a[0] = 1e6;
        vm.prank(owner);
        vault.addEntries(id, e, a, r);
    }

    function test_AddEntries_RevertsInvalidEmployeeForVault() public {
        uint256 id = _create(SAP1, 0, 1, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidEmployee.selector, address(vault)));
        this.callAdd(id, address(vault));
    }

    function test_AddEntries_RevertsInvalidEmployeeForUsdc() public {
        uint256 id = _create(SAP1, 0, 1, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidEmployee.selector, address(usdc)));
        this.callAdd(id, address(usdc));
    }

    /// @dev external trampoline so vm.expectRevert targets a real external call into the vault.
    function callAdd(uint256 id, address emp) external {
        _addOne(id, emp);
    }

    function test_AddEntries_InvalidEmployeeInMiddleOfBatchRevertsWholeBatch() public {
        uint256 id = _create(SAP1, 0, 3, 3e6);
        address[] memory e = new address[](3);
        uint256[] memory a = new uint256[](3);
        bytes32[] memory r = new bytes32[](3);
        e[0] = alice;
        e[1] = address(vault);
        e[2] = bob;
        a[0] = 1e6;
        a[1] = 1e6;
        a[2] = 1e6;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidEmployee.selector, address(vault)));
        vault.addEntries(id, e, a, r);
        // atomic: alice's earlier entry was rolled back
        assertEq(vault.getEntry(id, alice).amount, 0);
        assertEq(vault.getRun(id).entryCount, 0);
    }

    function test_AddEntries_ZeroAddressStillRevertsZeroAddress() public {
        uint256 id = _create(SAP1, 0, 1, 1e6);
        vm.expectRevert(PayrollVault.ZeroAddress.selector);
        this.callAdd(id, address(0));
    }

    function test_AddEntries_OrdinaryEmployeeStillAccepted() public {
        uint256 id = _create(SAP1, 0, 1, 1e6);
        _addOne(id, alice);
        assertEq(vault.getEntry(id, alice).amount, 1e6);
    }

    // ------------------------------------------------------------ constants & access
    function test_BoundedPause_Constants() public view {
        assertEq(vault.MAX_PAUSE(), 30 days);
        assertEq(vault.PAUSE_COOLDOWN(), 7 days);
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.pause();
    }

    function test_Unpause_OnlyOwner() public {
        _pause();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.unpause();
    }

    function test_Pause_EmitsPausedAndUnpausedEvents() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit Pausable.Paused(owner);
        _pause();
        assertTrue(vault.paused());
        assertTrue(vault.claimsPaused());
        vm.expectEmit(false, false, false, true, address(vault));
        emit Pausable.Unpaused(owner);
        _unpause();
        assertFalse(vault.paused());
        assertFalse(vault.claimsPaused());
    }

    function test_Pause_RevertsWhenAlreadyPaused() public {
        _pause();
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pause();
    }

    function test_Unpause_RevertsWhenNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vault.unpause();
    }

    function test_FirstPause_HasNoCooldown() public {
        _pause(); // right at deployment time
        assertTrue(vault.claimsPaused());
    }

    // ------------------------------------------------------------ lapse boundary
    function test_Lapse_ClaimsReopenExactlyAfter30Days_Claim() public {
        uint256 id = _openThree(SAP1, 0);
        vm.warp(ps);
        _pause();

        vm.warp(ps + P - 1);
        assertTrue(vault.claimsPaused());
        assertEq(vault.claimable(id, alice), 0);
        _expectPausedClaim(alice, id);

        vm.warp(ps + P);
        assertFalse(vault.claimsPaused());
        assertTrue(vault.paused());
        assertEq(vault.claimable(id, alice), A);
        _claim(alice, id);
        assertEq(usdc.balanceOf(alice), A);
        assertEq(vault.totalOwed(), TOTAL3 - A);
    }

    function test_Lapse_ClaimsReopenExactlyAfter30Days_ClaimMany() public {
        uint256 id = _openThree(SAP1, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.warp(ps);
        _pause();

        vm.warp(ps + P - 1);
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claimMany(ids);

        vm.warp(ps + P);
        _claimMany(bob, id);
        assertEq(usdc.balanceOf(bob), B);
    }

    function test_Lapse_PausedStaysTrueUntilUnpause() public {
        uint256 id = _openThree(SAP1, 0);
        vm.warp(ps);
        _pause();
        vm.warp(ps + P);
        assertTrue(vault.paused());
        vm.warp(ps + 365 days);
        assertTrue(vault.paused());
        assertFalse(vault.claimsPaused());
        assertEq(vault.claimable(id, carol), C);

        _unpause();
        assertFalse(vault.paused());
        assertFalse(vault.claimsPaused());
        assertEq(vault.claimable(id, carol), C);
    }

    function test_Lapse_LapsedPauseMustBeClearedBeforePausingAgain() public {
        _openThree(SAP1, 0);
        vm.warp(ps);
        _pause();
        // long after the lapse AND the cooldown, a second pause is still refused until unpause()
        vm.warp(ps + P + W + 1 days);
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pause();
        _unpause();
        _pause(); // cooldown is counted from the lapse, so this succeeds immediately
        assertTrue(vault.claimsPaused());
    }

    function test_Lapse_ClaimsPausedAgainAfterFreshPause() public {
        uint256 id = _openThree(SAP1, 0);
        vm.warp(ps);
        _pause();
        vm.warp(ps + 50 days);
        _unpause();
        _pause(); // lapse at ps+30d, cooldown ended ps+37d < ps+50d
        _expectPausedClaim(alice, id);
        vm.warp(block.timestamp + P);
        _claim(alice, id);
    }

    // ------------------------------------------------------------ deadline extension cap
    function test_Cap_ExtensionCappedWhileLapsedPauseRunning() public {
        uint64 D2 = uint64(t0 + 400 days);
        uint256 id = _openThree(SAP1, D2);
        vm.warp(ps);
        _pause();
        vm.warp(ps + 10 days);
        assertEq(vault.effectiveDeadline(id), uint256(D2) + 10 days);
        vm.warp(ps + P);
        assertEq(vault.effectiveDeadline(id), uint256(D2) + P);
        vm.warp(ps + 100 days);
        assertEq(vault.effectiveDeadline(id), uint256(D2) + P);
        _unpause();
        assertEq(vault.effectiveDeadline(id), uint256(D2) + P);
        vm.warp(ps + 300 days);
        assertEq(vault.effectiveDeadline(id), uint256(D2) + P);
    }

    function test_Cap_ClaimBoundaryUsesCappedExtension() public {
        uint64 D2 = uint64(t0 + 400 days);
        uint256 id = _openThree(SAP1, D2);
        vm.warp(ps);
        _pause();
        vm.warp(ps + 100 days);
        _unpause();
        vm.warp(uint256(D2) + P);
        _expectNotExpiredReclaim(id);
        _claim(alice, id);
        vm.warp(uint256(D2) + P + 1);
        _expectExpiredClaim(bob, id);
        vm.prank(owner);
        vault.reclaimExpired(id);
        assertEq(vault.totalOwed(), 0);
    }

    function test_Cap_RunCreatedDuringLapsedPauseGetsNoPhantomExtension() public {
        vm.warp(ps);
        _pause();
        vm.warp(ps + 40 days); // lapsed 10 days ago
        uint64 dl = uint64(block.timestamp + 20 days);
        uint256 id = _openThree(SAP1, dl);
        assertEq(vault.getRun(id).pausedBaseline, P);
        assertEq(vault.effectiveDeadline(id), dl);
        assertEq(vault.claimable(id, alice), A); // claims are open during the lapse
        vm.warp(ps + 50 days);
        _unpause();
        assertEq(vault.effectiveDeadline(id), dl);
        vm.warp(dl);
        _claim(alice, id);
        vm.warp(uint256(dl) + 1);
        _expectExpiredClaim(bob, id);
    }

    function testFuzz_Cap_ExtensionIsMinOfDurationAndMax(uint256 dur) public {
        dur = bound(dur, 0, 400 days);
        uint64 D2 = uint64(t0 + 800 days);
        uint256 id = _openThree(SAP1, D2);
        vm.warp(ps);
        _pause();
        vm.warp(ps + dur);
        uint256 ext = dur < P ? dur : P;
        assertEq(vault.effectiveDeadline(id), uint256(D2) + ext);
        assertEq(vault.claimsPaused(), dur < P);
        _unpause();
        assertEq(vault.effectiveDeadline(id), uint256(D2) + ext);
    }

    // ------------------------------------------------------------ cooldown
    function test_Cooldown_AfterNormalUnpauseBoundary() public {
        _openThree(SAP1, 0);
        vm.warp(ps);
        _pause();
        vm.warp(ps + 100);
        _unpause();
        uint256 u = ps + 100;

        _expectCooldown(u + W); // same block
        vm.warp(u + W - 1);
        _expectCooldown(u + W);
        vm.warp(u + W);
        _pause();
        assertTrue(vault.claimsPaused());
    }

    function test_Cooldown_ZeroLengthPauseStillStartsCooldown() public {
        vm.warp(ps);
        _pause();
        _unpause();
        _expectCooldown(ps + W);
        vm.warp(ps + W);
        _pause();
    }

    function test_Cooldown_AfterLapseAndLateUnpauseCountsFromLapse() public {
        _openThree(SAP1, 0);
        vm.warp(ps);
        _pause();
        vm.warp(ps + P + 5 days); // lapsed 5 days ago
        _unpause();
        // cooldown ends 7 days after the lapse (ps+P), i.e. 2 days after this unpause
        _expectCooldown(ps + P + W);
        vm.warp(ps + P + W - 1);
        _expectCooldown(ps + P + W);
        vm.warp(ps + P + W);
        _pause();
    }

    function test_Cooldown_AfterVeryLateUnpauseNoCooldownRemains() public {
        vm.warp(ps);
        _pause();
        vm.warp(ps + P + W + 1);
        _unpause();
        _pause(); // lapse+cooldown already elapsed
        assertTrue(vault.claimsPaused());
    }

    function test_Cooldown_ClaimsAlwaysOpenInsideCooldown() public {
        uint256 id = _openThree(SAP1, 0);
        vm.warp(ps);
        _pause();
        vm.warp(ps + 100);
        _unpause();
        uint256 u = ps + 100;

        assertEq(vault.claimable(id, alice), A);
        _claim(alice, id); // first second of cooldown
        vm.warp(u + W - 1);
        _expectCooldown(u + W);
        _claimMany(bob, id); // last second of cooldown
        assertEq(usdc.balanceOf(alice), A);
        assertEq(usdc.balanceOf(bob), B);
        vm.warp(u + W);
        _pause(); // cooldown over; owner can pause again
        _expectPausedClaim(carol, id);
    }

    function test_Cooldown_ClaimsOpenInsideCooldownAfterLapse() public {
        uint256 id = _openThree(SAP1, 0);
        vm.warp(ps);
        _pause();
        vm.warp(ps + 31 days);
        _unpause();
        // cooldown (ends ps+37d) still running; claims are open all through it
        assertTrue(block.timestamp < ps + P + W);
        _claim(alice, id);
        vm.warp(ps + P + W - 1);
        _claim(bob, id);
        _expectCooldown(ps + P + W);
        _claim(carol, id);
        assertEq(vault.totalOwed(), 0);
    }

    function test_Cooldown_CannotChainPausesToHoldClaimsClosed() public {
        // Worst case for employees: pause, lapse, unpause, wait exactly out the cooldown, pause again.
        // Claims are open from the lapse until the next pause: at least 7 days.
        uint256 id = _openThree(SAP1, 0);
        vm.warp(ps);
        _pause();
        vm.warp(ps + P);
        assertEq(vault.claimable(id, alice), A);
        _unpause();
        vm.warp(ps + P + W - 1);
        assertEq(vault.claimable(id, alice), A);
        vm.warp(ps + P + W);
        _pause();
        assertEq(vault.claimable(id, alice), 0);
    }
}
