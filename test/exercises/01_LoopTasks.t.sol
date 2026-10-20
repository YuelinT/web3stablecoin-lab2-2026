// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {SimpleStablecoin} from "../../src/SimpleStablecoin.sol";
import {Vault} from "../../src/Vault.sol";

/// @title Ex2 + Ex4 — hands-on tasks: turn red into green
/// @notice Tests exact supply accounting, decimal-unit mistakes, access control, pausing,
///         and the authority granted to the Vault through MINTER_ROLE.
contract LoopTasksTest is Test {
    MockUSDC internal usdc;
    SimpleStablecoin internal stable;
    Vault internal vault;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockUSDC();
        stable = new SimpleStablecoin(admin);
        vault = new Vault(usdc, stable);
        stable.grantRole(stable.MINTER_ROLE(), address(vault));
    }

    // ==================================================================
    // Ex2 · the decimals trap: a 6-decimal stablecoin meets 18-decimal intuition
    // ==================================================================

    /// @dev For any legitimate nonzero amount x, totalSupply() must grow by exactly x after
    ///      deposit(x). Alice is funded first so the test isolates supply accounting from
    ///      insufficient-balance failures.
    function test_Ex2_DepositIncreasesSupplyByExactly(uint96 raw) public {
        // Keep fuzz cases large enough to vary meaningfully without exploring impractical values.
        uint256 amount = uint256(raw) % 1_000_000e6;
        // Zero is rejected by the vault, so exclude it to exercise the successful deposit path.
        vm.assume(amount > 0);

        usdc.faucet(alice, amount);

        uint256 supplyBefore = stable.totalSupply();

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        uint256 supplyAfter = stable.totalSupply();

        assertEq(
            supplyAfter - supplyBefore,
            amount,
            "deposit must increase supply by exactly the deposited amount"
        );
    }

    /// @dev Run deposit with 1000e18 instead of 1000e6, see what happens, then assert what
    ///      you observed. MockUSDC has 6 decimals — 1000e18 is one billion USDC.
    ///      There is no expected answer here; the point is that you run it yourself and
    ///      read the numbers.
    function test_Ex2_DecimalsTrap() public {
        uint256 mistakenAmount = 1000e18;
        uint256 intendedAmount = 1000e6;

        usdc.faucet(alice, mistakenAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), mistakenAmount);
        vault.deposit(mistakenAmount);
        vm.stopPrank();

        // Raw-unit accounting still balances, which is why the semantic unit error is dangerous.
        assertEq(stable.balanceOf(alice), mistakenAmount);
        assertEq(stable.totalSupply(), mistakenAmount);
        assertEq(vault.totalCollateral(), mistakenAmount);

        assertEq(
            mistakenAmount / intendedAmount,
            1e12,
            "using 18-decimal notation makes the amount 1e12 times too large"
        );
    }

    // ==================================================================
    // Ex4 · permissions and pausing: where the guard is, who holds the key
    // ==================================================================

    /// @dev The attacker has no MINTER_ROLE, so calling mint directly must revert. Use
    ///      vm.expectRevert + abi.encodeWithSelector to pin down the exact error.
    function test_Ex4_Mint_RevertsForNonMinter() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                attacker,
                stable.MINTER_ROLE()
            )
        );

        vm.prank(attacker);
        stable.mint(attacker, 1e6);
    }

    /// @dev After pause(), an ordinary transfer must revert
    function test_Ex4_Pause_BlocksTransfers() public {
        uint256 amount = 100e6;

        // Seed Alice's balance first because pausing also blocks the mint performed by deposit().
        usdc.faucet(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        stable.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        stable.transfer(attacker, 1e6);
    }

    /// @dev What pause() freezes is _update, so redemption is frozen along with everything
    ///      else — why is that bad news in a real crisis?
    ///      (This is STUDENT-QUESTIONS.md B1 and B2.)
    function test_Ex4_Pause_BlocksRedeem() public {
        uint256 amount = 100e6;

        // Establish a redeemable position before activating the system-wide pause.
        usdc.faucet(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        stable.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        vault.redeem(amount);

        // A revert is atomic: neither Alice's balance nor the collateral reserve may change.
        assertEq(stable.balanceOf(alice), amount);
        assertEq(vault.totalCollateral(), amount);
    }

    /// @dev An attacker cannot burn someone else's balance
    function test_Ex4_AttackerCannotBurnOthersBalance() public {
        uint256 amount = 100e6;

        // Give Alice a real balance so the test isolates authorization from balance checks.
        usdc.faucet(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                attacker,
                stable.MINTER_ROLE()
            )
        );

        vm.prank(attacker);
        stable.burn(alice, amount);

        assertEq(stable.balanceOf(alice), amount, "Alice's balance must remain unchanged");
        assertEq(stable.totalSupply(), amount, "failed burn must not change total supply");
    }

    /// @dev ...but the vault can, because it holds MINTER_ROLE and burn() answers to that
    ///      same role. This test proves the backdoor exists; it does not justify it.
    function test_Ex4_VaultHoldsTheKey_CanBurnAnyonesBalance() public {
        uint256 amount = 100e6;

        usdc.faucet(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        assertTrue(
            stable.hasRole(stable.MINTER_ROLE(), address(vault)), "Vault must hold MINTER_ROLE"
        );

        // Call as the Vault directly to expose the role's power independently of redemption.
        vm.prank(address(vault));
        stable.burn(alice, amount);

        assertEq(stable.balanceOf(alice), 0, "Vault can burn Alice's balance");
        assertEq(stable.totalSupply(), 0, "burn must reduce total supply");
        assertEq(vault.totalCollateral(), amount, "burn does not return collateral to Alice");
    }
}
