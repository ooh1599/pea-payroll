// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {PayrollVaultTestBase} from "./PayrollVault.Base.t.sol";
import {PayrollVault} from "../PayrollVault.sol";

contract PayrollVaultLifecycleTest is PayrollVaultTestBase {
    uint64 internal deadline;

    function setUp() public override {
        super.setUp();
        deadline = uint64(block.timestamp + 1000);
    }

    // ---------------------------------------------------------------- expiry
    function test_Expiry_ClaimAtExactDeadlineWorks() public {
        uint256 id = _openThree(SAP1, deadline);
        vm.warp(deadline);
        assertEq(vault.claimable(id, alice), A);
        vm.prank(alice);
        vault.claim(id);
        assertEq(usdc.balanceOf(alice), A);
    }

    function test_Expiry_ClaimAfterDeadlineReverts() public {
        uint256 id = _openThree(SAP1, deadline);
        vm.warp(uint256(deadline) + 1);
        assertEq(vault.claimable(id, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ClaimDeadlinePassed.selector, id));
        vault.claim(id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ClaimDeadlinePassed.selector, id));
        vault.claimMany(ids);
    }

    function test_Expiry_ReclaimNotExpiredAtExactDeadline() public {
        uint256 id = _openThree(SAP1, deadline);
        vm.warp(deadline);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.RunNotExpired.selector, id));
        vault.reclaimExpired(id);
    }

    function test_Expiry_ReclaimNoDeadlineRunNeverExpires() public {
        uint256 id = _openThree(SAP1, 0);
        vm.warp(block.timestamp + 365 days * 50);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.RunNotExpired.selector, id));
        vault.reclaimExpired(id);
        vm.prank(alice);
        vault.claim(id); // still claimable
    }

    function test_Expiry_ReclaimReleasesOnlyUnclaimed() public {
        uint256 id = _draftThree(SAP1, deadline);
        vm.prank(owner);
        vault.revokeEntry(id, bob); // Draft-only revoke
        _fund(A + C);
        _open(id);
        vm.prank(alice);
        vault.claim(id);
        // reserved now: carol only
        assertEq(vault.totalOwed(), C);

        vm.warp(uint256(deadline) + 1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PayrollVault.ExpiredReclaimed(id, C);
        vm.prank(owner);
        vault.reclaimExpired(id);

        assertEq(vault.totalOwed(), 0);
        assertTrue(vault.getRun(id).expiredReleased);
        // reclaim does not move tokens
        assertEq(usdc.balanceOf(address(vault)), C);
    }

    function test_Expiry_ReclaimRevertPaths() public {
        uint256 id = _openThree(SAP1, deadline);
        uint256 draft = _draftThree(SAP2, deadline);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.reclaimExpired(id);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, draft, PayrollVault.Status.Draft)
        );
        vault.reclaimExpired(draft);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 9));
        vault.reclaimExpired(9);

        vm.warp(uint256(deadline) + 1);
        vm.startPrank(owner);
        vault.reclaimExpired(id);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ExpiryAlreadyReleased.selector, id));
        vault.reclaimExpired(id);
        vm.stopPrank();
    }

    function test_Expiry_ClaimAfterReleaseReverts() public {
        uint256 id = _openThree(SAP1, deadline);
        vm.warp(uint256(deadline) + 1);
        vm.prank(owner);
        vault.reclaimExpired(id);
        assertEq(vault.claimable(id, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ClaimDeadlinePassed.selector, id));
        vault.claim(id);
    }

    function test_Expiry_ReleasedFundsBecomeWithdrawable() public {
        uint256 id = _openThree(SAP1, deadline);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientSurplus.selector, 1, 0));
        vault.withdrawSurplus(owner, 1);

        vm.warp(uint256(deadline) + 1);
        vm.prank(owner);
        vault.reclaimExpired(id);
        vm.prank(owner);
        vault.withdrawSurplus(owner, TOTAL3);
        assertEq(usdc.balanceOf(owner), TOTAL3);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // ---------------------------------------------------------------- revoke (Draft-only)
    function test_Revoke_DraftDoesNotTouchTotalOwedAndOpenReservesNet() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.expectEmit(true, true, false, true, address(vault));
        emit PayrollVault.EntryRevoked(id, bob, B);
        vm.prank(owner);
        vault.revokeEntry(id, bob);

        assertEq(vault.totalOwed(), 0);
        PayrollVault.Run memory r = vault.getRun(id);
        assertEq(r.totalRevoked, B);
        assertEq(r.totalAllocated, TOTAL3); // gross stays
        assertEq(vault.unclaimedOf(id), A + C);
        assertTrue(vault.getEntry(id, bob).revoked);

        // control totals still match gross -> opens; only net is reserved
        _fund(A + C);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PayrollVault.PayrunOpened(id, A + C);
        _open(id);
        assertEq(vault.totalOwed(), A + C);
        assertEq(vault.claimable(id, bob), 0);
    }

    function test_Revoke_OpenRunReverts() public {
        uint256 id = _openThree(SAP1, 0);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, PayrollVault.Status.Open)
        );
        vault.revokeEntry(id, alice);

        // nothing changed: the entry is still claimable and fully reserved
        assertFalse(vault.getEntry(id, alice).revoked);
        assertEq(vault.getRun(id).totalRevoked, 0);
        assertEq(vault.totalOwed(), TOTAL3);
        assertEq(vault.claimable(id, alice), A);
        vm.prank(alice);
        vault.claim(id);
        assertEq(usdc.balanceOf(alice), A);
    }

    function test_Revoke_OpenRunRevertsEvenForMissingOrClaimedEntry() public {
        uint256 id = _openThree(SAP1, 0);
        vm.prank(alice);
        vault.claim(id);
        PayrollVault.Status open = PayrollVault.Status.Open;
        // the status check precedes entry checks
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, open));
        vault.revokeEntry(id, alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, open));
        vault.revokeEntry(id, stranger);
        vm.stopPrank();
    }

    function test_Revoke_ExpiredReleasedOpenRunStillReverts() public {
        uint256 id = _openThree(SAP1, deadline);
        vm.warp(uint256(deadline) + 1);
        vm.startPrank(owner);
        vault.reclaimExpired(id);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, PayrollVault.Status.Open)
        );
        vault.revokeEntry(id, alice);
        vm.stopPrank();
        assertEq(vault.totalOwed(), 0);
        assertEq(vault.getRun(id).totalRevoked, 0);
    }

    function test_Revoke_RevokedDraftFundsAreWithdrawableSurplusAfterOpen() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.prank(owner);
        vault.revokeEntry(id, carol);
        _fund(TOTAL3);
        _open(id);
        assertEq(vault.totalOwed(), A + B);
        vm.prank(owner);
        vault.withdrawSurplus(owner, C);
        assertEq(usdc.balanceOf(owner), C);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientSurplus.selector, 1, 0));
        vault.withdrawSurplus(owner, 1);
    }

    function test_Revoke_RevertPaths() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.revokeEntry(id, alice);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 5));
        vault.revokeEntry(5, alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.MissingEntry.selector, id, stranger));
        vault.revokeEntry(id, stranger);
        vault.revokeEntry(id, alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.EntryAlreadyRevoked.selector, id, alice));
        vault.revokeEntry(id, alice);
        vm.stopPrank();
    }

    function test_Revoke_CancelledRunReverts() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.startPrank(owner);
        vault.cancelPayrun(id);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, PayrollVault.Status.Cancelled)
        );
        vault.revokeEntry(id, alice);
        vm.stopPrank();
    }

    function test_Revoke_DraftEntryCannotBeReAdded() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.prank(owner);
        vault.revokeEntry(id, alice);
        address[] memory e = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes32[] memory r = new bytes32[](1);
        e[0] = alice;
        a[0] = 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.DuplicateEntry.selector, id, alice));
        vault.addEntries(id, e, a, r);
    }

    function test_Revoke_DraftRevokeThenPartialClaimsKeepsAccountingConsistent() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.prank(owner);
        vault.revokeEntry(id, bob);
        _fund(A + C);
        _open(id);
        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.totalOwed(), C);
        assertEq(vault.unclaimedOf(id), C);
        assertGe(usdc.balanceOf(address(vault)), vault.totalOwed());
    }

    // ---------------------------------------------------------------- withdrawSurplus
    function test_Surplus_LimitsAndEvent() public {
        _openThree(SAP1, 0);
        usdc.mint(address(vault), 50e6); // donation = surplus

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientSurplus.selector, 50e6 + 1, 50e6));
        vault.withdrawSurplus(owner, 50e6 + 1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit PayrollVault.SurplusWithdrawn(stranger, 50e6);
        vault.withdrawSurplus(stranger, 50e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(stranger), 50e6);
        assertEq(usdc.balanceOf(address(vault)), TOTAL3);
        assertEq(vault.totalOwed(), TOTAL3);
    }

    function test_Surplus_ZeroAmountAllowedAndZeroAddressReverts() public {
        vm.startPrank(owner);
        vault.withdrawSurplus(owner, 0);
        vm.expectRevert(PayrollVault.ZeroAddress.selector);
        vault.withdrawSurplus(address(0), 0);
        vm.stopPrank();
    }

    function test_Surplus_OnlyOwner() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.withdrawSurplus(stranger, 1e6);
    }

    function test_Surplus_CannotTouchDraftlessReservedFundsButCanTouchDraftFunds() public {
        // Draft allocations are not reserved: owner may withdraw funds earmarked for a Draft run.
        uint256 id = _draftThree(SAP1, 0);
        _fund(TOTAL3);
        vm.prank(owner);
        vault.withdrawSurplus(owner, TOTAL3);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InsufficientFunding.selector, TOTAL3, 0)
        );
        vault.openPayrun(id);
    }

    function test_Surplus_ClaimsStillPaidAfterMaxWithdrawal() public {
        uint256 id = _openThree(SAP1, 0);
        usdc.mint(address(vault), 7e6);
        vm.prank(owner);
        vault.withdrawSurplus(owner, 7e6);
        vm.prank(alice);
        vault.claim(id);
        vm.prank(bob);
        vault.claim(id);
        vm.prank(carol);
        vault.claim(id);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalOwed(), 0);
    }

    // ---------------------------------------------------------------- pause
    function test_Pause_BlocksClaimsOnly() public {
        uint256 id = _openThree(SAP1, 0);
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());
        assertEq(vault.claimable(id, alice), 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claim(id);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claimMany(ids);
        vm.stopPrank();

        // funding and admin still work
        _fund(1e6);
        uint256 draft = _draftThree(SAP2, 0);
        vm.prank(owner);
        vault.revokeEntry(draft, carol);

        vm.prank(owner);
        vault.unpause();
        assertEq(vault.claimable(id, alice), A);
        vm.prank(alice);
        vault.claim(id);
        assertEq(usdc.balanceOf(alice), A);
    }

    function test_Pause_AccessAndStateErrors() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.pause();

        vm.startPrank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vault.unpause();
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pause();
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.unpause();
    }

    // ---------------------------------------------------------------- ownership
    function test_Ownership_TwoStepTransfer() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit Ownable2Step.OwnershipTransferStarted(owner, alice);
        vm.prank(owner);
        vault.transferOwnership(alice);
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), alice);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.acceptOwnership();

        vm.expectEmit(true, true, false, false, address(vault));
        emit Ownable.OwnershipTransferred(owner, alice);
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
        assertEq(vault.pendingOwner(), address(0));

        // old owner lost rights, new owner has them
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.pause();
        vm.prank(alice);
        vault.pause();
    }

    function test_Ownership_RenounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert(PayrollVault.RenounceOwnershipDisabled.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), owner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.renounceOwnership();
    }

    // ---------------------------------------------------------------- duplicate sapRunId
    function test_DuplicateSapRunId_AcrossLifecycleStates() public {
        uint256 id = _openThree(SAP1, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.DuplicateSapRunId.selector, SAP1));
        vault.createPayrun(SAP1, "again", 0, 1, 1);
        assertEq(id, 1);
        assertEq(vault.runCount(), 1);
        // a different id still works
        assertEq(_create(SAP2, 0, 1, 1), 2);
    }
}
