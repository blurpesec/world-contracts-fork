import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    hydrateWorldConfig,
    initializeContext,
    handleError,
    getEnvConfig,
    shareHydratedConfig,
} from "../utils/helper";
import { executeSponsoredTransaction } from "../utils/transaction";
import {
    GAME_CHARACTER_ID,
    GAME_CHARACTER_B_ID,
    GAME_CHARACTER_C_ID,
    STORAGE_A_ITEM_ID,
    ITEM_A_TYPE_ID,
    ITEM_A_ITEM_ID,
} from "../utils/constants";
import { delay, getDelayMs } from "../utils/delay";
import { getCharacterOwnerCap } from "../character/helper";

async function gameItemToChain(
    storageUnit: string,
    characterId: string,
    ownerCapId: string,
    playerAddress: string,
    typeId: bigint,
    itemId: bigint,
    volume: bigint,
    quantity: number,
    adminAddress: string,
    client: SuiJsonRpcClient,
    playerKeypair: Ed25519Keypair,
    adminKeypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Move Items from from game to Chain ====");

    const tx = new Transaction();
    tx.setSender(playerAddress);
    tx.setGasOwner(adminAddress);

    const [ownerCap, receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.CHARACTER}::Character`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::game_item_to_chain_inventory`,
        typeArguments: [`${config.packageId}::${MODULES.CHARACTER}::Character`],
        arguments: [
            tx.object(storageUnit),
            tx.object(config.adminAcl),
            tx.object(characterId),
            ownerCap,
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure.u64(volume),
            tx.pure.u32(quantity),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.CHARACTER}::Character`],
        arguments: [tx.object(characterId), ownerCap, receipt],
    });

    const result = await executeSponsoredTransaction(
        tx,
        client,
        playerKeypair,
        adminKeypair,
        playerAddress,
        adminAddress,
        { showEvents: true }
    );

    console.log("Transaction digest:", result.digest);
    console.log("Item Id:", itemId);
}

async function depositForPlayer(
    envKeyName: string,
    gameCharacterId: number,
    label: string,
    ctx: ReturnType<typeof initializeContext>,
    env: ReturnType<typeof getEnvConfig>
) {
    const playerKey = process.env[envKeyName];
    if (!playerKey) {
        console.log(`Skipping ${label} — ${envKeyName} not set`);
        return;
    }

    const playerCtx = initializeContext(env.network, playerKey);
    shareHydratedConfig(ctx, playerCtx);
    const { client, keypair, config } = ctx;

    const playerAddress = playerCtx.address;
    const adminAddress = keypair.getPublicKey().toSuiAddress();

    const characterObject = deriveObjectId(
        config.objectRegistry,
        gameCharacterId,
        config.packageId
    );

    const storageUnit = deriveObjectId(
        config.objectRegistry,
        STORAGE_A_ITEM_ID,
        config.packageId
    );

    const characterOwnerCap = await getCharacterOwnerCap(
        characterObject,
        client,
        config,
        playerAddress
    );
    if (!characterOwnerCap) {
        throw new Error(`OwnerCap not found for ${label} (${characterObject})`);
    }

    console.log(`\n---- ${label} ----`);
    await gameItemToChain(
        storageUnit,
        characterObject,
        characterOwnerCap,
        playerAddress,
        ITEM_A_TYPE_ID,
        ITEM_A_ITEM_ID,
        10n,
        10,
        adminAddress,
        client,
        playerCtx.keypair,
        keypair,
        config
    );
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);

        const players: { envKey: string; gameCharacterId: number; label: string }[] = [
            { envKey: "PLAYER_A_PRIVATE_KEY", gameCharacterId: GAME_CHARACTER_ID, label: "Player A" },
            { envKey: "PLAYER_B_PRIVATE_KEY", gameCharacterId: GAME_CHARACTER_B_ID, label: "Player B" },
            { envKey: "PLAYER_C_PRIVATE_KEY", gameCharacterId: GAME_CHARACTER_C_ID, label: "Player C" },
        ];

        for (let i = 0; i < players.length; i++) {
            const p = players[i];
            await depositForPlayer(p.envKey, p.gameCharacterId, p.label, ctx, env);
            if (i < players.length - 1) await delay(getDelayMs());
        }
    } catch (error) {
        handleError(error);
    }
}

main();
