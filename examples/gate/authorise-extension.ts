import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";

const GATE_ID = "0x5cf64c96cfe536fbe2213d69f9ebb0b464fd225c1c31b2dc0ffe60ccc5f32242";
const EXTENSION_PACKAGE_ID = "0x224a9522433fe22ad3df25628579512acf21e3f66411d1c54133a917f8523844";

async function authoriseExtension(
    gateId: string,
    extensionPackageId: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Authorising Extension for Gate ====");

    const ownerAddress = keypair.getPublicKey().toSuiAddress();

    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::authorize_extension`,
        typeArguments: [`${extensionPackageId}::gate_extension::GateXAuth`],
        arguments: [tx.object(gateId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("Transaction digest:", result.digest);
    console.log("Extension authorized successfully for gate!");

    return result;
}

async function main() {
    console.log("============= Authorize Gate Extension ==============\n");

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;

        if (!exportedKey) {
            throw new Error(
                "PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = loadKeypair(exportedKey);
        const config = getConfig(network);

        const ownerAddress = keypair.getPublicKey().toSuiAddress();

        console.log("Network:", network);
        console.log("Owner address:", ownerAddress);
        console.log("Gate ID:", GATE_ID);
        console.log("Extension Package ID:", EXTENSION_PACKAGE_ID);

        await authoriseExtension(GATE_ID, EXTENSION_PACKAGE_ID, client, keypair, config);
    } catch (error) {
        console.error("\n=== Error ===");
        console.error("Error:", error instanceof Error ? error.message : error);
        if (error instanceof Error && error.stack) {
            console.error("Stack:", error.stack);
        }
        process.exit(1);
    }
}

main().catch(console.error);
