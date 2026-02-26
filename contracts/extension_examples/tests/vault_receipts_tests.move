#[test_only]
module extension_examples::vault_receipts_tests;

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
use extension_examples::vault_receipts::{Self, VaultAuth, DepositReceipt};

// === Constants ===
const OWNER_ITEM_ID: u32 = 1000u32;
const DEPOSITOR_ITEM_ID: u32 = 2000u32;
const REDEEMER_ITEM_ID: u32 = 3000u32;
const LOCATION_HASH: vector<u8> = x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const MAX_CAPACITY: u64 = 100000;
const STORAGE_TYPE_ID: u64 = 5555;
const STORAGE_ITEM_ID: u64 = 90002;

const LENS_TYPE_ID: u64 = 88070;
const LENS_ITEM_ID: u64 = 1000004145108;
const LENS_VOLUME: u64 = 50;
const LENS_QUANTITY: u32 = 5;

const MS_PER_SECOND: u64 = 1000;
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
const MAX_PRODUCTION: u64 = 100;
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;

// === Test Addresses ===
fun governor(): address { @0xA }
fun admin(): address { @0xB }
fun owner(): address { @0xC }
fun depositor(): address { @0xD }
fun redeemer(): address { @0xE }

// === Setup Helpers ===
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

// === Success Tests ===

/// Test the full deposit-and-redeem flow with different players:
/// - Owner: creates SSU, authorizes VaultAuth
/// - Depositor: deposits items, receives receipt
/// - Redeemer: receives transferred receipt, redeems items
#[test]
fun deposit_and_redeem_by_different_player() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
    let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);
    let redeemer_id = create_character(&mut ts, redeemer(), REDEEMER_ITEM_ID);

    // Owner creates, onlines, and authorizes VaultAuth on the storage unit
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
        storage_unit.authorize_extension<VaultAuth>(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit);
    };

    // Depositor: mint items into their ephemeral inventory
    ts::next_tx(&mut ts, depositor());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
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

    // Get owner_cap IDs for assertions
    let depositor_owner_cap_id = {
        ts::next_tx(&mut ts, admin());
        let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let id = c.owner_cap_id();
        ts::return_shared(c);
        id
    };
    let redeemer_owner_cap_id = {
        ts::next_tx(&mut ts, admin());
        let c = ts::take_shared_by_id<Character>(&ts, redeemer_id);
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

    // Depositor: deposit items and receive receipt
    ts::next_tx(&mut ts, depositor());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );

        let deposit_receipt = vault_receipts::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            LENS_TYPE_ID,
            ts.ctx(),
        );

        // Verify receipt properties
        assert_eq!(vault_receipts::receipt_storage_unit_id(&deposit_receipt), storage_id);
        assert_eq!(vault_receipts::receipt_type_id(&deposit_receipt), LENS_TYPE_ID);
        assert_eq!(vault_receipts::receipt_quantity(&deposit_receipt), LENS_QUANTITY);
        assert_eq!(vault_receipts::receipt_depositor(&deposit_receipt), depositor());

        // Transfer receipt to redeemer
        transfer::public_transfer(deposit_receipt, redeemer());

        depositor_char.return_owner_cap(owner_cap, receipt);
        ts::return_shared(depositor_char);
        ts::return_shared(storage_unit);
    };

    // Assert: items moved from depositor's ephemeral to main inventory
    ts::next_tx(&mut ts, admin());
    {
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        // Main inventory has the items
        assert_eq!(su.item_quantity(storage_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
        // Depositor's ephemeral is empty
        assert!(!su.contains_item(depositor_owner_cap_id, LENS_TYPE_ID));
        ts::return_shared(su);
    };

    // Redeemer: redeem the receipt (depositor is offline)
    ts::next_tx(&mut ts, redeemer());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut redeemer_char = ts::take_shared_by_id<Character>(&ts, redeemer_id);
        let (owner_cap, cap_receipt) = redeemer_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&redeemer_id),
            ts.ctx(),
        );

        // Take the deposit receipt
        let deposit_receipt = ts::take_from_sender<DepositReceipt>(&ts);

        vault_receipts::redeem_receipt(
            deposit_receipt,
            &mut storage_unit,
            &redeemer_char,
            &owner_cap,
            ts.ctx(),
        );

        redeemer_char.return_owner_cap(owner_cap, cap_receipt);
        ts::return_shared(redeemer_char);
        ts::return_shared(storage_unit);
    };

    // Assert: items moved from main to redeemer's ephemeral
    ts::next_tx(&mut ts, admin());
    {
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        // Main inventory is empty
        assert!(!su.contains_item(storage_owner_cap_id, LENS_TYPE_ID));
        // Redeemer's ephemeral has the items
        assert_eq!(su.item_quantity(redeemer_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
        // Depositor's ephemeral still empty
        assert!(!su.contains_item(depositor_owner_cap_id, LENS_TYPE_ID));
        ts::return_shared(su);
    };

    ts::end(ts);
}

/// Test that the depositor can redeem their own receipt
#[test]
fun deposit_and_self_redeem() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
    let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

    // Setup storage unit
    let (storage_id, nwn_id) = create_storage_unit(&mut ts, owner_id);
    online_storage_unit(&mut ts, owner(), owner_id, storage_id, nwn_id);

    // Authorize VaultAuth
    ts::next_tx(&mut ts, owner());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
            ts.ctx(),
        );
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        storage_unit.authorize_extension<VaultAuth>(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit);
    };

    // Mint items to depositor
    ts::next_tx(&mut ts, depositor());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
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

    let depositor_owner_cap_id = {
        ts::next_tx(&mut ts, admin());
        let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let id = c.owner_cap_id();
        ts::return_shared(c);
        id
    };

    // Deposit and get receipt
    ts::next_tx(&mut ts, depositor());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );

        let deposit_receipt = vault_receipts::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            LENS_TYPE_ID,
            ts.ctx(),
        );

        // Keep receipt for self
        transfer::public_transfer(deposit_receipt, depositor());

        depositor_char.return_owner_cap(owner_cap, receipt);
        ts::return_shared(depositor_char);
        ts::return_shared(storage_unit);
    };

    // Self-redeem
    ts::next_tx(&mut ts, depositor());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, cap_receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );

        let deposit_receipt = ts::take_from_sender<DepositReceipt>(&ts);
        vault_receipts::redeem_receipt(
            deposit_receipt,
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            ts.ctx(),
        );

        depositor_char.return_owner_cap(owner_cap, cap_receipt);
        ts::return_shared(depositor_char);
        ts::return_shared(storage_unit);
    };

    // Verify items back in depositor's ephemeral
    ts::next_tx(&mut ts, admin());
    {
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
        ts::return_shared(su);
    };

    ts::end(ts);
}

