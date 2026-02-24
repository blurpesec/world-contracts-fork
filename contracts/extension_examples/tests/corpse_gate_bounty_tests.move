#[test_only]
module extension_examples::corpse_gate_bounty_tests;

use std::{bcs, string::utf8};
use std::unit_test::assert_eq;
use sui::{clock, test_scenario as ts};
use world::{
    access::{AdminACL, OwnerCap, ServerAddressRegistry},
    character::{Self, Character},
    energy::EnergyConfig,
    gate::{Self, Gate, GateConfig, JumpPermit},
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    storage_unit::{Self, StorageUnit},
    test_helpers,
};
use extension_examples::{
    config::{Self, XAuth, ExtensionConfig},
    corpse_gate_bounty,
};

const GATE_TYPE_ID: u64 = 8888;
const GATE_ITEM_ID_1: u64 = 7001;
const GATE_ITEM_ID_2: u64 = 7002;
const CHARACTER_ITEM_ID: u32 = 101;
const TRIBE_ID: u32 = 100;

const MS_PER_SECOND: u64 = 1000;
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
const MAX_PRODUCTION: u64 = 200;
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;

const STORAGE_TYPE_ID: u64 = 5555;
const STORAGE_ITEM_ID: u64 = 90002;
const MAX_CAPACITY: u64 = 100000;

const CORPSE_TYPE_ID: u64 = 77777;
const CORPSE_ITEM_ID: u64 = 1000004145200;
const CORPSE_VOLUME: u64 = 200;
const CORPSE_QUANTITY: u32 = 1;

fun setup(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
    test_helpers::configure_fuel(ts);
    test_helpers::configure_assembly_energy(ts);
    test_helpers::register_server_address(ts);

    ts::next_tx(ts, test_helpers::governor());
    gate::init_for_testing(ts.ctx());
    config::init_for_testing(ts.ctx());

    ts::next_tx(ts, test_helpers::admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(ts);
        let mut gate_config = ts::take_shared<GateConfig>(ts);
        gate::set_max_distance(&mut gate_config, &admin_acl, GATE_TYPE_ID, 1_000_000_000, ts.ctx());
        ts::return_shared(gate_config);
        ts::return_shared(admin_acl);
    };
}

fun create_character(ts: &mut ts::Scenario, user: address, item_id: u32, tribe_id: u32): ID {
    ts::next_tx(ts, test_helpers::admin());
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = character::create_character(
        &mut registry,
        &admin_acl,
        item_id,
        test_helpers::tenant(),
        tribe_id,
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

fun create_network_node(ts: &mut ts::Scenario, character_id: ID): ID {
    ts::next_tx(ts, test_helpers::admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let nwn = network_node::anchor(
        &mut registry,
        &character,
        &admin_acl,
        NWN_ITEM_ID,
        NWN_TYPE_ID,
        test_helpers::get_verified_location_hash(),
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let nwn_id = object::id(&nwn);
    nwn.share_network_node(&admin_acl, ts.ctx());
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    nwn_id
}

fun create_gate(ts: &mut ts::Scenario, character_id: ID, nwn_id: ID, item_id: u64): ID {
    ts::next_tx(ts, test_helpers::admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let gate_obj = gate::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
        item_id,
        GATE_TYPE_ID,
        test_helpers::get_verified_location_hash(),
        ts.ctx(),
    );
    let gate_id = object::id(&gate_obj);
    gate_obj.share_gate(&admin_acl, ts.ctx());
    ts::return_shared(character);
    ts::return_shared(nwn);
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    gate_id
}

fun create_storage_unit(ts: &mut ts::Scenario, character_id: ID, nwn_id: ID): ID {
    ts::next_tx(ts, test_helpers::admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let su = storage_unit::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
        STORAGE_ITEM_ID,
        STORAGE_TYPE_ID,
        MAX_CAPACITY,
        test_helpers::get_verified_location_hash(),
        ts.ctx(),
    );
    let su_id = object::id(&su);
    su.share_storage_unit(&admin_acl, ts.ctx());
    ts::return_shared(character);
    ts::return_shared(nwn);
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    su_id
}

fun bring_nwn_online(ts: &mut ts::Scenario, user: address, character_id: ID, nwn_id: ID) {
    ts::next_tx(ts, user);
    let clock = clock::create_for_testing(ts.ctx());
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let mut character = ts::take_shared_by_id<Character>(ts, character_id);
    let ticket = ts::receiving_ticket_by_id<OwnerCap<NetworkNode>>(nwn.owner_cap_id());
    let (owner_cap, receipt) = character.borrow_owner_cap<NetworkNode>(ticket, ts.ctx());
    nwn.deposit_fuel_test(&owner_cap, FUEL_TYPE_ID, FUEL_VOLUME, 50, &clock);
    nwn.online(&owner_cap, &clock);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(nwn);
    ts::return_shared(character);
    clock.destroy_for_testing();
}

fun online_storage_unit(
    ts: &mut ts::Scenario,
    user: address,
    character_id: ID,
    storage_id: ID,
    nwn_id: ID,
) {
    ts::next_tx(ts, user);
    let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let energy_config = ts::take_shared<EnergyConfig>(ts);
    let mut character = ts::take_shared_by_id<Character>(ts, character_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
        ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_id),
        ts.ctx(),
    );
    storage_unit.online(&mut nwn, &energy_config, &owner_cap);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(storage_unit);
    ts::return_shared(nwn);
    ts::return_shared(energy_config);
    ts::return_shared(character);
}

fun link_and_online_gates(
    ts: &mut ts::Scenario,
    user: address,
    character_id: ID,
    nwn_id: ID,
    gate_a_id: ID,
    gate_b_id: ID,
) {
    ts::next_tx(ts, user);
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(ts);
        let gate_config = ts::take_shared<GateConfig>(ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(ts);
        let admin_acl = ts::take_shared<AdminACL>(ts);
        let mut gate_a = ts::take_shared_by_id<Gate>(ts, gate_a_id);
        let mut gate_b = ts::take_shared_by_id<Gate>(ts, gate_b_id);
        let mut character = ts::take_shared_by_id<Character>(ts, character_id);

        let (owner_cap_a, receipt_a) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_a.owner_cap_id()),
            ts.ctx(),
        );
        let (owner_cap_b, receipt_b) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_b.owner_cap_id()),
            ts.ctx(),
        );

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let clock = clock::create_for_testing(ts.ctx());
        gate_a.link_gates(
            &mut gate_b,
            &character,
            &gate_config,
            &server_registry,
            &admin_acl,
            &owner_cap_a,
            &owner_cap_b,
            bcs::to_bytes(&proof),
            &clock,
            ts.ctx(),
        );

        gate_a.online(&mut nwn, &energy_config, &owner_cap_a);
        gate_b.online(&mut nwn, &energy_config, &owner_cap_b);

        clock.destroy_for_testing();
        character.return_owner_cap(owner_cap_a, receipt_a);
        character.return_owner_cap(owner_cap_b, receipt_b);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_shared(gate_config);
        ts::return_shared(server_registry);
        ts::return_shared(admin_acl);
    };
}

