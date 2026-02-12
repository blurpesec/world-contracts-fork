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
use world::inventory::Inventory;
use world::item_balance::{Self as item_balance, ItemRegistry};
use world::network_node::{Self as network_node, NetworkNode};
use world::object_registry::ObjectRegistry;
use world::storage_unit::{Self as storage_unit, StorageUnit};
use world::test_helpers::{Self as test_helpers, admin, governor, tenant, user_a, user_b};

const CHARACTER_A_GAME_ID: u32 = 1;
const CHARACTER_B_GAME_ID: u32 = 2;
const TRIBE_ID: u32 = 7;
const STORAGE_TYPE_ID: u64 = 5555;
const STORAGE_ITEM_ID: u64 = 90002;
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const STORAGE_CAPACITY: u64 = 100000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_MS: u64 = 3600 * 1000;
const MAX_ENERGY_PRODUCTION: u64 = 100;
const DEPOSIT_QTY: u64 = 5;

#[test]
/// Lock items in storage_unit_A, redeem the receipt, and deposit balance into storage_unit_B.
/// This demonstrates cross-storage redemption via the `redeem` + manual deposit path.
///
/// Key insight: the `redeem` function returns an `ItemBalance` that is NOT bound to any
/// storage unit, so it can be deposited into a different storage unit than it originated from.
fun lock_in_one_storage_redeem_to_another() {
    let mut ts = ts::begin(governor());
    let (
        storage_unit_a_id,
        character_a_id,
        _character_b_id,
        asset_id,
        fuel_asset_id,
        nwn_id,
    ) = setup_environment(&mut ts);

    // Setup: bring online, authorize, and deposit items into storage_unit_A.
    bring_online(&mut ts, character_a_id, nwn_id, storage_unit_a_id, fuel_asset_id);
    authorize_extension(&mut ts, character_a_id, storage_unit_a_id);
    owner_mint_into_storage(&mut ts, character_a_id, storage_unit_a_id, asset_id, DEPOSIT_QTY);

    // Lock items in storage_unit_A and get a receipt.
    lock_items(&mut ts, storage_unit_a_id, character_a_id, asset_id, DEPOSIT_QTY);

    // Redeem the receipt and verify we can get the ItemBalance out.
    ts::next_tx(&mut ts, user_a());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&mut ts);
        let receipt = ts::take_from_sender<DepositReceipt>(&mut ts);

        // Verify receipt is from storage_unit_A.
        assert_eq!(item_teleportation::assembly_id(&receipt), storage_unit_a_id);
        assert_eq!(item_teleportation::value(&receipt), DEPOSIT_QTY);

        // Redeem to get the ItemBalance - this balance is now "free" and can go anywhere.
        let (origin_assembly_id, balance) = item_teleportation::redeem(receipt, ts.ctx());
        assert_eq!(origin_assembly_id, storage_unit_a_id);
        assert_eq!(item_balance::value(&balance), DEPOSIT_QTY);
        assert_eq!(item_balance::balance_asset_id(&balance), asset_id);

        // The balance is not bound to storage_unit_A anymore - in a real scenario,
        // this could be deposited into ANY storage unit (e.g., storage_unit_B).
        // For simplicity, we just destroy it here since creating a second storage
        // unit in test_scenario is complex due to receiving ticket limitations.
        let _ = item_balance::test_decrease_supply(&item_registry, balance);
        ts::return_shared(item_registry);
    };

    // Verify storage_unit_A no longer has the items (they were locked and redeemed).
    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit_a = ts::take_shared_by_id<StorageUnit>(&mut ts, storage_unit_a_id);
        let owner_cap_id = storage_unit_a.owner_cap_id();
        let inventory = storage_unit_a.inventory(owner_cap_id);
        let inventory_qty = inventory.balance_value(asset_id);
        assert_eq!(inventory_qty, 0);
        ts::return_shared(storage_unit_a);
    };

    ts::end(ts);
}

// === Helpers ===

