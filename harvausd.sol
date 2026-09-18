// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.7.0
//
// HAURVA PROTOCOL
// HAUSD - BNB-collateralized USD stablecoin
//
// IMPORTANT:
// This contract creates HAUSD with a target redemption value of $1.
// Each HAUSD is backed by an equivalent USD value of BNB held by this
// contract. The BNB/USD value is obtained automatically from Chainlink.
//
// BSC NETWORKS:
//   Mainnet: Chain ID 56
//   Testnet: Chain ID 97
//
// CHAINLINK BNB/USD:
//   Mainnet: 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE
//   Testnet: 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526
//
// HAUSD DECIMALS:
//   6
//
// MINT FEE:
//   0.05% of the BNB collateral amount.
//
// BASIC ECONOMICS:
//
//   User deposits BNB
//          |
//          v
//   Chainlink BNB/USD price
//          |
//          v
//   Contract calculates USD value
//          |
//          v
//   User receives HAUSD
//
//   Example:
//   If BNB = $600 and user deposits approximately 1 BNB,
//   the user receives approximately 600 HAUSD.
//
//   To redeem 600 HAUSD, the user receives approximately 1 BNB,
//   assuming the oracle price is still $600.
//
// NOTE:
// The contract guarantees the on-chain mint/redeem conversion rate.
// It cannot guarantee that HAUSD trades at exactly $1 on an external
// decentralized exchange. Market arbitrage is expected to keep the
// market price close to the redemption value.
//

pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    ERC20Burnable
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {
    ERC20Permit
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title Chainlink Aggregator V3 Interface
 *
 * @dev Minimal interface required to read the latest BNB/USD price.
 *
 * Chainlink price feeds normally return prices with 8 decimals.
 * For example:
 *
 *     $600 BNB
 *
 * is returned approximately as:
 *
 *     60000000000
 *
 * because:
 *
 *     600 * 10^8 = 60,000,000,000
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

/**
 * @title HaurvaProtocol
 * @notice HAUSD - BNB-collateralized USD stablecoin.
 *
 * Users can:
 *
 * 1. Mint HAUSD by depositing BNB.
 * 2. Pay a 0.05% minting fee in BNB.
 * 3. Redeem HAUSD for its corresponding USD value of BNB.
 * 4. Burn HAUSD during redemption.
 *
 * The contract owner is the administrative account.
 *
 * The owner can:
 *
 * - Withdraw accumulated minting fees.
 *
 * The owner CANNOT:
 *
 * - Arbitrarily mint HAUSD through an unrestricted mint function.
 * - Withdraw collateral backing outstanding HAUSD.
 *
 * This distinction is important because allowing the owner to withdraw
 * collateral would break the backing mechanism.
 */
contract HaurvaProtocol is ERC20, ERC20Burnable, Ownable, ERC20Permit {

    // ================================================================
    // CONSTANTS
    // ================================================================

    /**
     * @dev HAUSD uses 6 decimals.
     *
     * Therefore:
     *
     *     1 HAUSD = 1,000,000 units
     */
    uint8 private constant HAUSD_DECIMALS = 6;

    /**
     * @dev Minting fee:
     *
     * 0.05% = 5 / 10,000
     */
    uint256 public constant MINT_FEE_BPS = 5;

    /**
     * @dev BPS denominator.
     *
     * 10,000 basis points = 100%.
     */
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /**
     * @dev BNB uses 18 decimals.
     */
    uint256 private constant BNB_DECIMALS_FACTOR = 1e18;

    /**
     * @dev HAUSD uses 6 decimals.
     */
    uint256 private constant HAUSD_DECIMALS_FACTOR = 1e6;

    /**
     * @dev Maximum acceptable age of a Chainlink price.
     *
     * This protects the protocol from using an extremely old oracle
     * value if the feed stops updating.
     *
     * 1 hour is used here as a conservative test/prototype value.
     *
     * This value can be changed before production if the desired
     * oracle update policy is different.
     */
    uint256 public constant MAX_ORACLE_DELAY = 1 hours;


    // ================================================================
    // CHAINLINK ORACLE ADDRESSES
    // ================================================================

    /**
     * @dev Chainlink BNB/USD price feed on BSC Mainnet.
     *
     * Chain ID:
     *     56
     */
    address private constant MAINNET_BNB_USD =
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    /**
     * @dev Chainlink BNB/USD price feed on BSC Testnet.
     *
     * Chain ID:
     *     97
     */
    address private constant TESTNET_BNB_USD =
        0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526;


    // ================================================================
    // STATE VARIABLES
    // ================================================================

    /**
     * @dev Chainlink BNB/USD oracle used by this deployment.
     *
     * It is automatically selected based on block.chainid.
     *
     * Mainnet:
     *     0x0567...
     *
     * Testnet:
     *     0x2514...
     */
    AggregatorV3Interface public immutable bnbUsdOracle;


    // ================================================================
    // EVENTS
    // ================================================================

    /**
     * @dev Emitted whenever HAUSD is minted.
     *
     * `user`:
     *     Person receiving HAUSD.
     *
     * `hausdAmount`:
     *     HAUSD minted, using 6 decimals.
     *
     * `collateral`:
     *     BNB deposited as backing.
     *
     * `fee`:
     *     BNB minting fee.
     */
    event HAUSDMinted(
        address indexed user,
        uint256 hausdAmount,
        uint256 collateral,
        uint256 fee
    );

    /**
     * @dev Emitted whenever HAUSD is redeemed.
     *
     * `user`:
     *     Person receiving BNB.
     *
     * `hausdAmount`:
     *     HAUSD burned.
     *
     * `bnbReturned`:
     *     BNB returned to the user.
     */
    event HAUSDRedeemed(
        address indexed user,
        uint256 hausdAmount,
        uint256 bnbReturned
    );

    /**
     * @dev Emitted when the owner withdraws accumulated fees.
     */
    event FeesWithdrawn(
        address indexed owner,
        uint256 amount
    );


    // ================================================================
    // CONSTRUCTOR
    // ================================================================

    /**
     * @param initialOwner
     *     Your administrative wallet.
     *
     * The constructor automatically selects the correct Chainlink
     * BNB/USD feed according to the blockchain on which the contract
     * is deployed.
     *
     * BSC Mainnet:
     *     Chain ID 56
     *
     * BSC Testnet:
     *     Chain ID 97
     */
    constructor(address initialOwner)
        ERC20("Haurva Protocol", "HAUSD")
        Ownable(initialOwner)
        ERC20Permit("Haurva Protocol")
    {
        /**
         * Select the oracle based on the current chain.
         *
         * This prevents accidentally deploying a testnet oracle
         * on mainnet or vice versa.
         */
        if (block.chainid == 56) {
            bnbUsdOracle = AggregatorV3Interface(MAINNET_BNB_USD);
        } else if (block.chainid == 97) {
            bnbUsdOracle = AggregatorV3Interface(TESTNET_BNB_USD);
        } else {
            revert("Unsupported BSC network");
        }
    }


    // ================================================================
    // ERC20 DECIMALS
    // ================================================================

    /**
     * @notice HAUSD uses 6 decimal places.
     *
     * Therefore:
     *
     *     1 HAUSD
     *         =
     *     1,000,000 units
     */
    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return HAUSD_DECIMALS;
    }


    // ================================================================
    // ORACLE
    // ================================================================

    /**
     * @notice Returns the current BNB/USD price.
     *
     * @return price
     *     Current BNB price in USD with 8 decimal places.
     *
     * @dev Example:
     *
     *     BNB = $600
     *
     *     returned value:
     *
     *     60000000000
     *
     * The function also verifies:
     *
     * - The oracle returned a positive price.
     * - The oracle round has been completed.
     * - The price is not older than MAX_ORACLE_DELAY.
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
            
        ) = bnbUsdOracle.latestRoundData();

        require(answer > 0, "Invalid oracle price");

        require(
            updatedAt > 0,
            "Oracle has no update"
        );

        require(
            block.timestamp - updatedAt <= MAX_ORACLE_DELAY,
            "Oracle price is stale"
        );

        price = uint256(answer);
    }


    // ================================================================
    // CALCULATE BNB REQUIRED FOR MINTING
    // ================================================================

    /**
     * @notice Calculates the BNB collateral required for a given
     *         amount of HAUSD.
     *
     * @param hausdAmount
     *     Amount of HAUSD in 6-decimal units.
     *
     * @return bnbRequired
     *     Required BNB collateral in wei.
     *
     * Example:
     *
     * If:
     *
     *     BNB = $600
     *
     * and:
     *
     *     hausdAmount = 600,000,000
     *
     * which represents:
     *
     *     600 HAUSD
     *
     * then the required collateral is approximately:
     *
     *     1 BNB
     *
     * Formula:
     *
     *     BNB =
     *         HAUSD USD value
     *         ----------------
     *             BNB/USD
     */
    function getBNBRequired(
        uint256 hausdAmount
    )
        public
        view
        returns (uint256 bnbRequired)
    {
        require(
            hausdAmount > 0,
            "Amount must be greater than zero"
        );

        uint256 bnbPrice = getBNBPrice();

        /**
         * `hausdAmount` has 6 decimals.
         *
         * `bnbPrice` has 8 decimals.
         *
         * We convert the HAUSD amount into a USD value and then
         * convert that USD value into 18-decimal BNB.
         *
         * Formula:
         *
         *     BNB wei =
         *
         *     HAUSD units * 1e18
         *     ------------------
         *     1e6 * BNB/USD price
         */
        bnbRequired =
            (hausdAmount * BNB_DECIMALS_FACTOR)
            /
            (HAUSD_DECIMALS_FACTOR * bnbPrice);

        require(
            bnbRequired > 0,
            "Collateral too small"
        );
    }


    // ================================================================
    // CALCULATE MINTING FEE
    // ================================================================

    /**
     * @notice Calculates the 0.05% BNB minting fee.
     *
     * @param collateral
     *     BNB collateral amount in wei.
     *
     * @return fee
     *     Fee in wei.
     */
    function getMintFee(
        uint256 collateral
    )
        public
        pure
        returns (uint256 fee)
    {
        fee =
            (collateral * MINT_FEE_BPS)
            /
            BPS_DENOMINATOR;
    }


    // ================================================================
    // MINT HAUSD
    // ================================================================

    /**
     * @notice Mint HAUSD by depositing BNB.
     *
     * The user specifies exactly how many HAUSD they want.
     *
     * The contract:
     *
     * 1. Reads the current BNB/USD Chainlink price.
     * 2. Calculates the required BNB collateral.
     * 3. Calculates the 0.05% minting fee.
     * 4. Requires sufficient BNB.
     * 5. Keeps the collateral inside the vault.
     * 6. Keeps the fee inside the contract.
     * 7. Mints exactly the requested HAUSD amount.
     * 8. Refunds excess BNB.
     *
     * Example:
     *
     * BNB = $600
     *
     * User wants:
     *
     *     100 HAUSD
     *
     * Required collateral:
     *
     *     100 / 600 = 0.166666... BNB
     *
     * Fee:
     *
     *     0.166666... * 0.05%
     *
     * User therefore sends approximately:
     *
     *     0.166750... BNB
     *
     * and receives:
     *
     *     100 HAUSD
     */
    function mint(uint256 hausdAmount)
        external
        payable
    {
        require(
            hausdAmount > 0,
            "Amount must be greater than zero"
        );

        /**
         * Calculate the BNB collateral required to back the requested
         * amount of HAUSD at the current oracle price.
         */
        uint256 collateral = getBNBRequired(hausdAmount);

        /**
         * Calculate the 0.05% minting fee.
         */
        uint256 fee = getMintFee(collateral);

        /**
         * Total BNB the user needs to provide.
         */
        uint256 totalRequired = collateral + fee;

        require(
            msg.value >= totalRequired,
            "Insufficient BNB"
        );

        /**
         * Mint exactly the amount requested by the user.
         *
         * There is no owner-controlled arbitrary minting mechanism.
         * New HAUSD is created only against BNB collateral.
         */
        _mint(msg.sender, hausdAmount);

        /**
         * If the user sent more BNB than required, refund the excess.
         */
        uint256 excess = msg.value - totalRequired;

        if (excess > 0) {
            (bool success, ) = payable(msg.sender).call{
                value: excess
            }("");

            require(
                success,
                "Refund failed"
            );
        }

        emit HAUSDMinted(
            msg.sender,
            hausdAmount,
            collateral,
            fee
        );
    }


    // ================================================================
    // REDEEM HAUSD
    // ================================================================

    /**
     * @notice Redeem HAUSD for its BNB collateral value.
     *
     * The user must own at least `hausdAmount` HAUSD.
     *
     * The contract:
     *
     * 1. Reads the current BNB/USD price.
     * 2. Calculates the corresponding BNB value.
     * 3. Burns the user's HAUSD.
     * 4. Sends the corresponding BNB back.
     *
     * Example:
     *
     * If:
     *
     *     BNB = $600
     *
     * and the user redeems:
     *
     *     600 HAUSD
     *
     * approximately:
     *
     *     1 BNB
     *
     * is returned.
     *
     * There is currently NO redemption fee.
     */
    function redeem(uint256 hausdAmount)
        external
    {
        require(
            hausdAmount > 0,
            "Amount must be greater than zero"
        );

        /**
         * Calculate how much BNB corresponds to the HAUSD amount
         * using the current Chainlink BNB/USD price.
         */
        uint256 bnbAmount = getBNBRequired(hausdAmount);

        /**
         * The vault must contain enough BNB to satisfy redemption.
         *
         * Minting collateral is protected from owner withdrawal,
         * so the vault should normally have enough BNB provided that
         * the system remains properly collateralized.
         */
        require(
            address(this).balance >= bnbAmount,
            "Insufficient vault collateral"
        );

        /**
         * Burn the HAUSD being redeemed.
         *
         * This reduces the outstanding HAUSD supply.
         */
        _burn(msg.sender, hausdAmount);

        /**
         * Send the corresponding BNB to the redeemer.
         */
        (bool success, ) = payable(msg.sender).call{
            value: bnbAmount
        }("");

        require(
            success,
            "BNB transfer failed"
        );

        emit HAUSDRedeemed(
            msg.sender,
            hausdAmount,
            bnbAmount
        );
    }


    // ================================================================
    // VIEW VAULT INFORMATION
    // ================================================================

    /**
     * @notice Returns the total amount of BNB currently held by the
     *         protocol vault.
     *
     * This includes:
     *
     * - BNB collateral backing HAUSD.
     * - Accumulated minting fees.
     *
     * Because fees are held in the same contract balance, the raw
     * contract balance will normally be slightly greater than the
     * BNB required to back the outstanding HAUSD.
     */
    function vaultBalance()
        public
        view
        returns (uint256)
    {
        return address(this).balance;
    }


    /**
     * @notice Returns the total HAUSD supply.
     *
     * This represents the total amount of HAUSD currently circulating
     * according to this ERC20 contract.
     */
    function totalHAUSDSupply()
        public
        view
        returns (uint256)
    {
        return totalSupply();
    }


    /**
     * @notice Calculates the USD value represented by all outstanding
     *         HAUSD.
     *
     * @return usdValue
     *     USD value with 6 decimals.
     *
     * Example:
     *
     *     1,000 HAUSD
     *
     * returns:
     *
     *     1,000,000,000
     *
     * because HAUSD uses 6 decimals.
     */
    function outstandingUSDValue()
        public
        view
        returns (uint256 usdValue)
    {
        return totalSupply();
    }


    // ================================================================
    // COLLATERALIZATION
    // ================================================================

    /**
     * @notice Returns the BNB required to fully back all outstanding
     *         HAUSD at the current oracle price.
     */
    function requiredCollateral()
        public
        view
        returns (uint256)
    {
        if (totalSupply() == 0) {
            return 0;
        }

        return getBNBRequired(totalSupply());
    }


    /**
     * @notice Returns the protocol's collateralization ratio.
     *
     * The result uses 18 decimals.
     *
     * Example:
     *
     *     1.00e18 = 100%
     *     1.50e18 = 150%
     *     2.00e18 = 200%
     *
     * Since minting fees remain in the contract, the ratio will normally
     * be slightly above 100% after fees have accumulated.
     */
    function collateralizationRatio()
        public
        view
        returns (uint256)
    {
        uint256 supply = totalSupply();

        if (supply == 0) {
            return 0;
        }

        uint256 required = getBNBRequired(supply);

        if (required == 0) {
            return 0;
        }

        return
            (address(this).balance * 1e18)
            /
            required;
    }


    // ================================================================
    // FEE WITHDRAWAL
    // ================================================================

    /**
     * @notice Withdraw accumulated minting fees.
     *
     * SECURITY DESIGN:
     *
     * The owner must NOT be allowed to withdraw arbitrary BNB from
     * the vault because that BNB backs outstanding HAUSD.
     *
     * Therefore this function calculates:
     *
     *     withdrawable =
     *         vault balance
     *         -
     *         required collateral
     *
     * Only the excess above the collateral requirement can be withdrawn.
     *
     * This excess consists primarily of accumulated minting fees.
     */
    function withdrawFees()
        external
        onlyOwner
    {
        uint256 required = requiredCollateral();

        uint256 balance = address(this).balance;

        require(
            balance > required,
            "No withdrawable fees"
        );

        uint256 withdrawable = balance - required;

        (bool success, ) = payable(owner()).call{
            value: withdrawable
        }("");

        require(
            success,
            "Fee withdrawal failed"
        );

        emit FeesWithdrawn(
            owner(),
            withdrawable
        );
    }


    // ================================================================
    // RECEIVE
    // ================================================================

    /**
     * @dev Accept plain BNB transfers.
     *
     * WARNING:
     * Sending BNB directly to this contract does NOT mint HAUSD.
     *
     * Users should always use `mint()` when they want to create HAUSD.
     */
    receive()
        external
        payable
    {
        // Intentionally empty.
    }
}