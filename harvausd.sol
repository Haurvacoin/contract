// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.7.0
pragma solidity ^0.8.27;

/*
    ========================================================================
                           HAURVA PROTOCOL
                               HAUSD
    ========================================================================

    HAUSD is a BNB-backed USD stablecoin.

    TARGET:
        1 HAUSD = 1 USD

    COLLATERAL:
        BNB

    PRICE ORACLE:
        Chainlink BNB/USD

    HAUSD DECIMALS:
        6

    MINT FEE:
        0.05% in BNB

    ------------------------------------------------------------------------
    IMPORTANT DESIGN
    ------------------------------------------------------------------------

    Native BNB cannot be pulled directly from a user's wallet by a
    smart contract.

    Therefore, this contract uses a two-step system:

        STEP 1:
            User deposits BNB into the contract.

        STEP 2:
            User calls:

                mint(HAUSD amount)

            The contract automatically calculates how much of the user's
            deposited BNB is required.

    Example:

        BNB price = $600

        User deposits:
            1 BNB

        User calls:

            mint(100000000)

        This means:

            100 HAUSD

        The contract calculates:

            100 HAUSD = $100
            $100 / $600 = 0.166666... BNB

        Minting fee:

            0.166666... * 0.05%
            = 0.00008333... BNB

        Total deducted:

            approximately 0.16675 BNB

        User's remaining deposited balance:

            approximately 0.83325 BNB

    ------------------------------------------------------------------------
    REDEMPTION
    ------------------------------------------------------------------------

    When the user calls:

        redeem(HAUSD amount)

    the contract:

        1. Reads the current BNB/USD price.
        2. Calculates the BNB represented by the HAUSD.
        3. Burns the HAUSD.
        4. Returns the corresponding BNB.
        5. Reduces the user's deposited collateral balance.

    ------------------------------------------------------------------------
    IMPORTANT ECONOMIC NOTE
    ------------------------------------------------------------------------

    The Chainlink oracle determines the BNB/USD conversion.

    It does NOT force HAUSD to trade at exactly $1 on external exchanges.

    For example, HAUSD could theoretically trade at $0.98 or $1.02 on
    a DEX.

    The mint/redeem mechanism itself nevertheless treats:

        1 HAUSD = $1

    according to the oracle.

    ------------------------------------------------------------------------
*/


/*
    ========================================================================
                        CHAINLINK PRICE FEED INTERFACE
    ========================================================================
*/

interface AggregatorV3Interface {

    function decimals()
        external
        view
        returns (uint8);

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
    ========================================================================
                         OPENZEPPELIN IMPORTS
    ========================================================================
*/

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    ERC20Burnable
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {
    ERC20Permit
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    Pausable
} from "@openzeppelin/contracts/utils/Pausable.sol";


/*
    ========================================================================
                           HAURVA PROTOCOL
    ========================================================================
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
        ====================================================================
                              CONSTANTS
        ====================================================================
    */

    /*
        HAUSD uses 6 decimals.

        Therefore:

            1 HAUSD
                =
            1,000,000 internal units
    */
    uint8 private constant HAUSD_DECIMALS = 6;


    /*
        Minting fee = 0.05%.

        Basis points:

            10000 = 100%
            5     = 0.05%
    */
    uint256 public constant MINT_FEE_BPS = 5;


    /*
        Basis-point denominator.
    */
    uint256 private constant BPS_DENOMINATOR = 10_000;


    /*
        Maximum acceptable oracle age.

        If Chainlink has not updated for more than one hour,
        minting and redemption are stopped.

        This is a conservative test/prototype setting.
    */
    uint256 public constant MAX_ORACLE_DELAY = 1 hours;


    /*
        BSC Mainnet chain ID.
    */
    uint256 private constant BSC_MAINNET_CHAIN_ID = 56;


    /*
        BSC Testnet chain ID.
    */
    uint256 private constant BSC_TESTNET_CHAIN_ID = 97;


