/// Gas comparison: `inventory::withdraw_batch` / `deposit_batch` vs the same
/// number of single `withdraw` / `deposit` calls sharing one request in a PTB.
///
/// Each `bench_<N>_<mode>` test sets up an entity holding N item types, then
/// in one transaction withdraws one unit of each type and deposits it back.
/// Subtract the matching baseline (identical setup, no moves) to get the cost
/// of the moves alone; `run.sh` does this and prints the table.
#[test_only]
module inventory_batch_gas::batch_gas;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    docking,
    entity::{Self, Entity},
    object_registry::{Self, ObjectRegistry},
    request::Request,
    requirement::Requirement
};
use inventory::{inventory, item::Item};
use power::{grid_fuel, grid_generator, grid_load, power_grid};
use std::string;
use sui::{clock::{Self, Clock}, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const TENANT: vector<u8> = b"test";
const VOL: u64 = 2;
const MODULE_ID: u64 = 0x51;
const TYPE_ID: u64 = 1;
const DRAW: u64 = 1;
const GENERATOR_ID: u64 = 0x71;
const FUEL_BAY_ID: u64 = 0x72;
/// Item type ids held are FIRST_TYPE .. FIRST_TYPE + N.
const FIRST_TYPE: u64 = 1000;
const HELD: u64 = 5;

/// Setup only, with the default actions.
const MODE_BASELINE: u8 = 0;
/// One `withdraw_batch` and one `deposit_batch`.
const MODE_BATCH: u8 = 1;
/// Setup only, plus the N-requirement actions `MODE_SHARED` uses.
const MODE_BASELINE_SHARED: u8 = 2;
/// N single `withdraw` calls on one request, then N single `deposit` calls on
/// another, each followed by its power check, as a PTB would issue them.
const MODE_SHARED: u8 = 3;

#[test]
fun bench_0001_baseline() { bench(1, MODE_BASELINE) }
#[test]
fun bench_0001_batch() { bench(1, MODE_BATCH) }
#[test]
fun bench_0001_baseline_shared() { bench(1, MODE_BASELINE_SHARED) }
#[test]
fun bench_0001_shared() { bench(1, MODE_SHARED) }
#[test]
fun bench_0002_baseline() { bench(2, MODE_BASELINE) }
#[test]
fun bench_0002_batch() { bench(2, MODE_BATCH) }
#[test]
fun bench_0002_baseline_shared() { bench(2, MODE_BASELINE_SHARED) }
#[test]
fun bench_0002_shared() { bench(2, MODE_SHARED) }
#[test]
fun bench_0003_baseline() { bench(3, MODE_BASELINE) }
#[test]
fun bench_0003_batch() { bench(3, MODE_BATCH) }
#[test]
fun bench_0003_baseline_shared() { bench(3, MODE_BASELINE_SHARED) }
#[test]
fun bench_0003_shared() { bench(3, MODE_SHARED) }
#[test]
fun bench_0004_baseline() { bench(4, MODE_BASELINE) }
#[test]
fun bench_0004_batch() { bench(4, MODE_BATCH) }
#[test]
fun bench_0004_baseline_shared() { bench(4, MODE_BASELINE_SHARED) }
#[test]
fun bench_0004_shared() { bench(4, MODE_SHARED) }
#[test]
fun bench_0005_baseline() { bench(5, MODE_BASELINE) }
#[test]
fun bench_0005_batch() { bench(5, MODE_BATCH) }
#[test]
fun bench_0005_baseline_shared() { bench(5, MODE_BASELINE_SHARED) }
#[test]
fun bench_0005_shared() { bench(5, MODE_SHARED) }
#[test]
fun bench_0007_baseline() { bench(7, MODE_BASELINE) }
#[test]
fun bench_0007_batch() { bench(7, MODE_BATCH) }
#[test]
fun bench_0007_baseline_shared() { bench(7, MODE_BASELINE_SHARED) }
#[test]
fun bench_0007_shared() { bench(7, MODE_SHARED) }
#[test]
fun bench_0010_baseline() { bench(10, MODE_BASELINE) }
#[test]
fun bench_0010_batch() { bench(10, MODE_BATCH) }
#[test]
fun bench_0010_baseline_shared() { bench(10, MODE_BASELINE_SHARED) }
#[test]
fun bench_0010_shared() { bench(10, MODE_SHARED) }
#[test]
fun bench_0100_baseline() { bench(100, MODE_BASELINE) }
#[test]
fun bench_0100_batch() { bench(100, MODE_BATCH) }
#[test]
fun bench_0100_baseline_shared() { bench(100, MODE_BASELINE_SHARED) }
#[test]
fun bench_0100_shared() { bench(100, MODE_SHARED) }

fun bench(n: u64, mode: u8) {
    let mut scenario = ts::begin(ADMIN);
    object_registry::init_for_testing(scenario.ctx());
    admin_service::init_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1_000_000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, OWNER);
    power_inventory(&mut scenario, e_id, OWNER);
    n.do!(|i| bridge_in(&mut scenario, e_id, OWNER, FIRST_TYPE + i, HELD, VOL));

    let shared = mode == MODE_SHARED || mode == MODE_BASELINE_SHARED;
    if (shared) enable_n_actions(&mut scenario, e_id, OWNER, n);

    // The measured transaction.
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    docking::dock_for_testing(ship_id(), e_id, character_id(), scenario.ctx());
    let mut type_ids = vector[];
    let mut quantities = vector[];
    n.do!(|i| {
        type_ids.push_back(FIRST_TYPE + i);
        quantities.push_back(1);
    });

    let clock = clock::create_for_testing(scenario.ctx());
    if (mode == MODE_BATCH) {
        let mut req = e.interact(string::utf8(b"withdraw"), scenario.ctx());
        e.verify_owner(&mut req, &cap);
        let items = inventory::withdraw_batch(
            &mut e,
            &mut req,
            type_ids,
            quantities,
            scenario.ctx(),
        );
        grid_load::assert_online(&mut e, &mut req, &clock);
        e.complete_request(req);

        let mut req = e.interact(string::utf8(b"deposit"), scenario.ctx());
        e.verify_owner(&mut req, &cap);
        inventory::deposit_batch(&mut e, &mut req, items, scenario.ctx());
        grid_load::assert_online(&mut e, &mut req, &clock);
        e.complete_request(req);
    } else if (mode == MODE_SHARED) {
        let mut items = vector<Item>[];
        let mut req = e.interact(string::utf8(b"withdraw_n"), scenario.ctx());
        e.verify_owner(&mut req, &cap);
        n.do!(|i| {
            items.push_back(inventory::withdraw(&mut e, &mut req, type_ids[i], 1, scenario.ctx()));
            grid_load::assert_online(&mut e, &mut req, &clock);
        });
        e.complete_request(req);

        let mut req = e.interact(string::utf8(b"deposit_n"), scenario.ctx());
        e.verify_owner(&mut req, &cap);
        while (!items.is_empty()) {
            inventory::deposit(&mut e, &mut req, items.pop_back(), scenario.ctx());
            grid_load::assert_online(&mut e, &mut req, &clock);
        };
        e.complete_request(req);
        items.destroy_empty();
    };
    clock.destroy_for_testing();

    let inv = inventory::inventory(&e, MODULE_ID);
    n.do!(|i| assert!(inv.items().balance(FIRST_TYPE + i) == HELD));

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

// === Setup ===

fun ship_id(): ID { object::id_from_address(@0x5) }

fun character_id(): ID { object::id_from_address(@0x8) }

/// Claim an entity, install a powered-grid inventory, and mint an owner cap.
fun build_entity_with_inventory(
    scenario: &mut ts::Scenario,
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    id: u64,
    owner: address,
    capacity: u64,
): Entity {
    let (mut e, mut req) = entity::new(registry, id, string::utf8(TENANT));
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);

    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = power_grid::install(&mut e, &clock, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);

    let mut req = inventory::install(
        &mut e,
        MODULE_ID,
        TYPE_ID,
        option::some(string::utf8(b"SU-01")),
        capacity,
        DRAW,
        power_grid::firm(),
        power_grid::power(),
        0,
        0,
        &clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    clock.destroy_for_testing();

    let mut req = e.mint_access(owner, true, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    e
}

/// Owner-gated action whose other requirements are `reqs`.
fun enable(
    e: &mut Entity,
    name: vector<u8>,
    mut reqs: vector<Requirement>,
    owner_cap: &AccessCap,
    ctx: &mut TxContext,
) {
    reqs.insert(access_cap::owner_requirement(), 0);
    let mut req = e.enable_action(string::utf8(name), action::new(reqs), ctx);
    e.verify_owner(&mut req, owner_cap);
    e.complete_request(req);
}

fun configure_default_actions(scenario: &mut ts::Scenario, e_id: ID, owner: address) {
    ts::next_tx(scenario, owner);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let any = option::none();
    let bridge = inventory::bridge_in_requirement(MODULE_ID, any, any, any);
    enable(&mut e, b"bridge_in", vector[bridge], &cap, scenario.ctx());
    let deposit = inventory::deposit_requirement(MODULE_ID, any, any, any);
    enable(&mut e, b"deposit", vector[deposit], &cap, scenario.ctx());
    let withdraw = inventory::withdraw_requirement(MODULE_ID, any, any, any);
    enable(&mut e, b"withdraw", vector[withdraw], &cap, scenario.ctx());
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

/// Actions listing `n` withdraw / deposit requirements, so one request can
/// carry `n` single calls.
fun enable_n_actions(scenario: &mut ts::Scenario, e_id: ID, owner: address, n: u64) {
    ts::next_tx(scenario, owner);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let any = option::none();
    let mut w = vector[];
    let mut d = vector[];
    n.do!(|_| {
        w.push_back(inventory::withdraw_requirement(MODULE_ID, any, any, any));
        d.push_back(inventory::deposit_requirement(MODULE_ID, any, any, any));
    });
    enable(&mut e, b"withdraw_n", w, &cap, scenario.ctx());
    enable(&mut e, b"deposit_n", d, &cap, scenario.ctx());
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

/// Owner signs, `ADMIN` sponsors.
fun next_tx_owner_signs_admin_pays(scenario: &mut ts::Scenario, owner: address) {
    ts::next_tx(scenario, ADMIN);
    let mut acl = ts::take_shared<AdminACL>(scenario);
    if (!admin_service::is_sponsor(&acl, ADMIN)) {
        admin_service::add_sponsors(&mut acl, vector[ADMIN], scenario.ctx());
    };
    ts::return_shared(acl);

    let epoch = scenario.ctx().epoch();
    let timestamp = scenario.ctx().epoch_timestamp_ms();
    let rgp = scenario.ctx().reference_gas_price();
    let builder = ts::ctx_builder_from_sender(owner)
        .set_epoch(epoch)
        .set_epoch_timestamp(timestamp)
        .set_reference_gas_price(rgp)
        .set_sponsor(ADMIN);
    ts::next_with_context(scenario, builder);
}

fun bridge_in(
    scenario: &mut ts::Scenario,
    e_id: ID,
    owner: address,
    type_id: u64,
    qty: u64,
    vol: u64,
) {
    next_tx_owner_signs_admin_pays(scenario, owner);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);
    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    e.verify_owner(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, type_id, qty, vol);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    grid_load::assert_online(&mut e, &mut req, &clock);
    clock.destroy_for_testing();
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(acl);
    ts::return_shared(e);
}

/// Install a generator and fuel bay, fuel the grid, and bring the grid,
/// generator and inventory online.
fun power_inventory(scenario: &mut ts::Scenario, entity_id: ID, owner: address) {
    ts::next_tx(scenario, ADMIN);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = ts::take_shared<AdminACL>(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = grid_generator::install(
        &mut entity,
        GENERATOR_ID,
        option::none(),
        10,
        10,
        1,
        &clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    let mut req = grid_fuel::install(
        &mut entity,
        FUEL_BAY_ID,
        option::none(),
        1_000,
        &clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(entity);

    ts::next_tx(scenario, owner);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let any = option::none();
    enable_owner_in_handler(
        &mut entity,
        b"operate_grid",
        power_grid::operate_grid_requirement(),
        &cap,
        scenario.ctx(),
    );
    enable_owner_in_handler(
        &mut entity,
        b"deposit_fuel",
        power_grid::deposit_fuel_requirement(vector[], any, any, any, any),
        &cap,
        scenario.ctx(),
    );
    ts::return_to_sender(scenario, cap);
    ts::return_shared(entity);

    next_tx_owner_signs_admin_pays(scenario, owner);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = entity.interact(string::utf8(b"deposit_fuel"), scenario.ctx());
    grid_fuel::deposit_fuel(&mut entity, &mut req, 7, 100, 90, 14, &clock);
    entity.verify_owner(&mut req, &cap);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    clock.destroy_for_testing();
    ts::return_to_sender(scenario, cap);
    ts::return_shared(acl);
    ts::return_shared(entity);

    run_operate_grid!(scenario, entity_id, owner, |entity, req, clock| {
        power_grid::set_power_grid(entity, req, true, clock);
    });
    run_operate_grid!(scenario, entity_id, owner, |entity, req, clock| {
        grid_generator::set_generator(entity, req, GENERATOR_ID, true, clock);
    });
    run_operate_grid!(scenario, entity_id, owner, |entity, req, clock| {
        grid_load::set_desired_state(entity, req, MODULE_ID, true, clock);
    });
}

/// Action whose only requirement is `requirement`; the handler pushes the owner check.
fun enable_owner_in_handler(
    entity: &mut Entity,
    name: vector<u8>,
    requirement: Requirement,
    owner_cap: &AccessCap,
    ctx: &mut TxContext,
) {
    let mut req = entity.enable_action(string::utf8(name), action::new(vector[requirement]), ctx);
    entity.verify_owner(&mut req, owner_cap);
    entity.complete_request(req);
}

macro fun run_operate_grid(
    $scenario: &mut ts::Scenario,
    $entity_id: ID,
    $owner: address,
    $handler: |&mut Entity, &mut Request, &Clock|,
) {
    let scenario = $scenario;
    ts::next_tx(scenario, $owner);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, $entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = entity.interact(string::utf8(b"operate_grid"), scenario.ctx());
    $handler(&mut entity, &mut req, &clock);
    entity.verify_owner(&mut req, &cap);
    entity.complete_request(req);
    clock.destroy_for_testing();
    ts::return_to_sender(scenario, cap);
    ts::return_shared(entity);
}
