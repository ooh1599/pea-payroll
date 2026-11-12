// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PayrollVaultTestBase, MockUSDC} from "./PayrollVault.Base.t.sol";
import {PayrollVault} from "../PayrollVault.sol";

contract PayrollVaultCoreTest is PayrollVaultTestBase {
    // ---------------------------------------------------------------- deployment
    function test_Deploy_SetsState() public view {
        assertEq(address(vault.usdc()), address(usdc));
        assertEq(vault.owner(), owner);
        assertEq(vault.totalOwed(), 0);
        assertEq(vault.runCount(), 0);
        assertFalse(vault.paused());
    }

    function test_Deploy_RevertsOnZeroToken() public {
        vm.expectRevert(PayrollVault.ZeroAddress.selector);
        new PayrollVault(address(0), owner);
    }

    function test_Deploy_RevertsOnEoaToken() public {
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidToken.selector, alice));
        new PayrollVault(alice, owner);
    }

    function test_Deploy_RevertsOnWrongDecimals() public {
        MockUSDC t18 = new MockUSDC(18);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidDecimals.selector, uint8(18)));
        new PayrollVault(address(t18), owner);
    }

    function test_Deploy_RevertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new PayrollVault(address(usdc), address(0));
    }

    // ---------------------------------------------------------------- happy path
    function test_HappyPath_CreateAddFundOpenClaim() public {
        uint256 id = _draftThree(SAP1, 0);
        assertEq(id, 1);
        assertEq(vault.runCount(), 1);
        assertTrue(vault.sapRunIdUsed(SAP1));

        PayrollVault.Run memory r = vault.getRun(id);
        assertEq(r.sapRunId, SAP1);
        assertEq(r.label, "March payroll");
        assertEq(r.totalAllocated, TOTAL3);
        assertEq(r.entryCount, 3);
        assertEq(r.expectedEntryCount, 3);
        assertEq(r.expectedTotal, TOTAL3);
        assertEq(uint8(r.status), uint8(PayrollVault.Status.Draft));
        assertEq(vault.getEntry(id, bob).amount, B);
        // Draft allocations are not reserved
        assertEq(vault.totalOwed(), 0);

        _fund(TOTAL3);
        assertEq(usdc.balanceOf(address(vault)), TOTAL3);
        _open(id);
        assertEq(vault.totalOwed(), TOTAL3);
        assertEq(uint8(vault.getRun(id).status), uint8(PayrollVault.Status.Open));
        assertEq(vault.claimable(id, alice), A);

        vm.prank(alice);
        vault.claim(id);
        assertEq(usdc.balanceOf(alice), A);
        assertEq(vault.totalOwed(), TOTAL3 - A);
        assertEq(vault.getRun(id).totalClaimed, A);
        assertTrue(vault.getEntry(id, alice).claimed);
        assertEq(vault.claimable(id, alice), 0);
        assertEq(vault.unclaimedOf(id), B + C);
    }

    function test_HappyPath_ClaimManyAggregates() public {
        uint256 id1 = _openThree(SAP1, 0);
        uint256 id2 = _draftThree(SAP2, 0);
        _fund(TOTAL3);
        _open(id2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;
        vm.prank(bob);
        vault.claimMany(ids);
        assertEq(usdc.balanceOf(bob), 2 * B);
        assertEq(vault.totalOwed(), 2 * TOTAL3 - 2 * B);
        assertTrue(vault.getEntry(id1, bob).claimed);
        assertTrue(vault.getEntry(id2, bob).claimed);
    }

    function test_ClaimMany_EmptyIsNoop() public {
        _openThree(SAP1, 0);
        uint256[] memory ids = new uint256[](0);
        vm.prank(alice);
        vault.claimMany(ids);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.totalOwed(), TOTAL3);
    }

    function test_ClaimMany_AtMaxClaimsBoundaryRejectsAbove() public {
        uint256[] memory ids = new uint256[](51);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.BatchTooLarge.selector, 51, 50));
        vault.claimMany(ids);
    }

    function test_ClaimMany_DuplicateRunRevertsAtomically() public {
        uint256 id = _openThree(SAP1, 0);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.EntryAlreadyClaimed.selector, id, alice));
        vault.claimMany(ids);
        assertEq(usdc.balanceOf(alice), 0);
        assertFalse(vault.getEntry(id, alice).claimed);
    }

    function test_ClaimMany_OneBadRunRevertsWholeBatch() public {
        uint256 id1 = _openThree(SAP1, 0);
        uint256 id2 = _draftThree(SAP2, 0); // still Draft
        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id2, PayrollVault.Status.Draft)
        );
        vault.claimMany(ids);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_AddEntries_Max200Succeeds() public {
        uint256 id = _create(SAP1, 0, 200, 200e6);
        address[] memory e = new address[](200);
        uint256[] memory a = new uint256[](200);
        bytes32[] memory r = new bytes32[](200);
        for (uint256 i; i < 200; ++i) {
            e[i] = address(uint160(0x1000 + i));
            a[i] = 1e6;
        }
        vm.prank(owner);
        vault.addEntries(id, e, a, r);
        assertEq(vault.getRun(id).entryCount, 200);
        assertEq(vault.getRun(id).totalAllocated, 200e6);
    }

    // ---------------------------------------------------------------- events
    function test_Event_PayrunCreated() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit PayrollVault.PayrunCreated(1, SAP1, "March payroll", 0, 3, TOTAL3);
        _create(SAP1, 0, 3, TOTAL3);
    }

    function test_Event_EntryAdded() public {
        uint256 id = _create(SAP1, 0, 3, TOTAL3);
        vm.expectEmit(true, true, false, true, address(vault));
        emit PayrollVault.EntryAdded(id, alice, A, keccak256("a"));
        _addThree(id);
    }

    function test_Event_FundedAndOpened() public {
        uint256 id = _draftThree(SAP1, 0);
        usdc.mint(owner, TOTAL3);
        vm.startPrank(owner);
        usdc.approve(address(vault), TOTAL3);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PayrollVault.Funded(owner, TOTAL3);
        vault.fund(TOTAL3);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PayrollVault.PayrunOpened(id, TOTAL3);
        vault.openPayrun(id);
        vm.stopPrank();
    }

    function test_Event_Claimed() public {
        uint256 id = _openThree(SAP1, 0);
        vm.expectEmit(true, true, false, true, address(vault));
        emit PayrollVault.Claimed(id, carol, C);
        vm.prank(carol);
        vault.claim(id);
    }

    function test_Event_PayrunCancelled() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.expectEmit(true, false, false, false, address(vault));
        emit PayrollVault.PayrunCancelled(id);
        vm.prank(owner);
        vault.cancelPayrun(id);
        assertEq(uint8(vault.getRun(id).status), uint8(PayrollVault.Status.Cancelled));
    }

    // ---------------------------------------------------------------- createPayrun reverts
    function test_Create_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.createPayrun(SAP1, "x", 0, 1, 1);
    }

    function test_Create_DuplicateSapRunId() public {
        _create(SAP1, 0, 1, 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.DuplicateSapRunId.selector, SAP1));
        vault.createPayrun(SAP1, "x", 0, 1, 1);
    }

    function test_Create_DuplicateSapRunIdEvenAfterCancel() public {
        uint256 id = _create(SAP1, 0, 1, 1);
        vm.prank(owner);
        vault.cancelPayrun(id);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.DuplicateSapRunId.selector, SAP1));
        vault.createPayrun(SAP1, "x", 0, 1, 1);
    }

    function test_Create_PastOrCurrentDeadlineReverts() public {
        vm.warp(1000);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidDeadline.selector, uint64(999)));
        vault.createPayrun(SAP1, "x", 999, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidDeadline.selector, uint64(1000)));
        vault.createPayrun(SAP1, "x", 1000, 1, 1);
        vault.createPayrun(SAP1, "x", 1001, 1, 1); // strictly future is fine
        vm.stopPrank();
    }

    function test_Create_EmptyControlTotals() public {
        vm.startPrank(owner);
        vm.expectRevert(PayrollVault.EmptyControlTotals.selector);
        vault.createPayrun(SAP1, "x", 0, 0, 1);
        vm.expectRevert(PayrollVault.EmptyControlTotals.selector);
        vault.createPayrun(SAP1, "x", 0, 1, 0);
        vm.stopPrank();
    }

    function test_Create_TotalOverUint128Reverts() public {
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.AllocationOverflow.selector, 0, 0, tooBig));
        vault.createPayrun(SAP1, "x", 0, 1, tooBig);

        // exactly uint128 max is accepted
        vm.prank(owner);
        vault.createPayrun(SAP1, "x", 0, 1, type(uint128).max);
    }

    function test_Create_LabelTooLong() public {
        bytes memory ok = new bytes(128);
        bytes memory bad = new bytes(129);
        for (uint256 i; i < 129; ++i) {
            if (i < 128) ok[i] = "a";
            bad[i] = "a";
        }
        vm.startPrank(owner);
        vault.createPayrun(SAP1, string(ok), 0, 1, 1); // exactly 128 bytes OK
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.LabelTooLong.selector, 129, 128));
        vault.createPayrun(SAP2, string(bad), 0, 1, 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- addEntries reverts
    function test_Add_OnlyOwner() public {
        uint256 id = _create(SAP1, 0, 1, 1);
        address[] memory e = new address[](0);
        uint256[] memory a = new uint256[](0);
        bytes32[] memory r = new bytes32[](0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.addEntries(id, e, a, r);
    }

    function test_Add_UnknownRun() public {
        address[] memory e = new address[](0);
        uint256[] memory a = new uint256[](0);
        bytes32[] memory r = new bytes32[](0);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 0));
        vault.addEntries(0, e, a, r);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 5));
        vault.addEntries(5, e, a, r);
        vm.stopPrank();
    }

    function test_Add_NotDraftReverts() public {
        uint256 id = _openThree(SAP1, 0);
        address[] memory e = new address[](0);
        uint256[] memory a = new uint256[](0);
        bytes32[] memory r = new bytes32[](0);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, PayrollVault.Status.Open)
        );
        vault.addEntries(id, e, a, r);
    }

    function test_Add_ArrayLengthMismatch() public {
        uint256 id = _create(SAP1, 0, 3, TOTAL3);
        address[] memory e = new address[](2);
        uint256[] memory a = new uint256[](1);
        bytes32[] memory r = new bytes32[](2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ArrayLengthMismatch.selector, 2, 1, 2));
        vault.addEntries(id, e, a, r);

        // mismatch in the refs array alone is also reported with all three lengths
        a = new uint256[](2);
        r = new bytes32[](3);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ArrayLengthMismatch.selector, 2, 2, 3));
        vault.addEntries(id, e, a, r);
    }

    function test_Add_BatchTooLarge() public {
        uint256 id = _create(SAP1, 0, 300, 300e6);
        address[] memory e = new address[](201);
        uint256[] memory a = new uint256[](201);
        bytes32[] memory r = new bytes32[](201);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.BatchTooLarge.selector, 201, 200));
        vault.addEntries(id, e, a, r);
    }

    function test_Add_ZeroAddressAndZeroAmountAndDuplicate() public {
        uint256 id = _create(SAP1, 0, 3, TOTAL3);
        address[] memory e = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes32[] memory r = new bytes32[](1);
        a[0] = A;
        vm.prank(owner);
        vm.expectRevert(PayrollVault.ZeroAddress.selector);
        vault.addEntries(id, e, a, r);

        e[0] = alice;
        a[0] = 0;
        vm.prank(owner);
        vm.expectRevert(PayrollVault.ZeroAmount.selector);
        vault.addEntries(id, e, a, r);

        _add(id, alice, A);
        a[0] = A;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.DuplicateEntry.selector, id, alice));
        vault.addEntries(id, e, a, r);
    }

    function test_Add_AllocationOverflow() public {
        uint256 id = _create(SAP1, 0, 3, TOTAL3);
        address[] memory e = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes32[] memory r = new bytes32[](1);
        e[0] = alice;
        a[0] = uint256(type(uint128).max) + 1;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.AllocationOverflow.selector, id, 0, uint256(type(uint128).max) + 1)
        );
        vault.addEntries(id, e, a, r);
    }

    function test_Add_AllocationOverflowReportsCurrentTotal() public {
        uint256 max = type(uint128).max;
        uint256 id = _create(SAP1, 0, 2, max);
        _add(id, alice, max - 5);
        address[] memory e = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes32[] memory r = new bytes32[](1);
        e[0] = bob;
        a[0] = 6;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.AllocationOverflow.selector, id, max - 5, 6));
        vault.addEntries(id, e, a, r);
        // exactly the remaining headroom is fine
        a[0] = 5;
        vm.prank(owner);
        vault.addEntries(id, e, a, r);
        assertEq(vault.getRun(id).totalAllocated, max);
    }

    function test_Add_ExceedsControlTotalAmount() public {
        uint256 id = _create(SAP1, 0, 3, TOTAL3);
        _add(id, alice, A);
        address[] memory e = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes32[] memory r = new bytes32[](1);
        e[0] = bob;
        a[0] = TOTAL3 - A + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ExceedsControlTotals.selector, id));
        vault.addEntries(id, e, a, r);
    }

    function test_Add_ExceedsControlTotalCount() public {
        uint256 id = _create(SAP1, 0, 1, TOTAL3);
        _add(id, alice, A);
        address[] memory e = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes32[] memory r = new bytes32[](1);
        e[0] = bob;
        a[0] = 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ExceedsControlTotals.selector, id));
        vault.addEntries(id, e, a, r);
    }

    function test_Add_RevokedDraftEntryDoesNotRestoreCapacity() public {
        uint256 id = _create(SAP1, 0, 1, A);
        _add(id, alice, A);
        vm.prank(owner);
        vault.revokeEntry(id, alice);
        address[] memory e = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes32[] memory r = new bytes32[](1);
        e[0] = bob;
        a[0] = 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ExceedsControlTotals.selector, id));
        vault.addEntries(id, e, a, r);
    }

    // ---------------------------------------------------------------- openPayrun reverts
    function test_Open_OnlyOwner() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.openPayrun(id);
    }

    function test_Open_UnknownRun() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 1));
        vault.openPayrun(1);
    }

    function test_Open_EmptyPayrun() public {
        uint256 id = _create(SAP1, 0, 1, 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.EmptyPayrun.selector, id));
        vault.openPayrun(id);
    }

    function test_Open_ControlTotalCountMismatch() public {
        uint256 id = _create(SAP1, 0, 3, TOTAL3);
        _add(id, alice, A);
        _add(id, bob, B);
        _add(id, carol, C);
        // matches -> opens; build a mismatching one in a second run
        uint256 id2 = _create(SAP2, 0, 3, TOTAL3);
        _add(id2, alice, A);
        _add(id2, bob, B);
        _fund(TOTAL3);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.ControlTotalMismatch.selector, id2, 3, 2, TOTAL3, A + B)
        );
        vault.openPayrun(id2);
    }

    function test_Open_ControlTotalAmountMismatch() public {
        uint256 id = _create(SAP1, 0, 2, 300e6);
        _add(id, alice, A);
        _add(id, bob, A);
        _fund(1000e6);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.ControlTotalMismatch.selector, id, 2, 2, 300e6, 200e6)
        );
        vault.openPayrun(id);
    }

    function test_Open_InsufficientFunding() public {
        uint256 id = _draftThree(SAP1, 0);
        _fund(TOTAL3 - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientFunding.selector, TOTAL3, TOTAL3 - 1));
        vault.openPayrun(id);
    }

    function test_Open_SecondRunNeedsFundingOnTopOfFirst() public {
        _openThree(SAP1, 0); // consumes the entire balance
        uint256 id2 = _draftThree(SAP2, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientFunding.selector, 2 * TOTAL3, TOTAL3));
        vault.openPayrun(id2);
    }

    function test_Open_DeadlinePassedReverts() public {
        uint256 id = _draftThree(SAP1, uint64(block.timestamp + 100));
        _fund(TOTAL3);
        vm.warp(block.timestamp + 101);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ClaimDeadlinePassed.selector, id));
        vault.openPayrun(id);
    }

    function test_Open_TwiceReverts() public {
        uint256 id = _openThree(SAP1, 0);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, PayrollVault.Status.Open)
        );
        vault.openPayrun(id);
    }

    // ---------------------------------------------------------------- cancel
    function test_Cancel_OnlyOwnerAndOnlyDraft() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.cancelPayrun(id);

        uint256 id2 = _create(SAP2, 0, 1, 1);
        _add(id2, alice, 1);
        _fund(1);
        _open(id2);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id2, PayrollVault.Status.Open)
        );
        vault.cancelPayrun(id2);
    }

    function test_Cancel_CancelledRunIsDeadEverywhere() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.startPrank(owner);
        vault.cancelPayrun(id);
        PayrollVault.Status cancelled = PayrollVault.Status.Cancelled;
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, cancelled));
        vault.cancelPayrun(id);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, cancelled));
        vault.openPayrun(id);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, cancelled));
        vault.revokeEntry(id, alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, id, cancelled));
        vault.reclaimExpired(id);
        vm.stopPrank();
        assertEq(vault.claimable(id, alice), 0);
    }

    // ---------------------------------------------------------------- claim reverts
    function test_Claim_Reverts() public {
        uint256 id = _openThree(SAP1, 0);
        uint256 draft = _draftThree(SAP2, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.MissingEntry.selector, id, stranger));
        vault.claim(id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 99));
        vault.claim(99);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollVault.InvalidRunStatus.selector, draft, PayrollVault.Status.Draft)
        );
        vault.claim(draft);

        vm.prank(alice);
        vault.claim(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.EntryAlreadyClaimed.selector, id, alice));
        vault.claim(id);
    }

    function test_Claim_RevokedEntryReverts() public {
        uint256 id = _draftThree(SAP1, 0);
        vm.prank(owner);
        vault.revokeEntry(id, alice); // revocation is Draft-only
        _fund(B + C);
        _open(id);
        assertEq(vault.totalOwed(), B + C);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.EntryAlreadyRevoked.selector, id, alice));
        vault.claim(id);
        assertEq(vault.claimable(id, alice), 0);
    }

    // ---------------------------------------------------------------- fund / views
    function test_Fund_ZeroAmountReverts() public {
        vm.expectRevert(PayrollVault.ZeroAmount.selector);
        vault.fund(0);
    }

    function test_Fund_AnyoneCanFund() public {
        usdc.mint(stranger, 5e6);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 5e6);
        vault.fund(5e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 5e6);
    }

    function test_DirectTransferCountsAsFunding() public {
        uint256 id = _draftThree(SAP1, 0);
        usdc.mint(address(vault), TOTAL3);
        _open(id);
        assertEq(vault.totalOwed(), TOTAL3);
    }

    function test_Views_UnknownRun() public {
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 1));
        vault.getRun(1);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 1));
        vault.getEntry(1, alice);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.UnknownRun.selector, 0));
        vault.unclaimedOf(0);
        assertEq(vault.claimable(0, alice), 0);
        assertEq(vault.claimable(7, alice), 0);
    }
}
