import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { hexToBytes } from "../utils/helper";

const GATE_A_TYPE_ID = BigInt(Math.floor(Math.random() * 34535435) + 78);
const GATE_B_TYPE_ID = BigInt(Math.floor(Math.random() * 34535435) + 87);
const GATE_A_ITEM_ID = BigInt(Math.floor(Math.random() * 5675765) + 44);
const GATE_B_ITEM_ID = BigInt(Math.floor(Math.random() * 5675765) + 88);
const LOCATION_HASH = "0x16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049";
const MAX_JUMP_DISTANCE = 10000000n;

async function createGate(
    typeId: bigint,
    itemId: bigint,
    maxJumpDistance: bigint,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Create Gate ====");

    const tx = new Transaction();

    const [gate] = tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::create_gate`,
        arguments: [
            tx.object(config.adminCapObjectId),
            tx.pure.u64(typeId),
            tx.pure.u64(itemId),
            tx.pure.u64(maxJumpDistance),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    console.log("\nGate created: ", gate);

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::share_gate`,
        arguments: [gate, tx.object(config.adminCapObjectId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true },
    });

    console.log(result);

    const gateId = result.objectChanges?.find((change) => change.type === "created")?.objectId;

    if (!gateId) {
        throw new Error("Failed to create gate, object ID not found in transaction result");
    }

    console.log("Gate created:", gateId);
}

async function main() {
    console.log("============= Create Gate Creation example ==============\n");

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

        const adminAddress = keypair.getPublicKey().toSuiAddress();

        console.log("Network:", network);
        console.log("Server address:", adminAddress);

        const gateA = await createGate(
            GATE_A_TYPE_ID,
            GATE_A_ITEM_ID,
            MAX_JUMP_DISTANCE,
            client,
            keypair,
            config
        );
        const gateB = await createGate(
            GATE_B_TYPE_ID,
            GATE_B_ITEM_ID,
            MAX_JUMP_DISTANCE,
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
