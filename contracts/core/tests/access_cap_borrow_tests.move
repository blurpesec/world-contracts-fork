#[test_only]
module core::access_cap_borrow_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service,
    entity::{Self, Entity},
    test_helpers::{setup, take_acl, create_entity}
};
use std::string;
use sui::{test_scenario as ts, transfer::Receiving, vec_set::{Self, VecSet}};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const MEMBER: address = @0xC;

const ENotMember: u64 = 100;

/// A stand-in for a builder's DAO: a non-entity object that holds an entity's
/// cap and lets its members enable actions with it.
public struct Dao has key {
    id: UID,
    members: VecSet<address>,
}

fun create_dao(scenario: &mut ts::Scenario, members: vector<address>): ID {
    ts::next_tx(scenario, ADMIN);
    let dao = Dao { id: object::new(scenario.ctx()), members: vec_set::from_keys(members) };
    let dao_id = object::id(&dao);
    transfer::share_object(dao);
    dao_id
}

/// The DAO's own rule: only a member may enable an action on the entity whose
/// cap the DAO holds. The cap never leaves this function.
fun dao_enable_action(
    dao: &mut Dao,
    e: &mut Entity,
    ticket: Receiving<AccessCap>,
    name: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(dao.members.contains(&ctx.sender()), ENotMember);
    let (cap, receipt) = access_cap::borrow_parked(&mut dao.id, ticket);
    let mut req = e.enable_action(string::utf8(name), action::new(vector[]), ctx);
    e.verify_owner(&mut req, &cap);
    e.complete_request(req);
    access_cap::return_to(&mut dao.id, cap, receipt);
}

/// Mint the cap of `entity_id` to `owner` in an ADMIN tx. `owner` may be a plain
/// address or an entity object address (to park the cap on that entity).
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

/// Object id of the (single) `AccessCap` parked on `parent`.
fun parked_cap_id(parent: ID): ID {
    ts::most_recent_id_for_address<AccessCap>(parent.to_address()).destroy_some()
}

#[test]
fun borrow_then_return_reparks_cap_on_character() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su = create_entity(&mut scenario, 2);

    // Park the SU owner cap on the character; give the character's own cap to OWNER.
    mint_cap(&mut scenario, su, character.to_address(), true);
    mint_cap(&mut scenario, character, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    {
        let su_cap_id = parked_cap_id(character);
        let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
        let char_cap = ts::take_from_sender<AccessCap>(&scenario);
        let ticket = ts::receiving_ticket_by_id<AccessCap>(su_cap_id);

        let (su_cap, receipt) = c.borrow_access(&char_cap, ticket);
        assert!(su_cap.entity() == su);
        c.return_access(su_cap, receipt);

        ts::return_to_sender(&scenario, char_cap);
        ts::return_shared(c);
    };

    // The SU cap is back on the character.
    ts::next_tx(&mut scenario, OWNER);
    assert!(ts::has_most_recent_for_address<AccessCap>(character.to_address()));

    scenario.end();
}

#[test, expected_failure(abort_code = access_cap::ENotOwner)]
fun borrow_with_foreign_cap_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su = create_entity(&mut scenario, 2);
    let other = create_entity(&mut scenario, 3);

    mint_cap(&mut scenario, su, character.to_address(), true);
    // OWNER holds a cap for `other`, not the character.
    mint_cap(&mut scenario, other, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    let su_cap_id = parked_cap_id(character);
    let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
    let foreign_cap = ts::take_from_sender<AccessCap>(&scenario);
    let ticket = ts::receiving_ticket_by_id<AccessCap>(su_cap_id);

    let (_su_cap, _receipt) = c.borrow_access(&foreign_cap, ticket);

    abort
}

#[test]
fun transfer_with_receipt_relocates_cap_to_another_entity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su = create_entity(&mut scenario, 2);
    let other_character = create_entity(&mut scenario, 3);

    mint_cap(&mut scenario, su, character.to_address(), true);
    mint_cap(&mut scenario, character, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    {
        let su_cap_id = parked_cap_id(character);
        let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
        let char_cap = ts::take_from_sender<AccessCap>(&scenario);
        let ticket = ts::receiving_ticket_by_id<AccessCap>(su_cap_id);

        let (su_cap, receipt) = c.borrow_access(&char_cap, ticket);
        access_cap::transfer_with_receipt(su_cap, receipt, other_character.to_address());

        ts::return_to_sender(&scenario, char_cap);
        ts::return_shared(c);
    };

    // The cap now lives on the other character, not the original.
    ts::next_tx(&mut scenario, OWNER);
    assert!(ts::has_most_recent_for_address<AccessCap>(other_character.to_address()));
    assert!(!ts::has_most_recent_for_address<AccessCap>(character.to_address()));

    scenario.end();
}

