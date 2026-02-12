#[test_only]
module extension_examples::item_teleportation_tests;

use extension_examples::item_teleportation::{
    Self as item_teleportation,
    DepositReceiptsAuth,
    DepositReceipt
};
use std::unit_test::assert_eq;
use sui::clock;
use sui::test_scenario as ts;
use world::access::{AdminCap, OwnerCap};
use world::character::{Self as character, Character};
use world::energy::EnergyConfig;
use world::item_balance::{Self as item_balance, ItemRegistry};
use world::network_node::{Self as network_node, NetworkNode};
use world::object_registry::ObjectRegistry;
use world::storage_unit::{Self as storage_unit, StorageUnit};
use world::test_helpers::{Self as test_helpers, admin, governor, tenant, user_a, user_b};

const CHARACTER_A_GAME_ID: u32 = 1;
const CHARACTER_B_GAME_ID: u32 = 2;
const TRIBE_ID: u32 = 7;
const STORAGE_TYPE_ID: u64 = 5555;
const STORAGE_ITEM_ID_A: u64 = 90002;
const STORAGE_ITEM_ID_B: u64 = 90003;
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID_A: u64 = 5000;
const NWN_ITEM_ID_B: u64 = 5001;
const LOCATION_HASH_A: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const LOCATION_HASH_B: vector<u8> =
    x"7a8f3f2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const STORAGE_CAPACITY: u64 = 100000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_MS: u64 = 3600 * 1000;
const MAX_ENERGY_PRODUCTION: u64 = 100;
const DEPOSIT_QTY: u64 = 5;

#[test, expected_failure(abort_code = storage_unit::EBoundBalanceMismatch)]
/// Demonstrates that ITEM TELEPORTATION is now BLOCKED:
/// 1. Lock items in storage_unit_A (source)
/// 2. Get a DepositReceipt (bound to storage_unit_A)
/// 3. Attempt to redeem into storage_unit_B → ABORTS with EBoundBalanceMismatch
///
/// Key insight: DepositReceipts are now bound to their origin storage unit.
/// This prevents "teleporting" items between storage units without proximity proof.
fun teleport_items_from_storage_a_to_storage_b_blocked() {
    let mut ts = ts::begin(governor());
    let (
        storage_unit_a_id,
        character_a_id,
        _character_b_id,
        nwn_id,
    ) = setup_environment(&mut ts);
    let (asset_id) = setup_items(&mut ts);
    let (fuel_asset_id) = setup_fuel_item(&mut ts);
    // Setup storage_unit_A: bring online, authorize extension, deposit items.
    bring_online(&mut ts, character_a_id, nwn_id, storage_unit_a_id, fuel_asset_id);
    authorize_extension(&mut ts, character_a_id, storage_unit_a_id);
    owner_mint_into_storage(&mut ts, character_a_id, storage_unit_a_id, asset_id, DEPOSIT_QTY);

    // Create storage_unit_B and bring it online (reuse existing world setup).
    let (storage_unit_b_id, nwn_b_id) = anchor_infra(
        &mut ts,
        character_a_id,
        STORAGE_ITEM_ID_B,
        NWN_ITEM_ID_B,
        LOCATION_HASH_B,
    );
    bring_online(&mut ts, character_a_id, nwn_b_id, storage_unit_b_id, fuel_asset_id);
    authorize_extension(&mut ts, character_a_id, storage_unit_b_id);
    // Initial check - DEPOSIT_QTY exists in A
    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_a_id);
        let owner_cap_id = storage_unit_a.owner_cap_id();
        let inventory = storage_unit_a.inventory(owner_cap_id);
        let inventory_qty = inventory.balance_value(asset_id);
        assert_eq!(inventory_qty, DEPOSIT_QTY); // Items are starting in A!
        ts::return_shared(storage_unit_a);
    };

    // === TELEPORTATION STEP 1: Lock items in storage_unit_A ===
    // This withdraws items from A and wraps them in a receipt.
    lock_items(&mut ts, storage_unit_a_id, character_a_id, asset_id, DEPOSIT_QTY);

    // === TELEPORTATION STEP 2: Redeem receipt directly into storage_unit_B ===
    // This deposits the items into B - completing the teleportation!
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_b_id);
        let character_a = ts::take_shared_by_id<Character>(&ts, character_a_id);
        let item_registry = ts::take_shared<ItemRegistry>(&ts);
        let receipt = ts::take_from_sender<DepositReceipt>(&ts);

        // Verify receipt has expected value.
        assert_eq!(item_teleportation::value(&receipt), DEPOSIT_QTY);
        assert_eq!(item_teleportation::asset_id(&receipt), asset_id);

        // Redeem receipt INTO storage_unit_B (not A!).
        // This is the "teleportation" - items came from A but go into B.
        // Note: No owner_cap required - the extension auth pattern is used instead.
        item_teleportation::redeem_to_storage(
            &mut storage_unit_b,
            &item_registry,
            &character_a,
            receipt,
            item_teleportation::auth(),
            ts.ctx(),
        );

        ts::return_shared(item_registry);
        ts::return_shared(character_a);
        ts::return_shared(storage_unit_b);
    };

    // === VERIFY TELEPORTATION RESULT ===
    // storage_unit_A should have 0 items.
    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_a_id);
        let owner_cap_id = storage_unit_a.owner_cap_id();
        let inventory = storage_unit_a.inventory(owner_cap_id);
        let inventory_qty = inventory.balance_value(asset_id);
        assert_eq!(inventory_qty, 0); // Items are gone from A!
        ts::return_shared(storage_unit_a);
    };

    // storage_unit_B should have DEPOSIT_QTY items.
    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_b_id);
        let owner_cap_id = storage_unit_b.owner_cap_id();
        let inventory = storage_unit_b.inventory(owner_cap_id);
        let inventory_qty = inventory.balance_value(asset_id);
        assert_eq!(inventory_qty, DEPOSIT_QTY); // Items appeared in B!
        ts::return_shared(storage_unit_b);
    };

    ts::end(ts);
}

