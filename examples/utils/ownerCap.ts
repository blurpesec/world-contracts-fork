import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";

export async function findOwnerCapForObject(
    client: SuiClient,
    ownerAddress: string,
    ownedObjectId: string,
    packageId: string
): Promise<string | null> {
    console.log("Owner address:", ownerAddress);
    console.log("Looking for object:", ownedObjectId);

    const ownedObjects = await client.getOwnedObjects({
        owner: ownerAddress,
        filter: {
            StructType: `${packageId}::authority::OwnerCap`,
        },
        options: {
            showContent: true,
        },
    });

    // Find the OwnerCap that matches the owned object ID
    for (const obj of ownedObjects.data) {
        if (obj.data?.content?.dataType === "moveObject") {
            const fields = obj.data.content.fields as any;
            if (fields.owned_object_id === ownedObjectId) {
                return obj.data.objectId;
            }
        }
    }

    console.log("No matching OwnerCap found");
    return null;
}

export async function createOwnerCapForObject(
    objectId: string,
    playerAddress: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Creating a Owner Cap for ====", objectId);

    const tx = new Transaction();

    const [ownerCap] = tx.moveCall({
        target: `${config.packageId}::${MODULES.AUTHORITY}::create_owner_cap`,
        arguments: [tx.object(config.adminCapObjectId), tx.pure.address(objectId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.AUTHORITY}::transfer_owner_cap`,
        arguments: [ownerCap, tx.object(config.adminCapObjectId), tx.pure.address(playerAddress)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true },
    });

    console.log("\n====result====", result);

    // object id of the ownerCap
    const ownerCapId = result.objectChanges?.find((change) => change.type === "created")?.objectId;
    if (!ownerCapId) {
        throw new Error("object id was not found");
    }

    console.log("OwnerCap created", ownerCapId);

    console.log("Owner cap transferred to player address: ", playerAddress);
    console.log("\n", result.digest);
}