#[test, expected_failure(abort_code = access_cap::ENotTransferable)]
fun transfer_with_receipt_soulbound_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su = create_entity(&mut scenario, 2);
    let other_character = create_entity(&mut scenario, 3);

    // A soulbound SU cap can be parked but never relocated.
    mint_cap(&mut scenario, su, character.to_address(), false);
    mint_cap(&mut scenario, character, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    let su_cap_id = parked_cap_id(character);
    let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
    let char_cap = ts::take_from_sender<AccessCap>(&scenario);
    let ticket = ts::receiving_ticket_by_id<AccessCap>(su_cap_id);

    let (su_cap, receipt) = c.borrow_access(&char_cap, ticket);
    access_cap::transfer_with_receipt(su_cap, receipt, other_character.to_address());

    abort
}

#[test, expected_failure(abort_code = access_cap::EReceiptMismatch)]
fun return_with_mismatched_receipt_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su_one = create_entity(&mut scenario, 2);
    let su_two = create_entity(&mut scenario, 3);

    // Park two SU caps on the character.
    mint_cap(&mut scenario, su_one, character.to_address(), true);
    mint_cap(&mut scenario, su_two, character.to_address(), true);
    mint_cap(&mut scenario, character, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    let ids = ts::ids_for_address<AccessCap>(character.to_address());
    let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
    let char_cap = ts::take_from_sender<AccessCap>(&scenario);

    let (cap_a, _receipt_a) = c.borrow_access(
        &char_cap,
        ts::receiving_ticket_by_id<AccessCap>(ids[0]),
    );
    let (_cap_b, receipt_b) = c.borrow_access(
        &char_cap,
        ts::receiving_ticket_by_id<AccessCap>(ids[1]),
    );

    // Returning cap_a with cap_b's receipt aborts on the cap-id check.
    c.return_access(cap_a, receipt_b);

    abort
}

#[test, expected_failure(abort_code = entity::EStaleAccessCap)]
fun borrow_with_replaced_cap_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su = create_entity(&mut scenario, 2);

    mint_cap(&mut scenario, su, character.to_address(), true);
    mint_cap(&mut scenario, character, OWNER, false);
    // A new owner replaces OWNER's character cap.
    mint_cap(&mut scenario, character, ADMIN, false);

    ts::next_tx(&mut scenario, OWNER);
    let su_cap_id = parked_cap_id(character);
    let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
    let stale_cap = ts::take_from_sender<AccessCap>(&scenario);
    let ticket = ts::receiving_ticket_by_id<AccessCap>(su_cap_id);

    let (_su_cap, _receipt) = c.borrow_access(&stale_cap, ticket);

    abort
}

#[test]
fun dao_member_uses_parked_cap_and_it_returns_to_the_dao() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let su = create_entity(&mut scenario, 1);
    let dao_id = create_dao(&mut scenario, vector[MEMBER]);
    mint_cap(&mut scenario, su, dao_id.to_address(), true);

    ts::next_tx(&mut scenario, MEMBER);
    {
        let cap_id = parked_cap_id(dao_id);
        let mut dao = ts::take_shared_by_id<Dao>(&scenario, dao_id);
        let mut e = ts::take_shared_by_id<Entity>(&scenario, su);
        let ticket = ts::receiving_ticket_by_id<AccessCap>(cap_id);
        dao_enable_action(&mut dao, &mut e, ticket, b"member_action", scenario.ctx());
        assert!(e.has_owner_action(string::utf8(b"member_action")));
        ts::return_shared(e);
        ts::return_shared(dao);
    };

    // The cap is parked on the DAO again, and is still the entity's current cap.
    ts::next_tx(&mut scenario, MEMBER);
    let cap_id = parked_cap_id(dao_id);
    let e = ts::take_shared_by_id<Entity>(&scenario, su);
    assert!(e.access_cap_id() == option::some(cap_id));
    ts::return_shared(e);

    scenario.end();
}

#[test, expected_failure(abort_code = ENotMember)]
fun dao_non_member_cannot_use_parked_cap() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let su = create_entity(&mut scenario, 1);
    let dao_id = create_dao(&mut scenario, vector[MEMBER]);
    mint_cap(&mut scenario, su, dao_id.to_address(), true);

    ts::next_tx(&mut scenario, OWNER);
    let cap_id = parked_cap_id(dao_id);
    let mut dao = ts::take_shared_by_id<Dao>(&scenario, dao_id);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, su);
    let ticket = ts::receiving_ticket_by_id<AccessCap>(cap_id);
    dao_enable_action(&mut dao, &mut e, ticket, b"intruder_action", scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = access_cap::EReceiptMismatch)]
fun return_parked_cap_to_another_object_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let su = create_entity(&mut scenario, 1);
    let dao_id = create_dao(&mut scenario, vector[MEMBER]);
    let other_dao_id = create_dao(&mut scenario, vector[MEMBER]);
    mint_cap(&mut scenario, su, dao_id.to_address(), true);

    ts::next_tx(&mut scenario, MEMBER);
    let cap_id = parked_cap_id(dao_id);
    let mut dao = ts::take_shared_by_id<Dao>(&scenario, dao_id);
    let mut other = ts::take_shared_by_id<Dao>(&scenario, other_dao_id);
    let ticket = ts::receiving_ticket_by_id<AccessCap>(cap_id);

    let (cap, receipt) = access_cap::borrow_parked(&mut dao.id, ticket);
    access_cap::return_to(&mut other.id, cap, receipt);

    abort
}
