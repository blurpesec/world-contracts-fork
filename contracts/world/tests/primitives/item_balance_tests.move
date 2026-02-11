#[test_only]
module world::item_balance_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::test_scenario as ts;
use world::{
    access::AdminCap,
    in_game_id,
    item_balance::{Self, ItemRegistry},
    test_helpers::{Self, governor, admin, tenant}
};

// === Constants ===
const TYPE_ID_AMMO: u64 = 100;
const TYPE_ID_FUEL: u64 = 200;
const VOLUME: u64 = 50;
const MASS: u64 = 10;

// === Helpers ===

/// Register a single item type and return its asset_id.
fun register(
    ts: &mut ts::Scenario,
    type_id: u64,
    name: vector<u8>,
    volume: u64,
): ID {
    ts::next_tx(ts, admin());
    let mut item_registry = ts::take_shared<ItemRegistry>(ts);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);

    let asset_id = item_balance::register_item_type(
        &mut item_registry,
        &admin_cap,
        type_id,
        tenant(),
        name.to_string(),
        volume,
        MASS,
        b"https://example.com".to_string(),
    );

    ts::return_to_sender(ts, admin_cap);
    ts::return_shared(item_registry);
    asset_id
}

// ===========================
// Registration tests
// ===========================

#[test]
fun register_item_type_happy_path() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    // Verify metadata via view functions
    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);

        assert!(item_balance::item_exists(&item_registry, asset_id));

        let data = item_balance::item_data(&item_registry, asset_id);
        assert_eq!(data.data_name(), utf8(b"Ammo"));
        assert_eq!(data.data_volume(), VOLUME);
        assert_eq!(data.data_mass(), MASS);
        assert_eq!(data.data_url(), utf8(b"https://example.com"));
        assert_eq!(data.data_asset_id(), asset_id);

        // Verify key accessors
        let key = data.data_key();
        assert_eq!(in_game_id::type_id(&key), TYPE_ID_AMMO);
        assert_eq!(in_game_id::type_tenant(&key), tenant());

        // Verify reverse lookup
        assert!(item_balance::is_type_registered(&item_registry, TYPE_ID_AMMO, tenant()));
        assert_eq!(item_balance::asset_id_for(&item_registry, TYPE_ID_AMMO, tenant()), asset_id);

        // Verify convenience volume lookup
        assert_eq!(item_balance::volume(&item_registry, asset_id), VOLUME);

        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
fun register_multiple_types() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let ammo_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", 50);
    let fuel_id = register(&mut ts, TYPE_ID_FUEL, b"Fuel", 10);

    // Different type_ids produce different asset_ids
    assert!(ammo_id != fuel_id);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);
        assert!(item_balance::item_exists(&item_registry, ammo_id));
        assert!(item_balance::item_exists(&item_registry, fuel_id));
        assert_eq!(item_balance::volume(&item_registry, ammo_id), 50);
        assert_eq!(item_balance::volume(&item_registry, fuel_id), 10);
        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::EAlreadyRegistered)]
fun register_duplicate_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);
    register(&mut ts, TYPE_ID_AMMO, b"Ammo Again", VOLUME); // Should abort

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::ETypeIdEmpty)]
fun register_zero_type_id_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    register(&mut ts, 0, b"Bad Item", VOLUME); // type_id = 0 should abort

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::ETenantEmpty)]
fun register_empty_tenant_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    let mut item_registry = ts::take_shared<ItemRegistry>(&ts);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    item_balance::register_item_type(
        &mut item_registry,
        &admin_cap,
        TYPE_ID_AMMO,
        utf8(b""),  // empty tenant
        utf8(b"Ammo"),
        VOLUME,
        MASS,
        utf8(b""),
    );

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(item_registry);
    ts::end(ts);
}

// ===========================
// Update metadata tests
// ===========================

#[test]
fun update_metadata_happy_path() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    ts::next_tx(&mut ts, admin());
    {
        let mut item_registry = ts::take_shared<ItemRegistry>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);

        item_balance::update_item_metadata(
            &mut item_registry,
            &admin_cap,
            asset_id,
            utf8(b"Ammo v2"),
            75,
            20,
            utf8(b"https://v2.example.com"),
        );

        // Verify updated values
        let data = item_balance::item_data(&item_registry, asset_id);
        assert_eq!(data.data_name(), utf8(b"Ammo v2"));
        assert_eq!(data.data_volume(), 75);
        assert_eq!(data.data_mass(), 20);
        assert_eq!(data.data_url(), utf8(b"https://v2.example.com"));

        ts::return_to_sender(&ts, admin_cap);
        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::EAssetNotRegistered)]
fun update_metadata_nonexistent_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    let mut item_registry = ts::take_shared<ItemRegistry>(&ts);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    let fake_id = object::id_from_address(@0xDEAD);
    item_balance::update_item_metadata(
        &mut item_registry,
        &admin_cap,
        fake_id,
        utf8(b"Ghost"),
        0,
        0,
        utf8(b""),
    );

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(item_registry);
    ts::end(ts);
}

