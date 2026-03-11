#[test_only]
module extension_examples::warehouse_receipts_tests;

use std::string::utf8;
use std::unit_test::assert_eq;
use sui::{clock, test_scenario as ts};
use world::{
    access::{OwnerCap, AdminACL},
    character::{Self, Character},
    energy::EnergyConfig,
    inventory,
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    storage_unit::{Self, StorageUnit},
};
use extension_examples::warehouse_receipt::WarehouseReceipt;
use extension_examples::warehouse_receipts::{Self, VaultAuth};

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

    // Depositor: mint items into their owned inventory
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
    // Depositor: deposit items and receive receipt
    ts::next_tx(&mut ts, depositor());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );

        let deposit_receipt = warehouse_receipts::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            LENS_TYPE_ID,
            LENS_QUANTITY,
            ts.ctx(),
        );

        // Verify receipt properties
        assert_eq!(deposit_receipt.storage_unit_id(), storage_id);
        assert_eq!(deposit_receipt.type_id(), LENS_TYPE_ID);
        assert_eq!(deposit_receipt.quantity(), LENS_QUANTITY);

        // Transfer receipt to redeemer
        transfer::public_transfer(deposit_receipt, redeemer());

        depositor_char.return_owner_cap(owner_cap, receipt);
        ts::return_shared(depositor_char);
        ts::return_shared(storage_unit);
    };

    // Assert: items moved from depositor's owned inventory to open inventory
    ts::next_tx(&mut ts, admin());
    {
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        // Open inventory has the items
        assert_eq!(su.item_quantity(su.open_storage_key(), LENS_TYPE_ID), LENS_QUANTITY);
        // Depositor's owned inventory is empty
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
        let deposit_receipt = ts::take_from_sender<WarehouseReceipt>(&ts);

        warehouse_receipts::redeem_receipt(
            deposit_receipt,
            &mut storage_unit,
            &redeemer_char,
            ts.ctx(),
        );

        redeemer_char.return_owner_cap(owner_cap, cap_receipt);
        ts::return_shared(redeemer_char);
        ts::return_shared(storage_unit);
    };

    // Assert: items moved from open inventory to redeemer's owned inventory
    ts::next_tx(&mut ts, admin());
    {
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        // Open inventory is empty
        assert!(!su.contains_item(su.open_storage_key(), LENS_TYPE_ID));
        // Redeemer's owned inventory has the items
        assert_eq!(su.item_quantity(redeemer_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
        // Depositor's owned inventory still empty
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

        let deposit_receipt = warehouse_receipts::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            LENS_TYPE_ID,
            LENS_QUANTITY,
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

        let deposit_receipt = ts::take_from_sender<WarehouseReceipt>(&ts);
        warehouse_receipts::redeem_receipt(
            deposit_receipt,
            &mut storage_unit,
            &depositor_char,
            ts.ctx(),
        );

        depositor_char.return_owner_cap(owner_cap, cap_receipt);
        ts::return_shared(depositor_char);
        ts::return_shared(storage_unit);
    };

    // Verify items back in depositor's owned inventory
    ts::next_tx(&mut ts, admin());
    {
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
        ts::return_shared(su);
    };

    ts::end(ts);
}

/// Test redeem-and-gift: receipt holder redeems but directs items to a different player's character.
/// - Depositor deposits items, receives receipt, transfers it to redeemer
/// - Redeemer redeems the receipt but passes a third player's character as the target
/// - Items land in the third player's owned inventory, not the redeemer's
#[test]
fun redeem_and_gift_to_third_party() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
    let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);
    let redeemer_id = create_character(&mut ts, redeemer(), REDEEMER_ITEM_ID);
    // Third party who will receive the items
    let gift_recipient_id = create_character(&mut ts, @0xF, 4000u32);

    let (storage_id, nwn_id) = create_storage_unit(&mut ts, owner_id);
    online_storage_unit(&mut ts, owner(), owner_id, storage_id, nwn_id);

    // Authorize VaultAuth on the storage unit
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

    // Depositor: mint items into owned inventory
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

    // Capture owner_cap IDs for final assertions
    let redeemer_owner_cap_id = {
        ts::next_tx(&mut ts, admin());
        let c = ts::take_shared_by_id<Character>(&ts, redeemer_id);
        let id = c.owner_cap_id();
        ts::return_shared(c);
        id
    };
    let gift_recipient_owner_cap_id = {
        ts::next_tx(&mut ts, admin());
        let c = ts::take_shared_by_id<Character>(&ts, gift_recipient_id);
        let id = c.owner_cap_id();
        ts::return_shared(c);
        id
    };

    // Depositor: deposit and get receipt, transfer to redeemer
    ts::next_tx(&mut ts, depositor());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );

        let deposit_receipt = warehouse_receipts::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            LENS_TYPE_ID,
            LENS_QUANTITY,
            ts.ctx(),
        );
        transfer::public_transfer(deposit_receipt, redeemer());

        depositor_char.return_owner_cap(owner_cap, receipt);
        ts::return_shared(depositor_char);
        ts::return_shared(storage_unit);
    };

    // Redeemer: redeem the receipt but pass gift_recipient's character as the target
    ts::next_tx(&mut ts, redeemer());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let gift_recipient_char = ts::take_shared_by_id<Character>(&ts, gift_recipient_id);

        let deposit_receipt = ts::take_from_sender<WarehouseReceipt>(&ts);

        // Redeemer owns the receipt but directs items to gift_recipient's character
        warehouse_receipts::redeem_receipt(
            deposit_receipt,
            &mut storage_unit,
            &gift_recipient_char,
            ts.ctx(),
        );

        ts::return_shared(gift_recipient_char);
        ts::return_shared(storage_unit);
    };

    // Assert: items landed in gift recipient's owned inventory, not redeemer's
    ts::next_tx(&mut ts, admin());
    {
        let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        // Gift recipient has the items
        assert_eq!(su.item_quantity(gift_recipient_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
        // Redeemer does NOT have the items
        assert!(!su.has_inventory(redeemer_owner_cap_id));
        // Open inventory is empty
        assert!(!su.contains_item(su.open_storage_key(), LENS_TYPE_ID));
        ts::return_shared(su);
    };

    ts::end(ts);
}

// === Failure Tests ===

#[test]
#[expected_failure(abort_code = warehouse_receipts::EStorageUnitMismatch)]
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

        let deposit_receipt = warehouse_receipts::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            LENS_TYPE_ID,
            LENS_QUANTITY,
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

    let deposit_receipt = ts::take_from_sender<WarehouseReceipt>(&ts);

    // This should fail with EStorageUnitMismatch - no cleanup needed
    warehouse_receipts::redeem_receipt(
        deposit_receipt,
        &mut storage_unit_2,
        &depositor_char,
        ts.ctx(),
    );

    abort 0
}

