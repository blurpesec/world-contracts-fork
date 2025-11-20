import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { blake2b } from "@noble/hashes/blake2b";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { signPersonalMessage } from "../crypto/signMessage";
import { toHex, fromHex } from "../utils/helper";

const CLOCK_ID = "0x6";
const DEADLINE_BUFFER_MS = 60000 * 15; // 1 minute
const TEST_STRUCTURE_B_ID = "0x0000000000000000000000000000000000000000000000000000000000000002";
const STORAGE_UNIT_ID = "0xb78f2c84dbb71520c4698c4520bfca8da88ea8419b03d472561428cd1e3544e8";
const LOCATION_HASH = "0x16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049";

// BCS schema for Location Message
const LocationMessage = bcs.struct("LocationProofMessage", {
    server_address: bcs.Address,
    player_address: bcs.Address,
    target_structure_id: bcs.Address,
    target_location_hash: bcs.vector(bcs.u8()),
    player_structure_id: bcs.Address,
    distance: bcs.u64(),
    data: bcs.vector(bcs.u8()),
    deadline_ms: bcs.u64(),
});

// Typed interface for type safety
interface LocationMessageData {
    server_address: string;
    player_address: string;
    target_structure_id: string;
    target_location_hash: Uint8Array;
    player_structure_id: string;
    distance: bigint;
    data: number[];
    deadline_ms: bigint;
}

function createLocationMessage(
    serverAddress: string,
    playerAddress: string,
    targetStructureId: string,
    playerStructureId: string,
    locationHash: Uint8Array,
    distance: bigint = 0n,
    data: string = ""
): LocationMessageData {
    const currentTime = Date.now();
    const deadline = currentTime + DEADLINE_BUFFER_MS;

    return {
        server_address: serverAddress,
        player_address: playerAddress,
        target_structure_id: targetStructureId,
        target_location_hash: locationHash,
        player_structure_id: playerStructureId,
        distance,
        data: Array.from(new TextEncoder().encode(data)),
        deadline_ms: BigInt(deadline),
    };
}

// Serializes and signs a location message, returns proof bytes.
async function createLocationProofBytes(
    message: LocationMessageData,
    keypair: Ed25519Keypair
): Promise<Uint8Array> {
    // Step 1: Serialize the message
    const messageBytes = LocationMessage.serialize({
        server_address: message.server_address,
        player_address: message.player_address,
        target_structure_id: message.target_structure_id,
        target_location_hash: Array.from(message.target_location_hash),
        player_structure_id: message.player_structure_id,
        distance: message.distance,
        data: message.data,
        deadline_ms: message.deadline_ms,
    }).toBytes();

    // Step 2: Sign the message
    const fullSignature = await signPersonalMessage(messageBytes, keypair);

    // Step 3: Concatenate message bytes + signature bytes (flat structure)
    // This matches the unpack_proof() expectation in Move
    const signatureVec = bcs.vector(bcs.u8()).serialize(Array.from(fullSignature)).toBytes();

    const proofBytes = new Uint8Array(messageBytes.length + signatureVec.length);
    proofBytes.set(messageBytes, 0);
    proofBytes.set(signatureVec, messageBytes.length);

    return proofBytes;
}

async function main() {
    console.log("=== Location Proximity Verification example ===\n");
    console.log(
        "!!For this example to work, the contract needs to be deployed using `pnpm run deploy` first !!\n"
    );

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;
        const playerKey = process.env.PLAYER_A_PRIVATE_KEY;

        if (!exportedKey || !playerKey) {
            throw new Error(
                "PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = loadKeypair(exportedKey);
        const playerKeyPair = loadKeypair(playerKey);
        const config = getConfig(network);

        const adminAddress = keypair.getPublicKey().toSuiAddress();
        const playerAddress = playerKeyPair.getPublicKey().toSuiAddress(); // In real scenario, this would be the player's address

        console.log("Network:", network);
        console.log("Server address:", adminAddress);
        console.log("Player address:", playerAddress);

        console.log("\n=== Constructing Location Message ===");
        const message = createLocationMessage(
            adminAddress,
            playerAddress,
            STORAGE_UNIT_ID,
            TEST_STRUCTURE_B_ID,
            fromHex(LOCATION_HASH)
        );

        console.log("Message details:");
        console.log("  - Server address:", message.server_address);
        console.log("  - Player address:", message.player_address);
        console.log("  - Target structure ID:", message.target_structure_id);
        console.log("  - Location hash:", toHex(message.target_location_hash));
        console.log("  - Deadline (ms):", message.deadline_ms.toString());

        console.log("\n=== Creating Location Proof Bytes ===");
        const proofBytes = await createLocationProofBytes(message, keypair);

        console.log("Proof bytes hex:", toHex(proofBytes));
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
