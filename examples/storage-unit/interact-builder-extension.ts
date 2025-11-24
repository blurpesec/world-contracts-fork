import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { getConfig, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { findOwnerCapForObject } from "../utils/ownerCap";

const SHIP_ID = "0xc41971f090c145b2258bc0917400d6b5773b1290f5ea67392914d19a13f3b982";
const STORAGE_UNIT_ID = "0x24f58d2a20bfd1b8228f9e4a661d80150b79c867f48ed8945d1bcad11278d485";
const EXTENSION_PACKAGE_ID = "0x7e14978d020b162690f550385f8a347a732e73e70190ecc4fe0c7091507590c2";
const TREASURY_CAP_ID = "0x3eee3bb39cc9a29a85a3b99d4abf1f398127ec2f5b70fd469f7c095b52c302b5";

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
        target: `${extensionPackageId}::storage_extension::collect_corpse_bounty`,
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
