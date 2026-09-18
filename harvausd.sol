// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.7.0
pragma solidity ^0.8.27;

/*
    ================================================================
                         HAURVA PROTOCOL
                             HAUSD
    ================================================================

    DESCRIPTION
    -----------
    HAUSD is a BNB-backed USD stablecoin.

    The contract uses the Chainlink BNB/USD price feed to determine
    how much BNB is required to mint a given amount of HAUSD.

    Example:

        If BNB = $600

        1 BNB can back approximately:

            600 HAUSD

        because:

            1 HAUSD = $1

    COLLATERAL MODEL
    ----------------
    Users deposit BNB into this contract.

    The contract mints HAUSD against that BNB collateral.

    When a user redeems HAUSD:

        HAUSD is burned
        BNB collateral is released

    Therefore, the contract itself acts as the BNB vault.

    MINTING FEE
    -----------
    Every mint charges a 0.05% fee in BNB.

    IMPORTANT:
    The fee is charged ON TOP of the required collateral.

    For example, if 1 BNB is required as collateral:

        collateral = 1 BNB
        fee        = 0.0005 BNB
        total      = 1.0005 BNB

    This prevents the minting fee from making the vault
    undercollateralized.

    DECIMALS
    --------
    HAUSD uses 6 decimals.

        1 HAUSD = 1,000,000 units

    BNB itself uses 18 decimals.

    Chainlink BNB/USD feeds normally use 8 decimals.

    The contract performs the necessary conversion between:

        BNB:      18 decimals
        HAUSD:     6 decimals
        USD feed:  8 decimals

    ORACLE
    ------
    Chainlink BNB/USD is hardcoded according to the network.

        BSC Mainnet:
        0x0567F2323251f0AAb15c8DfB1967E4e8A7D42aeE

        BSC Testnet:
        0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526

    The contract automatically chooses the correct oracle based
    on block.chainid.

    ADMIN
    -----
    The deployer supplies initialOwner.

    The owner can:

        - withdraw accumulated minting fees
        - pause the protocol
        - unpause the protocol
        - transfer ownership

    The owner CANNOT arbitrarily mint HAUSD.

    HAUSD can only be minted through the collateralized mint()
    function.

    SAFETY
    ------
    The contract:

        - rejects stale oracle data
        - rejects zero/negative oracle prices
        - prevents zero-value mints
        - prevents zero-value redemptions
        - refunds accidental excess BNB
        - uses ReentrancyGuard for BNB transfers
        - allows emergency pause
        - does not allow arbitrary owner minting

    IMPORTANT ECONOMIC NOTE
    -----------------------
    This contract creates a BNB-backed dollar token.

    It does NOT by itself guarantee that HAUSD trades for exactly
    $1 on external exchanges.

    The oracle guarantees that PRIMARY MINT and REDEEM calculations
    use the current BNB/USD reference price.

    External market price can still temporarily differ from $1.

    ================================================================
*/


/*
    ----------------------------------------------------------------
    Chainlink AggregatorV3Interface
    ----------------------------------------------------------------

    We define the small portion of the Chainlink interface that
    this contract actually needs.

    latestRoundData() returns the latest oracle price.
*/
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}


/*
    ----------------------------------------------------------------
    Minimal ERC20 interface dependencies
    ----------------------------------------------------------------
*/

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";


