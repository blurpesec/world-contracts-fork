import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, loadKeypair } from "../utils/client";

const STORAGE_UNIT_ID = "0xf24567f0aa6aa62720c6889df730b94430c882353a3f2d324fb216e74f9b41de";
const ITEM_OBJECT_ID = "0x25bd5a4c2599b8ad971153d216208e84bba2a153059174abae63ad328cd1f3f5";

async function main() {
    console.log("============= Create example ==============\n");

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
