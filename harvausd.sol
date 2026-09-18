// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.7.0
pragma solidity ^0.8.27;

/*
    ================================================================
                         HAURVA PROTOCOL
                              HAUSD
    ================================================================

    HAUSD is a BNB-backed, oracle-priced stablecoin.

    CORE IDEA
    ---------
    1. A user sends BNB/tBNB to mint().
    2. The contract reads the current BNB/USD price from Chainlink.
    3. The deposited BNB (minus the 0.05% minting fee) is valued in USD.
    4. The contract mints exactly that USD value in HAUSD.
    5. When redeeming, HAUSD is burned.
    6. The contract sends the corresponding amount of BNB back to
       the user using the current Chainlink BNB/USD price.

    DECIMALS
    --------
    HAUSD uses 6 decimals.

    FEES
    ----
    Mint fee:
        0.05% = 5 basis points

    The minting fee is immediately transferred to the contract owner.

    There is currently NO redemption fee.

    ORACLE
    ------
    Chainlink BNB/USD Price Feed.

    BSC Testnet:
        0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526

    BSC Mainnet:
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE

    Both feeds use 8 decimals.

    NETWORKS
    --------
    BSC Testnet:
        Chain ID 97

    BSC Mainnet:
        Chain ID 56

    The constructor automatically selects the correct oracle
    according to block.chainid.

    LOGO
    ----
    Project artwork:

    https://github.com/Haurvacoin/artwork/blob/main/haurvacoin.png?raw=true

    IMPORTANT
    ---------
    This contract does NOT force HAUSD to trade at exactly $1 on
    PancakeSwap or another external market.

    Minting and redemption are performed against the Chainlink
    BNB/USD oracle at approximately $1 per HAUSD.

    SECURITY
    --------
    - Oracle price must be positive.
    - Oracle data must not be stale.
    - HAUSD cannot be minted without BNB collateral.
    - BNB can only enter through mint().
    - Redemption burns HAUSD before sending BNB.
    - Native BNB transfers use a low-level call.
    - No unnecessary ReentrancyGuard is used to keep gas usage low.
*/

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    ERC20Burnable
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {
    ERC20Permit
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";


/*
    ================================================================
                       CHAINLINK ORACLE INTERFACE
    ================================================================
*/
interface IChainlinkAggregator {
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
    ================================================================
                         HAURVA PROTOCOL
    ================================================================
*/
contract HaurvaProtocol is ERC20, ERC20Burnable, Ownable, ERC20Permit {

    /*
        ------------------------------------------------------------
                           CONSTANTS
        ------------------------------------------------------------
    */

    // HAUSD uses 6 decimal places.
    uint8 private constant HAUSD_DECIMALS = 6;

    // Chainlink BNB/USD feeds use 8 decimal places.
    uint256 private constant ORACLE_DECIMALS = 8;

    // One BNB = 10^18 wei.
    uint256 private constant BNB_DECIMALS = 18;

    // One HAUSD = 10^6 units.
    uint256 private constant USD_SCALE = 1e6;

    // Minting fee = 0.05% = 5 basis points.
    uint256 public constant MINT_FEE_BPS = 5;

    // Basis-point denominator.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /*
        Chainlink BNB/USD price feeds.

        BSC Testnet:
        0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526

        BSC Mainnet:
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE
    */
    address private constant BSC_TESTNET_BNB_USD =
        0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526;

    address private constant BSC_MAINNET_BNB_USD =
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    /*
        Maximum acceptable age of oracle data.

        If the Chainlink price has not updated for more than one day,
        minting and redemption are stopped.
    */
    uint256 public constant MAX_ORACLE_DELAY = 1 days;


    /*
        ------------------------------------------------------------
                           STATE VARIABLES
        ------------------------------------------------------------
    */

    /*
        The Chainlink BNB/USD oracle selected automatically according
        to the network.
    */
    IChainlinkAggregator public immutable bnbUsdOracle;


    /*
        ------------------------------------------------------------
                              EVENTS
        ------------------------------------------------------------
    */

    event HAUSDMinted(
        address indexed user,
        uint256 bnbCollateral,
        uint256 fee,
        uint256 hausdMinted,
        uint256 bnbUsdPrice
    );

    event HAUSDRedeemed(
        address indexed user,
        uint256 hausdBurned,
        uint256 bnbReturned,
        uint256 bnbUsdPrice
    );


    /*
        ------------------------------------------------------------
                           CUSTOM ERRORS
        ------------------------------------------------------------
    */

    error UnsupportedNetwork();
    error NoBNBSent();
    error InvalidOraclePrice();
    error OraclePriceStale();
    error InvalidOracleAnswer();
    error ZeroHAUSDAmount();
    error InsufficientBNBReserve();
    error BNBSendFailed();
    error DirectBNBTransferDisabled();


    /*
        ------------------------------------------------------------
                           CONSTRUCTOR
        ------------------------------------------------------------
    */

    /*
        initialOwner:
            The wallet that will become the administrator/owner.

        This means the deployer does NOT have to be the admin wallet.

        In Remix, simply enter the desired admin wallet address when
        deploying the contract.
    */
    constructor(address initialOwner)
        ERC20("Haurva Protocol", "HAUSD")
        Ownable(initialOwner)
        ERC20Permit("Haurva Protocol")
    {
        /*
            BSC Testnet.
        */
        if (block.chainid == 97) {
            bnbUsdOracle =
                IChainlinkAggregator(BSC_TESTNET_BNB_USD);
        }

        /*
            BSC Mainnet.
        */
        else if (block.chainid == 56) {
            bnbUsdOracle =
                IChainlinkAggregator(BSC_MAINNET_BNB_USD);
        }

        /*
            Prevent accidental deployment on an unsupported network.
        */
        else {
            revert UnsupportedNetwork();
        }
    }


    /*
        ------------------------------------------------------------
                           ERC20 DECIMALS
        ------------------------------------------------------------
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
                            ORACLE FUNCTIONS
        ============================================================
    */

    function getBNBPrice()
        public
        view
        returns (uint256 price)
    {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = bnbUsdOracle.latestRoundData();

        /*
            Reject zero and negative prices.
        */
        if (answer <= 0) {
            revert InvalidOraclePrice();
        }

        /*
            Reject oracle responses without a timestamp.
        */
        if (updatedAt == 0) {
            revert InvalidOracleAnswer();
        }

        /*
            Reject incomplete oracle rounds.
        */
        if (answeredInRound < roundId) {
            revert InvalidOracleAnswer();
        }

        /*
            Reject stale prices.
        */
        if (block.timestamp - updatedAt > MAX_ORACLE_DELAY) {
            revert OraclePriceStale();
        }

        /*
            Confirm that the oracle has the expected 8 decimals.
        */
        if (bnbUsdOracle.decimals() != ORACLE_DECIMALS) {
            revert InvalidOracleAnswer();
        }

        price = uint256(answer);
    }


    /*
        ============================================================
                        PRICING CALCULATIONS
        ============================================================
    */

    /*
        Converts BNB wei into HAUSD's 6-decimal representation.

        Example:

            1 BNB
            BNB/USD = $600

            Result:
            600,000,000

            Which represents:
            600 HAUSD
    */
    function bnbToHAUSD(uint256 bnbAmount)
        public
        view
        returns (uint256)
    {
        uint256 price = getBNBPrice();

        return
            (bnbAmount * price)
            / 1e20;
    }


    /*
        Converts HAUSD's 6-decimal representation into BNB wei.

        Example:

            600 HAUSD
            BNB/USD = $600

            Result:
            1e18 wei

            Which represents:
            1 BNB
    */
    function hausdToBNB(uint256 hausdAmount)
        public
        view
        returns (uint256)
    {
        uint256 price = getBNBPrice();

        return
            (hausdAmount * 1e20)
            / price;
    }


    /*
        ============================================================
                         MINT QUOTATION
        ============================================================
    */

    /*
        Calculates the result of a mint without spending gas.

        totalBNB:
            Total amount of BNB the user intends to send.

        Returns:

            collateralBNB
                BNB retained as protocol collateral.

            feeBNB
                0.05% minting fee.

            hausdAmount
                HAUSD that will be minted.
    */
    function quoteMint(uint256 totalBNB)
        public
        view
        returns (
            uint256 collateralBNB,
            uint256 feeBNB,
            uint256 hausdAmount
        )
    {
        if (totalBNB == 0) {
            return (0, 0, 0);
        }

        /*
            Calculate 0.05% fee.
        */
        feeBNB =
            (totalBNB * MINT_FEE_BPS)
            / BPS_DENOMINATOR;

        /*
            Remaining BNB becomes collateral.
        */
        collateralBNB = totalBNB - feeBNB;

        /*
            Convert collateral into HAUSD.
        */
        hausdAmount = bnbToHAUSD(collateralBNB);
    }


    /*
        ============================================================
                              MINT
        ============================================================
    */

    /*
        Mints HAUSD by depositing native BNB.

        The user does NOT provide a HAUSD amount.

        The user simply calls:

            mint()

        and attaches BNB/tBNB as transaction VALUE.

        The contract automatically:

            1. Reads Chainlink BNB/USD.
            2. Calculates the 0.05% fee.
            3. Retains the remaining BNB as collateral.
            4. Converts the collateral value to USD.
            5. Mints the corresponding HAUSD.
            6. Sends the fee to the initialOwner/admin wallet.
    */
    function mint()
        external
        payable
    {
        if (msg.value == 0) {
            revert NoBNBSent();
        }

        /*
            Calculate the minting fee.
        */
        uint256 fee =
            (msg.value * MINT_FEE_BPS)
            / BPS_DENOMINATOR;

        /*
            Remaining BNB becomes collateral.
        */
        uint256 collateral =
            msg.value - fee;

        /*
            Convert collateral BNB into HAUSD.
        */
        uint256 hausdAmount =
            bnbToHAUSD(collateral);

        if (hausdAmount == 0) {
            revert ZeroHAUSDAmount();
        }

        uint256 price =
            getBNBPrice();

        /*
            Mint HAUSD before the external BNB transfer.
        */
        _mint(msg.sender, hausdAmount);

        /*
            Send the minting fee to the contract owner.

            The owner is the initialOwner supplied during deployment.
        */
        if (fee > 0) {
            (bool success, ) =
                payable(owner()).call{value: fee}("");

            if (!success) {
                revert BNBSendFailed();
            }
        }

        emit HAUSDMinted(
            msg.sender,
            collateral,
            fee,
            hausdAmount,
            price
        );
    }


    /*
        ============================================================
                            REDEEM
        ============================================================
    */

    /*
        Burns HAUSD and returns its BNB value.

        hausdAmount:
            Amount expressed using HAUSD's 6 decimals.

        Example:

            100 HAUSD

            becomes:

            100000000
    */
    function redeem(uint256 hausdAmount)
        external
    {
        if (hausdAmount == 0) {
            revert ZeroHAUSDAmount();
        }

        /*
            Calculate BNB equivalent using the current oracle price.
        */
        uint256 bnbAmount =
            hausdToBNB(hausdAmount);

        if (bnbAmount == 0) {
            revert ZeroHAUSDAmount();
        }

        /*
            Ensure enough BNB is available for redemption.
        */
        if (address(this).balance < bnbAmount) {
            revert InsufficientBNBReserve();
        }

        uint256 price =
            getBNBPrice();

        /*
            Burn the HAUSD before sending BNB.
        */
        _burn(msg.sender, hausdAmount);

        /*
            Return BNB to the redeemer.
        */
        (bool success, ) =
            payable(msg.sender).call{value: bnbAmount}("");

        if (!success) {
            revert BNBSendFailed();
        }

        emit HAUSDRedeemed(
            msg.sender,
            hausdAmount,
            bnbAmount,
            price
        );
    }


    /*
        ============================================================
                         PROTOCOL INFORMATION
        ============================================================
    */

    /*
        Returns the amount of BNB currently held as protocol reserve.
    */
    function bnbReserve()
        external
        view
        returns (uint256)
    {
        return address(this).balance;
    }


    /*
        Returns the total HAUSD supply in raw 6-decimal units.
    */
    function totalHAUSDSupply()
        external
        view
        returns (uint256)
    {
        return totalSupply();
    }


    /*
        ============================================================
                       DIRECT BNB TRANSFERS
        ============================================================
    */

    /*
        Ordinary direct BNB transfers are rejected.

        Users must use mint() so that the protocol can correctly
        calculate the fee, oracle value, and HAUSD amount.
    */
    receive()
        external
        payable
    {
        revert DirectBNBTransferDisabled();
    }

    fallback()
        external
        payable
    {
        revert DirectBNBTransferDisabled();
    }
}