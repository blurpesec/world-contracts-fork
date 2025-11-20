import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { hexToBytes } from "../utils/helper";

const GATE_A_ID = "0x5cf64c96cfe536fbe2213d69f9ebb0b464fd225c1c31b2dc0ffe60ccc5f32242";
const GATE_B_ID = "0x7d29f93f14c95c445caaabe4ef8b36e0802e3879d48c960c0b981ff402b6ac1d";
const EXTENSION_PACKAGE_ID = "0x224a9522433fe22ad3df25628579512acf21e3f66411d1c54133a917f8523844";
const TREASURY_CAP_ID = "0x0d2c582a35a6b3959857ba63dcde18b17850084d3878ae3bd248239aa868a48d";

async function jump(
    gateAId: string,
    gateBId: string,
    extensionPackageId: string,
    treasuryCapId: string,
    playerAddress: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Jump Through Gate ====");

    const tx = new Transaction();

    const slayTokenType = `${extensionPackageId}::builder_token::BUILDER_TOKEN`;
    const coins = await client.getCoins({
        owner: playerAddress,
        coinType: slayTokenType,
    });

    if (coins.data.length === 0) {
        throw new Error("No SLAY tokens found. You need SLAY tokens to jump!");
    }

    console.log(`Found ${coins.data.length} SLAY coin(s)`);
    const slayCoinId = coins.data[0].coinObjectId;

    const canJump = tx.moveCall({
        target: `${extensionPackageId}::gate_extension::jump`,
        arguments: [
            tx.object(gateAId),
            tx.object(gateBId),
            tx.object(slayCoinId),
            tx.object(treasuryCapId),
        ],
    });

    const devInspectResult = await client.devInspectTransactionBlock({
        transactionBlock: tx,
        sender: playerAddress,
    });

    console.log("Status:", devInspectResult.effects.status.status);

    if (devInspectResult.effects.status.status === "failure") {
        console.log("Error:", devInspectResult.effects.status.error);
        throw new Error("Transaction would fail: " + devInspectResult.effects.status.error);
    }

    // The return value is in the results array
    if (devInspectResult.results && devInspectResult.results.length > 0) {
        const returnValues = devInspectResult.results[0].returnValues;
        if (returnValues && returnValues.length > 0) {
            const [canJumpBytes, canJumpType] = returnValues[0];
            const canJumpValue = canJumpBytes[0] === 1;
            console.log("canJump return value:", canJumpValue);
        }
    }

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("result", result);

    if (result.effects?.status?.status === "success") {
        console.log("Transaction digest:", result.digest);

        if (result.events) {
            console.log("\nEvents emitted:");
            result.events.forEach((event: any) => {
                console.log("  Event type:", event.type);
                console.log("  Event data:", event.parsedJson);
            });
        }
    } else {
        console.log("Error:", result.effects?.status);
    }

    return result;
}

async function main() {
    console.log("============= Jump Through Gate Example ==============\n");

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

        const playerAddress = keypair.getPublicKey().toSuiAddress();

        console.log("Network:", network);
        console.log("Player address:", playerAddress);
        console.log("Gate A ID:", GATE_A_ID);
        console.log("Gate B ID:", GATE_B_ID);
        console.log("Extension Package ID:", EXTENSION_PACKAGE_ID);
        console.log("Treasury Cap ID:", TREASURY_CAP_ID);

        await jump(
            GATE_A_ID,
            GATE_B_ID,
            EXTENSION_PACKAGE_ID,
            TREASURY_CAP_ID,
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
