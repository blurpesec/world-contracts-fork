/// 3rd Party extension
module extension::storage_extension;

use extension::builder_token::{Self, BUILDER_TOKEN};
use sui::coin::{Self, TreasuryCap};
use world::{authority::{Self, OwnerCap}, storage_unit::{Self, StorageUnit}};

const CORPS_TYPE_ID: u64 = 566789;

public struct CorpseXAuth has drop {}

public fun mint_nft_for_corpse(
    ship: &mut StorageUnit,
    storage_unit: &mut StorageUnit,
    owner: &OwnerCap,
    treasury: &mut coin::TreasuryCap<BUILDER_TOKEN>,
    ctx: &mut TxContext,
) {
    // assert if he has these tokens

    // Verify the corpse
    let corpse = ship.withdraw_by_owner(owner, CORPS_TYPE_ID, ctx);
    storage_unit.deposit_item(CorpseXAuth {}, corpse, ctx);

    // Mint nft
    builder_token::mint(treasury, 1_000_000_000 * 1, ctx.sender(), ctx);
}
