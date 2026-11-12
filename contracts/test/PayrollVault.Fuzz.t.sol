// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {PayrollVaultTestBase, MockUSDC} from "./PayrollVault.Base.t.sol";
import {PayrollVault} from "../PayrollVault.sol";

// ============================================================================ fuzz
contract PayrollVaultFuzzTest is PayrollVaultTestBase {
    function testFuzz_ClaimsPayExactAmountsAndDrainReservation(uint96 a, uint96 b, uint96 c) public {
        uint256 x = bound(a, 1, 1e15);
        uint256 y = bound(b, 1, 1e15);
        uint256 z = bound(c, 1, 1e15);
        uint256 id = _create(SAP1, 0, 3, x + y + z);
        _add(id, alice, x);
        _add(id, bob, y);
        _add(id, carol, z);
        _fund(x + y + z);
        _open(id);
        assertEq(vault.totalOwed(), x + y + z);

        vm.prank(alice);
        vault.claim(id);
        vm.prank(bob);
        vault.claim(id);
        vm.prank(carol);
        vault.claim(id);

        assertEq(usdc.balanceOf(alice), x);
        assertEq(usdc.balanceOf(bob), y);
        assertEq(usdc.balanceOf(carol), z);
        assertEq(vault.totalOwed(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.getRun(id).totalClaimed, x + y + z);
    }

    function testFuzz_DeadlineBoundary(uint256 deadlineOffset, uint256 warpOffset) public {
        deadlineOffset = bound(deadlineOffset, 1, 1e6);
        warpOffset = bound(warpOffset, 0, 2e6);
        uint64 dl = uint64(block.timestamp + deadlineOffset);
        uint256 id = _openThree(SAP1, dl);
        uint256 target = block.timestamp + warpOffset;
        vm.warp(target);

        if (target <= dl) {
            assertEq(vault.claimable(id, alice), A);
            vm.prank(alice);
            vault.claim(id);
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(PayrollVault.RunNotExpired.selector, id));
            vault.reclaimExpired(id);
        } else {
            assertEq(vault.claimable(id, alice), 0);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(PayrollVault.ClaimDeadlinePassed.selector, id));
            vault.claim(id);
            vm.prank(owner);
            vault.reclaimExpired(id);
            assertEq(vault.totalOwed(), 0);
        }
    }

    /// @dev Revocation happens only in Draft (before opening). Afterwards any ordering of claim / reclaim
    ///      leaves totalOwed equal to the other run's reservation plus this run's net unclaimed amount
    ///      while it is unreleased, and any attempted revoke on the Open run reverts.
    function testFuzz_DraftRevokeThenClaimReclaimOrderingNeverUnderflows(uint8 plan) public {
        uint64 dl = uint64(block.timestamp + 100);
        uint256 id1 = _draftThree(SAP1, dl);

        bool revokeBob = plan & 1 != 0;
        bool revokeAlice = plan & 2 != 0;
        bool claimAlice = plan & 4 != 0 && !revokeAlice;
        bool reclaim = plan & 8 != 0;
        bool claimCarol = plan & 16 != 0;

        if (revokeBob) {
            vm.prank(owner);
            vault.revokeEntry(id1, bob);
        }
        if (revokeAlice) {
            vm.prank(owner);
            vault.revokeEntry(id1, alice);
        }
        _fund(TOTAL3);
        _open(id1);
        uint256 id2 = _draftThree(SAP2, 0);
        _fund(TOTAL3);
        _open(id2);

        uint256 net = TOTAL3 - (revokeBob ? B : 0) - (revokeAlice ? A : 0);
        assertEq(vault.totalOwed(), TOTAL3 + net);

        if (claimAlice) {
            vm.prank(alice);
            vault.claim(id1);
        }
        if (claimCarol) {
            vm.prank(carol);
            vault.claim(id1);
        }
        if (reclaim) {
            vm.warp(uint256(dl) + 1);
            vm.prank(owner);
            vault.reclaimExpired(id1);
        }

        // revoking on an Open run always fails, whatever happened before
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id1, PayrollVault.Status.Open)
        );
        vault.revokeEntry(id1, carol);

        uint256 expected = TOTAL3; // run 2 untouched
        if (!reclaim) expected += vault.unclaimedOf(id1);
        assertEq(vault.totalOwed(), expected);
        assertEq(vault.unclaimedOf(id1), net - (claimAlice ? A : 0) - (claimCarol ? C : 0));
        assertGe(usdc.balanceOf(address(vault)), vault.totalOwed());
    }

    /// @dev For any sequence of pauses, a run's effective deadline equals its original deadline plus the
    ///      total paused time since creation, and a claim at that exact moment succeeds.
    function testFuzz_PauseExtendsDeadlineByPausedDuration(uint256 g1, uint256 p1, uint256 g2, uint256 p2) public {
        g1 = bound(g1, 0, 500);
        p1 = bound(p1, 0, 60 days);
        g2 = bound(g2, 0, 10 days);
        p2 = bound(p2, 0, 60 days);
        uint256 start = block.timestamp;
        uint64 dl = uint64(start + 400 days);
        uint256 id = _openThree(SAP1, dl);
        uint256 cap = vault.MAX_PAUSE();
        uint256 cool = vault.PAUSE_COOLDOWN();

        vm.warp(start + g1);
        vm.prank(owner);
        vault.pause();
        vm.warp(start + g1 + p1);
        vm.prank(owner);
        vault.unpause();
        // the cooldown runs from the end (or lapse) of the first pause
        uint256 lastEnd = start + g1 + (p1 < cap ? p1 : cap);
        uint256 second = lastEnd + cool + g2;
        if (second < block.timestamp) second = block.timestamp;
        vm.warp(second);
        vm.prank(owner);
        vault.pause();
        vm.warp(second + p2);
        vm.prank(owner);
        vault.unpause();

        uint256 eff = uint256(dl) + (p1 < cap ? p1 : cap) + (p2 < cap ? p2 : cap);
        assertEq(vault.effectiveDeadline(id), eff);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.RunNotExpired.selector, id));
        vault.reclaimExpired(id);
        vm.warp(eff);
        vm.prank(alice);
        vault.claim(id);
        vm.warp(eff + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ClaimDeadlinePassed.selector, id));
        vault.claim(id);
        vm.prank(owner);
        vault.reclaimExpired(id);
        assertEq(vault.totalOwed(), 0);
    }

    function testFuzz_SurplusWithdrawalLimit(uint256 donation, uint256 request) public {
        donation = bound(donation, 0, 1e18);
        request = bound(request, 0, 2e18);
        _openThree(SAP1, 0);
        usdc.mint(address(vault), donation);

        vm.prank(owner);
        if (request > donation) {
            vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientSurplus.selector, request, donation));
            vault.withdrawSurplus(owner, request);
        } else {
            vault.withdrawSurplus(owner, request);
            assertEq(usdc.balanceOf(owner), request);
        }
        assertGe(usdc.balanceOf(address(vault)), vault.totalOwed());
    }

    function testFuzz_ControlTotalMismatchBlocksOpen(uint96 a, uint96 b, uint96 delta) public {
        uint256 x = bound(a, 1, 1e15);
        uint256 y = bound(b, 1, 1e15);
        uint256 d = bound(delta, 1, 1e15);
        uint256 id = _create(SAP1, 0, 2, x + y + d);
        _add(id, alice, x);
        _add(id, bob, y);
        usdc.mint(address(vault), x + y + d);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.ControlTotalMismatch.selector, id, 2, 2, x + y + d, x + y)
        );
        vault.openPayrun(id);
        // the excess can never be uploaded beyond the control total
        address[] memory e = new address[](1);
        uint256[] memory am = new uint256[](1);
        bytes32[] memory r = new bytes32[](1);
        e[0] = carol;
        am[0] = d;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ExceedsControlTotals.selector, id));
        vault.addEntries(id, e, am, r); // count cap (2) reached
    }
}