#[test]
/// Demonstrates that items CAN be deposited back to the SAME storage unit:
/// 1. Lock items in storage_unit_A
/// 2. Get a DepositReceipt (bound to storage_unit_A)
/// 3. Redeem the receipt back into storage_unit_A → SUCCESS
///
/// This is the correct pattern for deposit receipts.
fun deposit_receipt_same_storage_unit_works() {
    let mut ts = ts::begin(governor());
    let (
        storage_unit_a_id,
        character_a_id,
        _character_b_id,
        nwn_id,
    ) = setup_environment(&mut ts);
    let (asset_id) = setup_items(&mut ts);
    let (fuel_asset_id) = setup_fuel_item(&mut ts);

    bring_online(&mut ts, character_a_id, nwn_id, storage_unit_a_id, fuel_asset_id);
    authorize_extension(&mut ts, character_a_id, storage_unit_a_id);
    owner_mint_into_storage(&mut ts, character_a_id, storage_unit_a_id, asset_id, DEPOSIT_QTY);

    // Initial check - DEPOSIT_QTY exists
    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_a_id);
        let owner_cap_id = storage_unit_a.owner_cap_id();
        let inventory = storage_unit_a.inventory(owner_cap_id);
        assert_eq!(inventory.balance_value(asset_id), DEPOSIT_QTY);
        ts::return_shared(storage_unit_a);
    };

    // Lock items into a receipt
    lock_items(&mut ts, storage_unit_a_id, character_a_id, asset_id, DEPOSIT_QTY);

    // Verify items are withdrawn (inventory should be 0)
    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_a_id);
        let owner_cap_id = storage_unit_a.owner_cap_id();
        let inventory = storage_unit_a.inventory(owner_cap_id);
        assert_eq!(inventory.balance_value(asset_id), 0);
        ts::return_shared(storage_unit_a);
    };

    // Redeem receipt back INTO the SAME storage unit
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_a_id);
        let character_a = ts::take_shared_by_id<Character>(&ts, character_a_id);
        let item_registry = ts::take_shared<ItemRegistry>(&ts);
        let receipt = ts::take_from_sender<DepositReceipt>(&ts);

        // Verify receipt is bound to storage_unit_A
        assert_eq!(item_teleportation::origin_storage_unit_id(&receipt), storage_unit_a_id);
        assert_eq!(item_teleportation::value(&receipt), DEPOSIT_QTY);

        // Redeem back to the SAME storage unit - this works!
        item_teleportation::redeem_to_storage(
            &mut storage_unit_a,
            &item_registry,
            &character_a,
            receipt,
            item_teleportation::auth(),
            ts.ctx(),
        );

        ts::return_shared(item_registry);
        ts::return_shared(character_a);
        ts::return_shared(storage_unit_a);
    };

    // Verify items are back
    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_a_id);
        let owner_cap_id = storage_unit_a.owner_cap_id();
        let inventory = storage_unit_a.inventory(owner_cap_id);
        assert_eq!(inventory.balance_value(asset_id), DEPOSIT_QTY);
        ts::return_shared(storage_unit_a);
    };

    ts::end(ts);
}

