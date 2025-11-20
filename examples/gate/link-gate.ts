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

async function linkGate(
    gateAId: string,
    gateBId: string,
    playerAddress: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Link Gates ====");

    const tx = new Transaction();

    const [gate] = tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::link_gates`,
        arguments: [tx.object(gateAId), tx.object(gateBId)],
    });

    console.log("\nGate Linked: ", gate);

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true },
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
}

async function main() {
    console.log("============= Online and Link Gate Creation example ==============\n");

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

        // await online(GATE_A_ID, adminAddress, client, keypair, config);
        // await online(GATE_B_ID, adminAddress, client, keypair, config);

        await linkGate(GATE_A_ID, GATE_B_ID, adminAddress, client, keypair, config);
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
