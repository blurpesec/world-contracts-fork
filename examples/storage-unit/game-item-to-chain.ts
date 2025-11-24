import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";

const SHIP_INVENTORY_ID = "0xc41971f090c145b2258bc0917400d6b5773b1290f5ea67392914d19a13f3b982";

const ITEM_A_TYPE_ID = BigInt(Math.floor(Math.random() * 1000000) + 5);
const CORPSE_ITEM_ID = 566789n;

async function gameItemToChain(
    storageUnit: string,
    typeId: bigint,
    itemId: bigint,
    volume: bigint,
    quantity: number,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Move Items from from game to Chain ====");

    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::game_item_to_chain_inventory`,
        arguments: [
            tx.object(storageUnit),
            tx.object(config.adminCapObjectId),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure.u64(volume),
            tx.pure.u32(quantity),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true },
    });

    const mintEvent = result.events?.find((event) =>
        event.type.endsWith("::inventory::ItemMintedEvent")
    );

    if (!mintEvent) {
        throw new Error("ItemMintedEvent not found in transaction result");
    }

    const eventData = mintEvent.parsedJson as { item_uid: string };
    const itemObjectId = eventData.item_uid;

    if (!itemObjectId) {
        throw new Error("Failed to get item UID from ItemMintedEvent");
    }

    console.log("Corpse objectId:", itemObjectId);

    console.log("TypeId of the item: ", typeId);
    console.log("ItemId of the item: ", itemId);
}

async function main() {
    console.log("============= Deposit Corse ==============\n");

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;
        const playerAddress = process.env.PLAYER_A_ADDRESS || "";

        if (!exportedKey) {
            throw new Error(
                "PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = loadKeypair(exportedKey);
        const config = getConfig(network);

        const adminAddress = keypair.getPublicKey().toSuiAddress();

        console.log("Network:", network);
        console.log("Server address:", adminAddress);
        console.log("Player address:", playerAddress);

        await gameItemToChain(
            SHIP_INVENTORY_ID,
            ITEM_A_TYPE_ID,
            CORPSE_ITEM_ID,
            10n,
            10,
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
