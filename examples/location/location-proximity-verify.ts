import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { blake2b } from "@noble/hashes/blake2b";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { signPersonalMessage, toHex } from "../crypto/signMessage";

const CLOCK_ID = "0x6";
const DEADLINE_BUFFER_MS = 60000; // 1 minute
const TEST_STRUCTURE_B_ID = "0x0000000000000000000000000000000000000000000000000000000000000002";
const TEST_STORAGE_UNIT_TYPE_ID = 10000234n;
const TEST_STORAGE_UNIT_ITEM_ID = 1n;
const TEST_STORAGE_UNIT_MAX_CAPACITY = 10000000n;

// BCS schema for Location Message
const LocationMessage = bcs.struct("Message", {
    from: bcs.Address,
    to: bcs.Address,
    structure_a_id: bcs.Address,
    location_a_hash: bcs.vector(bcs.u8()),
    structure_b_id: bcs.Address,
    distance: bcs.u64(),
    data: bcs.vector(bcs.u8()),
    deadline_ms: bcs.u64(),
});

// Typed interface for type safety
interface LocationMessageData {
    from: string;
    to: string;
    structure_a_id: string;
    location_a_hash: Uint8Array;
    structure_b_id: string;
    distance: bigint;
    data: number[];
    deadline_ms: bigint;
}

function createLocationHashFromCoordinates(
    solarSystemId: number,
    x: number,
    y: number,
    z: number
): Uint8Array {
    // Serialize coordinates into a byte array
    // Format: solarSystemId (8 bytes) + x (8 bytes) + y (8 bytes) + z (8 bytes)
    const buffer = new ArrayBuffer(32);
    const view = new DataView(buffer);

    // Convert numbers to bigint for proper 64-bit handling
    view.setBigUint64(0, BigInt(solarSystemId), true); // little-endian
    view.setBigUint64(8, BigInt(Math.floor(x)), true);
    view.setBigUint64(16, BigInt(Math.floor(y)), true);
    view.setBigUint64(24, BigInt(Math.floor(z)), true);

    const coordinatesBytes = new Uint8Array(buffer);

    return blake2b(coordinatesBytes, { dkLen: 32 });
}

function createLocationMessage(
    from: string,
    to: string,
    structureAId: string,
    structureBId: string,
    locationHash: Uint8Array,
    distance: bigint = 0n,
    data: string = ""
): LocationMessageData {
    const currentTime = Date.now();
    const deadline = currentTime + DEADLINE_BUFFER_MS;

    return {
        from,
        to,
        structure_a_id: structureAId,
        location_a_hash: locationHash,
        structure_b_id: structureBId,
        distance,
        data: Array.from(new TextEncoder().encode(data)),
        deadline_ms: BigInt(deadline),
    };
}

// Serializes and signs a location message.
async function signLocationMessage(
    message: LocationMessageData,
    keypair: Ed25519Keypair
): Promise<[Uint8Array, Uint8Array]> {
    const messageBytes = LocationMessage.serialize(message).toBytes();
    const fullSignature = await signPersonalMessage(messageBytes, keypair);

    return [messageBytes, fullSignature];
}

function logSignatureDetails(fullSignature: Uint8Array): void {
    console.log("Full signature (97 bytes):", toHex(fullSignature));
    console.log("  - Flag (1 byte):", toHex(fullSignature.slice(0, 1)));
    console.log("  - Signature (64 bytes):", toHex(fullSignature.slice(1, 65)));
    console.log("  - Public key (32 bytes):", toHex(fullSignature.slice(65, 97)));
}

