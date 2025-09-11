# More Vaults Core

## Description

More Vaults Core is a system for creating and managing vault contracts using the Diamond Pattern (EIP-2535). The project is built on Foundry and supports creating upgradeable vault contracts.

## Installation

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js (for dependencies)

### Install Dependencies

```bash
# Clone the repository
git clone <repository-url>
cd More-Vaults

# Install Foundry dependencies
forge install

# Build the project
forge build
```

## Usage

### Build Project

```bash
forge build
```

### Run Tests

```bash
forge test
```

### Gas Snapshots

```bash
forge snapshot
```

### Local Node

```bash
anvil
```

## Creating a Vault

### Environment Variables Setup

Create a `.env` file in the project root with the following variables:

#### Required Variables for Vault Creation:

```bash
# Private key for signing transactions
PRIVATE_KEY=your_private_key_here

# Vault roles
OWNER=0x...                    # Vault owner address
CURATOR=0x...                  # Vault curator address
GUARDIAN=0x...                 # Vault guardian address
FEE_RECIPIENT=0x...            # Fee recipient address

# Base asset for vault
UNDERLYING_ASSET=0x...         # Token address to be used in vault

# Vault parameters
FEE=500                        # Fee in basis points (500 = 5%)
DEPOSIT_CAPACITY=1000000000000000000000000  # Maximum deposit capacity (in wei with decimals of underlying asset)
TIME_LOCK_PERIOD=86400         # Time lock period in seconds (86400 = 1 day), for test purposes set it as 0
MAX_SLIPPAGE_PERCENT=1000       # Maximum slippage in basis points (1000 = 10%)

# Vault metadata
VAULT_NAME="My Vault"          # Vault name
VAULT_SYMBOL="MV"              # Vault symbol

# Deployment parameters
IS_HUB=true                    # true for hub vault, false for spoke vault
SALT=0x0000000000000000000000000000000000000000000000000000000000000001  # Salt for CREATE2

# Deployed core contract addresses, can be found in .env.deployments or in docs
DIAMOND_LOUPE_FACET=0x...
ACCESS_CONTROL_FACET=0x...
CONFIGURATION_FACET=0x...
VAULT_FACET=0x...
MULTICALL_FACET=0x...
ERC4626_FACET=0x...
ERC7540_FACET=0x...

ORACLE_REGISTRY=0x...
VAULT_REGISTRY=0x...
VAULTS_FACTORY=0x...
```

### Running the Vault Creation Script

#### For Flow Testnet (Chain ID: 545)

```bash
forge script scripts/CreateVault.s.sol:CreateVaultScript \
  --chain-id 545 \
  --rpc-url https://testnet.evm.nodes.onflow.org \
  -vv \
  --slow \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url 'https://evm-testnet.flowscan.io/api/'
```

#### For Flow Mainnet (Chain ID: 747)

```bash
forge script scripts/CreateVault.s.sol:CreateVaultScript \
  --chain-id 747 \
  --rpc-url https://mainnet.evm.nodes.onflow.org \
  -vv \
  --slow \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url 'https://evm.flowscan.io/api/'
```

#### For Sepolia Testnet (Chain ID: 11155111)

```bash
forge script scripts/CreateVault.s.sol:CreateVaultScript \
  --chain-id 11155111 \
  --rpc-url YOUR_RPC_URL \
  -vv \
  --slow \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url 'https://sepolia.etherscan.io/api/'
```

### Execution Result

After successful script execution:

1. Vault will be deployed to an address that will be printed to console
2. Vault address will be saved to `.env.deployments` file
3. Contract will be verified on the blockchain explorer

## Project Structure

```
src/
├── facets/           # Diamond facets (functionality)
├── factory/          # Vault factory
├── registry/         # Vault registry
├── interfaces/       # Interfaces
└── MoreVaultsDiamond.sol  # Main Diamond contract

scripts/
├── Deploy.s.sol      # System deployment script
├── CreateVault.s.sol # Vault creation script
└── config/           # Deployment configuration

test/                 # Tests
lib/                  # Foundry dependencies
```

## Additional Commands

### Cast (Contract Interaction)

```bash
cast <subcommand>
```

### Help

```bash
forge --help
anvil --help
cast --help
```

## Foundry Documentation

https://book.getfoundry.sh/
