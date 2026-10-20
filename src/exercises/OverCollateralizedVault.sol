// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SimpleStablecoin} from "../SimpleStablecoin.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title Over-collateralized vault (Ex5)
/// @notice Unlike the 1:1 loop in Vault.sol, $1 of collateral deposited here mints at most
///         0.667 sUSD (a 150% collateral ratio). Once the collateral ratio falls below
///         120%, anyone can take that collateral at a discount by paying sUSD — that is
///         liquidation, the core mechanism behind MakerDAO.
///
///         Three decimal scales must be told apart:
///           collateral  18 decimals (like WETH)
///           stable       6 decimals (like USDC)
///           priceFeed    8 decimals (like Chainlink ETH/USD)
contract OverCollateralizedVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateral;
    SimpleStablecoin public immutable stable;
    IPriceFeed public immutable priceFeed;

    uint256 public constant RATIO_PRECISION = 100;
    uint256 public constant MIN_COLLATERAL_RATIO = 150; // 150% is the floor for minting
    uint256 public constant LIQUIDATION_RATIO = 120; // below 120% you can be liquidated
    uint256 public constant LIQUIDATION_BONUS = 10; // the liquidator takes an extra 10%

    /// @dev Collateral the user has deposited, 18 decimals
    mapping(address => uint256) public collateralOf;
    /// @dev Stablecoin the user owes, 6 decimals
    mapping(address => uint256) public debtOf;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralRedeemed(address indexed user, uint256 amount);
    event StableMinted(address indexed user, uint256 amount);
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    error ZeroAddress();
    error ZeroAmount();
    error Undercollateralized();
    error NotLiquidatable();
    error InsufficientCollateral();

    constructor(IERC20 collateral_, SimpleStablecoin stable_, IPriceFeed priceFeed_) {
        if (
            address(collateral_) == address(0) || address(stable_) == address(0)
                || address(priceFeed_) == address(0)
        ) {
            revert ZeroAddress();
        }
        collateral = collateral_;
        stable = stable_;
        priceFeed = priceFeed_;
    }

    // ==================================================================
    // Given to you — no decimal conversion involved, do not touch
    // ==================================================================

    /// @notice What one unit of collateral is worth in USD, 8 decimals
    /// @dev Production code would also check whether updatedAt is stale and whether
    ///      answer <= 0 — the oracle is an attack surface of its own
    function collateralPrice() public view returns (uint256) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        if (answer <= 0) revert ZeroAmount();
        return uint256(answer);
    }

    /// @notice The user's collateral, converted into sUSD smallest units (6 decimals)
    function collateralValueOf(address user) public view returns (uint256) {
        return collateralValue(collateralOf[user]);
    }

    /// @notice Current collateral ratio; 150 means 150%. Returns the maximum when there is
    ///         no debt at all
    function collateralRatio(address user) public view returns (uint256) {
        if (debtOf[user] == 0) return type(uint256).max;
        return collateralValueOf(user) * RATIO_PRECISION / debtOf[user];
    }

    /// @notice Deposit collateral
    function depositCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
    }

    /// @notice Repay debt: burn sUSD and reduce what is owed
    function repay(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (amount > debtOf[msg.sender]) revert InsufficientCollateral();
        stable.burn(msg.sender, amount);
        debtOf[msg.sender] -= amount;
    }

    // ==================================================================
    // Ex5.1 — decimal conversion
    // ==================================================================

    /// @notice Convert `amount` units of collateral (18 decimals) into sUSD smallest units
    ///         (6 decimals)
    /// @dev Multiplying 18-decimal collateral by an 8-decimal price produces 26 decimals.
    ///      Dividing by 1e20 normalizes the result to the stablecoin's 6-decimal base units.
    function collateralValue(uint256 amount) public view returns (uint256) {
        return amount * collateralPrice() / 1e20;
    }

    // ==================================================================
    // Ex5.2 — minting has to leave enough collateral behind
    // ==================================================================

    /// @notice Mint `amount` of sUSD, but the collateral ratio afterwards must not fall
    ///         below MIN_COLLATERAL_RATIO
    /// @dev Record the debt first and check second, so collateralRatio() evaluates the
    ///      post-mint position. A revert rolls the tentative debt update back atomically.
    function mintStable(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // Check the position that would exist after minting, not its healthier pre-mint state.
        debtOf[msg.sender] += amount;

        if (collateralRatio(msg.sender) < MIN_COLLATERAL_RATIO) {
            revert Undercollateralized();
        }

        // Interact with the token only after all local accounting checks have passed.
        stable.mint(msg.sender, amount);

        emit StableMinted(msg.sender, amount);
    }

    // ==================================================================
    // Ex5.3 — withdrawing collateral must not leave the position unhealthy either
    // ==================================================================

    /// @notice Withdraw `amount` units of collateral; the ratio afterwards must not fall
    ///         below MIN_COLLATERAL_RATIO
    function redeemCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        if (amount > collateralOf[msg.sender]) {
            revert InsufficientCollateral();
        }

        // Test the ratio after the proposed withdrawal; a revert restores this subtraction.
        collateralOf[msg.sender] -= amount;

        if (collateralRatio(msg.sender) < MIN_COLLATERAL_RATIO) {
            revert Undercollateralized();
        }

        // Transfer last so external token code cannot run before accounting is finalized.
        collateral.safeTransfer(msg.sender, amount);

        emit CollateralRedeemed(msg.sender, amount);
    }

    // ==================================================================
    // Ex5.4 — liquidation
    // ==================================================================

    /// @notice Once the ratio falls below LIQUIDATION_RATIO, anyone may burn that user's
    ///         entire sUSD debt and seize collateral worth
    ///         "debt value × (100% + LIQUIDATION_BONUS)".
    /// @dev The collateral may not be enough to pay the bonus. Capping seizure at the
    ///      available balance avoids an underflow and makes any remaining shortfall explicit
    ///      as bad debt rather than pretending the liquidator can seize nonexistent assets.
    function liquidate(address user) external {
        if (collateralRatio(user) >= LIQUIDATION_RATIO) {
            revert NotLiquidatable();
        }

        uint256 userDebt = debtOf[user];
        uint256 availableCollateral = collateralOf[user];

        // The bonus compensates third parties for restoring an unhealthy position.
        uint256 debtValueWithBonus =
            userDebt * (RATIO_PRECISION + LIQUIDATION_BONUS) / RATIO_PRECISION;

        // Reverse collateralValue(): convert 6-decimal USD value back to 18-decimal collateral.
        uint256 collateralToSeize = debtValueWithBonus * 1e20 / collateralPrice();

        if (collateralToSeize > availableCollateral) {
            collateralToSeize = availableCollateral;
        }

        // Finalize internal accounting before calling either external token contract.
        debtOf[user] = 0;
        collateralOf[user] = availableCollateral - collateralToSeize;

        stable.burn(msg.sender, userDebt);
        collateral.safeTransfer(msg.sender, collateralToSeize);

        emit Liquidated(user, msg.sender, userDebt, collateralToSeize);
    }
}