/*
    ================================================================
                         HAURVA PROTOCOL
    ================================================================
*/
contract HaurvaProtocol is
    ERC20,
    ERC20Burnable,
    Ownable,
    ERC20Permit,
    ReentrancyGuard,
    Pausable
{
    /*
        ============================================================
                            CONSTANTS
        ============================================================
    */

    /*
        HAUSD uses 6 decimals.

        Therefore:

            1 HAUSD = 1,000,000 internal units
    */
    uint8 private constant HAUSD_DECIMALS = 6;

    /*
        Minting fee:

            0.05%

        Expressed in basis points:

            1%   = 100 basis points
            0.05% = 5 basis points
    */
    uint256 public constant MINT_FEE_BPS = 5;

    /*
        Basis-point denominator.

            10000 = 100%
    */
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /*
        USD target.

        One HAUSD represents exactly $1 for the purposes of the
        mint/redeem mechanism.
    */
    uint256 private constant USD_PRICE = 1e6;


    /*
        ============================================================
                        CHAINLINK ORACLES
        ============================================================
    */

    /*
        BSC Mainnet Chain ID:

            56
    */
    uint256 private constant BSC_MAINNET_CHAIN_ID = 56;

    /*
        BSC Testnet Chain ID:

            97
    */
    uint256 private constant BSC_TESTNET_CHAIN_ID = 97;

    /*
        Chainlink BNB/USD price feed on BSC Mainnet.

        Feed decimals: 8

        Example:

            $600 BNB

        is represented approximately as:

            60000000000
    */
    address private constant MAINNET_BNB_USD =
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    /*
        Chainlink BNB/USD price feed on BSC Testnet.

        Feed decimals: normally 8.

        This is the oracle used when deploying to BSC Testnet.
    */
    address private constant TESTNET_BNB_USD =
        0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526;


    /*
        ============================================================
                            STATE VARIABLES
        ============================================================
    */

    /*
        Chainlink BNB/USD oracle selected during construction.

        It is immutable because the oracle should not silently change
        after deployment.
    */
    AggregatorV3Interface public immutable bnbUsdFeed;

    /*
        Maximum acceptable age of a Chainlink price.

        If Chainlink has not updated the feed for more than this
        amount of time, mint/redeem operations are rejected.

        1 hour is deliberately conservative for this example.

        For a production stablecoin, this value should be selected
        based on the actual feed heartbeat and risk model.
    */
    uint256 public constant MAX_ORACLE_DELAY = 1 hours;

    /*
        Total BNB collateral currently held by the protocol.

        This is kept as an explicit accounting variable rather than
        relying exclusively on address(this).balance.

        The difference can contain accumulated mint fees.
    */
    uint256 public totalCollateral;


    /*
        ============================================================
                              EVENTS
        ============================================================
    */

    /*
        Emitted whenever HAUSD is minted.
    */
    event HAUSDMinted(
        address indexed user,
        uint256 hausdAmount,
        uint256 collateralBNB,
        uint256 feeBNB,
        uint256 bnbUsdPrice
    );

    /*
        Emitted whenever HAUSD is redeemed.
    */
    event HAUSDRedeemed(
        address indexed user,
        uint256 hausdAmount,
        uint256 collateralBNB,
        uint256 bnbUsdPrice
    );

    /*
        Emitted when accumulated protocol fees are withdrawn.
    */
    event FeesWithdrawn(
        address indexed recipient,
        uint256 amount
    );


    /*
        ============================================================
                            CONSTRUCTOR
        ============================================================
    */

    /*
        initialOwner:
            Address that will control administrative functions.

        On deployment, pass your own wallet address here.

        Example:

            0xYourWalletAddress
    */
    constructor(address initialOwner)
        ERC20("Haurva Protocol", "HAUSD")
        Ownable(initialOwner)
        ERC20Permit("Haurva Protocol")
    {
        /*
            Automatically select the correct Chainlink oracle.

            This makes the SAME source code usable on:

                BSC Testnet
                BSC Mainnet
        */
        if (block.chainid == BSC_MAINNET_CHAIN_ID) {
            bnbUsdFeed = AggregatorV3Interface(MAINNET_BNB_USD);
        } else if (block.chainid == BSC_TESTNET_CHAIN_ID) {
            bnbUsdFeed = AggregatorV3Interface(TESTNET_BNB_USD);
        } else {
            /*
                Prevent deployment on an unexpected network.

                This is intentional because using the wrong oracle
                on another chain could create catastrophic pricing
                problems.
            */
            revert("Unsupported BSC network");
        }
    }


    /*
        ============================================================
                          ERC20 DECIMALS
        ============================================================
    */

    /*
        HAUSD deliberately uses 6 decimals.

        Therefore:

            1 HAUSD
                =
            1,000,000 internal units
    */
    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return HAUSD_DECIMALS;
    }


    /*
        ============================================================
                       ORACLE PRICE FUNCTION
        ============================================================
    */

    /*
        Returns the current BNB/USD price.

        Chainlink's BNB/USD feed uses its own decimal precision.
        We normalize the result to 8 decimals.

        Example:

            BNB = $600

        returned value:

            60,000,000,000

        because:

            600 * 1e8
    */
    function getBNBPrice()
        public
        view
        returns (uint256 price)
    {
        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,
            
        ) = bnbUsdFeed.latestRoundData();

        /*
            The oracle must return a positive price.
        */
        require(answer > 0, "Invalid oracle price");

        /*
            Prevent the contract from using stale oracle data.

            This protects users if the oracle stops updating.
        */
        require(
            updatedAt > 0 &&
            block.timestamp - updatedAt <= MAX_ORACLE_DELAY,
            "Stale oracle price"
        );

        /*
            Chainlink BNB/USD is expected to use 8 decimals.

            We explicitly normalize in case the feed configuration
            differs in the future.
        */
        uint8 feedDecimals = bnbUsdFeed.decimals();

        uint256 rawPrice = uint256(answer);

        if (feedDecimals == 8) {
            price = rawPrice;
        } else if (feedDecimals < 8) {
            price = rawPrice * (10 ** (8 - feedDecimals));
        } else {
            price = rawPrice / (10 ** (feedDecimals - 8));
        }
    }


    /*
        ============================================================
                     CALCULATE BNB FOR HAUSD
        ============================================================
    */

    /*
        Converts HAUSD amount into the required BNB collateral.

        Inputs:

            hausdAmount:
                6-decimal HAUSD amount.

        Example:

            600 HAUSD

        internally:

            600,000,000

        If BNB = $600:

            required BNB = 1 BNB

        Mathematical relationship:

            HAUSD USD value
                =
            BNB amount * BNB/USD price
    */
    function hausdToBNB(uint256 hausdAmount)
        public
        view
        returns (uint256)
    {
        require(hausdAmount > 0, "Amount is zero");

        uint256 bnbPrice = getBNBPrice();

        /*
            HAUSD has 6 decimals.
            BNB has 18 decimals.
            Oracle has 8 decimals.

            Formula:

                BNB wei =
                    HAUSD units * 1e20 / BNB/USD price

            Example:

                600,000,000 * 1e20
                ------------------
                  60,000,000,000

                = 1e18 wei

                = 1 BNB
        */
        return (hausdAmount * 1e20) / bnbPrice;
    }


    /*
        ============================================================
                     CALCULATE HAUSD FOR BNB
        ============================================================
    */

    /*
        Converts BNB collateral into HAUSD.

        This is useful for displaying how much HAUSD a particular
        BNB deposit would generate.

        Example:

            1 BNB
            BNB = $600

            => approximately 600 HAUSD
    */
    function bnbToHAUSD(uint256 bnbAmount)
        public
        view
        returns (uint256)
    {
        require(bnbAmount > 0, "Amount is zero");

        uint256 bnbPrice = getBNBPrice();

        /*
            Formula:

                HAUSD units =
                    BNB wei * BNB/USD price / 1e20
        */
        return (bnbAmount * bnbPrice) / 1e20;
    }


    /*
        ============================================================
                            MINT FUNCTION
        ============================================================
    */

    /*
        Mint HAUSD by depositing BNB collateral.

        The user specifies exactly how many HAUSD they want.

        Example:

            User wants:

                100 HAUSD

            If BNB = $600:

                collateral = 0.166666666... BNB

            Mint fee:

                collateral * 0.05%

            User therefore sends:

                collateral + fee

        IMPORTANT:

        The mint fee is NOT removed from collateral.

        The collateral remains entirely in the vault, while the
        fee becomes protocol revenue.

        Any excess BNB accidentally sent is refunded.
    */
    function mint(uint256 hausdAmount)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(hausdAmount > 0, "Amount is zero");

        /*
            Calculate how much BNB is required to fully back the
            requested HAUSD amount.
        */
        uint256 collateralBNB = hausdToBNB(hausdAmount);

        require(collateralBNB > 0, "Collateral too small");

        /*
            Calculate the 0.05% minting fee.

            fee = collateral * 5 / 10000
        */
        uint256 feeBNB =
            (collateralBNB * MINT_FEE_BPS) /
            BPS_DENOMINATOR;

        /*
            Total BNB required from the user.
        */
        uint256 requiredBNB = collateralBNB + feeBNB;

        require(
            msg.value >= requiredBNB,
            "Insufficient BNB"
        );

        /*
            Increase recorded collateral.

            Only the collateral portion is considered backing.

            The fee remains outside totalCollateral.
        */
        totalCollateral += collateralBNB;

        /*
            Mint the requested HAUSD.

            There is intentionally no public arbitrary mint function.

            HAUSD enters circulation only against BNB collateral.
        */
        _mint(msg.sender, hausdAmount);

        /*
            Refund accidental excess BNB.

            Example:

                Required = 1.0005 BNB
                Sent     = 1.1 BNB

            Refund:

                0.0995 BNB
        */
        uint256 excessBNB = msg.value - requiredBNB;

        if (excessBNB > 0) {
            (bool success, ) = payable(msg.sender).call{
                value: excessBNB
            }("");

            require(success, "Refund failed");
        }

        /*
            Emit an event for frontends, indexers and analytics.
        */
        emit HAUSDMinted(
            msg.sender,
            hausdAmount,
            collateralBNB,
            feeBNB,
            getBNBPrice()
        );
    }


    /*
        ============================================================
                          REDEEM FUNCTION
        ============================================================
    */

    /*
        Redeem HAUSD for BNB.

        Example:

            User owns:

                600 HAUSD

            BNB = $600

            Redemption:

                600 HAUSD
                    ->
                1 BNB

        The HAUSD is burned first.

        Then the corresponding amount of BNB is returned.

        No redemption fee is currently charged.
    */
    function redeem(uint256 hausdAmount)
        external
        nonReentrant
        whenNotPaused
    {
        require(hausdAmount > 0, "Amount is zero");

        /*
            User must own the HAUSD they are attempting to redeem.
        */
        require(
            balanceOf(msg.sender) >= hausdAmount,
            "Insufficient HAUSD"
        );

        /*
            Calculate the BNB value represented by the HAUSD.
        */
        uint256 collateralBNB = hausdToBNB(hausdAmount);

        require(
            collateralBNB > 0,
            "Redemption too small"
        );

        /*
            Make sure the vault has enough recorded collateral.
        */
        require(
            totalCollateral >= collateralBNB,
            "Insufficient collateral"
        );

        /*
            Also check the actual contract balance.

            This is an additional safety check against accounting
            inconsistencies.
        */
        require(
            address(this).balance >= collateralBNB,
            "Insufficient vault balance"
        );

        /*
            Burn the HAUSD before transferring BNB.

            This follows the checks-effects-interactions pattern
            and prevents the same HAUSD from being redeemed twice.
        */
        _burn(msg.sender, hausdAmount);

        /*
            Reduce recorded collateral.
        */
        totalCollateral -= collateralBNB;

        /*
            Transfer the corresponding BNB back to the user.
        */
        (bool success, ) = payable(msg.sender).call{
            value: collateralBNB
        }("");

        require(success, "BNB transfer failed");

        /*
            Emit redemption event.
        */
        emit HAUSDRedeemed(
            msg.sender,
            hausdAmount,
            collateralBNB,
            getBNBPrice()
        );
    }


    /*
        ============================================================
                       PROTOCOL INFORMATION
        ============================================================
    */

    /*
        Returns the amount of BNB currently recorded as backing HAUSD.
    */
    function collateralBalance()
        external
        view
        returns (uint256)
    {
        return totalCollateral;
    }


    /*
        Returns the BNB currently held by the contract.

        This can be slightly higher than totalCollateral because
        accumulated mint fees are also held by the contract.
    */
    function vaultBalance()
        external
        view
        returns (uint256)
    {
        return address(this).balance;
    }


    /*
        Returns accumulated protocol fees.

        This represents:

            actual BNB balance
                -
            recorded collateral
    */
    function accumulatedFees()
        public
        view
        returns (uint256)
    {
        uint256 balance = address(this).balance;

        if (balance <= totalCollateral) {
            return 0;
        }

        return balance - totalCollateral;
    }


    /*
        ============================================================
                        WITHDRAW PROTOCOL FEES
        ============================================================
    */

    /*
        Withdraw accumulated minting fees.

        ONLY the owner can call this function.

        Critically, the owner cannot withdraw the collateral
        represented by outstanding HAUSD.

        Only:

            address(this).balance - totalCollateral

        can be withdrawn.
    */
    function withdrawFees(uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(amount > 0, "Amount is zero");

        /*
            The owner can never withdraw collateral.
        */
        require(
            amount <= accumulatedFees(),
            "Exceeds available fees"
        );

        (bool success, ) = payable(owner()).call{
            value: amount
        }("");

        require(success, "Fee withdrawal failed");

        emit FeesWithdrawn(owner(), amount);
    }


    /*
        ============================================================
                              PAUSING
        ============================================================
    */

    /*
        Emergency pause.

        When paused:

            mint()
            redeem()

        are disabled.

        Existing HAUSD balances are not destroyed.
        ERC20 transfers continue to work.
    */
    function pause()
        external
        onlyOwner
    {
        _pause();
    }


    /*
        Remove emergency pause.
    */
    function unpause()
        external
        onlyOwner
    {
        _unpause();
    }


    /*
        ============================================================
                         RECEIVE / FALLBACK
        ============================================================
    */

    /*
        Direct BNB transfers are intentionally rejected.

        Users should use:

            mint()

        instead.

        This prevents BNB from entering the vault without
        corresponding HAUSD accounting.
    */
    receive() external payable {
        revert("Use mint()");
    }

    /*
        Reject unknown function calls carrying BNB.
    */
    fallback() external payable {
        revert("Invalid function");
    }
}