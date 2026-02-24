#[test_only]
module extension_examples::item_teleport_tests;

use std::string::utf8;
use sui::{clock, test_scenario as ts};
use world::{
    access::{OwnerCap, AdminACL},
    character::{Self, Character},
    energy::EnergyConfig,
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    storage_unit::{Self, StorageUnit},
};
use extension_examples::item_teleport::{Self, TeleportAuth};

const CHARACTER_A_ITEM_ID: u32 = 1234u32;
const LOCATION_A_HASH: vector<u8> = x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const LOCATION_B_HASH: vector<u8> = x"8b9f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5c";
const MAX_CAPACITY: u64 = 100000;
const STORAGE_A_TYPE_ID: u64 = 5555;
const STORAGE_A_ITEM_ID: u64 = 90002;
const STORAGE_B_TYPE_ID: u64 = 5555;
const STORAGE_B_ITEM_ID: u64 = 90003;

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
fun user_a(): address { @0xC }

fun setup_world(ts: &mut ts::Scenario) {
    world::test_helpers::setup_world(ts);
    world::test_helpers::configure_assembly_energy(ts);
    world::test_helpers::register_server_address(ts);
}

fun create_network_node(ts: &mut ts::Scenario, character_id: ID, nwn_item_id: u64): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);

    let nwn = network_node::anchor(
        &mut registry,
        &character,
        &admin_acl,
        nwn_item_id,
        NWN_TYPE_ID,
        LOCATION_A_HASH,
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let id = object::id(&nwn);
    nwn.share_network_node(&admin_acl, ts.ctx());

    ts::return_shared(character);
    ts::return_shared(admin_acl);
    ts::return_shared(registry);
    id
}

fun create_storage_unit(
    ts: &mut ts::Scenario,
    character_id: ID,
    location: vector<u8>,
    item_id: u64,
    type_id: u64,
    nwn_item_id: u64,
): (ID, ID) {
    let nwn_id = create_network_node(ts, character_id, nwn_item_id);
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
            item_id,
            type_id,
            MAX_CAPACITY,
            location,
            ts.ctx(),
        );
        let storage_unit_id = object::id(&storage_unit);
        storage_unit.share_storage_unit(&admin_acl, ts.ctx());
        ts::return_shared(admin_acl);
        storage_unit_id
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
        nwn.deposit_fuel_test(
            &owner_cap,
            FUEL_TYPE_ID,
            FUEL_VOLUME,
            10,
            &clock,
        );
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

#[test]
fun test_teleport_item() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    
    // Create Character
    ts::next_tx(&mut ts, admin());
    let character_id = {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_acl,
            CHARACTER_A_ITEM_ID,
            utf8(b"tenant"),
            100,
            user_a(),
            utf8(b"name"),
            ts.ctx(),
        );
        let id = object::id(&character);
        character.share_character(&admin_acl, ts.ctx());
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
        id
    };

    // Create Storage Unit A
    let (storage_a_id, nwn_a_id) = create_storage_unit(
        &mut ts,
        character_id,
        LOCATION_A_HASH,
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
        NWN_ITEM_ID,
    );
    online_storage_unit(&mut ts, user_a(), character_id, storage_a_id, nwn_a_id);

    // Mint item into Storage Unit A
    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_id),
            ts.ctx(),
        );
        let mut storage_unit_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        
        storage_unit_a.game_item_to_chain_inventory_test<StorageUnit>(
            &character,
            &owner_cap,
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
            ts.ctx(),
        );
        
        // Approve Auth witness
        storage_unit_a.authorize_extension<TeleportAuth>(&owner_cap);
        
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit_a);
    };

    // Create Storage Unit B
    let (storage_b_id, nwn_b_id) = create_storage_unit(
        &mut ts,
        character_id,
        LOCATION_B_HASH,
        STORAGE_B_ITEM_ID,
        STORAGE_B_TYPE_ID,
        NWN_ITEM_ID + 1,
    );
    online_storage_unit(&mut ts, user_a(), character_id, storage_b_id, nwn_b_id);

    // Approve Auth witness for Storage Unit B
    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_id),
            ts.ctx(),
        );
        let mut storage_unit_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);
        
        storage_unit_b.authorize_extension<TeleportAuth>(&owner_cap);
        
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit_b);
    };

    // Call custom logic teleport_item
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let mut storage_unit_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        
        item_teleport::teleport_item(
            &mut storage_unit_a,
            &mut storage_unit_b,
            &character,
            AMMO_TYPE_ID,
            ts.ctx()
        );
        
        ts::return_shared(character);
        ts::return_shared(storage_unit_a);
        ts::return_shared(storage_unit_b);
    };

    ts::end(ts);
}
