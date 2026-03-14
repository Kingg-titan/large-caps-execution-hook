export const CHAINS = {
  anvil: {
    chainId: 31337,
    name: "Anvil Local",
    explorerBaseUrl: "http://localhost:8545",
  },
  baseSepolia: {
    chainId: 84532,
    name: "Base Sepolia",
    explorerBaseUrl: "https://sepolia.basescan.org",
  },
} as const;

export type ChainKey = keyof typeof CHAINS;
