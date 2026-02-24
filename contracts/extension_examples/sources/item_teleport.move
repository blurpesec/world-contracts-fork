module extension_examples::item_teleport;

use world::character::Character;
use world::storage_unit::{Self, StorageUnit};

/// Authorized extension witness type for item teleportation.
public struct TeleportAuth has drop {}

/// Builder extension example:
/// Teleport an item from one storage unit to another.
/// Demonstrates how to use the `Auth` witness extension pattern to authorize
/// custom logic to withdraw and deposit items on `StorageUnit`s.
public fun teleport_item(
    source_storage_unit: &mut StorageUnit,
    dest_storage_unit: &mut StorageUnit,
    character: &Character,
    type_id: u64,
    ctx: &mut TxContext,
) {
    // Withdraw the item from the source storage unit
    let (item, item_location) = storage_unit::withdraw_item<TeleportAuth>(
        source_storage_unit,
        character,
        TeleportAuth {},
        type_id,
        ctx,
    );

    // Deposit the item into the destination storage unit
    storage_unit::deposit_item<TeleportAuth>(
        dest_storage_unit,
        character,
        item,
        item_location,
        TeleportAuth {},
        ctx,
    );
}
