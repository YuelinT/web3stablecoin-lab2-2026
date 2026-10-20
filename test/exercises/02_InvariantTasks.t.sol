// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {SimpleStablecoin} from "../../src/SimpleStablecoin.sol";
import {Vault} from "../../src/Vault.sol";

/// @title Ex6 — invariant testing
/// @notice Every test so far set up a situation and then checked the result. Invariant
///         testing flips that around: let the machine call operations randomly and
///         repeatedly, then ask "no matter how it thrashes, does this property still
///         hold?"
///
///         That is what a stablecoin should be tested like — you will never guess the
///         order an attacker does things in.
/// @dev How it works: Foundry picks functions from the handler at random, picks random
///      arguments, and calls them N times in a row; after each round it runs every
///      invariant_* function. The first failed assertion is a counterexample.
contract VaultHandler is Test {
    MockUSDC internal usdc;
    SimpleStablecoin internal stable;
    Vault internal vault;

    address[3] public users;

    /// @dev Bookkeeping: proves the fuzzer really reached the handler instead of idling
    uint256 public ghost_deposits;
    uint256 public ghost_redeems;

    constructor(MockUSDC usdc_, SimpleStablecoin stable_, Vault vault_) {
        usdc = usdc_;
        stable = stable_;
        vault = vault_;

        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");
        for (uint256 i; i < users.length; ++i) {
            usdc.faucet(users[i], 1_000_000e6);
        }
    }

    /// @dev Given to you — this is the standard shape of "pick a random argument and keep it
    ///      inside a valid range"
    function deposit(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = usdc.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        ghost_deposits++;
    }

    /// Ex6.1 — randomized redemption action
    /// @dev Zero-balance users are skipped and amounts are bounded to available sUSD so the
    ///      fuzzer explores successful state transitions. Unlike deposit(), redeem() needs no
    ///      allowance because the Vault burns the user's sUSD through its MINTER_ROLE.
    function redeem(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 stableBalance = stable.balanceOf(user);

        // Skip impossible actions so the fuzzer explores valid state transitions, not reverts.
        if (stableBalance == 0) {
            return;
        }

        // Bounding preserves randomness while ensuring every attempted redemption can succeed.
        amount = bound(amount, 1, stableBalance);

        vm.prank(user);
        vault.redeem(amount);

        // Increment only after success so the ghost value counts real state transitions.
        ghost_redeems++;
    }
}

contract InvariantTasksTest is Test {
    MockUSDC internal usdc;
    SimpleStablecoin internal stable;
    Vault internal vault;
    VaultHandler internal handler;

    address internal admin = address(this);

    function setUp() public {
        usdc = new MockUSDC();
        stable = new SimpleStablecoin(admin);
        vault = new Vault(usdc, stable);
        stable.grantRole(stable.MINTER_ROLE(), address(vault));

        handler = new VaultHandler(usdc, stable, vault);

        // Let the fuzzer call only the handler's deposit / redeem, not its other functions
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Ex6.2 — the main invariant: collateral is never less than the supply
    /// @dev The safety property uses >= rather than equality because excess collateral is
    ///      safe while any collateral shortfall leaves part of the supply unbacked. Foundry
    ///      reports the randomized call sequence if this property is ever violated.
    function invariant_CollateralBacksSupply() public view {
        assertGe(
            vault.totalCollateral(),
            stable.totalSupply(),
            "collateral must always cover the stablecoin supply"
        );
    }

    /// Ex6.3 — the vault itself never holds sUSD
    /// @dev Think about why this has to hold: the vault only ever mints sUSD to users and
    ///      should keep none for itself. If this one breaks, what does that mean?
    function invariant_VaultHoldsNoStablecoin() public view {
        assertEq(stable.balanceOf(address(vault)), 0, "vault must never hold sUSD");
    }
}