// === Helpers ===

fun setup_items(ts: &mut ts::Scenario): (ID) {
    test_helpers::register_ammo_item(ts)
}

fun setup_fuel_item(ts: &mut ts::Scenario): (ID) {
    test_helpers::register_fuel_item(ts)
}

fun setup_environment(ts: &mut ts::Scenario): (ID, ID, ID, ID) {
    test_helpers::setup_world(ts);
    test_helpers::configure_fuel(ts);
    test_helpers::configure_assembly_energy(ts);

    let (character_a_id, character_b_id) = create_characters(ts);
    let (storage_unit_id, nwn_id) = anchor_infra(ts, character_a_id, STORAGE_ITEM_ID_A, NWN_ITEM_ID_A, LOCATION_HASH_A);

    (storage_unit_id, character_a_id, character_b_id, nwn_id)
}

fun create_characters(ts: &mut ts::Scenario): (ID, ID) {
    ts::next_tx(ts, admin());
    let character_a_id;
    let character_b_id;
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let mut registry = ts::take_shared<ObjectRegistry>(ts);

        let char_a = character::create_character(
            &mut registry,
            &admin_cap,
            CHARACTER_A_GAME_ID,
            tenant(),
            TRIBE_ID,
            user_a(),
            b"A".to_string(),
            ts.ctx(),
        );
        let char_b = character::create_character(
            &mut registry,
            &admin_cap,
            CHARACTER_B_GAME_ID,
            tenant(),
            TRIBE_ID,
            user_b(),
            b"B".to_string(),
            ts.ctx(),
        );

        character_a_id = object::id(&char_a);
        character_b_id = object::id(&char_b);

        character::share_character(char_a, &admin_cap);
        character::share_character(char_b, &admin_cap);

        ts::return_shared(registry);
        ts::return_to_sender(ts, admin_cap);
    };
    (character_a_id, character_b_id)
}

fun anchor_infra(ts: &mut ts::Scenario, character_a_id: ID, storage_unit_id_to_use:u64, nwn_id_to_use: u64,location_hash_to_use: vector<u8> ): (ID, ID) {
    ts::next_tx(ts, admin());
    let storage_unit_id;
    let nwn_id;
    {
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let character_a = ts::take_shared_by_id<Character>(ts, character_a_id);

        let mut nwn = network_node::anchor(
            &mut registry,
            &character_a,
            &admin_cap,
            nwn_id_to_use,
            NWN_TYPE_ID,
            location_hash_to_use,
            FUEL_MAX_CAPACITY,
            FUEL_BURN_RATE_MS,
            MAX_ENERGY_PRODUCTION,
            ts.ctx(),
        );
        nwn_id = object::id(&nwn);

        let su = storage_unit::anchor(
            &mut registry,
            &mut nwn,
            &character_a,
            &admin_cap,
            storage_unit_id_to_use,
            STORAGE_TYPE_ID,
            STORAGE_CAPACITY,
            location_hash_to_use,
            ts.ctx(),
        );
        storage_unit_id = object::id(&su);

        storage_unit::share_storage_unit(su, &admin_cap);
        network_node::share_network_node(nwn, &admin_cap);

        ts::return_shared(character_a);
        ts::return_shared(registry);
        ts::return_to_sender(ts, admin_cap);
    };
    (storage_unit_id, nwn_id)
}

