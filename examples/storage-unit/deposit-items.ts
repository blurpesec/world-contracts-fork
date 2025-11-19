import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";

const STORAGE_UNIT_ID = "0xf24567f0aa6aa62720c6889df730b94430c882353a3f2d324fb216e74f9b41de";
const ITEM_OBJECT_ID = "0xb311234b640b3f9afa0faef32a45ae8f5aae09445521ba1934e901cb5187399d";

async function withdrawItem(
    storageUnit: string,
    type_id: bigint,
    item_id: bigint,
    volume: bigint,
    quantity: number,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Move Items from from game to Chain ====");

    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::game_to_chain_inventory`,
        arguments: [
            tx.object(storageUnit),
            tx.object(config.adminCapObjectId),
            tx.pure.u64(item_id),
            tx.pure.u64(type_id),
            tx.pure.u64(volume),
            tx.pure.u32(quantity),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true },
    });

    // Find the ItemMintedEvent and extract the item_uid
    const mintEvent = result.events?.find(
        (event) => event.type.endsWith("::inventory::ItemMintedEvent")
    );

    if (!mintEvent) {
        throw new Error("ItemMintedEvent not found in transaction result");
    }

    // Type the parsed event data to access item_uid
    const eventData = mintEvent.parsedJson as { item_uid: string };
    const itemObjectId = eventData.item_uid;

    if (!itemObjectId) {
        throw new Error("Failed to get item UID from ItemMintedEvent");
    }

    console.log("Item minted on-chain with objectId:", itemObjectId);

    console.log("Items moved on-chain: ", type_id);
}

async function main() {
    console.log("============= Create example ==============\n");

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;
        const playerAddress = process.env.PLAYER_A_ADDRESS || "";

        if (!exportedKey) {
            throw new Error(
                "PRIVATE_KEY environment variable is required. " +
                "Create a .env file with PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = loadKeypair(exportedKey);
        const config = getConfig(network);

        const adminAddress = keypair.getPublicKey().toSuiAddress();

        console.log("Network:", network);
        console.log("Server address:", adminAddress);
        console.log("Player address:", playerAddress);
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
