// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PayrollVaultTestBase} from "./PayrollVault.Base.t.sol";
import {PayrollVault} from "../PayrollVault.sol";

/// @dev Shared helpers for the bounded-pause suites. No test functions here.
abstract contract PayrollVaultPauseBase is PayrollVaultTestBase {
    uint256 internal constant P = 30 days; // MAX_PAUSE
    uint256 internal constant W = 7 days; // PAUSE_COOLDOWN

    uint256 internal t0;

    function setUp() public virtual override {
        super.setUp();
        t0 = block.timestamp;
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

    function _claimMany(address who, uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(who);
        vault.claimMany(ids);
    }

    function _expectExpiredClaim(address who, uint256 id) internal {
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.ClaimDeadlinePassed.selector, id));
        vault.claim(id);
    }

    function _expectPausedClaim(address who, uint256 id) internal {
        vm.prank(who);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        vault.claim(id);
    }

    function _expectNotExpiredReclaim(uint256 id) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.RunNotExpired.selector, id));
        vault.reclaimExpired(id);
    }

    function _expectCooldown(uint256 availableAt) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.PauseCooldownActive.selector, availableAt));
        vault.pause();
    }

    /// @dev Owner cannot pull even 1 wei when everything held is reserved.
    function _expectNoSurplus() internal {
        assertEq(usdc.balanceOf(address(vault)), vault.totalOwed());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PayrollVault.InsufficientSurplus.selector, 1, 0));
        vault.withdrawSurplus(owner, 1);
    }
}
