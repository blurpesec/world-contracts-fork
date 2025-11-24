import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";

const GATE_A_ID = "0xb4a7a5ff9ee205b4be67db5d61506b8d0d0a4fc85d5cd78e3f73d7161f9ab3dd";
const GATE_B_ID = "0xddbfce7ef9cbf43c25122fd654430cf178b4b1fec1aada249b8b0647a280ca23";

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
    console.log("============= Online and Link Gate ==============\n");

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
