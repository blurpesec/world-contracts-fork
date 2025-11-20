import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { findOwnerCapForObject } from "../utils/ownerCap";

const SHIP_ID = "0x3036d4908afdea54f48e04ac988a8550a331a77797c671947c976d0f11c03656";
const STORAGE_UNIT_ID = "0x6f09f1a70be5e76296a5844a6945996b1ee931b43a3a72e3db77f464f7fbffcf";
const EXTENSION_PACKAGE_ID = "0x224a9522433fe22ad3df25628579512acf21e3f66411d1c54133a917f8523844";
const TREASURY_CAP_ID = "0x0d2c582a35a6b3959857ba63dcde18b17850084d3878ae3bd248239aa868a48d";

async function interact(
    shipId,
    storageUnitId,
    treasuryCapId,
    extensionPackageId,
    client,
    keypair,
    config
) {
    console.log("\n==== Interacting with Extension ====");

    const ownerAddress = keypair.getPublicKey().toSuiAddress();

    const ownerCapId = await findOwnerCapForObject(client, ownerAddress, shipId, config.packageId);

    if (!ownerCapId) {
        throw new Error(`ownerCap not found for storage unit${shipId}. `);
    }

    console.log("OwnerCap:", ownerCapId);

    const tx = new Transaction();

    tx.moveCall({
        target: `${extensionPackageId}::storage_extension::mint_nft_for_corpse`,
        arguments: [
            tx.object(shipId),
            tx.object(storageUnitId),
            tx.object(ownerCapId),
            tx.object(treasuryCapId),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    // const devInspectResult = await client.devInspectTransactionBlock({
    //     transactionBlock: tx,
    //     sender: ownerAddress,
    // });

    // console.log("Dev inspect status:", devInspectResult.effects.status.status);
    // if (devInspectResult.effects.status.status === "failure") {
    //     console.log("Dev inspect results:", devInspectResult);
    // } else {
    //     console.log("Dev inspect results:", devInspectResult.results);
    //     console.log("Dev inspect events:", devInspectResult.events);
    // }

    console.log(result);

    if (result.effects?.status?.status === "success") {
        console.log("Extension interaction successful!");
        console.log("Transaction digest:", result.digest);

        if (result.objectChanges) {
            console.log("\nObject changes:");
            result.objectChanges.forEach((change: any) => {
                if (change.type === "created") {
                    console.log(`  Created: ${change.objectType} - ${change.objectId}`);
                }
            });
        }
    }
}

async function main() {
    console.log("============= Interact with Builder Extension ==============\n");

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PLAYER_A_PRIVATE_KEY || process.env.PRIVATE_KEY;

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
        console.log("Ship ID:", SHIP_ID);
        console.log("Storage Unit ID:", STORAGE_UNIT_ID);
        console.log("Extension Package ID:", EXTENSION_PACKAGE_ID);
        console.log("Treasury Cap ID:", TREASURY_CAP_ID);

        await interact(
            SHIP_ID,
            STORAGE_UNIT_ID,
            TREASURY_CAP_ID,
            EXTENSION_PACKAGE_ID,
            client,
            keypair,
            config
        );
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