    /*
        Chainlink BNB/USD feed on BSC Mainnet.
    */
    address private constant MAINNET_BNB_USD =
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;


    /*
        Chainlink BNB/USD feed on BSC Testnet.
    */
    address private constant TESTNET_BNB_USD =
        0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526;


    /*
        ====================================================================
                             STATE VARIABLES
        ====================================================================
    */

    /*
        The Chainlink BNB/USD oracle selected automatically according
        to the network on which the contract is deployed.
    */
    AggregatorV3Interface public immutable bnbUsdFeed;


    /*
        User BNB balances.

        This records how much BNB each user has deposited into the
        protocol and has not yet been used as collateral for minted HAUSD.

        Example:

            user deposits 1 BNB

            depositedBNB[user]
                =
            1 BNB
    */
    mapping(address => uint256) public depositedBNB;


    /*
        Total BNB currently deposited by all users.

        This is accounting data and should correspond to the collateral
        held by the contract, excluding protocol fees.
    */
    uint256 public totalDepositedBNB;


    /*
        ====================================================================
                                  EVENTS
        ====================================================================
    */

    /*
        Emitted when a user deposits BNB.
    */
    event BNBDeposited(
        address indexed user,
        uint256 amount
    );


    /*
        Emitted when a user withdraws unused BNB.
    */
    event BNBWithdrawn(
        address indexed user,
        uint256 amount
    );


    /*
        Emitted when HAUSD is minted.
    */
    event HAUSDMinted(
        address indexed user,
        uint256 hausdAmount,
        uint256 collateralBNB,
        uint256 feeBNB,
        uint256 bnbUsdPrice
    );


    /*
        Emitted when HAUSD is redeemed.
    */
    event HAUSDRedeemed(
        address indexed user,
        uint256 hausdAmount,
        uint256 collateralBNB,
        uint256 bnbUsdPrice
    );


    /*
        Emitted when the owner withdraws protocol fees.
    */
    event FeesWithdrawn(
        address indexed owner,
        uint256 amount
    );


    /*
        ====================================================================
                               CONSTRUCTOR
        ====================================================================
    */

    /*
        initialOwner:
            Your administrative wallet.

        The constructor automatically selects the correct Chainlink
        oracle based on block.chainid.

        BSC Testnet:
            Chain ID 97

        BSC Mainnet:
            Chain ID 56
    */
    constructor(address initialOwner)
        ERC20("Haurva Protocol", "HAUSD")
        Ownable(initialOwner)
        ERC20Permit("Haurva Protocol")
    {

        /*
            Automatically select the correct BNB/USD oracle.
        */
        if (block.chainid == BSC_MAINNET_CHAIN_ID) {

            bnbUsdFeed =
                AggregatorV3Interface(MAINNET_BNB_USD);

        } else if (block.chainid == BSC_TESTNET_CHAIN_ID) {

            bnbUsdFeed =
                AggregatorV3Interface(TESTNET_BNB_USD);

        } else {

            /*
                Prevent deployment on an unsupported network.

                This protects against accidentally deploying the
                contract somewhere where these oracle addresses are
                meaningless.
            */
            revert("Unsupported BSC network");
        }
    }


    /*
        ====================================================================
                              ERC20 DECIMALS
        ====================================================================
    */

    /*
        HAUSD uses 6 decimals instead of the ERC20 default of 18.

        Therefore:

            1 HAUSD = 1,000,000 units
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
        ====================================================================
                           GET BNB/USD PRICE
        ====================================================================
    */

    /*
        Reads the current BNB/USD price from Chainlink.

        The returned value is normalized to 8 decimals.

        Example:

            BNB = $600

        returns approximately:

            60000000000

        because:

            $600 * 10^8
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
            Reject invalid oracle prices.
        */
        require(
            answer > 0,
            "Invalid oracle price"
        );


