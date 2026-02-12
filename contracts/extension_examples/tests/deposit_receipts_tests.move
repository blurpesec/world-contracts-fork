#[test_only]
module extension_examples::deposit_receipts_tests;

use extension_examples::deposit_receipts::{
    Self as deposit_receipts,
    DepositReceiptsStorageAbstractionAuth,
    DepositReceipt,
    Vault
};
use std::unit_test::assert_eq;
use sui::clock;
use sui::object;
use sui::test_scenario as ts;
use sui::transfer;
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
fun lock_mints_receipt() {
    let mut ts = ts::begin(governor());
    let (
        vault_id,
        storage_unit_id,
        character_a_id,
        _character_b_id,
        asset_id,
        fuel_asset_id,
        nwn_id,
    ) = setup_environment(&mut ts);

    // Bring infra online and authorize the receipt extension.
    bring_online(&mut ts, character_a_id, nwn_id, storage_unit_id, fuel_asset_id);
    authorize_extension(&mut ts, character_a_id, storage_unit_id);

    // Mint ammo into the storage unit.
    mint_into_storage(&mut ts, character_a_id, storage_unit_id, asset_id, DEPOSIT_QTY);

    // Lock items and mint a receipt owned by user A.
    let receipt_id = lock_items(
        &mut ts,
        vault_id,
        storage_unit_id,
        character_a_id,
        asset_id,
        DEPOSIT_QTY,
    );

    // Verify escrow reflects the locked quantity.
    ts::next_tx(&mut ts, user_a());
    {
        let vault = ts::take_shared_by_id<Vault>(&mut ts, vault_id);
        let escrowed = deposit_receipts::escrow_quantity(&vault, receipt_id);
        assert_eq!(escrowed, DEPOSIT_QTY);
        ts::return_shared(vault);
    };

    ts::end(ts);
}

#[test]
fun transfer_then_redeem() {
    let mut ts = ts::begin(governor());
    let (
        vault_id,
        storage_unit_id,
        character_a_id,
        _character_b_id,
        asset_id,
        fuel_asset_id,
        nwn_id,
    ) = setup_environment(&mut ts);

    // Bring infra online and authorize the receipt extension.
    bring_online(&mut ts, character_a_id, nwn_id, storage_unit_id, fuel_asset_id);
    authorize_extension(&mut ts, character_a_id, storage_unit_id);

    // Mint ammo into the storage unit.
    mint_into_storage(&mut ts, character_a_id, storage_unit_id, asset_id, DEPOSIT_QTY);

    // Lock items and mint a receipt owned by user A.
    let receipt_id = lock_items(
        &mut ts,
        vault_id,
        storage_unit_id,
        character_a_id,
        asset_id,
        DEPOSIT_QTY,
    );

    // Transfer the receipt A -> B.
    ts::next_tx(&mut ts, user_a());
    {
            let receipt = ts::take_from_sender<DepositReceipt>(&mut ts);
        transfer::public_transfer(receipt, user_b());
    };

    // Redeem the receipt as user B (bearer-style) and keep the balance owned.
    ts::next_tx(&mut ts, user_b());
    {
        let mut vault = ts::take_shared_by_id<Vault>(&mut ts, vault_id);
        let item_registry = ts::take_shared<ItemRegistry>(&mut ts);
            let receipt = ts::take_from_sender<DepositReceipt>(&mut ts);
        let redeemed = deposit_receipts::redeem(
            &mut vault,
            receipt,
            deposit_receipts::auth(),
            ts.ctx(),
        );

        assert_eq!(item_balance::value(&redeemed), DEPOSIT_QTY);
        assert_eq!(item_balance::balance_asset_id(&redeemed), asset_id);

        // @todo: investigate if this is needed?
        // Burn the redeemed balance to satisfy move semantics for the test.
        let _ = item_balance::test_decrease_supply(&item_registry, redeemed);

        ts::return_shared(item_registry);
        ts::return_shared(vault);
    };

    // Check escrow cleared
    ts::next_tx(&mut ts, user_b());
    {
        let vault = ts::take_shared_by_id<Vault>(&mut ts, vault_id);
        let escrowed = deposit_receipts::escrow_quantity(&vault, receipt_id);
        assert_eq!(escrowed, 0);
        ts::return_shared(vault);
    };

    ts::end(ts);
}

#[test]
#[expected_failure]
fun lock_rejects_wrong_sender() {
    let mut ts = ts::begin(governor());
    let (
        vault_id,
        storage_unit_id,
        character_a_id,
        _character_b_id,
        asset_id,
        fuel_asset_id,
        nwn_id,
    ) = setup_environment(&mut ts);

    // Bring infra online and authorize the receipt extension.
    bring_online(&mut ts, character_a_id, nwn_id, storage_unit_id, fuel_asset_id);
    authorize_extension(&mut ts, character_a_id, storage_unit_id);

    // Mint ammo into the storage unit.
    mint_into_storage(&mut ts, character_a_id, storage_unit_id, asset_id, DEPOSIT_QTY);

    // Negative path: user B cannot lock character A's storage; sender check should abort.
    ts::next_tx(&mut ts, user_b());
    {
        let mut vault = ts::take_shared_by_id<Vault>(&mut ts, vault_id);
        let mut su = ts::take_shared_by_id<StorageUnit>(&mut ts, storage_unit_id);
        let item_registry = ts::take_shared<ItemRegistry>(&mut ts);
        let mut character_a = ts::take_shared_by_id<Character>(&mut ts, character_a_id);
        let owner_cap = character_a.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_a_id),
            ts.ctx(),
        );

        let receipt = deposit_receipts::lock_and_mint(
            &mut vault,
            &mut su,
            &item_registry,
            &character_a,
            &owner_cap,
            asset_id,
            DEPOSIT_QTY,
            deposit_receipts::auth(),
            ts.ctx(),
        );

        // Move the receipt away to satisfy the type checker (abort triggers before this path).
        transfer::public_transfer(receipt, user_b());

        character_a.return_owner_cap(owner_cap);
        ts::return_shared(character_a);
        ts::return_shared(item_registry);
        ts::return_shared(su);
        ts::return_shared(vault);
    };

    ts::end(ts);
}

