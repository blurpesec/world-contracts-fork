#[test_only]
module core::controller_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service,
    entity::{Self, Entity},
    test_helpers::{setup, take_acl, create_entity}
};
use std::{internal, string, type_name};
use sui::test_scenario as ts;

const ADMIN: address = @0xA;
const OWNER: address = @0xB;

/// A stand-in for a builder contract that takes over an entity (a vault).
public struct Vault() has drop;

/// Some other contract, which must not be able to act for `Vault`.
public struct Other() has drop;

fun mint_cap(scenario: &mut ts::Scenario, entity_id: ID, owner: address, transferable: bool) {
    ts::next_tx(scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let mut req = e.mint_access(owner, transferable, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(e);
    ts::return_shared(acl);
}

/// OWNER hands `entity_id` to `Vault` with the cap they hold.
fun hand_to_vault(scenario: &mut ts::Scenario, entity_id: ID) {
    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    e.hand_over_control(cap, internal::permit<Vault>());
    ts::return_shared(e);
}

/// `Vault` enables an owner action on `entity_id` as its controller.
fun vault_enables(scenario: &mut ts::Scenario, entity_id: ID, name: vector<u8>) {
    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let mut req = e.enable_action(string::utf8(name), action::new(vector[]), scenario.ctx());
    e.verify_controller(&mut req, internal::permit<Vault>());
    e.complete_request(req);
    ts::return_shared(e);
}

#[test]
fun hand_over_retires_cap_and_controller_acts_as_owner() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let su = create_entity(&mut scenario, 1);
    mint_cap(&mut scenario, su, OWNER, true);
    hand_to_vault(&mut scenario, su);

    // The cap no longer exists anywhere, and the entity names its controller.
    ts::next_tx(&mut scenario, OWNER);
    assert!(!ts::has_most_recent_for_sender<AccessCap>(&scenario));
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, su);
        assert!(e.access_cap_id().is_none());
        assert!(e.controller() == option::some(type_name::with_original_ids<Vault>()));
        ts::return_shared(e);
    };

    vault_enables(&mut scenario, su, b"vault_action");
    ts::next_tx(&mut scenario, OWNER);
    let e = ts::take_shared_by_id<Entity>(&scenario, su);
    assert!(e.has_owner_action(string::utf8(b"vault_action")));
    ts::return_shared(e);

    scenario.end();
}

#[test, expected_failure(abort_code = entity::ENotController)]
fun other_type_cannot_act_for_the_controller() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let su = create_entity(&mut scenario, 1);
    mint_cap(&mut scenario, su, OWNER, true);
    hand_to_vault(&mut scenario, su);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, su);
    let mut req = e.enable_action(string::utf8(b"intruder"), action::new(vector[]), scenario.ctx());
    e.verify_controller(&mut req, internal::permit<Other>());

    abort
}

#[test, expected_failure(abort_code = entity::ENotController)]
fun cap_owned_entity_has_no_controller() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let su = create_entity(&mut scenario, 1);
    mint_cap(&mut scenario, su, OWNER, true);

    // Never handed over: a contract can't claim to control it.
    vault_enables(&mut scenario, su, b"vault_action");

    abort
}

#[test, expected_failure(abort_code = access_cap::ENotOwner)]
fun controller_cannot_satisfy_a_request_for_another_entity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let vault = create_entity(&mut scenario, 1);
    let other = create_entity(&mut scenario, 2);
    mint_cap(&mut scenario, vault, OWNER, true);
    hand_to_vault(&mut scenario, vault);

    // Controlling `vault` proves nothing about `other`.
    ts::next_tx(&mut scenario, OWNER);
    let v = ts::take_shared_by_id<Entity>(&scenario, vault);
    let mut o = ts::take_shared_by_id<Entity>(&scenario, other);
    let mut req = o.enable_action(string::utf8(b"steal"), action::new(vector[]), scenario.ctx());
    v.verify_controller(&mut req, internal::permit<Vault>());

    abort
}

#[test, expected_failure(abort_code = entity::EStaleAccessCap)]
fun replaced_cap_cannot_hand_over() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let su = create_entity(&mut scenario, 1);
    mint_cap(&mut scenario, su, OWNER, true);
    // The admin gives the entity to someone else; OWNER's cap is stale.
    mint_cap(&mut scenario, su, ADMIN, true);

    hand_to_vault(&mut scenario, su);

    abort
}

#[test, expected_failure(abort_code = access_cap::ENotTransferable)]
fun soulbound_cap_cannot_hand_over() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let su = create_entity(&mut scenario, 1);
    mint_cap(&mut scenario, su, OWNER, false);

    hand_to_vault(&mut scenario, su);

    abort
}

#[test]
fun admin_mint_access_clears_the_controller() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let su = create_entity(&mut scenario, 1);
    mint_cap(&mut scenario, su, OWNER, true);
    hand_to_vault(&mut scenario, su);

    // Admin override is unchanged: a new cap ends the controller's ownership.
    mint_cap(&mut scenario, su, OWNER, true);
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, su);
    assert!(e.controller().is_none());
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.enable_action(
        string::utf8(b"owner_action"),
        action::new(vector[]),
        scenario.ctx(),
    );
    e.verify_owner(&mut req, &cap);
    e.complete_request(req);
    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);

    scenario.end();
}

#[test]
fun controlled_entity_can_be_deleted() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let su = create_entity(&mut scenario, 1);
    mint_cap(&mut scenario, su, OWNER, true);
    hand_to_vault(&mut scenario, su);

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, su);
    let acl = take_acl(&scenario);
    let (mut req, ticket) = e.request_delete();
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.delete(req, ticket);
    ts::return_shared(acl);

    scenario.end();
}
