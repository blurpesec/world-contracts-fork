import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { findOwnerCapForObject } from "../utils/ownerCap";

const STORAGE_UNIT_ID = "0xc41971f090c145b2258bc0917400d6b5773b1290f5ea67392914d19a13f3b982";

export async function online(
    storageUnitId: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Bringing Storage Unit Online ====");
    console.log("Storage Unit ID:", storageUnitId);

    const ownerAddress = keypair.getPublicKey().toSuiAddress();

    const ownerCapId = await findOwnerCapForObject(
        client,
        ownerAddress,
        storageUnitId,
        config.packageId
    );

    if (!ownerCapId) {
        throw new Error(`ownerCap not found for storage unit ${storageUnitId}. `);
    }

    console.log("OwnerCap:", ownerCapId);

    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::online`,
        arguments: [tx.object(storageUnitId), tx.object(ownerCapId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Storage Unit brought online successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= online assembly example ==============\n");

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PLAYER_A_PRIVATE_KEY || process.env.PRIVATE_KEY;

        if (!exportedKey) {
            throw new Error(
                "PLAYER_A_PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = loadKeypair(exportedKey);
        const config = getConfig(network);

        const playerAddress = keypair.getPublicKey().toSuiAddress();

        console.log("Network:", network);
        console.log("Player address:", playerAddress);

        await online(STORAGE_UNIT_ID, client, keypair, config);
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
