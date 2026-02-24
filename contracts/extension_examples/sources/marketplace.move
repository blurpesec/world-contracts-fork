/// Simple marketplace extension demonstrating `deposit_to_owned` and `withdraw_from_owned`.
///
/// Flow:
/// 1. Seller (SSU owner) places items in the main inventory and authorizes MarketAuth.
/// 2. Buyer calls `buy_item`, providing their payment from ephemeral storage.
///    The extension:
///    - Withdraws the listed item from main inventory
///    - Withdraws the buyer's payment from their ephemeral inventory
///    - Deposits the payment into the seller's ephemeral inventory (async, seller can be offline)
///    - Deposits the purchased item into the buyer's ephemeral inventory
///
/// No AdminACL required — fully usable by external (non-operator-sponsored) extensions.
module extension_examples::marketplace;

use world::{
    access::OwnerCap,
    character::Character,
    storage_unit::StorageUnit,
};

public struct MarketAuth has drop {}

public fun market_auth(): MarketAuth { MarketAuth {} }

/// Buyer purchases an item from the main inventory.
/// `seller_owner_cap_id` is the Character OwnerCap ID of the seller
/// so the extension can push the payment into the seller's ephemeral inventory.
public fun buy_item<T: key>(
    storage_unit: &mut StorageUnit,
    buyer_character: &Character,
    seller_owner_cap_id: ID,
    buyer_owner_cap: &OwnerCap<T>,
    listed_type_id: u64,
    payment_type_id: u64,
    ctx: &mut TxContext,
) {
    // 1. Withdraw the listed item from main inventory (extension access)
    let (listed_item, listed_location) = storage_unit.withdraw_item<MarketAuth>(
        buyer_character,
        MarketAuth {},
        listed_type_id,
        ctx,
    );

    // 2. Withdraw buyer's payment from their ephemeral inventory (owner + extension access)
    let (payment, payment_location) = storage_unit.withdraw_from_owned<MarketAuth, T>(
        buyer_character,
        buyer_owner_cap,
        MarketAuth {},
        payment_type_id,
        ctx,
    );

    // 3. Deposit payment into seller's ephemeral inventory (seller can be offline)
    storage_unit.deposit_to_owned<MarketAuth>(
        buyer_character,
        seller_owner_cap_id,
        payment,
        payment_location,
        MarketAuth {},
        ctx,
    );

    // 4. Deposit purchased item into buyer's ephemeral inventory
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
