// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {PayrollVaultTestBase} from "./PayrollVault.Base.t.sol";
import {PayrollVault} from "../PayrollVault.sol";

/// @dev Pausing freezes claim deadlines: each run's effective deadline is extended by the time
///      the vault spent paused since the run was created.
contract PayrollVaultPauseTest is PayrollVaultTestBase {
    bytes32 internal constant SAP3 = keccak256("SAP-3");

    uint256 internal t0;
    uint64 internal D; // original absolute deadline = t0 + 1000

    function setUp() public override {
        super.setUp();
        t0 = block.timestamp;
        D = uint64(t0 + 1000);
    }

    function _pause() internal {
        vm.prank(owner);
        vault.pause();
    }

    function _unpause() internal {
        vm.prank(owner);
        vault.unpause();
    }

    function _claim(address who, uint256 id) internal {
        vm.prank(who);
        vault.claim(id);
    }

    function _expectExpiredClaim(address who, uint256 id) internal {
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ClaimDeadlinePassed.selector, id));
        vault.claim(id);
    }

    function _expectNotExpiredReclaim(uint256 id) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.RunNotExpired.selector, id));
        vault.reclaimExpired(id);
    }

    // ---------------------------------------------------------------- claims
    function test_Pause_ClaimAfterOriginalDeadlineSucceedsWhenPauseCoveredGap() public {
        uint256 id = _openThree(SAP1, D);
        vm.warp(t0 + 900);
        _pause();
        vm.warp(t0 + 1500); // original deadline passed entirely inside the pause
        _unpause(); // paused 600s -> effective deadline D + 600

        assertEq(vault.claimable(id, alice), A);
        _claim(alice, id);
        assertEq(usdc.balanceOf(alice), A);

        // still valid at the exact extended deadline, expired strictly after it
        vm.warp(uint256(D) + 600);
        assertEq(vault.claimable(id, bob), B);
        _claim(bob, id);
        vm.warp(uint256(D) + 601);
        assertEq(vault.claimable(id, carol), 0);
        _expectExpiredClaim(carol, id);
    }

    function test_Pause_ClaimManyHonoursExtendedDeadline() public {
        uint256 id = _openThree(SAP1, D);
        vm.warp(t0 + 900);
        _pause();
        vm.warp(t0 + 1300);
        _unpause(); // +400
        vm.warp(uint256(D) + 400);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(alice);
        vault.claimMany(ids);
        assertEq(usdc.balanceOf(alice), A);

        vm.warp(uint256(D) + 401);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ClaimDeadlinePassed.selector, id));
        vault.claimMany(ids);
    }

    function test_Pause_ClaimsRevertWhilePausedEvenBeforeDeadline() public {
        uint256 id = _openThree(SAP1, D);
        vm.warp(t0 + 10);
        _pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claim(id);
        assertEq(vault.claimable(id, alice), 0);
    }

    function test_Pause_DeadlineExpiredBeforePauseStaysExpired() public {
        uint256 id = _openThree(SAP1, D);
        vm.warp(uint256(D) + 1); // already expired
        _expectExpiredClaim(alice, id);
        _pause();
        vm.warp(uint256(D) + 500);
        _unpause();
        // pausing after expiry must not resurrect claims
        assertEq(vault.claimable(id, alice), 0);
        _expectExpiredClaim(alice, id);
        vm.prank(owner);
        vault.reclaimExpired(id);
        assertEq(vault.totalOwed(), 0);
    }

    function test_Pause_ZeroDurationPauseDoesNotExtend() public {
        uint256 id = _openThree(SAP1, D);
        vm.warp(t0 + 500);
        _pause();
        _unpause();
        assertEq(vault.effectiveDeadline(id), D);
        vm.warp(uint256(D) + 1);
        _expectExpiredClaim(alice, id);
    }

    // ---------------------------------------------------------------- reclaim
    function test_Pause_ReclaimRevertsWhilePausedAndUntilExtendedDeadlinePasses() public {
        uint256 id = _openThree(SAP1, D);
        vm.warp(t0 + 900);
        _pause();

        vm.warp(uint256(D) + 50); // original deadline passed, still paused
        _expectNotExpiredReclaim(id);
        vm.warp(uint256(D) + 5000); // deadline keeps receding while paused
        _expectNotExpiredReclaim(id);

        _unpause(); // paused from t0+900 to D+5000
        uint256 extra = uint256(D) + 5000 - (t0 + 900);
        assertEq(vault.effectiveDeadline(id), uint256(D) + extra);

        // right after unpausing the run is not expired; it only expires after the extended deadline
        _expectNotExpiredReclaim(id);
        vm.warp(uint256(D) + extra);
        _expectNotExpiredReclaim(id);
        assertEq(vault.claimable(id, alice), A);

        vm.warp(uint256(D) + extra + 1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PayrollVault.ExpiredReclaimed(id, TOTAL3);
        vm.prank(owner);
        vault.reclaimExpired(id);
        assertEq(vault.totalOwed(), 0);
    }

    function test_Pause_ReclaimAllowedWhilePausedOnlyIfAlreadyExpiredBeforePause() public {
        uint256 id = _openThree(SAP1, D);
        vm.warp(uint256(D) + 10);
        _pause();
        vm.warp(uint256(D) + 100);
        vm.prank(owner);
        vault.reclaimExpired(id); // expiry preceded the pause
        assertTrue(vault.getRun(id).expiredReleased);
    }

    // ---------------------------------------------------------------- effectiveDeadline
    function test_EffectiveDeadline_ValuesAcrossPauseLifecycle() public {
        uint256 id = _openThree(SAP1, D);
        assertEq(vault.effectiveDeadline(id), D);
        assertEq(vault.getRun(id).pausedBaseline, 0);

        vm.warp(t0 + 200);
        _pause();
        assertEq(vault.effectiveDeadline(id), D); // nothing elapsed yet
        vm.warp(t0 + 500);
        assertEq(vault.effectiveDeadline(id), uint256(D) + 300); // grows 1:1 while paused
        vm.warp(t0 + 800);
        assertEq(vault.effectiveDeadline(id), uint256(D) + 600);
        _unpause();
        assertEq(vault.effectiveDeadline(id), uint256(D) + 600);
        vm.warp(t0 + 5000); // frozen once unpaused
        assertEq(vault.effectiveDeadline(id), uint256(D) + 600);
    }

    function test_EffectiveDeadline_ZeroForUnlimitedRunEvenAcrossPause() public {
        uint256 id = _openThree(SAP1, 0);
        assertEq(vault.effectiveDeadline(id), 0);
        _pause();
        vm.warp(block.timestamp + 100);
        assertEq(vault.effectiveDeadline(id), 0);
        _unpause();
        assertEq(vault.effectiveDeadline(id), 0);
        _claim(alice, id);
    }

    function test_EffectiveDeadline_UnknownRunReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 0));
        vault.effectiveDeadline(0);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 3));
        vault.effectiveDeadline(3);
    }

    function test_EffectiveDeadline_DraftRunPauseAdjustsOpenDeadlineCheck() public {
        uint256 id = _draftThree(SAP1, D);
        _fund(TOTAL3);
        vm.warp(t0 + 900);
        _pause();
        vm.warp(t0 + 1100); // past the original deadline, but frozen
        _unpause(); // +200 -> effective t0+1200
        assertEq(vault.effectiveDeadline(id), t0 + 1200);
        _open(id); // would revert ClaimDeadlinePassed without the pause adjustment
        _claim(alice, id);
        assertEq(usdc.balanceOf(alice), A);
    }

    // ---------------------------------------------------------------- runs created while paused
    function test_Pause_RunCreatedWhilePausedIsOnlyExtendedByLaterPauseTime() public {
        vm.warp(t0 + 100);
        _pause();
        uint256 id1 = _draftThree(SAP1, D);
        assertEq(vault.getRun(id1).pausedBaseline, 0);

        vm.warp(t0 + 400);
        uint256 id2 = _draftThree(SAP2, D);
        assertEq(vault.getRun(id2).pausedBaseline, 300);
        assertEq(vault.effectiveDeadline(id2), D); // no pause time since its creation

        _fund(2 * TOTAL3);
        _open(id1); // admin actions work while paused
        _open(id2);

        vm.warp(t0 + 700);
        assertEq(vault.effectiveDeadline(id1), uint256(D) + 600);
        assertEq(vault.effectiveDeadline(id2), uint256(D) + 300);
        _unpause();
        assertEq(vault.effectiveDeadline(id1), uint256(D) + 600);
        assertEq(vault.effectiveDeadline(id2), uint256(D) + 300);

        vm.warp(uint256(D) + 300);
        _claim(alice, id2);
        vm.warp(uint256(D) + 301);
        _expectExpiredClaim(bob, id2);
        assertEq(vault.claimable(id1, bob), B); // run 1 has 300 more seconds

        vm.warp(uint256(D) + 600);
        _claim(bob, id1);
        vm.warp(uint256(D) + 601);
        _expectExpiredClaim(carol, id1);
    }

    function test_Pause_RunCreatedWhilePausedCannotBeClaimedUntilUnpause() public {
        _pause();
        uint256 id = _draftThree(SAP1, D);
        _fund(TOTAL3);
        _open(id);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claim(id);
        _unpause();
        _claim(alice, id);
    }

    // ---------------------------------------------------------------- multiple cycles
    function test_Pause_MultipleCyclesAccumulatePerRunBaselines() public {
        // deadlines are far out so the 7-day pause cooldowns fit between cycles
        uint64 L = uint64(t0 + 100 days);
        uint256 W = 7 days;
        _fund(3 * TOTAL3);
        uint256 id1 = _draftThree(SAP1, L);
        _open(id1);

        // cycle 1: t0+100 .. t0+200 (100s)
        vm.warp(t0 + 100);
        _pause();
        vm.warp(t0 + 200);
        _unpause();
        assertEq(vault.effectiveDeadline(id1), uint256(L) + 100);

        // run 2 created between cycles (baseline 100)
        vm.warp(t0 + 250);
        uint256 id2 = _draftThree(SAP2, L);
        _open(id2);
        assertEq(vault.getRun(id2).pausedBaseline, 100);
        assertEq(vault.effectiveDeadline(id2), L);

        // cycle 2: s2 .. s2+150 (150s), s2 = end of cycle 1 + cooldown; run 3 created mid-pause (baseline 150)
        uint256 s2 = t0 + 200 + W;
        vm.warp(s2);
        _pause();
        vm.warp(s2 + 50);
        uint256 id3 = _draftThree(SAP3, L);
        _open(id3);
        assertEq(vault.getRun(id3).pausedBaseline, 150);
        vm.warp(s2 + 150);
        _unpause();
        assertEq(vault.effectiveDeadline(id1), uint256(L) + 250);
        assertEq(vault.effectiveDeadline(id2), uint256(L) + 150);
        assertEq(vault.effectiveDeadline(id3), uint256(L) + 100);

        // cycle 3: s3 .. s3+10 (10s)
        uint256 s3 = s2 + 150 + W;
        vm.warp(s3);
        _pause();
        vm.warp(s3 + 10);
        _unpause();
        D = L; // boundaries below are relative to the common original deadline
        assertEq(vault.effectiveDeadline(id1), uint256(D) + 260);
        assertEq(vault.effectiveDeadline(id2), uint256(D) + 160);
        assertEq(vault.effectiveDeadline(id3), uint256(D) + 110);

        // boundaries, in ascending time order
        vm.warp(uint256(D) + 110);
        _claim(alice, id3);
        vm.warp(uint256(D) + 111);
        _expectExpiredClaim(bob, id3);
        assertEq(vault.claimable(id2, bob), B);

        vm.warp(uint256(D) + 160);
        _claim(bob, id2);
        vm.warp(uint256(D) + 161);
        _expectExpiredClaim(carol, id2);
        assertEq(vault.claimable(id1, carol), C);

        vm.warp(uint256(D) + 260);
        _claim(carol, id1);
        vm.warp(uint256(D) + 261);
        _expectExpiredClaim(alice, id1);

        // each run is releasable exactly once it is past its own extended deadline
        vm.startPrank(owner);
        vault.reclaimExpired(id1);
        vault.reclaimExpired(id2);
        vault.reclaimExpired(id3);
        vm.stopPrank();
        assertEq(vault.totalOwed(), 0);
    }

    // ---------------------------------------------------------------- reserved funds
    function test_Pause_OwnerCannotTakeReservedFundsByPausingAndWaiting() public {
        uint256 id = _openThree(SAP1, D);
        vm.warp(t0 + 10);
        _pause();
        // while claims are paused (strictly before the 30 day lapse) nothing is reclaimable
        vm.warp(t0 + 10 + 30 days - 1);
        _expectNotExpiredReclaim(id);
        assertEq(vault.totalOwed(), TOTAL3);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientSurplus.selector, 1, 0));
        vault.withdrawSurplus(owner, 1);
        assertEq(usdc.balanceOf(address(vault)), TOTAL3);

        // claims reopened by the lapse (pause not cleared): the extended deadline is D + 30 days
        vm.warp(t0 + 10 + 30 days);
        _expectNotExpiredReclaim(id);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientSurplus.selector, 1, 0));
        vault.withdrawSurplus(owner, 1);

        // employees still get paid after unpause, and the owner still cannot reclaim yet
        _unpause();
        _expectNotExpiredReclaim(id);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientSurplus.selector, 1, 0));
        vault.withdrawSurplus(owner, 1);
        _claim(alice, id);
        _claim(bob, id);
        _claim(carol, id);
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(carol), TOTAL3);
        assertEq(vault.totalOwed(), 0);
    }

    function test_Pause_OwnerCannotShortCircuitByRepeatedPauseUnpause() public {
        uint64 L = uint64(t0 + 100 days);
        uint256 id = _openThree(SAP1, L);
        for (uint256 i; i < 5; ++i) {
            // each cycle starts after the 7 day cooldown of the previous one
            vm.warp(t0 + 100 + i * 8 days);
            _pause();
            vm.warp(t0 + 200 + i * 8 days);
            _unpause();
        }
        // five 100s pauses -> +500s; the claim window never shrinks
        assertEq(vault.effectiveDeadline(id), uint256(L) + 500);
        vm.warp(uint256(L) + 500);
        _expectNotExpiredReclaim(id);
        _claim(alice, id);
    }
}