// ============================================================================ invariants
/// @dev Owner of the vault; drives bounded random sequences of lifecycle actions.
contract PayrollHandler is Test {
    PayrollVault public vault;
    MockUSDC public usdc;
    address[5] public actors;
    uint256 internal nonce;
    uint256 public okOpen;
    uint256 public okClaim;
    uint256 public okRevoke;
    uint256 public okReclaim;
    uint256 public okPause;

    // ghost state: independent record of paused time and per-run pause baselines
    uint256 public ghostPausedAccrued;
    uint256 public ghostPausedSince;
    uint256 public ghostLastEnd;
    bool public ghostPaused;
    uint256 internal constant CAP = 30 days;
    uint256 internal constant COOL = 7 days;
    mapping(uint256 => uint256) public ghostBaseline;
    bool public pauseCooldownViolated;
    bool public overdrawSucceeded;
    bool public claimsDivergedFromModel;
    // violation flags, asserted false by the invariants
    bool public revokeSucceededOutsideDraft;
    bool public claimSucceededAfterDeadline;
    bool public claimSucceededWhilePaused;
    bool public reclaimSucceededBeforeDeadline;
    bool public revokeDraftFailed;

    constructor(PayrollVault v, MockUSDC t) {
        vault = v;
        usdc = t;
        for (uint256 i; i < 5; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
        }
    }

    function _run(uint256 seed) internal view returns (uint256) {
        uint256 n = vault.runCount();
        return n == 0 ? 0 : (seed % n) + 1;
    }

    function _revokeDraft(uint256 id, address emp) internal {
        try vault.revokeEntry(id, emp) { ++okRevoke; } catch { revokeDraftFailed = true; }
    }

    /// @dev Independent model: a running pause counts at most 30 days.
    function ghostPausedNow() public view returns (uint256) {
        uint256 elapsed = ghostPaused ? block.timestamp - ghostPausedSince : 0;
        return ghostPausedAccrued + (elapsed < CAP ? elapsed : CAP);
    }

    /// @dev Independent model of claimsPaused().
    function ghostClaimsPaused() public view returns (bool) {
        return ghostPaused && block.timestamp < ghostPausedSince + CAP;
    }

    function _ensureFunding(uint256 additional) internal {
        uint256 needed = vault.totalOwed() + additional;
        uint256 bal = usdc.balanceOf(address(vault));
        if (bal < needed) usdc.mint(address(vault), needed - bal);
    }

    function newRun(uint256 seed, uint256 n, bool withDeadline, bool openIt, bool underfund, bool revokeOne)
        external
    {
        n = bound(n, 1, 5);
        uint64 dl = withDeadline ? uint64(block.timestamp + bound(seed, 1, 2000)) : 0;
        uint256[] memory amts = new uint256[](n);
        address[] memory emps = new address[](n);
        bytes32[] memory refs = new bytes32[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            amts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, 1000e6);
            emps[i] = actors[i];
            total += amts[i];
        }
        uint256 id = vault.createPayrun(keccak256(abi.encode(++nonce)), "r", dl, n, total);
        vault.addEntries(id, emps, amts, refs);
        ghostBaseline[id] = ghostPausedNow();
        if (revokeOne) {
            // revocation is only valid while the run is still Draft
            _revokeDraft(id, emps[seed % n]);
        }
        if (openIt) {
            if (!underfund) _ensureFunding(total);
            try vault.openPayrun(id) { ++okOpen; } catch {}
        }
    }

    function openDraft(uint256 seed) external {
        uint256 id = _run(seed);
        if (id == 0) return;
        _ensureFunding(vault.unclaimedOf(id));
        try vault.openPayrun(id) { ++okOpen; } catch {}
    }

    function cancel(uint256 seed) external {
        uint256 id = _run(seed);
        if (id == 0) return;
        try vault.cancelPayrun(id) {} catch {}
    }

    function claim(uint256 runSeed, uint256 actorSeed) external {
        uint256 id = _run(runSeed);
        if (id == 0) return;
        uint256 eff = vault.effectiveDeadline(id);
        bool wasPaused = ghostClaimsPaused();
        if (vault.claimsPaused() != wasPaused) claimsDivergedFromModel = true;
        vm.prank(actors[actorSeed % 5]);
        try vault.claim(id) {
            ++okClaim;
            if (eff != 0 && block.timestamp > eff) claimSucceededAfterDeadline = true;
            if (wasPaused) claimSucceededWhilePaused = true;
        } catch {}
    }

    function claimMany(uint256 seedA, uint256 seedB, uint256 actorSeed) external {
        uint256[] memory ids = new uint256[](2);
        ids[0] = _run(seedA);
        ids[1] = _run(seedB);
        if (ids[0] == 0) return;
        bool wasPaused = ghostClaimsPaused();
        vm.prank(actors[actorSeed % 5]);
        try vault.claimMany(ids) {
            ++okClaim;
            if (wasPaused) claimSucceededWhilePaused = true;
        } catch {}
    }

    function revoke(uint256 runSeed, uint256 actorSeed) external {
        uint256 id = _run(runSeed);
        if (id == 0) return;
        PayrollVault.Status st = vault.getRun(id).status;
        try vault.revokeEntry(id, actors[actorSeed % 5]) {
            ++okRevoke;
            if (st != PayrollVault.Status.Draft) revokeSucceededOutsideDraft = true;
        } catch {}
    }

    function reclaim(uint256 runSeed) external {
        uint256 id = _run(runSeed);
        if (id == 0) return;
        // independent model: original deadline + capped paused time since creation
        uint256 dl0 = vault.getRun(id).claimDeadline;
        uint256 eff = dl0 == 0 ? 0 : dl0 + ghostPausedNow() - ghostBaseline[id];
        try vault.reclaimExpired(id) {
            ++okReclaim;
            if (eff == 0 || block.timestamp <= eff) reclaimSucceededBeforeDeadline = true;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 1500));
    }

    function donate(uint256 amount) external {
        usdc.mint(address(vault), bound(amount, 0, 500e6));
    }

    function withdraw(uint256 amount) external {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 owed = vault.totalOwed();
        uint256 avail = bal > owed ? bal - owed : 0;
        // one wei past the surplus (i.e. into reserved funds) must always be refused
        try vault.withdrawSurplus(address(0xBEEF), avail + 1) { overdrawSucceeded = true; } catch {}
        try vault.withdrawSurplus(address(0xBEEF), bound(amount, 0, avail)) {} catch {}
    }

    /// @dev Long warp so that pauses can lapse (30 days) and cooldowns (7 days) elapse.
    function warpLong(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 45 days));
    }

    function pauseToggle(bool on) external {
        if (on && !ghostPaused) {
            bool cooling = ghostLastEnd != 0 && block.timestamp < ghostLastEnd + COOL;
            try vault.pause() {
                if (cooling) pauseCooldownViolated = true;
                ghostPaused = true;
                ghostPausedSince = block.timestamp;
                ++okPause;
            } catch {
                if (!cooling) pauseCooldownViolated = true; // a legal pause was refused
            }
        } else if (!on && ghostPaused) {
            vault.unpause();
            uint256 elapsed = block.timestamp - ghostPausedSince;
            uint256 duration = elapsed < CAP ? elapsed : CAP;
            ghostPausedAccrued += duration;
            ghostLastEnd = ghostPausedSince + duration;
            ghostPaused = false;
            ghostPausedSince = 0;
        }
    }
}

