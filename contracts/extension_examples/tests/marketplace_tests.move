#[test_only]
module extension_examples::marketplace_tests;

use std::string::utf8;
use std::unit_test::assert_eq;
use sui::{clock, test_scenario as ts};
use world::{
    access::{OwnerCap, AdminACL},
    character::{Self, Character},
    energy::EnergyConfig,
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    storage_unit::{Self, StorageUnit},
};
use extension_examples::marketplace::{Self, MarketAuth};

const OWNER_ITEM_ID: u32 = 1000u32;
const SELLER_ITEM_ID: u32 = 1234u32;
const BUYER_ITEM_ID: u32 = 5678u32;
const LOCATION_HASH: vector<u8> = x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const MAX_CAPACITY: u64 = 100000;
const STORAGE_TYPE_ID: u64 = 5555;
const STORAGE_ITEM_ID: u64 = 90002;

const LENS_TYPE_ID: u64 = 88070;
const LENS_ITEM_ID: u64 = 1000004145108;
const LENS_VOLUME: u64 = 50;
const LENS_QUANTITY: u32 = 5;

const AMMO_TYPE_ID: u64 = 88069;
const AMMO_ITEM_ID: u64 = 1000004145107;
const AMMO_VOLUME: u64 = 100;
const AMMO_QUANTITY: u32 = 10;

const MS_PER_SECOND: u64 = 1000;
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
const MAX_PRODUCTION: u64 = 100;
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;

fun governor(): address { @0xA }
fun admin(): address { @0xB }
fun owner(): address { @0xC }
fun seller(): address { @0xD }
fun buyer(): address { @0xE }

fun setup_world(ts: &mut ts::Scenario) {
    world::test_helpers::setup_world(ts);
    world::test_helpers::configure_assembly_energy(ts);
    world::test_helpers::register_server_address(ts);
}

fun create_character(ts: &mut ts::Scenario, user: address, item_id: u32): ID {
    ts::next_tx(ts, admin());
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = character::create_character(
        &mut registry,
        &admin_acl,
        item_id,
        utf8(b"tenant"),
        100,
        user,
        utf8(b"name"),
        ts.ctx(),
    );
    let id = object::id(&character);
    character.share_character(&admin_acl, ts.ctx());
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    id
}

fun create_storage_unit(ts: &mut ts::Scenario, character_id: ID): (ID, ID) {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);

    let nwn = network_node::anchor(
        &mut registry,
        &character,
        &admin_acl,
        NWN_ITEM_ID,
        NWN_TYPE_ID,
        LOCATION_HASH,
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let nwn_id = object::id(&nwn);
    nwn.share_network_node(&admin_acl, ts.ctx());

    ts::return_shared(character);
    ts::return_shared(admin_acl);
    ts::return_shared(registry);

    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let storage_unit_id = {
        let admin_acl = ts::take_shared<AdminACL>(ts);
        let storage_unit = storage_unit::anchor(
            &mut registry,
            &mut nwn,
            &character,
            &admin_acl,
            STORAGE_ITEM_ID,
            STORAGE_TYPE_ID,
            MAX_CAPACITY,
            LOCATION_HASH,
            ts.ctx(),
        );
        let id = object::id(&storage_unit);
        storage_unit.share_storage_unit(&admin_acl, ts.ctx());
        ts::return_shared(admin_acl);
        id
    };
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(nwn);
    (storage_unit_id, nwn_id)
}

fun online_storage_unit(
    ts: &mut ts::Scenario,
    user: address,
    character_id: ID,
    storage_id: ID,
    nwn_id: ID,
) {
    let clock = clock::create_for_testing(ts.ctx());
    ts::next_tx(ts, user);
    let mut character = ts::take_shared_by_id<Character>(ts, character_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<NetworkNode>(
        ts::most_recent_receiving_ticket<OwnerCap<NetworkNode>>(&character_id),
        ts.ctx(),
    );
    ts::next_tx(ts, user);
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        nwn.deposit_fuel_test(&owner_cap, FUEL_TYPE_ID, FUEL_VOLUME, 10, &clock);
        ts::return_shared(nwn);
    };
    ts::next_tx(ts, user);
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        nwn.online(&owner_cap, &clock);
        ts::return_shared(nwn);
    };
    character.return_owner_cap(owner_cap, receipt);

    ts::next_tx(ts, user);
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(ts);
        let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_id),
            ts.ctx(),
        );
        storage_unit.online(&mut nwn, &energy_config, &owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(storage_unit);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::return_shared(character);
    clock.destroy_for_testing();
}