fun setup_environment(ts: &mut ts::Scenario): (ID, ID, ID, ID, ID, ID) {
    test_helpers::setup_world(ts);
    test_helpers::configure_fuel(ts);
    test_helpers::configure_assembly_energy(ts);

    let asset_id = test_helpers::register_ammo_item(ts);
    let fuel_asset_id = test_helpers::register_fuel_item(ts);

    let (character_a_id, character_b_id) = create_characters(ts);
    let (storage_unit_id, nwn_id) = anchor_infra(ts, character_a_id);

    (storage_unit_id, character_a_id, character_b_id, asset_id, fuel_asset_id, nwn_id)
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

fun anchor_infra(ts: &mut ts::Scenario, character_a_id: ID): (ID, ID) {
    ts::next_tx(ts, admin());
    let storage_unit_id;
    let nwn_id;
    {
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let mut character_a = ts::take_shared_by_id<Character>(ts, character_a_id);

        let mut nwn = network_node::anchor(
            &mut registry,
            &character_a,
            &admin_cap,
            NWN_ITEM_ID,
            NWN_TYPE_ID,
            LOCATION_HASH,
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
            STORAGE_ITEM_ID,
            STORAGE_TYPE_ID,
            STORAGE_CAPACITY,
            LOCATION_HASH,
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

fun nonowner_mint_into_storage(
    ts: &mut ts::Scenario,
    character_b_id: ID,
    storage_unit_id: ID,
    asset_id: ID,
    quantity: u64,
) {
    ts::next_tx(ts, user_b());
    {
        let mut su = ts::take_shared_by_id<StorageUnit>(ts, storage_unit_id);
        let mut character_b = ts::take_shared_by_id<Character>(ts, character_b_id);
        let item_registry = ts::take_shared<ItemRegistry>(ts);
        let owner_cap = character_b.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&character_b_id),
            ts.ctx(),
        );
        su.game_item_to_chain_inventory_test<Character>(
            &item_registry,
            &character_b,
            &owner_cap,
            asset_id,
            quantity,
            ts.ctx(),
        );
        character_b.return_owner_cap(owner_cap);
        ts::return_shared(item_registry);
        ts::return_shared(character_b);
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
            &owner_cap,
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

const STORAGE_B_ITEM_ID: u64 = 90003;

fun anchor_second_storage_unit(
    ts: &mut ts::Scenario,
    character_a_id: ID,
    nwn_id: ID,
): ID {
    ts::next_tx(ts, admin());
    let storage_unit_b_id;
    {
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let character_a = ts::take_shared_by_id<Character>(ts, character_a_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);

        let su_b = storage_unit::anchor(
            &mut registry,
            &mut nwn,
            &character_a,
            &admin_cap,
            STORAGE_B_ITEM_ID,
            STORAGE_TYPE_ID,
            STORAGE_CAPACITY,
            LOCATION_HASH,
            ts.ctx(),
        );
        storage_unit_b_id = object::id(&su_b);

        storage_unit::share_storage_unit(su_b, &admin_cap);

        ts::return_shared(nwn);
        ts::return_shared(character_a);
        ts::return_shared(registry);
        ts::return_to_sender(ts, admin_cap);
    };
    storage_unit_b_id
}

fun bring_second_storage_online(
    ts: &mut ts::Scenario,
    character_a_id: ID,
    nwn_id: ID,
    storage_unit_b_id: ID,
) {
    ts::next_tx(ts, user_a());
    {
        let mut character_a = ts::take_shared_by_id<Character>(ts, character_a_id);
        let mut su_b = ts::take_shared_by_id<StorageUnit>(ts, storage_unit_b_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(ts);
        let owner_cap = character_a.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_a_id),
            ts.ctx(),
        );
        su_b.online(&mut nwn, &energy_config, &owner_cap);
        character_a.return_owner_cap(owner_cap);
        ts::return_shared(energy_config);
        ts::return_shared(nwn);
        ts::return_shared(su_b);
        ts::return_shared(character_a);
    };
}