contract PayrollVaultInvariantTest is PayrollVaultTestBase {
    PayrollHandler internal handler;

    function setUp() public override {
        usdc = new MockUSDC(6);
        // The handler must own the vault and the vault must be known to the handler:
        // resolve the cycle by predicting the handler's CREATE address.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vault = new PayrollVault(address(usdc), predicted);
        handler = new PayrollHandler(vault, usdc);
        require(address(handler) == predicted, "prediction failed");
        targetContract(address(handler));
    }

    /// @dev Logs how many state-changing actions actually succeeded (guards against a vacuous run).
    function afterInvariant() public view {
        console2.log("open/claim/revoke/reclaim", handler.okOpen(), handler.okClaim());
        console2.log("revoke/reclaim", handler.okRevoke(), handler.okReclaim());
        console2.log("pauses", handler.okPause());
    }

    /// PROPERTY: the vault can always cover every reserved obligation.
    function invariant_BalanceCoversTotalOwed() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.totalOwed());
    }

    /// PROPERTY: totalOwed == sum of unclaimed(unrevoked) in Open, non-released runs.
    function invariant_TotalOwedEqualsUnclaimedInLiveOpenRuns() public view {
        uint256 sum;
        uint256 n = vault.runCount();
        for (uint256 id = 1; id <= n; ++id) {
            PayrollVault.Run memory r = vault.getRun(id);
            if (r.status == PayrollVault.Status.Open && !r.expiredReleased) {
                sum += uint256(r.totalAllocated) - r.totalClaimed - r.totalRevoked;
            }
        }
        assertEq(vault.totalOwed(), sum);
    }

    /// PROPERTY: per-run accounting never exceeds gross, and employees only receive what was claimed.
    function invariant_RunAccountingAndPayouts() public view {
        uint256 claimedSum;
        uint256 n = vault.runCount();
        for (uint256 id = 1; id <= n; ++id) {
            PayrollVault.Run memory r = vault.getRun(id);
            assertLe(uint256(r.totalClaimed) + r.totalRevoked, r.totalAllocated);
            assertLe(r.entryCount, r.expectedEntryCount);
            assertLe(r.totalAllocated, r.expectedTotal);
            claimedSum += r.totalClaimed;
        }
        uint256 held;
        for (uint256 i; i < 5; ++i) {
            held += usdc.balanceOf(handler.actors(i));
        }
        assertEq(held, claimedSum);
    }

    /// PROPERTY: revocation never succeeds outside Draft, and never fails on a fresh Draft entry.
    function invariant_RevokeOnlyInDraft() public view {
        assertFalse(handler.revokeSucceededOutsideDraft());
        assertFalse(handler.revokeDraftFailed());
        uint256 n = vault.runCount();
        for (uint256 id = 1; id <= n; ++id) {
            PayrollVault.Run memory r = vault.getRun(id);
            if (r.status == PayrollVault.Status.Open && !r.expiredReleased) {
                // revoked amounts in a live Open run were all revoked before opening, so net reserve is exact
                assertEq(vault.unclaimedOf(id), uint256(r.totalAllocated) - r.totalClaimed - r.totalRevoked);
            }
        }
    }

    /// PROPERTY: effectiveDeadline == claimDeadline + paused time since creation (tracked independently).
    function invariant_EffectiveDeadlineTracksPausedTime() public view {
        uint256 n = vault.runCount();
        for (uint256 id = 1; id <= n; ++id) {
            PayrollVault.Run memory r = vault.getRun(id);
            uint256 eff = vault.effectiveDeadline(id);
            if (r.claimDeadline == 0) {
                assertEq(eff, 0);
            } else {
                assertEq(eff, uint256(r.claimDeadline) + handler.ghostPausedNow() - handler.ghostBaseline(id));
                assertGe(eff, r.claimDeadline);
                assertEq(r.pausedBaseline, handler.ghostBaseline(id));
            }
        }
    }

    /// PROPERTY: no claim succeeds while paused or after the pause-adjusted deadline; no reclaim succeeds before it.
    function invariant_PauseNeverLetsDeadlinesBeBypassed() public view {
        assertFalse(handler.claimSucceededAfterDeadline());
        assertFalse(handler.claimSucceededWhilePaused());
        assertFalse(handler.reclaimSucceededBeforeDeadline());
    }

    /// PROPERTY: claimsPaused() matches the independent capped model, paused() is true until unpause(),
    ///           and no pause ever began inside the 7-day cooldown (nor was a legal one refused).
    function invariant_PauseModelAndCooldown() public view {
        assertEq(vault.claimsPaused(), handler.ghostClaimsPaused());
        assertEq(vault.paused(), handler.ghostPaused());
        assertFalse(handler.pauseCooldownViolated());
        // a pause can never keep claims closed longer than 30 days
        if (vault.paused() && block.timestamp >= handler.ghostPausedSince() + 30 days) {
            assertFalse(vault.claimsPaused());
        }
    }

    /// PROPERTY: reserved funds are never withdrawable, however pauses, lapses and cooldowns interleave.
    function invariant_ReservedFundsNeverWithdrawable() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.totalOwed());
        assertFalse(handler.overdrawSucceeded());
    }
}
