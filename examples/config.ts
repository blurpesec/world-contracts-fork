// Configuration for different networks
export const NETWORKS = {
    localnet: {
        url: "http://127.0.0.1:9000",
        packageId: "0xfac4d336b199d0aa17180f51d8ec55515a26f4e1e8c6f4ff190a697db9ca707e",
        adminCapObjectId: "",
    },
    testnet: {
        url: "https://fullnode.testnet.sui.io:443",
        packageId: "0xe5495523cde599dc78000bef6203b19c89c00794614932dc44a34070e683a33c",
        adminCapObjectId: "0xe459ee8fbb9691d2cc3f7b4fc31a32ccad0b2db30dc8f5d1792623a2c21b13d6",
    },
    mainnet: {
        url: "https://fullnode.mainnet.sui.io:443",
        packageId: "0x...",
        adminCapObjectId: "",
    },
};

export type Network = keyof typeof NETWORKS;

export function getConfig(network: Network = "localnet") {
    return NETWORKS[network];
}

// Module names
export const MODULES = {
    SIG_VERIFY: "sig_verify",
    LOCATION: "location",
    STORAGE_UNIT: "storage_unit",
    WORLD: "world",
} as const;
