// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {PayrollVaultPauseBase} from "./PayrollVault.PauseBase.t.sol";
import {PayrollVault} from "../PayrollVault.sol";

/// @dev Multi-step pause / lapse / cooldown sequences: reserved funds, abandoned owner, many cycles.
contract PayrollVaultScenariosTest is PayrollVaultPauseBase {
    bytes32 internal constant SAP3 = keccak256("SAP-3");

    /// @dev Whatever the surplus is, one wei more must be refused (reserved funds are untouchable).
    function _assertReservedSafe() internal {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 owed = vault.totalOwed();
        assertGe(bal, owed);
        uint256 surplus = bal - owed;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientSurplus.selector, surplus + 1, surplus));
        vault.withdrawSurplus(owner, surplus + 1);
    }

    // ------------------------------------------------------------ reserved funds
    function test_Reserved_NoPauseCooldownSequenceLetsOwnerTakeReservedFunds() public {
        uint64 D1 = uint64(t0 + 60 days);
        uint256 id = _openThree(SAP1, D1);
        usdc.mint(address(vault), 50e6); // genuine surplus
        _assertReservedSafe();
        uint256 ps = t0 + 1 days;

        // pause #1, through and past its 30 day lapse (still not cleared)
        vm.warp(ps);
        _pause();
        uint256[3] memory cps = [ps + P - 1, ps + P, t0 + 89 days];
        for (uint256 i; i < 3; ++i) {
            vm.warp(cps[i]);
            _expectNotExpiredReclaim(id);
            _assertReservedSafe();
            assertEq(vault.totalOwed(), TOTAL3);
        }
        // clear it right before the extended deadline (D1 + 30d = t0+90d)
        _unpause();
        assertEq(vault.effectiveDeadline(id), uint256(D1) + P);
        _expectNotExpiredReclaim(id);
        _assertReservedSafe();

        // re-pause immediately (cooldown counted from the lapse at ps+P): deadline recedes further
        _pause();
        vm.warp(t0 + 95 days);
        assertEq(vault.effectiveDeadline(id), uint256(D1) + P + 6 days);
        _expectNotExpiredReclaim(id);
        _assertReservedSafe();
        vm.warp(t0 + 100 days);
        _unpause(); // +11 days -> 41 days total
        uint256 eff = uint256(D1) + P + 11 days;
        assertEq(eff, t0 + 101 days);
        assertEq(vault.effectiveDeadline(id), eff);

        // inside the new cooldown the owner can neither pause again nor reclaim early
        _expectCooldown(t0 + 100 days + W);
        _expectNotExpiredReclaim(id);
        _assertReservedSafe();

        // alice claims at the exact extended deadline; bob is one second late
        vm.warp(eff);
        _claim(alice, id);
        _expectNotExpiredReclaim(id);
        vm.warp(eff + 1);
        _expectExpiredClaim(bob, id);

        // only now can the owner release B + C, and then exactly surplus + B + C is withdrawable
        vm.prank(owner);
        vault.reclaimExpired(id);
        assertEq(vault.totalOwed(), 0);
        _assertReservedSafe();
        vm.prank(owner);
        vault.withdrawSurplus(owner, 50e6 + B + C);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(alice), A);
    }

    function test_Reserved_ReclaimStillBlockedByLapsedUnclearedPauseUntilExtendedDeadline() public {
        uint64 D1 = uint64(t0 + 5 days);
        uint256 id = _openThree(SAP1, D1);
        vm.warp(t0 + 1 days);
        _pause();
        // deadline D1 would have passed during the pause, but the extension (capped) pushes it to D1 + 30d
        vm.warp(uint256(D1) + 1);
        _expectNotExpiredReclaim(id);
        vm.warp(uint256(D1) + P);
        _expectNotExpiredReclaim(id);
        _claim(alice, id); // claims open: lapsed at ps+30d = t0+31d < D1+30d
        vm.warp(uint256(D1) + P + 1);
        _expectExpiredClaim(bob, id);
        vm.prank(owner);
        vault.reclaimExpired(id); // permitted even though paused() is still true
        assertEq(vault.totalOwed(), 0);
        assertTrue(vault.paused());
    }

    // ------------------------------------------------------------ owner lost while paused
    function test_OwnerLost_EmployeesStillClaimAfterDay30AndFundsStayReserved() public {
        uint256 idU = _openThree(SAP1, 0); // unlimited
        uint256 idF = _openThree(SAP2, uint64(t0 + 60 days)); // finite
        assertEq(vault.totalOwed(), 2 * TOTAL3);
        uint256 ps = t0 + 1 days;
        vm.warp(ps);
        _pause();

        // then nobody calls anything. Day 29.999: still frozen.
        vm.warp(ps + P - 1);
        _expectPausedClaim(alice, idU);
        _expectPausedClaim(alice, idF);

        // day 30: claims reopen on their own, with no owner transaction
        vm.warp(ps + P);
        _claim(alice, idU);
        _claimMany(bob, idF);
        assertEq(usdc.balanceOf(alice), A);
        assertEq(usdc.balanceOf(bob), B);

        // finite run keeps its (capped) extended deadline D + 30d = t0+90d
        vm.warp(t0 + 90 days);
        _claim(carol, idF);
        vm.warp(t0 + 90 days + 1);
        _expectExpiredClaim(alice, idF);

        // a year later the vault is STILL "paused" yet unlimited payroll is claimable
        vm.warp(ps + 365 days);
        assertTrue(vault.paused());
        assertFalse(vault.claimsPaused());
        _claim(bob, idU);
        _claimMany(carol, idU);
        assertEq(usdc.balanceOf(carol), C + C);
        // only alice's expired-but-unreleased F allocation is still reserved; it cannot be taken
        assertEq(vault.totalOwed(), A);
        _expectNoSurplus();
    }

    function test_OwnerLost_FullyOpenedWindowIsAtLeastTheRemainingDeadlineTime() public {
        // deadline 10 days after creation, pause 1 day in: remaining 9 days is preserved after the lapse
        uint256 id = _openThree(SAP1, uint64(t0 + 10 days));
        uint256 ps = t0 + 1 days;
        vm.warp(ps);
        _pause();
        vm.warp(ps + 400 days);
        // pause lapsed at ps+30d; eff = D + 30d = ps + 39d, long gone after 400 days: expired
        _expectExpiredClaim(alice, id);
        // but exactly at the first instant of reopening the employee had 9 full days
        assertEq(vault.effectiveDeadline(id) - (ps + P), 9 days);
    }

    // ------------------------------------------------------------ multiple cycles
    function test_Cycles_AccumulateCappedDurationsAcrossRunsAndCooldowns() public {
        uint64 D = uint64(t0 + 400 days);
        _fund(2 * TOTAL3);
        uint256 id1 = _draftThree(SAP1, D);
        _open(id1);

        // cycle 1: 10 days, ordinary
        uint256 s1 = t0 + 1 days;
        vm.warp(s1);
        _pause();
        vm.warp(s1 + 10 days);
        _unpause();
        assertEq(vault.effectiveDeadline(id1), uint256(D) + 10 days);

        // run 2 opened between cycles: baseline 10 days
        vm.warp(s1 + 11 days);
        uint256 id2 = _draftThree(SAP2, D);
        _open(id2);
        assertEq(vault.getRun(id2).pausedBaseline, 10 days);
        assertEq(vault.effectiveDeadline(id2), D);

        // cycle 2: pause exactly at the cooldown boundary; runs 40 days -> capped to 30
        uint256 s2 = s1 + 10 days + W;
        vm.warp(s2 - 1);
        _expectCooldown(s2);
        vm.warp(s2);
        _pause();
        vm.warp(s2 + 40 days);
        _unpause();
        assertEq(vault.effectiveDeadline(id1), uint256(D) + 40 days);
        assertEq(vault.effectiveDeadline(id2), uint256(D) + P);

        // cycle 3: cooldown (from the lapse at s2+30d) is long over; 5 days
        uint256 s3 = s2 + 40 days;
        _pause();
        vm.warp(s3 + 5 days);
        _unpause();
        assertEq(vault.effectiveDeadline(id1), uint256(D) + 45 days);
        assertEq(vault.effectiveDeadline(id2), uint256(D) + 35 days);

        // and the cooldown restarts after cycle 3
        vm.warp(s3 + 5 days + W - 1);
        _expectCooldown(s3 + 5 days + W);

        // exact boundaries, ascending
        vm.warp(uint256(D) + 35 days);
        _claim(alice, id2);
        _expectNotExpiredReclaim(id1);
        vm.warp(uint256(D) + 35 days + 1);
        _expectExpiredClaim(bob, id2);
        assertEq(vault.claimable(id1, bob), B);

        vm.warp(uint256(D) + 45 days);
        _claim(bob, id1);
        vm.warp(uint256(D) + 45 days + 1);
        _expectExpiredClaim(carol, id1);

        vm.startPrank(owner);
        vault.reclaimExpired(id1);
        vault.reclaimExpired(id2);
        vm.stopPrank();
        assertEq(vault.totalOwed(), 0);
    }

    function testFuzz_Cycles_ExtensionIsSumOfCappedDurations(uint256 d1, uint256 d2, uint256 d3) public {
        d1 = bound(d1, 0, 50 days);
        d2 = bound(d2, 0, 50 days);
        d3 = bound(d3, 0, 50 days);
        uint64 D = uint64(t0 + 1000 days);
        uint256 id = _openThree(SAP1, D);
        uint256[3] memory ds = [d1, d2, d3];
        uint256 expected;
        uint256 lastEnd;
        uint256 at = t0 + 1 days;
        for (uint256 i; i < 3; ++i) {
            vm.warp(at);
            _pause();
            vm.warp(at + ds[i]);
            _unpause();
            uint256 capped = ds[i] < P ? ds[i] : P;
            expected += capped;
            lastEnd = at + capped;
            assertEq(vault.effectiveDeadline(id), uint256(D) + expected);
            // next pause: at the cooldown boundary, but never in the past
            at = lastEnd + W;
            if (at < block.timestamp) at = block.timestamp;
            if (at > block.timestamp) {
                vm.warp(at - 1);
                if (at - 1 < lastEnd + W) _expectCooldown(lastEnd + W);
            }
        }
        vm.warp(uint256(D) + expected);
        _claim(alice, id);
        vm.warp(uint256(D) + expected + 1);
        _expectExpiredClaim(bob, id);
    }
}
