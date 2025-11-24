import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";
import { hexToBytes } from "../utils/helper";

const GATE_A_ID = "0xb4a7a5ff9ee205b4be67db5d61506b8d0d0a4fc85d5cd78e3f73d7161f9ab3dd";
const GATE_B_ID = "0xddbfce7ef9cbf43c25122fd654430cf178b4b1fec1aada249b8b0647a280ca23";
const EXTENSION_PACKAGE_ID = "0x7e14978d020b162690f550385f8a347a732e73e70190ecc4fe0c7091507590c2";
const TREASURY_CAP_ID = "0x3eee3bb39cc9a29a85a3b99d4abf1f398127ec2f5b70fd469f7c095b52c302b5";

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
        throw new Error(
            "The Gate refuses to activate! You lack the Builder's Token required to traverse the void between worlds."
        );
    }

    console.log(`Found ${coins.data.length} SLAY coin(s)`);
    const slayCoinId = coins.data[0].coinObjectId;

    tx.moveCall({
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
