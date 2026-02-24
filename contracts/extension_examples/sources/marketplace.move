/// Simple marketplace extension demonstrating `withdraw_from_owned`, `deposit_to_owned`,
/// `withdraw_item`, and `deposit_item`.
///
/// Any player with an ephemeral inventory on the storage unit can trade.
/// The SSU owner's only role is authorizing MarketAuth.
///
/// Flow:
/// 1. Seller calls `list_item` to move an item from their ephemeral into main inventory.
/// 2. Buyer calls `buy_item` (seller can be offline):
///    - Withdraws the listed item from main
///    - Withdraws the buyer's payment from their ephemeral
///    - Deposits the payment into the seller's ephemeral
///    - Deposits the purchased item into the buyer's ephemeral
///
/// No AdminACL required -- fully usable by external (non-operator-sponsored) extensions.
module extension_examples::marketplace;

use world::{
    access::OwnerCap,
    character::Character,
    storage_unit::StorageUnit,
};

public struct MarketAuth has drop {}

public fun market_auth(): MarketAuth { MarketAuth {} }

/// Seller lists an item by moving it from their ephemeral inventory into main.
public fun list_item<T: key>(
    storage_unit: &mut StorageUnit,
    seller_character: &Character,
    seller_owner_cap: &OwnerCap<T>,
    type_id: u64,
    ctx: &mut TxContext,
) {
    let (item, item_location) = storage_unit.withdraw_from_owned<MarketAuth, T>(
        seller_character,
        seller_owner_cap,
        MarketAuth {},
        type_id,
        ctx,
    );

    storage_unit.deposit_item<MarketAuth>(
        seller_character,
        item,
        item_location,
        MarketAuth {},
        ctx,
    );
}

/// Buyer purchases a listed item from main inventory.
/// `seller_owner_cap_id` identifies the seller's ephemeral inventory for payment delivery.
public fun buy_item<T: key>(
    storage_unit: &mut StorageUnit,
    buyer_character: &Character,
    seller_owner_cap_id: ID,
    buyer_owner_cap: &OwnerCap<T>,
    listed_type_id: u64,
    payment_type_id: u64,
    ctx: &mut TxContext,
) {
    let (listed_item, listed_location) = storage_unit.withdraw_item<MarketAuth>(
        buyer_character,
        MarketAuth {},
        listed_type_id,
        ctx,
    );

    let (payment, payment_location) = storage_unit.withdraw_from_owned<MarketAuth, T>(
        buyer_character,
        buyer_owner_cap,
        MarketAuth {},
        payment_type_id,
        ctx,
    );

    storage_unit.deposit_to_owned<MarketAuth>(
        buyer_character,
        seller_owner_cap_id,
        payment,
        payment_location,
        MarketAuth {},
        ctx,
    );

    let buyer_owner_cap_id = object::id(buyer_owner_cap);
    storage_unit.deposit_to_owned<MarketAuth>(
        buyer_character,
        buyer_owner_cap_id,
        listed_item,
        listed_location,
        MarketAuth {},
        ctx,
    );
}
