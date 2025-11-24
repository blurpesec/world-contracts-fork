/// 3rd Party extension
module extension::storage_extension;

use extension::builder_token::{Self, BUILDER_TOKEN, Treasury};
use sui::coin;
use world::{authority::{Self, OwnerCap}, storage_unit::{Self, StorageUnit}};

const CORPS_TYPE_ID: u64 = 566789;

public struct CorpseXAuth has drop {}

public fun collect_corpse_bounty(
    ship: &mut StorageUnit,
    storage_unit: &mut StorageUnit,
    owner: &OwnerCap,
    treasury: &mut Treasury,
    ctx: &mut TxContext,
) {
    // Verify the corpse
    let corpse = ship.withdraw_by_owner(owner, CORPS_TYPE_ID, ctx);
    storage_unit.deposit_item(CorpseXAuth {}, corpse, ctx);

    builder_token::mint(
        builder_token::borrow_cap_mut(treasury),
        1_000_000_000 * 1,
        ctx.sender(),
        ctx,
    );
}
