import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";

const GATE_ID = "0xb4a7a5ff9ee205b4be67db5d61506b8d0d0a4fc85d5cd78e3f73d7161f9ab3dd";
const EXTENSION_PACKAGE_ID = "0x7e14978d020b162690f550385f8a347a732e73e70190ecc4fe0c7091507590c2";

async function authoriseExtension(
    gateId: string,
    extensionPackageId: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Customising Gate ====");

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