// ===========================
// Balance API tests
// ===========================

#[test]
fun balance_zero_and_value() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    let b = item_balance::zero(asset_id);
    assert_eq!(b.value(), 0);
    assert_eq!(b.balance_asset_id(), asset_id);
    b.destroy_zero();

    ts::end(ts);
}

#[test]
fun balance_join() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);

        let mut a = item_balance::test_increase_supply(&item_registry, asset_id, 30);
        let b = item_balance::test_increase_supply(&item_registry, asset_id, 20);

        let total = a.join(b);
        assert_eq!(total, 50);
        assert_eq!(a.value(), 50);

        item_balance::test_decrease_supply(&item_registry, a);
        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::EAssetMismatch)]
fun balance_join_mismatched_assets_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let ammo_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);
    let fuel_id = register(&mut ts, TYPE_ID_FUEL, b"Fuel", 10);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);

        let mut a = item_balance::test_increase_supply(&item_registry, ammo_id, 10);
        let b = item_balance::test_increase_supply(&item_registry, fuel_id, 10);

        a.join(b); // Should abort — different asset_ids

        item_balance::test_decrease_supply(&item_registry, a);
        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
fun balance_split() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);

        let mut original = item_balance::test_increase_supply(&item_registry, asset_id, 100);
        let split_off = original.split(40);

        assert_eq!(original.value(), 60);
        assert_eq!(split_off.value(), 40);
        assert_eq!(split_off.balance_asset_id(), asset_id);

        item_balance::test_decrease_supply(&item_registry, original);
        item_balance::test_decrease_supply(&item_registry, split_off);
        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::ENotEnough)]
fun balance_split_insufficient_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);
        let mut b = item_balance::test_increase_supply(&item_registry, asset_id, 10);
        let overflow = b.split(20); // Should abort — only 10 available

        item_balance::test_decrease_supply(&item_registry, overflow);
        item_balance::test_decrease_supply(&item_registry, b);
        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
fun balance_withdraw_all() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);

        let mut b = item_balance::test_increase_supply(&item_registry, asset_id, 75);
        let all = b.withdraw_all();

        assert_eq!(b.value(), 0);
        assert_eq!(all.value(), 75);

        b.destroy_zero();
        item_balance::test_decrease_supply(&item_registry, all);
        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
fun balance_into_parts() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);
        let b = item_balance::test_increase_supply(&item_registry, asset_id, 42);

        let (id, val) = b.into_parts();
        assert_eq!(id, asset_id);
        assert_eq!(val, 42);

        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::ENonZero)]
fun destroy_zero_nonzero_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);
        let b = item_balance::test_increase_supply(&item_registry, asset_id, 5);
        b.destroy_zero(); // Should abort — value is 5, not 0

        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

// ===========================
// Supply (increase/decrease) tests
// ===========================

#[test]
fun increase_and_decrease_supply() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);

        let b = item_balance::test_increase_supply(&item_registry, asset_id, 100);
        assert_eq!(b.value(), 100);
        assert_eq!(b.balance_asset_id(), asset_id);

        let burned = item_balance::test_decrease_supply(&item_registry, b);
        assert_eq!(burned, 100);

        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::EAssetNotRegistered)]
fun increase_supply_unregistered_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);
        let fake_id = object::id_from_address(@0xDEAD);

        let b = item_balance::test_increase_supply(&item_registry, fake_id, 10);
        item_balance::test_decrease_supply(&item_registry, b);

        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::EAssetNotRegistered)]
fun decrease_supply_unregistered_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let asset_id = register(&mut ts, TYPE_ID_AMMO, b"Ammo", VOLUME);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);

        // Create a valid balance, then try to decrease with a fake asset_id
        let b = item_balance::test_increase_supply(&item_registry, asset_id, 10);
        let (_, val) = b.into_parts();

        // Reconstruct a balance with a fake asset_id
        let fake_id = object::id_from_address(@0xDEAD);
        let fake_balance = item_balance::test_increase_supply(&item_registry, fake_id, val);
        // ^ This will abort because fake_id is not registered

        item_balance::test_decrease_supply(&item_registry, fake_balance);
        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

// ===========================
// View function tests
// ===========================

#[test]
fun item_exists_returns_false_for_unknown() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);
        let fake_id = object::id_from_address(@0xDEAD);
        assert!(!item_balance::item_exists(&item_registry, fake_id));
        assert!(!item_balance::is_type_registered(&item_registry, 999, tenant()));
        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::EAssetNotRegistered)]
fun item_data_nonexistent_aborts() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);
        let fake_id = object::id_from_address(@0xDEAD);
        let _ = item_balance::item_data(&item_registry, fake_id); // Should abort

        ts::return_shared(item_registry);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = item_balance::EAssetNotRegistered)]
fun asset_id_for_nonexistent_aborts() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let item_registry = ts::take_shared<ItemRegistry>(&ts);
        let _ = item_balance::asset_id_for(&item_registry, 999, tenant()); // Should abort

        ts::return_shared(item_registry);
    };

    ts::end(ts);
}
