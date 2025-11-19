# Examples

TypeScript examples demonstrating how to interact with the World Contracts on the Sui blockchain.

## Getting Started

### Prerequisites

1. **Start a local Sui node** (if running locally)  
   See the [main README](../README.md) for setup instructions.

2. **Install dependencies**
   ```bash
   pnpm install
   ```

3. **Set up environment variables**  
   Create a `.env` file in the project root:
   ```env
   SUI_NETWORK=localnet  # or testnet, mainnet
   PRIVATE_KEY=suiprivkey1...  # Your Sui private key
   ```

4. **Deploy contracts** (for localnet)
   ```bash
   pnpm run deploy
   ```

## Running Examples

```bash
pnpm run sig-verify.ts
```

## Formatting

```bash
pnpm run fmt:ts
```