#[test]
#[expected_failure]
fun withdraw_after_lock_fails() {
    let mut ts = ts::begin(governor());
    let (
        vault_id,
        storage_unit_id,
        character_a_id,
        _character_b_id,
        asset_id,
        fuel_asset_id,
        nwn_id,
    ) = setup_environment(&mut ts);

    // Bring infra online and authorize the receipt extension.
    bring_online(&mut ts, character_a_id, nwn_id, storage_unit_id, fuel_asset_id);
    authorize_extension(&mut ts, character_a_id, storage_unit_id);

    // Mint ammo into the storage unit.
    mint_into_storage(&mut ts, character_a_id, storage_unit_id, asset_id, DEPOSIT_QTY);

    // Lock items to move them out of the storage inventory into escrow.
    let _receipt_id = lock_items(
        &mut ts,
        vault_id,
        storage_unit_id,
        character_a_id,
        asset_id,
        DEPOSIT_QTY,
    );

    // Attempt to withdraw the same items back to the game; should fail because inventory no longer holds them.
    ts::next_tx(&mut ts, user_a());
    {
        let mut su = ts::take_shared_by_id<StorageUnit>(&mut ts, storage_unit_id);
        let item_registry = ts::take_shared<ItemRegistry>(&mut ts);
        let mut character_a = ts::take_shared_by_id<Character>(&mut ts, character_a_id);
        let owner_cap = character_a.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_a_id),
            ts.ctx(),
        );

        let withdrawn = storage_unit::withdraw_item<DepositReceiptsStorageAbstractionAuth>(
            &mut su,
            &item_registry,
            &character_a,
            deposit_receipts::auth(),
            asset_id,
            DEPOSIT_QTY,
            ts.ctx(),
        );

        // @todo: investigate if this is needed?
        // Burn the withdrawn balance to satisfy move semantics in this failure-path test.
        let _ = item_balance::test_decrease_supply(&item_registry, withdrawn);

        character_a.return_owner_cap(owner_cap);
        ts::return_shared(character_a);
        ts::return_shared(item_registry);
        ts::return_shared(su);
    };

    ts::end(ts);
}

// === Helpers ===

fun setup_environment(ts: &mut ts::Scenario): (ID, ID, ID, ID, ID, ID, ID) {
    test_helpers::setup_world(ts);
    test_helpers::configure_fuel(ts);
    test_helpers::configure_assembly_energy(ts);

    let asset_id = test_helpers::register_ammo_item(ts);
    let fuel_asset_id = test_helpers::register_fuel_item(ts);

    // Create characters for user A and B
    let (character_a_id, character_b_id) = create_characters(ts);

    // Anchor network node and storage unit for user A
    let (storage_unit_id, nwn_id) = anchor_infra(ts, character_a_id);

    // Create vault
    ts::next_tx(ts, admin());
    let vault_id;
    {
        let vault = deposit_receipts::create_vault(ts.ctx());
        vault_id = object::id(&vault);
        transfer::public_share_object(vault);
    };

    (vault_id, storage_unit_id, character_a_id, character_b_id, asset_id, fuel_asset_id, nwn_id)
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

        let mut su = storage_unit::anchor(
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

    // Deposit fuel
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

    // Confirm escrow cleared after redemption.
    // Bring network node online
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

    // Bring storage unit online
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
        storage_unit::authorize_extension<DepositReceiptsStorageAbstractionAuth>(
            &mut su,
            &owner_cap,
        );
        character_a.return_owner_cap(owner_cap);
        ts::return_shared(su);
        ts::return_shared(character_a);
    };
}

fun mint_into_storage(
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
    vault_id: ID,
    storage_unit_id: ID,
    character_a_id: ID,
    asset_id: ID,
    quantity: u64,
): ID {
    ts::next_tx(ts, user_a());
    let receipt_id;
    {
        let mut vault = ts::take_shared_by_id<Vault>(ts, vault_id);
        let mut su = ts::take_shared_by_id<StorageUnit>(ts, storage_unit_id);
        let item_registry = ts::take_shared<ItemRegistry>(ts);
        let mut character_a = ts::take_shared_by_id<Character>(ts, character_a_id);
        let owner_cap = character_a.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_a_id),
            ts.ctx(),
        );

        let receipt = deposit_receipts::lock_and_mint(
            &mut vault,
            &mut su,
            &item_registry,
            &character_a,
            &owner_cap,
            asset_id,
            quantity,
            deposit_receipts::auth(),
            ts.ctx(),
        );
        receipt_id = object::id(&receipt);
        // Keep the receipt owned by the sender and satisfy move of the value.
        transfer::public_transfer(receipt, user_a());
        character_a.return_owner_cap(owner_cap);
        ts::return_shared(character_a);
        ts::return_shared(item_registry);
        ts::return_shared(su);
        ts::return_shared(vault);
    };
    receipt_id
}