async function createStorageUnit(
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>,
    locationHash: Uint8Array
): Promise<string> {
    console.log("\n=== Creating Storage Unit ===");

    const tx = new Transaction();

    const [storageUnit] = tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::create_storage_unit`,
        arguments: [
            tx.object(config.adminCapObjectId),
            tx.pure.u64(TEST_STORAGE_UNIT_TYPE_ID),
            tx.pure.u64(TEST_STORAGE_UNIT_ITEM_ID),
            tx.pure.u64(TEST_STORAGE_UNIT_MAX_CAPACITY),
            tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(locationHash))),
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

    console.log("Storage unit created:", storageUnitId);
    return storageUnitId;
}

async function verifyProximity(
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>,
    storageUnitId: string,
    message: LocationMessageData,
    fullSignature: Uint8Array,
    senderAddress: string
): Promise<boolean> {
    console.log("\n=== Verifying Proximity ===");

    const tx = new Transaction();

    // Construct proof
    const [proof] = tx.moveCall({
        target: `${config.packageId}::${MODULES.LOCATION}::construct_message_proof`,
        arguments: [
            tx.pure.address(message.from),
            tx.pure.address(message.to),
            tx.pure.address(message.structure_a_id),
            tx.pure(bcs.vector(bcs.u8()).serialize(message.location_a_hash)),
            tx.pure.address(message.structure_b_id),
            tx.pure.u64(message.distance),
            tx.pure(bcs.vector(bcs.u8()).serialize(message.data)),
            tx.pure.u64(message.deadline_ms),
            tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(fullSignature))),
        ],
    });

    // Verify proximity - this returns a bool
    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::verify_storage_proximity`,
        arguments: [tx.object(storageUnitId), proof, tx.object(CLOCK_ID)],
    });

    // Using devInspectTransactionBlock to read the return value
    // Note: This simulates the transaction without executing it, use `signAndExecuteTransaction` for execution
    const inspectResult = await client.devInspectTransactionBlock({
        transactionBlock: tx,
        sender: senderAddress,
    });

    if (inspectResult.effects.status.status !== "success") {
        console.error("Verification transaction failed:", inspectResult.effects.status.error);
        return false;
    }

    // Extract the boolean return value from the second moveCall (index 1)
    const returnValues = inspectResult.results?.[1]?.returnValues;

    if (returnValues && returnValues.length > 0) {
        // Move bool is encoded as u8: 1 = true, 0 = false
        const verificationResult = returnValues[0][0][0];
        const isValid = verificationResult === 1;

        console.log("Verification result:", isValid ? "PASSED" : "FAILED");
        return isValid;
    } else {
        console.warn("Could not read return value from verification");
        return false;
    }
}

async function main() {
    console.log("=== Location Proximity Verification example ===\n");
    console.log(
        "!!For this example to work, the contract needs to be deployed using `pnpm run deploy` first !!\n"
    );

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;

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
        const playerAddress = adminAddress; // In real scenario, this would be the player's address

        console.log("Network:", network);
        console.log("Server address:", adminAddress);
        console.log("Player address:", playerAddress);

        // Use Blake2b hash of coordinates (example coordinates)
        const locationHash = createLocationHashFromCoordinates(
            1, // solarSystemId
            100, // x coordinate
            200, // y coordinate
            300 // z coordinate
        );
        console.log("\nLocation hash:", toHex(locationHash));

        // Step 1. Create storage unit
        const storageUnitId = await createStorageUnit(client, keypair, config, locationHash);

        // Step 2. Construct message to sign and authorise a location proximity
        console.log("\n=== Constructing Location Message ===");
        const message = createLocationMessage(
            adminAddress,
            playerAddress,
            storageUnitId,
            TEST_STRUCTURE_B_ID,
            locationHash
        );

        console.log("Message details:");
        console.log("  - From:", message.from);
        console.log("  - To:", message.to);
        console.log("  - Structure A ID:", message.structure_a_id);
        console.log("  - Structure B ID:", message.structure_b_id);
        console.log("  - Location hash:", toHex(message.location_a_hash));
        console.log("  - Distance:", message.distance.toString());
        console.log("  - Data:", toHex(new Uint8Array(message.data)));
        console.log("  - Deadline (ms):", message.deadline_ms.toString());

        const [messageBytes, fullSignature] = await signLocationMessage(message, keypair);

        console.log("\nSerialized message hex:", toHex(messageBytes));
        logSignatureDetails(fullSignature);

        // Verify proximity
        const isValid = await verifyProximity(
            client,
            keypair,
            config,
            storageUnitId,
            message,
            fullSignature,
            playerAddress
        );

        if (isValid) {
            console.log("\n=== Location verification completed successfully ===");
        } else {
            console.log("\n=== Location verification failed ===");
            process.exit(1);
        }
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
