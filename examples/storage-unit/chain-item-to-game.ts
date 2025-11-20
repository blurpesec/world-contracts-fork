import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { hexToBytes } from "../utils/helper";
import { findOwnerCapForObject } from "../utils/ownerCap";

const CLOCK_ID = "0x6";
const STORAGE_UNIT = "0xb78f2c84dbb71520c4698c4520bfca8da88ea8419b03d472561428cd1e3544e8";
const ITEM_A_TYPE_ID = 10n;
const LOCATION_HASH = "0x16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049";
const PROOF =
    "0x93d3209c7f138aded41dcb008d066ae872ed558bd8dcb562da47d4ef782953330cf028f916c9992b2c4f3e05d3a82a9d2355c5eece712429877315c122be2dd3b78f2c84dbb71520c4698c4520bfca8da88ea8419b03d472561428cd1e3544e82016217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc04900000000000000000000000000000000000000000000000000000000000000020000000000000000005fd1ef9d9a0100006100a147607a02a2ce13f103e44ee7c21ec0d48d93ce0a0a9bccd9ddc8d782e6cb84e8d9364dc1d1741d4aa18722f2b062f8947b17274906b0cca6fd5f439f305701a94e21ea26cc336019c11a5e10c4b39160188dda0f6b4bfe198dd689db8f3df9";

async function gameItemToChain(
    storageUnit: string,
    locationProof: string, //?
    itemId: bigint,
    quantity: number,
    playerAddress: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Move Items from from Chain to Game ====");

    const ownerCap = await findOwnerCapForObject(
        client,
        playerAddress,
        storageUnit,
        config.packageId
    );

    if (!ownerCap) {
        throw new Error(`ownerCap not found for storage unit ${storageUnit}. `);
    }

    console.log("OwnerCap:", ownerCap);

    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::chain_item_to_game_inventory`,
        arguments: [
            tx.object(storageUnit),
            tx.object(config.serverAddressRegistry),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(locationProof))),
            tx.object(ownerCap),
            tx.pure.u64(itemId),
            tx.pure.u32(quantity),
            tx.object(CLOCK_ID),
        ],
    });

    const devInspectResult = await client.devInspectTransactionBlock({
        transactionBlock: tx,
        sender: playerAddress,
    });

    console.log("Dev inspect status:", devInspectResult.effects.status.status);
    if (devInspectResult.effects.status.status === "failure") {
        console.log("Dev inspect results:", devInspectResult);
    } else {
        console.log("Dev inspect results:", devInspectResult.results);
        console.log("Dev inspect events:", devInspectResult.events);
    }
    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true },
    });

    // Find the ItemBurnedEvent and extract the item_uid
    const burnEvent = result.events?.find((event) =>
        event.type.endsWith("::inventory::ItemBurnedEvent")
    );

    if (!burnEvent) {
        throw new Error("ItemBurnedEvent not found in transaction result");
    }

    // Type the parsed event data to access item_uid
    const eventData = burnEvent.parsedJson as { item_id: string };
    const itemObjectId = eventData.item_id;

    if (!itemObjectId) {
        throw new Error("Failed to get item UID from ItemBurnedEvent");
    }

    console.log("Item burned on-chain with objectId:", itemObjectId);
}

async function main() {
    console.log("============= Move Items from chain to game example ==============\n");

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PLAYER_A_PRIVATE_KEY;

        if (!exportedKey) {
            throw new Error(
                "PLAYER_A_PRIVATE_KEY environment variable is required eg: PLAYER_A_PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = loadKeypair(exportedKey);
        const config = getConfig(network);

        const playerAddress = keypair.getPublicKey().toSuiAddress();

        console.log("Network:", network);
        console.log("Player address:", playerAddress);

        await gameItemToChain(
            STORAGE_UNIT,
            PROOF,
            ITEM_A_TYPE_ID,
            10,
            playerAddress,
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