/// Async marketplace test with three independent players:
/// - Owner: creates and onlines the SSU, authorizes MarketAuth (never trades)
/// - Seller: has Lens in ephemeral, lists them for sale, then goes offline
/// - Buyer: has Ammo in ephemeral, buys Lens while seller is offline
#[test]
fun test_async_marketplace_trade() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
    let seller_id = create_character(&mut ts, seller(), SELLER_ITEM_ID);
    let buyer_id = create_character(&mut ts, buyer(), BUYER_ITEM_ID);

    // Owner creates, onlines, and authorizes MarketAuth on the storage unit
    let (storage_id, nwn_id) = create_storage_unit(&mut ts, owner_id);
    online_storage_unit(&mut ts, owner(), owner_id, storage_id, nwn_id);

    ts::next_tx(&mut ts, owner());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
            ts.ctx(),
        );
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        storage_unit.authorize_extension<MarketAuth>(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit);
    };

    // Seller: mint Lens into their ephemeral inventory (using Character OwnerCap)
    ts::next_tx(&mut ts, seller());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, seller_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&seller_id),
            ts.ctx(),
        );
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        storage_unit.game_item_to_chain_inventory_test<Character>(
            &character, &owner_cap,
            LENS_ITEM_ID, LENS_TYPE_ID, LENS_VOLUME, LENS_QUANTITY,
            ts.ctx(),
        );
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit);
    };

    // Buyer: mint Ammo into their ephemeral inventory
    ts::next_tx(&mut ts, buyer());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, buyer_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&buyer_id),
            ts.ctx(),
        );
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        storage_unit.game_item_to_chain_inventory_test<Character>(
            &character, &owner_cap,
            AMMO_ITEM_ID, AMMO_TYPE_ID, AMMO_VOLUME, AMMO_QUANTITY,
            ts.ctx(),
        );
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit);
    };

    // Resolve OwnerCap IDs for assertions and the buy_item call
    let seller_owner_cap_id = {
        ts::next_tx(&mut ts, admin());
        let c = ts::take_shared_by_id<Character>(&ts, seller_id);
        let id = c.owner_cap_id();
        ts::return_shared(c);
        id
    };
    let buyer_owner_cap_id = {
        ts::next_tx(&mut ts, admin());
        let c = ts::take_shared_by_id<Character>(&ts, buyer_id);
        let id = c.owner_cap_id();
        ts::return_shared(c);
        id
    };
    let storage_owner_cap_id = {
        ts::next_tx(&mut ts, admin());
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let id = su.owner_cap_id();
        ts::return_shared(su);
        id
    };

    // Seller lists Lens (moves from ephemeral -> main)
    ts::next_tx(&mut ts, seller());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut seller_char = ts::take_shared_by_id<Character>(&ts, seller_id);
        let (owner_cap, receipt) = seller_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&seller_id),
            ts.ctx(),
        );

        marketplace::list_item(
            &mut storage_unit, &seller_char, &owner_cap, LENS_TYPE_ID, ts.ctx(),
        );

        seller_char.return_owner_cap(owner_cap, receipt);
        ts::return_shared(seller_char);
        ts::return_shared(storage_unit);
    };

    // Assert: Lens moved from seller's ephemeral to main
    ts::next_tx(&mut ts, admin());
    {
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        assert_eq!(su.item_quantity(storage_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
        assert!(!su.contains_item(seller_owner_cap_id, LENS_TYPE_ID));
        assert_eq!(su.item_quantity(buyer_owner_cap_id, AMMO_TYPE_ID), AMMO_QUANTITY);
        ts::return_shared(su);
    };

    // Buyer executes the trade (seller is offline!)
    ts::next_tx(&mut ts, buyer());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut buyer_char = ts::take_shared_by_id<Character>(&ts, buyer_id);
        let (owner_cap, receipt) = buyer_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&buyer_id),
            ts.ctx(),
        );

        marketplace::buy_item(
            &mut storage_unit,
            &buyer_char,
            seller_owner_cap_id,
            &owner_cap,
            LENS_TYPE_ID,
            AMMO_TYPE_ID,
            ts.ctx(),
        );

        buyer_char.return_owner_cap(owner_cap, receipt);
        ts::return_shared(buyer_char);
        ts::return_shared(storage_unit);
    };

    // After trade assertions
    ts::next_tx(&mut ts, admin());
    {
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);

        // Main inventory: empty
        assert!(!su.contains_item(storage_owner_cap_id, LENS_TYPE_ID));
        assert!(!su.contains_item(storage_owner_cap_id, AMMO_TYPE_ID));

        // Buyer's ephemeral: has Lens, no more Ammo
        assert_eq!(su.item_quantity(buyer_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
        assert!(!su.contains_item(buyer_owner_cap_id, AMMO_TYPE_ID));

        // Seller's ephemeral: has Ammo (payment received while offline)
        assert_eq!(su.item_quantity(seller_owner_cap_id, AMMO_TYPE_ID), AMMO_QUANTITY);
        assert!(!su.contains_item(seller_owner_cap_id, LENS_TYPE_ID));

        ts::return_shared(su);
    };

    ts::end(ts);
}
