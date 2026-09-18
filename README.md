# Haurva Protocol

![Haurva Protocol](https://github.com/Haurvacoin/artwork/blob/main/haurvacoin.png?raw=true)

**Haurva Protocol** is a BNB-collateralized stablecoin protocol built on **BNB Smart Chain**.

Its native stablecoin, **HAUSD**, is designed to maintain a target value of:

> **1 HAUSD = 1 USD**

HAUSD uses the **Chainlink BNB/USD oracle** to automatically determine the USD value of BNB and calculate the amount of BNB required to mint or redeem HAUSD.

The protocol is built around a simple mechanism:

**Mint:** BNB → Chainlink BNB/USD → HAUSD

**Redeem:** HAUSD → Chainlink BNB/USD → BNB

---

## Core Principles

Haurva Protocol is built around several principles:

* **BNB-collateralized**
* **USD-denominated**
* **6-decimal HAUSD**
* **Automatic BNB/USD pricing**
* **Chainlink oracle integration**
* **Permissionless minting**
* **Permissionless redemption**
* **No arbitrary owner minting**
* **Collateral protection**
* **0.05% minting fee paid in BNB**
* **No redemption fee in the current implementation**

The goal is to keep the core monetary mechanism simple, transparent, and entirely on-chain.

---

## HAUSD

HAUSD is an ERC-20 token with **6 decimal places**.

Therefore:

**1 HAUSD = 1,000,000 units**

For example:

**100 HAUSD = 100,000,000 units**

Using six decimals makes HAUSD compatible with the decimal convention commonly used by USD-denominated stablecoins.

---

## How HAUSD Works

HAUSD is minted and redeemed according to the current BNB/USD price obtained from Chainlink.

The protocol does not use a fixed amount of BNB per HAUSD. Instead, the required BNB amount changes automatically as the BNB/USD exchange rate changes.

For example, if BNB is $500:

**1 HAUSD ≈ 0.002 BNB**

If BNB later becomes $1,000:

**1 HAUSD ≈ 0.001 BNB**

The USD-denominated value remains approximately:

**1 HAUSD = $1**

while the required BNB quantity changes.

---

## Minting

A user specifies the amount of HAUSD they want to create.

The protocol obtains the current BNB/USD price from Chainlink and calculates the amount of BNB required to represent the requested USD value.

For example, if:

**BNB = $600**

and the user wants:

**100 HAUSD**

the required collateral is approximately:

**100 / 600 = 0.1666666667 BNB**

The user must additionally pay the protocol's **0.05% minting fee**.

Therefore:

**Total BNB required = Collateral + Minting Fee**

The collateral remains inside the protocol vault.

The minting fee becomes protocol revenue.

---

## Minting Formula

Conceptually, the protocol uses:

**Required BNB = HAUSD USD Value / BNB/USD Price**

For example:

**HAUSD requested = $1,000**

**BNB price = $600**

**Required BNB ≈ 1.66666667 BNB**

The smart contract performs this calculation using integer arithmetic while accounting for HAUSD's 6 decimals, BNB's 18 decimals, and the Chainlink oracle's decimals.

---

## Minting Fee

Every mint operation charges:

**0.05%**

of the BNB collateral amount.

The protocol expresses this using basis points:

**0.05% = 5 basis points**

The fee is calculated as:

**Mint Fee = Collateral × 5 / 10,000**

For example:

**Collateral = 1 BNB**

**Fee = 0.0005 BNB**

Therefore the user sends:

**1.0005 BNB**

and receives the HAUSD corresponding to **1 BNB** of collateral.

---

## Redemption

HAUSD can be redeemed for its corresponding BNB value.

When a user calls `redeem()`, the protocol:

1. Reads the current BNB/USD Chainlink price.
2. Calculates the BNB equivalent of the HAUSD.
3. Burns the user's HAUSD.
4. Transfers the corresponding BNB to the user.

For example, if:

**BNB = $600**

and the user redeems:

**600 HAUSD**

the protocol returns approximately:

**1 BNB**

The redeemed HAUSD is permanently burned, decreasing the total HAUSD supply.

---

## Redemption Fee

The current implementation has:

**0% redemption fee**

Therefore:

**Mint: 0.05%**

**Redeem: 0%**

A redemption fee may be introduced in a future protocol version if required.

---

## Price Oracle

Haurva Protocol uses the **Chainlink BNB/USD price feed** to determine the current USD value of BNB.

The contract automatically selects the appropriate oracle according to the blockchain on which it is deployed.

### BNB Smart Chain Mainnet

**Chain ID:** `56`

**BNB/USD Oracle:**

`0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE`

### BNB Smart Chain Testnet

**Chain ID:** `97`

**BNB/USD Oracle:**

`0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526`

The contract rejects deployment on unsupported networks to prevent accidental use of an incorrect oracle configuration.

---

## Oracle Safety

The protocol does not blindly accept the oracle response.

Before using the BNB/USD price, the contract verifies that:

* The oracle returned a positive price.
* The oracle has been updated.
* The returned price is not older than the configured maximum oracle delay.

The current maximum accepted oracle age is:

**1 hour**

If the oracle becomes stale, operations requiring the BNB/USD price will revert.

This protects the protocol from continuing to operate using an excessively old BNB price.

---

## Collateral Vault

The Haurva Protocol smart contract itself acts as the BNB collateral vault.

When users mint HAUSD:

**User → BNB → Haurva Protocol → HAUSD → User**

The BNB collateral remains inside the contract until HAUSD is redeemed.

---

## Collateralization

The protocol derives the BNB collateral requirement from the total HAUSD supply and the current BNB/USD price.

Conceptually:

**Required Collateral = Total HAUSD converted into BNB at the current BNB/USD price**

The contract exposes `requiredCollateral()` to calculate the BNB required to back all outstanding HAUSD.

It also exposes `collateralizationRatio()` to compare the BNB held by the protocol with the BNB required to back the outstanding HAUSD.

Examples:

* **100% = 1.00x**
* **150% = 1.50x**
* **200% = 2.00x**

Because minting fees remain inside the protocol, the collateralization ratio will normally become slightly greater than 100% as fees accumulate.

---

## Protocol Fees

Minting fees accumulate inside the protocol vault.

The owner can call `withdrawFees()` to withdraw BNB that exceeds the amount required to back all outstanding HAUSD.

The contract calculates:

**Withdrawable Amount = Vault Balance − Required Collateral**

Only the excess may be withdrawn.

The owner cannot simply withdraw arbitrary BNB from the vault.

This separation is important because BNB required to back outstanding HAUSD must remain available for redemption.

---

## Administrative Account

The wallet supplied during deployment becomes the contract owner.

The owner is the administrative account for the protocol.

However, the owner does **not** have an unrestricted HAUSD minting function.

There is intentionally no `ownerMint()` or equivalent mechanism that allows the administrator to create HAUSD without BNB collateral.

The normal HAUSD creation mechanism is:

**BNB collateral → Chainlink BNB/USD → HAUSD calculation → HAUSD mint**

The owner is primarily responsible for administration and withdrawal of excess protocol fees.

---

## Price Stability Mechanism

Haurva Protocol establishes an on-chain conversion relationship between HAUSD and USD through BNB.

The protocol's redemption mechanism creates an economic reference point:

**1 HAUSD ≈ $1**

However, the smart contract cannot directly control the price of HAUSD on external decentralized exchanges.

For example, HAUSD could temporarily trade at $0.97 or $1.03 on a secondary market.

The protocol's minting and redemption mechanism provides an arbitrage mechanism that can encourage the market price to move toward the protocol's underlying redemption value.

Therefore:

> **Haurva Protocol provides an on-chain BNB/USD conversion mechanism. It does not guarantee that HAUSD will trade at exactly $1 on every external market.**

---

## Example Lifecycle

Assume:

**BNB price = $600**

A user wants:

**600 HAUSD**

The protocol calculates:

**600 USD / 600 USD per BNB = 1 BNB**

The user deposits:

**1 BNB collateral + 0.0005 BNB minting fee**

The protocol mints:

**600 HAUSD**

The protocol vault now contains approximately:

**1.0005 BNB**

The user can later redeem:

**600 HAUSD**

If BNB is still $600, the protocol:

**Burns 600 HAUSD → Returns approximately 1 BNB**

The remaining **0.0005 BNB** represents the accumulated minting fee.

---

## Example When BNB Price Changes

Suppose a user originally minted:

**600 HAUSD**

when:

**BNB = $600**

The user deposited approximately:

**1 BNB**

Later, BNB increases to:

**$1,200**

The protocol now calculates:

**600 HAUSD / $1,200 = 0.5 BNB**

Therefore redeeming 600 HAUSD would return approximately:

**0.5 BNB**

The USD value remains approximately:

**$600**

The amount of BNB required changes automatically according to the Chainlink BNB/USD price.

---

## Security Model

Haurva Protocol is designed around several basic security principles.

### No Arbitrary Minting

HAUSD cannot normally be created without corresponding BNB collateral.

### Collateral Protection

The owner cannot withdraw BNB that is required to back outstanding HAUSD.

### Oracle Validation

The protocol rejects invalid or stale oracle prices.

### Burn on Redemption

Redeemed HAUSD is burned, reducing the outstanding supply.

### Excess BNB Refund

If a user sends more BNB than required during minting, the excess is returned automatically.

### Network-Specific Oracle

The contract automatically selects the appropriate BNB/USD oracle for BNB Smart Chain Mainnet or Testnet.

---

## ERC-20 Features

HAUSD implements:

* ERC-20
* ERC-20 Burnable
* ERC-20 Permit
* Ownable

The token therefore supports standard ERC-20 wallets, exchanges, and decentralized applications.

HAUSD also supports permit functionality through OpenZeppelin's `ERC20Permit` implementation, allowing compatible applications to approve token spending through signed messages rather than requiring a separate on-chain approval transaction.

---

## Contract Interface

### `mint(uint256 hausdAmount)`

Creates HAUSD by depositing BNB.

The user must provide enough BNB to cover:

**Required Collateral + 0.05% Minting Fee**

### `redeem(uint256 hausdAmount)`

Burns HAUSD and returns the corresponding BNB value to the caller.

No redemption fee is currently charged.

### `getBNBPrice()`

Returns the latest valid Chainlink BNB/USD price.

### `getBNBRequired(uint256 hausdAmount)`

Calculates the amount of BNB required for a specified amount of HAUSD.

HAUSD amounts use six decimals.

### `getMintFee(uint256 collateral)`

Calculates the 0.05% minting fee for a specified BNB collateral amount.

### `vaultBalance()`

Returns the total BNB balance held by the protocol contract.

### `totalHAUSDSupply()`

Returns the total outstanding HAUSD supply.

### `outstandingUSDValue()`

Returns the USD-denominated value represented by the outstanding HAUSD supply.

### `requiredCollateral()`

Returns the amount of BNB required to back all outstanding HAUSD at the current Chainlink BNB/USD price.

### `collateralizationRatio()`

Returns the current protocol collateralization ratio using 18-decimal precision.

For example:

* `1e18` = 100%
* `1.5e18` = 150%
* `2e18` = 200%

### `withdrawFees()`

Allows the contract owner to withdraw BNB that exceeds the amount required to back outstanding HAUSD.

Collateral required for outstanding HAUSD cannot be withdrawn through this function.

---

## Deployment

Haurva Protocol is designed for:

**BNB Smart Chain Testnet**

Chain ID: **97**

and:

**BNB Smart Chain Mainnet**

Chain ID: **56**

The constructor requires:

`constructor(address initialOwner)`

The supplied address becomes the contract owner.

### Remix Deployment

1. Open Remix IDE.
2. Create `HaurvaProtocol.sol`.
3. Paste the contract into the file.
4. Compile using Solidity `0.8.27`.
5. Enable optimization if desired.
6. Connect Remix to MetaMask.
7. Select BNB Smart Chain Testnet.
8. Enter your test wallet address as `initialOwner`.
9. Deploy the contract.
10. Verify that the deployed contract reports the correct Chainlink oracle address.

The contract automatically selects the Testnet oracle when deployed on chain ID `97`.

When deployed on chain ID `56`, it automatically selects the Mainnet oracle.

---

## Testing

Before using real funds, the protocol should be extensively tested on BNB Smart Chain Testnet.

### 1. Test the Oracle

Call:

`getBNBPrice()`

Verify that the contract returns a valid BNB/USD price.

### 2. Test BNB Requirement

Call:

`getBNBRequired(uint256 hausdAmount)`

For example, for 100 HAUSD, pass:

`100000000`

because HAUSD has six decimals.

### 3. Test the Mint Fee

Call:

`getMintFee(uint256 collateral)`

and verify that the result corresponds to 0.05% of the collateral.

### 4. Test Minting

Mint a small amount of HAUSD.

Verify:

* HAUSD balance increases.
* Total HAUSD supply increases.
* BNB vault balance increases.
* The 0.05% fee is retained by the protocol.

### 5. Test Excess BNB

Send more BNB than required.

Verify that the required collateral plus the minting fee remains in the contract while the excess is returned to the user.

### 6. Test Redemption

Redeem HAUSD.

Verify:

* HAUSD balance decreases.
* Total supply decreases.
* BNB balance increases.
* Redeemed HAUSD is burned.

### 7. Test Collateralization

Check:

`requiredCollateral()`

and:

`collateralizationRatio()`

before and after minting and redemption.

### 8. Test Fee Withdrawal

As the owner, call:

`withdrawFees()`

Verify that only BNB exceeding the required collateral can be withdrawn.

### 9. Test Unauthorized Access

Attempt to call `withdrawFees()` from a wallet other than the owner.

The transaction should revert.

### 10. Test Unsupported Networks

Attempting to deploy the contract on a network other than BNB Smart Chain Mainnet or Testnet should revert with:

`Unsupported BSC network`

---

## Testnet

For development and testing:

**Network:** BNB Smart Chain Testnet

**Chain ID:** 97

**Native Currency:** tBNB

Use test BNB only.

Do not use real BNB for testnet experimentation.

Test BNB can be obtained through the BNB Chain testnet faucet.

---

## Mainnet Considerations

The current implementation should be considered a **prototype / testnet implementation**, not a fully audited production stablecoin protocol.

Before deploying Haurva Protocol with real funds, additional work should be performed.

Recommended areas include:

* Independent smart-contract audit.
* Extensive unit testing.
* Fuzz testing.
* Invariant testing.
* Oracle failure testing.
* Oracle manipulation analysis.
* Extreme BNB price movement testing.
* Emergency pause or circuit-breaker mechanisms.
* Minimum mint limits.
* Maximum mint limits.
* Better handling of rounding.
* Formal collateral accounting.
* Multisig ownership.
* Secure administrative key management.
* Operational monitoring.
* Incident-response procedures.
* Liquidity planning.
* HAUSD market-making strategy.
* Economic stress testing.
* Clear protocol risk disclosures.

A stablecoin is a financial system, not merely an ERC-20 token.

Correct Solidity code alone does not guarantee that the overall protocol is economically safe or robust.

---

## Repository Structure

A simple repository can use:

`haurva-protocol/`

* `contracts/`

  * `HaurvaProtocol.sol`
* `artwork/`

  * `haurvacoin.png`
* `README.md`
* `LICENSE`

The Haurva Protocol artwork is available at:

[https://github.com/Haurvacoin/artwork/blob/main/haurvacoin.png](https://github.com/Haurvacoin/artwork/blob/main/haurvacoin.png)

---

## Project Identity

| Property           | Value             |
| ------------------ | ----------------- |
| Protocol           | Haurva Protocol   |
| Stablecoin         | HAUSD             |
| Target Value       | $1 USD            |
| Primary Collateral | BNB               |
| Blockchain         | BNB Smart Chain   |
| Token Standard     | ERC-20            |
| Token Decimals     | 6                 |
| Minting Fee        | 0.05%             |
| Redemption Fee     | 0%                |
| Oracle             | Chainlink BNB/USD |
| Testnet            | BSC Testnet       |
| Testnet Chain ID   | 97                |
| Mainnet            | BSC Mainnet       |
| Mainnet Chain ID   | 56                |

---

## Disclaimer

Haurva Protocol is experimental software.

HAUSD is not risk-free.

The protocol depends on:

* Smart-contract correctness.
* Chainlink oracle availability and correctness.
* BNB Smart Chain.
* BNB liquidity.
* The economic assumptions of the collateral and redemption mechanism.
* The security of user wallets.
* The security of the protocol's administrative keys.

The protocol should be independently audited and extensively tested before being used with real funds.

Nothing in this repository constitutes financial, investment, legal, tax, or accounting advice.

Users interact with the protocol at their own risk.

---

# Haurva Protocol

> **Freedom of money. Backed by BNB. Priced in USD.**

**HAUSD — Haurva Protocol**