/// Test that the SSU owner cannot withdraw items from the open inventory using their OwnerCap<StorageUnit>.
/// withdraw_by_owner keys the inventory lookup by object::id(owner_cap), which resolves to the
/// main inventory — not the open inventory. Items deposited via the extension into open storage
/// are unreachable through owner-direct access.
#[test]
#[expected_failure(abort_code = inventory::EItemDoesNotExist)]
fun owner_cannot_withdraw_from_open_inventory() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
    let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

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

    // Depositor: mint items into owned inventory
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

    // Depositor: deposit items into open inventory via extension
    ts::next_tx(&mut ts, depositor());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );

        let deposit_receipt = warehouse_receipts::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            LENS_TYPE_ID,
            LENS_QUANTITY,
            ts.ctx(),
        );
        // Discard the receipt — we only care about the open inventory state
        transfer::public_transfer(deposit_receipt, depositor());

        depositor_char.return_owner_cap(owner_cap, receipt);
        ts::return_shared(depositor_char);
        ts::return_shared(storage_unit);
    };

    // SSU owner tries to withdraw from open inventory using their OwnerCap<StorageUnit>
    // This looks up the main inventory (keyed by owner_cap_id), not the open inventory,
    // so it aborts with EItemDoesNotExist
    ts::next_tx(&mut ts, owner());
    let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
    let mut owner_char = ts::take_shared_by_id<Character>(&ts, owner_id);
    let (owner_cap, _receipt) = owner_char.borrow_owner_cap<StorageUnit>(
        ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
        ts.ctx(),
    );

    // Aborts here with EItemDoesNotExist — the open inventory is unreachable via owner_cap_id
    let _item = storage_unit.withdraw_by_owner(
        &owner_char,
        &owner_cap,
        LENS_TYPE_ID,
        LENS_QUANTITY,
        ts.ctx(),
    );

    abort 0
}