fun authorize_xauth_on_gate(ts: &mut ts::Scenario, user: address, character_id: ID, gate_id: ID) {
    ts::next_tx(ts, user);
    let mut gate_obj = ts::take_shared_by_id<Gate>(ts, gate_id);
    let mut character = ts::take_shared_by_id<Character>(ts, character_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Gate>(
        ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_obj.owner_cap_id()),
        ts.ctx(),
    );
    gate_obj.authorize_extension<XAuth>(&owner_cap);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(gate_obj);
}

fun authorize_xauth_on_storage_unit(
    ts: &mut ts::Scenario,
    user: address,
    character_id: ID,
    storage_id: ID,
) {
    ts::next_tx(ts, user);
    let mut character = ts::take_shared_by_id<Character>(ts, character_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
        ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_id),
        ts.ctx(),
    );
    let mut su = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
    su.authorize_extension<XAuth>(&owner_cap);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(su);
    ts::return_shared(character);
}

/// Player submits a corpse to the bounty, receives a JumpPermit, and jumps through the gate.
#[test]
fun test_collect_corpse_bounty_and_jump() {
    let mut ts = ts::begin(test_helpers::governor());
    setup(&mut ts);

    let user = test_helpers::user_a();
    let character_id = create_character(&mut ts, user, CHARACTER_ITEM_ID, TRIBE_ID);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);
    let storage_id = create_storage_unit(&mut ts, character_id, nwn_id);

    bring_nwn_online(&mut ts, user, character_id, nwn_id);
    online_storage_unit(&mut ts, user, character_id, storage_id, nwn_id);
    link_and_online_gates(&mut ts, user, character_id, nwn_id, gate_a_id, gate_b_id);
    authorize_xauth_on_gate(&mut ts, user, character_id, gate_a_id);
    authorize_xauth_on_gate(&mut ts, user, character_id, gate_b_id);
    authorize_xauth_on_storage_unit(&mut ts, user, character_id, storage_id);

    // Mint corpse into player's ephemeral inventory
    ts::next_tx(&mut ts, user);
    {
        let mut su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&character_id),
            ts.ctx(),
        );
        su.game_item_to_chain_inventory_test<Character>(
            &character, &owner_cap,
            CORPSE_ITEM_ID, CORPSE_TYPE_ID, CORPSE_VOLUME, CORPSE_QUANTITY,
            ts.ctx(),
        );
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(su);
    };

    // Configure bounty to accept CORPSE_TYPE_ID
    ts::next_tx(&mut ts, test_helpers::governor());
    {
        let mut ext_config = ts::take_shared<ExtensionConfig>(&ts);
        let config_admin_cap = ts::take_from_sender<config::AdminCap>(&ts);
        corpse_gate_bounty::set_bounty_type_id(&mut ext_config, &config_admin_cap, CORPSE_TYPE_ID);
        assert_eq!(corpse_gate_bounty::bounty_type_id(&ext_config), CORPSE_TYPE_ID);
        ts::return_to_sender(&ts, config_admin_cap);
        ts::return_shared(ext_config);
    };

    // Player collects bounty: withdraws corpse from ephemeral, deposits to main, gets JumpPermit
    ts::next_tx(&mut ts, user);
    {
        let ext_config = ts::take_shared<ExtensionConfig>(&ts);
        let mut su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&character_id),
            ts.ctx(),
        );
        let clock = clock::create_for_testing(ts.ctx());

        corpse_gate_bounty::collect_corpse_bounty(
            &ext_config,
            &mut su,
            &gate_a,
            &gate_b,
            &character,
            &admin_acl,
            &owner_cap,
            CORPSE_TYPE_ID,
            &clock,
            ts.ctx(),
        );

        clock.destroy_for_testing();
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(su);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(ext_config);
        ts::return_shared(admin_acl);
    };

    // Verify corpse moved to main inventory and player has a JumpPermit
    let _su_owner_cap_id = {
        ts::next_tx(&mut ts, test_helpers::admin());
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let id = su.owner_cap_id();
        assert_eq!(su.item_quantity(id, CORPSE_TYPE_ID), CORPSE_QUANTITY);
        ts::return_shared(su);
        id
    };

    // Jump through the gate using the permit
    ts::next_tx(&mut ts, user);
    {
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let permit = ts::take_from_address<JumpPermit>(&ts, user);
        let clock = clock::create_for_testing(ts.ctx());

        gate::test_jump_with_permit(&gate_a, &gate_b, &character, permit, &clock);

        clock.destroy_for_testing();
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(character);
    };

    ts::end(ts);
}

