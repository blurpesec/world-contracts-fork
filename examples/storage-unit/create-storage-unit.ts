import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { createOwnerCapForObject } from "../utils/ownerCap";
import { hexToBytes } from "../utils/helper";
import { online } from "./online";

const STORAGE_A_TYPE_ID = BigInt(Math.floor(Math.random() * 1000000) + 5);
const STORAGE_B_TYPE_ID = BigInt(Math.floor(Math.random() * 500) + 500);
const STORAGE_A_ITEM_ID = BigInt(Math.floor(Math.random() * 7) + 7);
const STORAGE_B_ITEM_ID = BigInt(Math.floor(Math.random() * 99) + 99);
const MAX_CAPACITY = 1000000000000n;
const LOCATION_HASH = "0x16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function createStorageUnit(
    typeId: bigint,
    itemId: bigint,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
): Promise<string> {
    console.log("\n==== Creating Storage Unit ====");

    const tx = new Transaction();

    const [storageUnit] = tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::create_storage_unit`,
        arguments: [
            tx.object(config.adminCapObjectId),
            tx.pure.u64(typeId),
            tx.pure.u64(itemId),
            tx.pure.u64(MAX_CAPACITY),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::share_storage_unit`,
        arguments: [storageUnit, tx.object(config.adminCapObjectId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true },
    });

    const storageUnitId = result.objectChanges?.find(
        (change) => change.type === "created"
    )?.objectId;

    if (!storageUnitId) {
        throw new Error("Failed to create storage unit: object ID not found in transaction result");
    }
    return storageUnitId;
}

async function main() {
    console.log("============= Create Storage Unit example ==============\n");

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;
        const playerExportedKey = process.env.PLAYER_A_PRIVATE_KEY || exportedKey;

        if (!exportedKey || !playerExportedKey) {
            throw new Error(
                "PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = loadKeypair(exportedKey);
        const playerKeypair = loadKeypair(playerExportedKey);
        const config = getConfig(network);

        const playerAddress = playerKeypair.getPublicKey().toSuiAddress();
        const adminAddress = keypair.getPublicKey().toSuiAddress();

        console.log("Network:", network);
        console.log("Server address:", adminAddress);
        console.log("Player address (derived from key):", playerAddress);

        // Create a owner inventory
        const storageUnitId = await createStorageUnit(
            STORAGE_A_TYPE_ID,
            STORAGE_A_ITEM_ID,
            client,
            keypair,
            config
        );

        await sleep(1000);

        const ShipId = await createStorageUnit(
            STORAGE_B_TYPE_ID,
            STORAGE_B_ITEM_ID,
            client,
            keypair,
            config
        );
        await sleep(1000);

        await createOwnerCapForObject(storageUnitId, playerAddress, client, keypair, config);

        await sleep(1000);

        await createOwnerCapForObject(ShipId, playerAddress, client, keypair, config);

        await sleep(1000);

        console.log("===========================\n");
        console.log("Owner Inventory created:", storageUnitId);
        console.log("Ship Inventory created:", ShipId);
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
