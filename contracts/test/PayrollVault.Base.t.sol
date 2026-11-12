// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PayrollVault} from "../PayrollVault.sol";

/// @dev Simple mock token with configurable decimals (6 for USDC-like).
contract MockUSDC is ERC20 {
    uint8 private immutable _dec;

    constructor(uint8 dec_) ERC20("Mock USDC", "mUSDC") {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract PayrollVaultTestBase is Test {
    PayrollVault internal vault;
    MockUSDC internal usdc;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant A = 100e6;
    uint256 internal constant B = 200e6;
    uint256 internal constant C = 300e6;
    uint256 internal constant TOTAL3 = 600e6;

    bytes32 internal constant SAP1 = keccak256("SAP-1");
    bytes32 internal constant SAP2 = keccak256("SAP-2");
    bytes32 internal constant REF = keccak256("ref");

    function setUp() public virtual {
        usdc = new MockUSDC(6);
        vault = new PayrollVault(address(usdc), owner);
    }

    function _create(bytes32 sap, uint64 deadline, uint256 count, uint256 total) internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createPayrun(sap, "March payroll", deadline, count, total);
    }

    function _add(uint256 id, address emp, uint256 amt) internal {
        address[] memory e = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes32[] memory r = new bytes32[](1);
        e[0] = emp;
        a[0] = amt;
        r[0] = REF;
        vm.prank(owner);
        vault.addEntries(id, e, a, r);
    }

    function _addThree(uint256 id) internal {
        address[] memory e = new address[](3);
        uint256[] memory a = new uint256[](3);
        bytes32[] memory r = new bytes32[](3);
        e[0] = alice;
        e[1] = bob;
        e[2] = carol;
        a[0] = A;
        a[1] = B;
        a[2] = C;
        r[0] = keccak256("a");
        r[1] = keccak256("b");
        r[2] = keccak256("c");
        vm.prank(owner);
        vault.addEntries(id, e, a, r);
    }

    function _fund(uint256 amt) internal {
        usdc.mint(owner, amt);
        vm.startPrank(owner);
        usdc.approve(address(vault), amt);
        vault.fund(amt);
        vm.stopPrank();
    }

    function _open(uint256 id) internal {
        vm.prank(owner);
        vault.openPayrun(id);
    }

    /// @dev Creates a Draft run with alice/bob/carol (600 USDC) without funding or opening.
    function _draftThree(bytes32 sap, uint64 deadline) internal returns (uint256 id) {
        id = _create(sap, deadline, 3, TOTAL3);
        _addThree(id);
    }

    /// @dev Creates, loads, funds exactly 600 USDC and opens a three-employee run.
    function _openThree(bytes32 sap, uint64 deadline) internal returns (uint256 id) {
        id = _draftThree(sap, deadline);
        _fund(TOTAL3);
        _open(id);
    }
}