/// Bounty fails when corpse type doesn't match the configured bounty type
#[test]
#[expected_failure(abort_code = corpse_gate_bounty::ECorpseTypeMismatch)]
fun test_collect_corpse_bounty_fails_wrong_type() {
    let mut ts = ts::begin(test_helpers::governor());
    setup(&mut ts);

    let user = test_helpers::user_a();
    let character_id = create_character(&mut ts, user, CHARACTER_ITEM_ID + 1, TRIBE_ID);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);
    let storage_id = create_storage_unit(&mut ts, character_id, nwn_id);

    bring_nwn_online(&mut ts, user, character_id, nwn_id);
    online_storage_unit(&mut ts, user, character_id, storage_id, nwn_id);
    link_and_online_gates(&mut ts, user, character_id, nwn_id, gate_a_id, gate_b_id);
    authorize_xauth_on_gate(&mut ts, user, character_id, gate_a_id);
    authorize_xauth_on_gate(&mut ts, user, character_id, gate_b_id);
    authorize_xauth_on_storage_unit(&mut ts, user, character_id, storage_id);

    // Mint corpse item
    ts::next_tx(&mut ts, user);
    {
        let mut su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&character_id),
            ts.ctx(),
        );
        su.game_item_to_chain_inventory_test<Character>(
            &character, &owner_cap,
            CORPSE_ITEM_ID, CORPSE_TYPE_ID, CORPSE_VOLUME, CORPSE_QUANTITY,
            ts.ctx(),
        );
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(su);
    };

    // Configure bounty to expect a DIFFERENT type id
    let wrong_bounty_type: u64 = 99999;
    ts::next_tx(&mut ts, test_helpers::governor());
    {
        let mut ext_config = ts::take_shared<ExtensionConfig>(&ts);
        let config_admin_cap = ts::take_from_sender<config::AdminCap>(&ts);
        corpse_gate_bounty::set_bounty_type_id(&mut ext_config, &config_admin_cap, wrong_bounty_type);
        ts::return_to_sender(&ts, config_admin_cap);
        ts::return_shared(ext_config);
    };

    // Collect bounty with CORPSE_TYPE_ID (doesn't match wrong_bounty_type) -> should abort
    ts::next_tx(&mut ts, user);
    {
        let ext_config = ts::take_shared<ExtensionConfig>(&ts);
        let mut su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&character_id),
            ts.ctx(),
        );
        let clock = clock::create_for_testing(ts.ctx());

        corpse_gate_bounty::collect_corpse_bounty(
            &ext_config,
            &mut su,
            &gate_a,
            &gate_b,
            &character,
            &admin_acl,
            &owner_cap,
            CORPSE_TYPE_ID,
            &clock,
            ts.ctx(),
        );

        clock.destroy_for_testing();
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(su);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(ext_config);
        ts::return_shared(admin_acl);
    };

    ts::end(ts);
}