// === Failure Tests ===

#[test]
#[expected_failure(abort_code = vault_receipts::EStorageUnitMismatch)]
fun redeem_at_wrong_storage_unit() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
    let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

    // Setup first storage unit
    let (storage_id_1, nwn_id_1) = create_storage_unit(&mut ts, owner_id);
    online_storage_unit(&mut ts, owner(), owner_id, storage_id_1, nwn_id_1);

    // Authorize on first SSU
    ts::next_tx(&mut ts, owner());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
            ts.ctx(),
        );
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
        storage_unit.authorize_extension<VaultAuth>(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit);
    };

    // Mint items
    ts::next_tx(&mut ts, depositor());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
        storage_unit.game_item_to_chain_inventory_test<Character>(
            &character, &owner_cap,
            LENS_ITEM_ID, LENS_TYPE_ID, LENS_VOLUME, LENS_QUANTITY,
            ts.ctx(),
        );
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit);
    };

    // Deposit at first SSU
    ts::next_tx(&mut ts, depositor());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );

        let deposit_receipt = vault_receipts::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            LENS_TYPE_ID,
            ts.ctx(),
        );
        transfer::public_transfer(deposit_receipt, depositor());

        depositor_char.return_owner_cap(owner_cap, receipt);
        ts::return_shared(depositor_char);
        ts::return_shared(storage_unit);
    };

    // Create second storage unit (different NWN + SSU)
    ts::next_tx(&mut ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&ts);
    let character = ts::take_shared_by_id<Character>(&ts, owner_id);
    let admin_acl = ts::take_shared<AdminACL>(&ts);

    let nwn_2 = network_node::anchor(
        &mut registry,
        &character,
        &admin_acl,
        NWN_ITEM_ID + 1,
        NWN_TYPE_ID,
        LOCATION_HASH,
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let nwn_id_2 = object::id(&nwn_2);
    nwn_2.share_network_node(&admin_acl, ts.ctx());

    ts::return_shared(character);
    ts::return_shared(admin_acl);
    ts::return_shared(registry);

    ts::next_tx(&mut ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&ts);
    let mut nwn_2 = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id_2);
    let character = ts::take_shared_by_id<Character>(&ts, owner_id);
    let storage_id_2 = {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let storage_unit = storage_unit::anchor(
            &mut registry,
            &mut nwn_2,
            &character,
            &admin_acl,
            STORAGE_ITEM_ID + 1,
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
    ts::return_shared(nwn_2);

    // Online second SSU
    online_storage_unit(&mut ts, owner(), owner_id, storage_id_2, nwn_id_2);

    // Authorize on second SSU
    ts::next_tx(&mut ts, owner());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
            ts.ctx(),
        );
        let mut storage_unit_2 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_2);
        storage_unit_2.authorize_extension<VaultAuth>(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit_2);
    };

    // Try to redeem receipt at second SSU (should fail)
    ts::next_tx(&mut ts, depositor());
    let mut storage_unit_2 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_2);
    let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
    let (owner_cap, _cap_receipt) = depositor_char.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
        ts.ctx(),
    );

    let deposit_receipt = ts::take_from_sender<DepositReceipt>(&ts);

    // This should fail with EStorageUnitMismatch - no cleanup needed
    vault_receipts::redeem_receipt(
        deposit_receipt,
        &mut storage_unit_2,
        &depositor_char,
        &owner_cap,
        ts.ctx(),
    );

    abort 0
}
