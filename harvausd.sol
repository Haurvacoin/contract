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

    Example:

        BNB price = $600

        User sends 1 BNB
        Mint fee = 0.05%
        Collateral = approximately 0.999500249875 BNB

        HAUSD minted ≈ 599.700149925 HAUSD

    If the user wants exactly the equivalent of 0.1 BNB of collateral,
    they need to send approximately 0.100050025 BNB because the 0.05%
    fee is charged in addition to the collateral amount.

    FEES
    ----
    Mint fee:
        0.05% = 5 basis points

    The minting fee is immediately transferred to the contract owner
    (the administrator wallet).

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

    The constructor automatically selects the correct oracle according
    to block.chainid.

    LOGO
    ----
    Project artwork:

    https://github.com/Haurvacoin/artwork/blob/main/haurvacoin.png?raw=true

    IMPORTANT
    ---------
    This contract does NOT magically force HAUSD to trade at exactly
    $1 on PancakeSwap or another external market.

    Instead, minting and redemption are always performed against the
    Chainlink BNB/USD oracle at approximately $1 per HAUSD.

    This creates the on-chain arbitrage mechanism around the $1 target.

    SECURITY
    --------
    - Oracle price must be positive.
    - Oracle data must not be stale.
    - HAUSD cannot be minted without BNB collateral.
    - BNB can only enter through mint().
    - Redemption burns HAUSD before sending BNB.
    - Native BNB transfers use a low-level call.
    - No unnecessary ReentrancyGuard is used to keep gas usage low;
      state changes occur before the external BNB transfer.
    ================================================================
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

    We define only the part of Chainlink's AggregatorV3Interface
    that this contract actually needs.

    This avoids importing the entire Chainlink package and keeps the
    contract simpler to deploy in Remix.
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

    // HAUSD always uses 6 decimal places.
    uint8 private constant HAUSD_DECIMALS = 6;

    // Chainlink BNB/USD feeds use 8 decimal places.
    uint256 private constant ORACLE_DECIMALS = 8;

    // 10^18 represents one BNB in native EVM units (wei).
    uint256 private constant BNB_DECIMALS = 18;

    // 1 USD represented using HAUSD's 6 decimals.
    uint256 private constant USD_SCALE = 1e6;

    /*
        Minting fee:

        0.05%
        =
        5 / 10,000
        =
        0.0005
    */
    uint256 public constant MINT_FEE_BPS = 5;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /*
        Chainlink BNB/USD price feeds.

        These addresses are hardcoded so users cannot replace the
        oracle with an arbitrary address.

        BSC Testnet feed:
        0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526

        BSC Mainnet feed:
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE
    */
    address private constant BSC_TESTNET_BNB_USD =
        0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526;

    address private constant BSC_MAINNET_BNB_USD =
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    /*
        Maximum acceptable age of oracle data.

        If Chainlink has not updated the BNB/USD price for more than
        1 day, minting and redemption are stopped rather than using
        potentially stale pricing.

        This is a safety mechanism.
    */
    uint256 public constant MAX_ORACLE_DELAY = 1 days;


    /*
        ------------------------------------------------------------
                           STATE VARIABLES
        ------------------------------------------------------------
    */

    /*
        The Chainlink BNB/USD oracle selected automatically during
        deployment according to the network's chain ID.
    */
    IChainlinkAggregator public immutable bnbUsdOracle;


    /*
        ------------------------------------------------------------
                              EVENTS
        ------------------------------------------------------------
    */

    /*
        Emitted whenever someone mints HAUSD.

        bnbCollateral:
            Amount of BNB actually retained by the protocol as
            collateral.

        fee:
            BNB minting fee paid to the administrator.

        hausdMinted:
            Number of HAUSD tokens created.
    */
    event HAUSDMinted(
        address indexed user,
        uint256 bnbCollateral,
        uint256 fee,
        uint256 hausdMinted,
        uint256 bnbUsdPrice
    );


    /*
        Emitted whenever HAUSD is redeemed for BNB.
    */
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
        The deployer's wallet becomes the administrator.

        No constructor argument is necessary.

        On BSC Testnet:
            Chain ID 97
            Test BNB oracle is selected.

        On BSC Mainnet:
            Chain ID 56
            Mainnet BNB oracle is selected.

        Deployment on another chain intentionally fails.
    */
    constructor()
        ERC20("Haurva Protocol", "HAUSD")
        Ownable(msg.sender)
        ERC20Permit("Haurva Protocol")
    {
        if (block.chainid == 97) {
            bnbUsdOracle =
                IChainlinkAggregator(BSC_TESTNET_BNB_USD);
        }
        else if (block.chainid == 56) {
            bnbUsdOracle =
                IChainlinkAggregator(BSC_MAINNET_BNB_USD);
        }
        else {
            revert UnsupportedNetwork();
        }
    }


    /*
        ------------------------------------------------------------
                           ERC20 DECIMALS
        ------------------------------------------------------------

        HAUSD deliberately uses 6 decimals instead of the ERC20
        default of 18.

        Therefore:

            1 HAUSD  = 1,000,000 units

        This is convenient for a USD-denominated stablecoin.
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

    /*
        Returns the current Chainlink BNB/USD price.

        Example:

            BNB = $600

        Chainlink returns:

            60000000000

        because the oracle uses 8 decimals.

        The function rejects:

        - negative prices
        - zero prices
        - incomplete oracle rounds
        - stale oracle data
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

        if (answer <= 0) {
            revert InvalidOraclePrice();
        }

        if (updatedAt == 0) {
            revert InvalidOracleAnswer();
        }

        if (answeredInRound < roundId) {
            revert InvalidOracleAnswer();
        }

        if (block.timestamp - updatedAt > MAX_ORACLE_DELAY) {
            revert OraclePriceStale();
        }

        /*
            Chainlink's BNB/USD feed is expected to use 8 decimals.

            We explicitly verify this so a future incompatible oracle
            cannot silently break the pricing mathematics.
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
        Converts BNB (wei) into HAUSD (6 decimals).

        Formula:

            BNB USD value
            =
            BNB amount * BNB/USD price

        Scaling:

            BNB has 18 decimals.
            Oracle has 8 decimals.
            HAUSD has 6 decimals.

        Therefore:

            HAUSD =
                bnbWei * oraclePrice
                / 10^20

        Example:

            1 BNB
            BNB price = $600

            1e18 * 600e8 / 1e20
            =
            600e6

            =
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
        Converts HAUSD (6 decimals) into BNB wei.

        Example:

            600 HAUSD
            BNB price = $600

            600e6 * 1e20 / 600e8
            =
            1e18

            =
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
        Calculates what happens if the user sends a particular
        amount of BNB to mint().

        IMPORTANT:

        The amount supplied here represents the TOTAL BNB payment.

        The 0.05% fee is taken from that payment.

        The remainder becomes collateral.

        Example:

            User sends:
                0.1 BNB

            Fee:
                approximately 0.000049975 BNB

            Collateral:
                approximately 0.099950025 BNB

        This function is view-only and costs no gas when called
        off-chain.
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
            Calculate fee:

                fee = total * 5 / 10,000
        */
        feeBNB =
            (totalBNB * MINT_FEE_BPS)
            / BPS_DENOMINATOR;

        /*
            Everything remaining becomes collateral.
        */
        collateralBNB = totalBNB - feeBNB;

        /*
            Convert collateral BNB to HAUSD using the live oracle.
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

        NO ARGUMENT IS REQUIRED.

        The user simply calls:

            mint()

        and attaches BNB/tBNB to the transaction.

        The contract automatically:

            1. Reads the BNB/USD oracle.
            2. Calculates the 0.05% fee.
            3. Keeps the remaining BNB as collateral.
            4. Calculates its USD value.
            5. Mints the corresponding HAUSD.
            6. Sends the fee to the administrator.

        This means Remix does NOT need a "hausdAmount" input.

        The only value the user needs to provide is the native BNB
        transaction Value.

        IMPORTANT:

        Because the fee is taken from the supplied BNB, sending
        exactly 0.1 BNB does NOT result in the USD value of exactly
        0.1 BNB being minted.

        If the user wants exactly the collateral value of 0.1 BNB,
        they should send approximately:

            0.100050025 BNB

        which leaves approximately 0.1 BNB after the 0.05% fee.
    */
    function mint()
        external
        payable
    {
        if (msg.value == 0) {
            revert NoBNBSent();
        }

        /*
            Calculate fee directly from the total amount sent.
        */
        uint256 fee =
            (msg.value * MINT_FEE_BPS)
            / BPS_DENOMINATOR;

        /*
            The remainder stays inside this contract as collateral.
        */
        uint256 collateral =
            msg.value - fee;

        /*
            Convert the collateral to HAUSD using the current
            Chainlink BNB/USD price.
        */
        uint256 hausdAmount =
            bnbToHAUSD(collateral);

        if (hausdAmount == 0) {
            revert ZeroHAUSDAmount();
        }

        uint256 price =
            getBNBPrice();

        /*
            Effects first:

            Mint the HAUSD before performing the external native
            BNB transfer.

            This minimizes reentrancy risk without adding the
            gas overhead of ReentrancyGuard.
        */
        _mint(msg.sender, hausdAmount);

        /*
            The minting fee is sent directly to the administrator.

            The collateral remains in this contract.
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

        Input uses HAUSD's 6-decimal representation.

        Example:

            User owns:

                100 HAUSD

            Call:

                redeem(100000000)

            assuming:

                BNB = $600

            The contract returns approximately:

                0.166666666666... BNB

        There is currently NO redemption fee.
    */
    function redeem(uint256 hausdAmount)
        external
    {
        if (hausdAmount == 0) {
            revert ZeroHAUSDAmount();
        }

        /*
            Calculate how much BNB corresponds to the HAUSD being
            redeemed using the current BNB/USD oracle price.
        */
        uint256 bnbAmount =
            hausdToBNB(hausdAmount);

        if (bnbAmount == 0) {
            revert ZeroHAUSDAmount();
        }

        /*
            Make sure the protocol actually has enough BNB available
            to honor the redemption.

            This check prevents a failed native BNB transfer.
        */
        if (address(this).balance < bnbAmount) {
            revert InsufficientBNBReserve();
        }

        uint256 price =
            getBNBPrice();

        /*
            IMPORTANT:

            Burn the user's HAUSD BEFORE sending BNB.

            This is the critical state change that prevents a caller
            from attempting to redeem the same tokens repeatedly.
        */
        _burn(msg.sender, hausdAmount);

        /*
            Send native BNB to the redeemer.

            call() is used instead of transfer() because transfer()
            imposes the old 2300-gas stipend and can become fragile
            with smart-contract wallets.
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
        Returns the amount of BNB currently held by the protocol.

        This represents the native BNB reserve available for
        redemption.
    */
    function bnbReserve()
        external
        view
        returns (uint256)
    {
        return address(this).balance;
    }


    /*
        Returns the current theoretical USD value of all HAUSD
        currently outstanding, according to the oracle.

        Because HAUSD has 6 decimals, totalSupply() / 1e6 gives the
        human-readable token amount.
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
        Users should NEVER send BNB directly to the contract.

        All collateral deposits must go through mint() so that:

            - the oracle price is read
            - the minting fee is calculated
            - HAUSD is created

        Therefore direct native BNB transfers are rejected.

        NOTE:

        A forced BNB transfer through mechanisms such as SELFDESTRUCT
        cannot be prevented at the EVM level, but ordinary transfers
        are rejected here.
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