        /*
            Reject stale oracle data.

            If Chainlink has stopped updating, the protocol does not
            continue minting/redeeming using potentially dangerous
            outdated pricing.
        */
        require(
            updatedAt > 0 &&
            block.timestamp - updatedAt <= MAX_ORACLE_DELAY,
            "Stale oracle price"
        );


        /*
            Convert Chainlink's native decimal precision to 8 decimals.
        */
        uint8 feedDecimals = bnbUsdFeed.decimals();

        uint256 rawPrice = uint256(answer);


        if (feedDecimals == 8) {

            price = rawPrice;

        } else if (feedDecimals < 8) {

            price =
                rawPrice *
                (10 ** (8 - feedDecimals));

        } else {

            price =
                rawPrice /
                (10 ** (feedDecimals - 8));
        }
    }


    /*
        ====================================================================
                       CALCULATE BNB REQUIRED FOR HAUSD
        ====================================================================
    */

    /*
        Converts a HAUSD amount into its BNB value.

        HAUSD:
            6 decimals

        BNB:
            18 decimals

        Chainlink:
            8 decimals

        Example:

            BNB = $600

            100 HAUSD
                =
            $100

            $100 / $600
                =
            0.166666... BNB
    */
    function hausdToBNB(
        uint256 hausdAmount
    )
        public
        view
        returns (uint256)
    {
        require(
            hausdAmount > 0,
            "Amount is zero"
        );


        uint256 bnbPrice = getBNBPrice();


        /*
            Convert HAUSD's 6-decimal representation into BNB's
            18-decimal representation using the oracle's 8 decimals.
        */
        return
            (hausdAmount * 1e20) /
            bnbPrice;
    }


    /*
        ====================================================================
                     CALCULATE HAUSD FOR A BNB AMOUNT
        ====================================================================
    */

    /*
        Converts BNB into its equivalent HAUSD value.

        This function is useful for frontends and testing.

        Example:

            1 BNB
            BNB = $600

            => 600 HAUSD
    */
    function bnbToHAUSD(
        uint256 bnbAmount
    )
        public
        view
        returns (uint256)
    {
        require(
            bnbAmount > 0,
            "Amount is zero"
        );


        uint256 bnbPrice = getBNBPrice();


        /*
            Convert BNB's 18 decimals into HAUSD's 6 decimals.
        */
        return
            (bnbAmount * bnbPrice) /
            1e20;
    }


    /*
        ====================================================================
                              DEPOSIT BNB
        ====================================================================
    */

    /*
        Deposit BNB into the user's protocol balance.

        This is the ONLY function where the user needs to specify a
        payable BNB amount.

        After depositing BNB, the user can mint HAUSD without entering
        another BNB amount.

        Example:

            User sends:

                1 BNB

            depositedBNB[user]:

                1 BNB
    */
    function depositBNB()
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(
            msg.value > 0,
            "No BNB sent"
        );


        /*
            Increase the user's deposited balance.
        */
        depositedBNB[msg.sender] += msg.value;


        /*
            Increase global collateral accounting.
        */
        totalDepositedBNB += msg.value;


        emit BNBDeposited(
            msg.sender,
            msg.value
        );
    }


    /*
        ====================================================================
                         WITHDRAW UNUSED BNB
        ====================================================================
    */

    /*
        Allows a user to withdraw BNB that has NOT been used to back
        HAUSD.

        Example:

            User deposits:

                1 BNB

            User mints:

                100 HAUSD

            If 0.16675 BNB was consumed by the minting process,

            the user can withdraw approximately:

                0.83325 BNB

        The user cannot withdraw BNB that is already backing HAUSD.
    */
    function withdrawBNB(
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
    {
        require(
            amount > 0,
            "Amount is zero"
        );


        require(
            depositedBNB[msg.sender] >= amount,
            "Insufficient deposited BNB"
        );


        /*
            Reduce the user's balance before transferring BNB.

            This follows the checks-effects-interactions pattern.
        */
        depositedBNB[msg.sender] -= amount;


        totalDepositedBNB -= amount;


        /*
            Return BNB to the user.
        */
        (bool success, ) =
            payable(msg.sender).call{
                value: amount
            }("");


        require(
            success,
            "BNB transfer failed"
        );


        emit BNBWithdrawn(
            msg.sender,
            amount
        );
    }


    /*
        ====================================================================
                              MINT HAUSD
        ====================================================================
    */

    /*
        THIS IS NOW THE SIMPLE USER INTERFACE.

        The user specifies ONLY:

            hausdAmount

        There is NO payable BNB field.

        The required BNB is taken from the user's previously deposited
        BNB balance.

        Example:

            User has deposited:

                1 BNB

            User wants:

                100 HAUSD

            They simply call:

                mint(100000000)

        The contract automatically calculates:

            collateral BNB
            +
            0.05% minting fee

        and deducts that amount from depositedBNB[user].

        This is the cleanest possible native-BNB design while still
        allowing the user to specify the desired HAUSD amount.
    */
    function mint(
        uint256 hausdAmount
    )
        external
        nonReentrant
        whenNotPaused
    {
        require(
            hausdAmount > 0,
            "Amount is zero"
        );


        /*
            Calculate the BNB collateral required for the requested
            amount of HAUSD.
        */
        uint256 collateralBNB =
            hausdToBNB(hausdAmount);


        require(
            collateralBNB > 0,
            "Collateral too small"
        );


        /*
            Calculate the 0.05% minting fee.

            Example:

                1 BNB collateral

                fee =
                    1 * 5 / 10000

                    =
                    0.0005 BNB
        */
        uint256 feeBNB =
            (collateralBNB * MINT_FEE_BPS) /
            BPS_DENOMINATOR;


        /*
            Total amount deducted from the user's deposited BNB.
        */
        uint256 totalRequiredBNB =
            collateralBNB + feeBNB;


        /*
            Make sure the user has enough previously deposited BNB.
        */
        require(
            depositedBNB[msg.sender] >= totalRequiredBNB,
            "Insufficient deposited BNB"
        );


        /*
            Deduct the collateral and fee from the user's deposited
            balance.

            The collateral remains part of totalDepositedBNB because
            it backs the newly minted HAUSD.

            The fee is removed from totalDepositedBNB because it becomes
            protocol revenue.
        */
        depositedBNB[msg.sender] -= totalRequiredBNB;


        /*
            Only the actual collateral is counted as outstanding
            collateral.

            The fee becomes protocol revenue.
        */
        totalDepositedBNB -= feeBNB;


        /*
            Mint the requested HAUSD.

            There is NO owner-only arbitrary mint function.

            HAUSD can only enter circulation through collateralized minting.
        */
        _mint(
            msg.sender,
            hausdAmount
        );


        emit HAUSDMinted(
            msg.sender,
            hausdAmount,
            collateralBNB,
            feeBNB,
            getBNBPrice()
        );
    }


    /*
        ====================================================================
                             REDEEM HAUSD
        ====================================================================
    */

    /*
        Redeem HAUSD for BNB.

        User specifies ONLY:

            hausdAmount

        Example:

            User owns:

                100 HAUSD

            BNB = $600

            User calls:

                redeem(100000000)

            The contract calculates:

                100 HAUSD
                    =
                $100
                    =
                ~0.166666 BNB

            HAUSD is burned and the corresponding BNB is returned.
    */
    function redeem(
        uint256 hausdAmount
    )
        external
        nonReentrant
        whenNotPaused
    {
        require(
            hausdAmount > 0,
            "Amount is zero"
        );


        /*
            Make sure the user owns the HAUSD.
        */
        require(
            balanceOf(msg.sender) >= hausdAmount,
            "Insufficient HAUSD"
        );


        /*
            Calculate how much BNB the HAUSD represents at the
            current Chainlink BNB/USD price.
        */
        uint256 collateralBNB =
            hausdToBNB(hausdAmount);


        require(
            collateralBNB > 0,
            "Redemption too small"
        );


        /*
            Make sure the protocol has enough recorded collateral.
        */
        require(
            totalDepositedBNB >= collateralBNB,
            "Insufficient collateral"
        );


        /*
            Make sure the actual contract balance is sufficient.
        */
        require(
            address(this).balance >= collateralBNB,
            "Insufficient vault balance"
        );


        /*
            Burn HAUSD before transferring BNB.

            This prevents the same HAUSD from being redeemed twice.
        */
        _burn(
            msg.sender,
            hausdAmount
        );


        /*
            Remove the redeemed collateral from global accounting.
        */
        totalDepositedBNB -= collateralBNB;


        /*
            The redeemed BNB is transferred directly to the user.

            It is NOT necessary to add it back to depositedBNB because
            the user is receiving it directly into their wallet.
        */
        (bool success, ) =
            payable(msg.sender).call{
                value: collateralBNB
            }("");


        require(
            success,
            "BNB transfer failed"
        );


        emit HAUSDRedeemed(
            msg.sender,
            hausdAmount,
            collateralBNB,
            getBNBPrice()
        );
    }


    /*
        ====================================================================
                          VIEW USER INFORMATION
        ====================================================================
    */

    /*
        Returns how much BNB the user has deposited and not withdrawn.

        This is useful for Remix and frontends.
    */
    function userBNBBalance(
        address user
    )
        external
        view
        returns (uint256)
    {
        return depositedBNB[user];
    }


    /*
        Returns the actual BNB held by the contract.

        This includes:

            user collateral
            +
            protocol fees
    */
    function vaultBalance()
        external
        view
        returns (uint256)
    {
        return address(this).balance;
    }


    /*
        ====================================================================
                         PROTOCOL FEE ACCOUNTING
        ====================================================================
    */

    /*
        Returns the amount of BNB that can theoretically be withdrawn
        as protocol fees.

        Formula:

            actual vault balance
                -
            outstanding user collateral
    */
    function accumulatedFees()
        public
        view
        returns (uint256)
    {
        uint256 balance =
            address(this).balance;


        if (balance <= totalDepositedBNB) {
            return 0;
        }


        return
            balance - totalDepositedBNB;
    }


    /*
        ====================================================================
                         WITHDRAW PROTOCOL FEES
        ====================================================================
    */

    /*
        The owner can withdraw accumulated minting fees.

        The owner CANNOT withdraw BNB that is recorded as user
        collateral.

        This protects outstanding HAUSD backing.
    */
    function withdrawFees(
        uint256 amount
    )
        external
        onlyOwner
        nonReentrant
    {
        require(
            amount > 0,
            "Amount is zero"
        );


        require(
            amount <= accumulatedFees(),
            "Exceeds available fees"
        );


        /*
            Transfer only protocol revenue.
        */
        (bool success, ) =
            payable(owner()).call{
                value: amount
            }("");


        require(
            success,
            "Fee withdrawal failed"
        );


        emit FeesWithdrawn(
            owner(),
            amount
        );
    }


    /*
        ====================================================================
                                PAUSE
        ====================================================================
    */

    /*
        Emergency pause.

        While paused:

            depositBNB()
            withdrawBNB()
            mint()
            redeem()

        are disabled.

        ERC20 transfers continue to function.
    */
    function pause()
        external
        onlyOwner
    {
        _pause();
    }


    /*
        ====================================================================
                               UNPAUSE
        ====================================================================
    */

    /*
        Re-enable protocol operations.
    */
    function unpause()
        external
        onlyOwner
    {
        _unpause();
    }


    /*
        ====================================================================
                         DIRECT BNB TRANSFERS
        ====================================================================
    */

    /*
        Reject BNB sent directly to the contract.

        Users must use:

            depositBNB()

        so that the contract can correctly record their collateral.
    */
    receive()
        external
        payable
    {
        revert("Use depositBNB()");
    }


    /*
        Reject unknown calls that attempt to send BNB.
    */
    fallback()
        external
        payable
    {
        revert("Invalid function");
    }
}