fun bring_online(
    ts: &mut ts::Scenario,
    character_a_id: ID,
    nwn_id: ID,
    storage_unit_id: ID,
    fuel_asset_id: ID,
) {
    let clock_obj = clock::create_for_testing(ts.ctx());

    ts::next_tx(ts, user_a());
    {
        let mut character_a = ts::take_shared_by_id<Character>(ts, character_a_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let item_registry = ts::take_shared<ItemRegistry>(ts);
        let owner_cap = character_a.borrow_owner_cap<NetworkNode>(
            ts::most_recent_receiving_ticket<OwnerCap<NetworkNode>>(&character_a_id),
            ts.ctx(),
        );
        let balance = item_balance::test_increase_supply(&item_registry, fuel_asset_id, 10);
        network_node::deposit_fuel_test(&mut nwn, &item_registry, &owner_cap, balance, &clock_obj);
        character_a.return_owner_cap(owner_cap);
        ts::return_shared(item_registry);
        ts::return_shared(nwn);
        ts::return_shared(character_a);
    };

    ts::next_tx(ts, user_a());
    {
        let mut character_a = ts::take_shared_by_id<Character>(ts, character_a_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let owner_cap = character_a.borrow_owner_cap<NetworkNode>(
            ts::most_recent_receiving_ticket<OwnerCap<NetworkNode>>(&character_a_id),
            ts.ctx(),
        );
        network_node::online(&mut nwn, &owner_cap, &clock_obj);
        character_a.return_owner_cap(owner_cap);
        ts::return_shared(nwn);
        ts::return_shared(character_a);
    };

    ts::next_tx(ts, user_a());
    {
        let mut character_a = ts::take_shared_by_id<Character>(ts, character_a_id);
        let mut su = ts::take_shared_by_id<StorageUnit>(ts, storage_unit_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(ts);
        let owner_cap = character_a.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_a_id),
            ts.ctx(),
        );
        su.online(&mut nwn, &energy_config, &owner_cap);
        character_a.return_owner_cap(owner_cap);
        ts::return_shared(energy_config);
        ts::return_shared(nwn);
        ts::return_shared(su);
        ts::return_shared(character_a);
    };

    clock::destroy_for_testing(clock_obj);
}

fun authorize_extension(ts: &mut ts::Scenario, character_a_id: ID, storage_unit_id: ID) {
    ts::next_tx(ts, user_a());
    {
        let mut character_a = ts::take_shared_by_id<Character>(ts, character_a_id);
        let mut su = ts::take_shared_by_id<StorageUnit>(ts, storage_unit_id);
        let owner_cap = character_a.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_a_id),
            ts.ctx(),
        );
        storage_unit::authorize_extension<DepositReceiptsAuth>(&mut su, &owner_cap);
        character_a.return_owner_cap(owner_cap);
        ts::return_shared(su);
        ts::return_shared(character_a);
    };
}

fun owner_mint_into_storage(
    ts: &mut ts::Scenario,
    character_a_id: ID,
    storage_unit_id: ID,
    asset_id: ID,
    quantity: u64,
) {
    ts::next_tx(ts, user_a());
    {
        let mut su = ts::take_shared_by_id<StorageUnit>(ts, storage_unit_id);
        let mut character_a = ts::take_shared_by_id<Character>(ts, character_a_id);
        let item_registry = ts::take_shared<ItemRegistry>(ts);
        let owner_cap = character_a.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_a_id),
            ts.ctx(),
        );
        su.game_item_to_chain_inventory_test<StorageUnit>(
            &item_registry,
            &character_a,
            &owner_cap,
            asset_id,
            quantity,
            ts.ctx(),
        );
        character_a.return_owner_cap(owner_cap);
        ts::return_shared(item_registry);
        ts::return_shared(character_a);
        ts::return_shared(su);
    };
}

fun lock_items(
    ts: &mut ts::Scenario,
    storage_unit_id: ID,
    character_a_id: ID,
    asset_id: ID,
    quantity: u64,
): ID {
    ts::next_tx(ts, user_a());
    let receipt_id;
    {
        let mut su = ts::take_shared_by_id<StorageUnit>(ts, storage_unit_id);
        let item_registry = ts::take_shared<ItemRegistry>(ts);
        let mut character_a = ts::take_shared_by_id<Character>(ts, character_a_id);
        let owner_cap = character_a.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_a_id),
            ts.ctx(),
        );

        let receipt = item_teleportation::lock_and_mint(
            &mut su,
            &item_registry,
            &character_a,
            asset_id,
            quantity,
            item_teleportation::auth(),
            ts.ctx(),
        );
        receipt_id = object::id(&receipt);
        transfer::public_transfer(receipt, user_a());
        character_a.return_owner_cap(owner_cap);
        ts::return_shared(character_a);
        ts::return_shared(item_registry);
        ts::return_shared(su);
    };
    receipt_id
}

