import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { findOwnerCapForObject } from "../utils/ownerCap";

const STORAGE_UNIT_ID = "0x24f58d2a20bfd1b8228f9e4a661d80150b79c867f48ed8945d1bcad11278d485";
const EXTENSION_PACKAGE_ID = "0x7e14978d020b162690f550385f8a347a732e73e70190ecc4fe0c7091507590c2";

async function authoriseExtension(storageUnitId, extensionPackageId, client, keypair, config) {
    console.log("\n==== Customising Storage Unit ====");

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
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::authorize_extension`,
        typeArguments: [`${extensionPackageId}::storage_extension::CorpseXAuth`],
        arguments: [tx.object(storageUnitId), tx.object(ownerCapId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log(result);

    const devInspectResult = await client.devInspectTransactionBlock({
        transactionBlock: tx,
        sender: ownerAddress,
    });

    console.log("Dev inspect status:", devInspectResult.effects.status.status);
    if (devInspectResult.effects.status.status === "failure") {
        console.log("Dev inspect results:", devInspectResult);
    } else {
        console.log("Dev inspect results:", devInspectResult.results);
        console.log("Dev inspect events:", devInspectResult.events);
    }
}

async function main() {
    console.log("===========================\n");

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
        console.log("Storage Unit ID:", STORAGE_UNIT_ID);
        console.log("Extension Package ID:", EXTENSION_PACKAGE_ID);

        await authoriseExtension(STORAGE_UNIT_ID, EXTENSION_PACKAGE_ID, client, keypair, config);
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
