#[test_only]
module adr_inventory::inventory_docking_tests;

use adr_core::{
    action,
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    interaction_service::{Self as svc, Docked, Interaction, ProofConfig},
    object_registry::{Self, ObjectRegistry},
    request,
    requirement::Requirement
};
use adr_inventory::inventory;
use std::string;
use sui::test_scenario as ts;

const ADMIN: address = @0xA;
const MODULE_ID: u64 = 0x51;
const ORE: u64 = 77_800;

fun enable(e: &mut Entity, name: vector<u8>, r: Requirement, acl: &AdminACL, ctx: &mut TxContext) {
    let mut req = e.enable_admin_action(string::utf8(name), action::new(vector[r]), ctx);
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
}

/// An entity with a stocked inventory and admin-enabled `withdraw` and
/// `deposit` actions that declare only their item rules, no docking.
fun setup(scenario: &mut ts::Scenario): (Entity, AdminACL, ProofConfig<Docked>) {
    object_registry::init_for_testing(scenario.ctx());
    admin_service::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared<ObjectRegistry>();
    let mut acl = scenario.take_shared<AdminACL>();
    acl.add_sponsors(vector[ADMIN], scenario.ctx());

    let (mut e, mut req) = entity::new(&mut registry, 1, string::utf8(b"t"));
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let mut req = inventory::install(&mut e, MODULE_ID, 1, option::none(), 1_000, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    enable(
        &mut e,
        b"bridge_in",
        inventory::bridge_in_requirement(MODULE_ID, option::none(), option::none(), option::none()),
        &acl,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"withdraw",
        inventory::withdraw_requirement(MODULE_ID, option::none(), option::none(), option::none()),
        &acl,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"deposit",
        inventory::deposit_requirement(MODULE_ID, option::none(), option::none(), option::none()),
        &acl,
        scenario.ctx(),
    );

    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    inventory::game_item_to_chain_inventory(&mut e, &mut req, ORE, 10, 1);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    ts::return_shared(registry);
    let cfg = svc::create_config_for_testing<Docked>(
        svc::mode_attested(),
        vector[],
        scenario.ctx(),
    );
    (e, acl, cfg)
}

#[test]
fun withdraw_and_deposit_push_docked_requirement() {
    let mut scenario = ts::begin(ADMIN);
    let (mut e, acl, cfg) = setup(&mut scenario);

    let mut req = e.interact(string::utf8(b"withdraw"), scenario.ctx());
    let item = inventory::withdraw(&mut e, &mut req, ORE, 3, scenario.ctx());
    assert!(req.next().is<Interaction<Docked>>());
    svc::verify_interaction_attested(&mut req, &cfg, &acl, scenario.ctx());
    e.complete_request(req);

    let mut req = e.interact(string::utf8(b"deposit"), scenario.ctx());
    inventory::deposit(&mut e, &mut req, item);
    assert!(req.next().is<Interaction<Docked>>());
    svc::verify_interaction_attested(&mut req, &cfg, &acl, scenario.ctx());
    e.complete_request(req);

    assert!(inventory::balance_of(&e, MODULE_ID, ORE) == 10);
    svc::destroy_config_for_testing(cfg);
    ts::return_shared(acl);
    e.share();
    scenario.end();
}

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun withdraw_cannot_complete_without_docking() {
    let mut scenario = ts::begin(ADMIN);
    let (mut e, _acl, _cfg) = setup(&mut scenario);
    let mut req = e.interact(string::utf8(b"withdraw"), scenario.ctx());
    let _item = inventory::withdraw(&mut e, &mut req, ORE, 3, scenario.ctx());
    e.complete_request(req);
    abort
}
