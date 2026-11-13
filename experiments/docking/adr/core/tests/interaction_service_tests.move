#[test_only]
module adr_core::interaction_service_tests;

use adr_core::{
    admin_service::{Self, AdminACL},
    dock_session::{Self, DockSession},
    interaction_service::{Self as svc, Docked, ProofConfig},
    request::{Self, Request}
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

// Vectors signed by `ed25519(seed = [7; 32])`: DockingProof { creation_id: @0x5,
// target: @0x57, sender: @0xc, deadline_ms: 10_000, nonce: 1 | 2 }.
const PK: vector<u8> = x"ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c";
const PAYLOAD_1: vector<u8> =
    x"00000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000057000000000000000000000000000000000000000000000000000000000000000c10270000000000000100000000000000";
const SIG_1: vector<u8> =
    x"8beabd6dedb943045592bcba0c8df2e8cd2f9b0ada2ddcce6d0c089aec3ec8d1207f337c1f8f35c15a9dfc2fea826a3c6bcb93b267a2a5c62aae72220848cb03";
const PAYLOAD_2: vector<u8> =
    x"00000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000057000000000000000000000000000000000000000000000000000000000000000c10270000000000000200000000000000";
const SIG_2: vector<u8> =
    x"2d3edf5274962b9593798929280848b36aa4ebe5c8d03c1f906e32ca25d66a63dbafb9e53f8885c36f63d1b9f80ce245605dbbc3a721371f00c8d47053de010d";

const ADMIN: address = @0xA;
const SPONSOR: address = @0x5B;
const PLAYER: address = @0xc;
const OTHER: address = @0xd;
const SHIP: address = @0x5;
const STRUCTURE: address = @0x57;
const STRANGER: address = @0x99;
const DEADLINE: u64 = 10_000;

fun docked_request(entity: address): Request {
    request::new_for_testing(
        option::some(object::id_from_address(entity)),
        vector[svc::docked_requirement()],
    )
}

fun finish(r: Request) {
    assert!(r.requires().is_empty());
    r.destroy();
}

fun setup(sender: address, mode: u8): (ts::Scenario, ProofConfig<Docked>, Clock) {
    let mut scenario = ts::begin(sender);
    let cfg = svc::create_config_for_testing<Docked>(mode, PK, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000);
    (scenario, cfg, clock)
}

fun teardown(scenario: ts::Scenario, cfg: ProofConfig<Docked>, clock: Clock) {
    svc::destroy_config_for_testing(cfg);
    clock.destroy_for_testing();
    scenario.end();
}

/// AdminACL with ADMIN as admin and SPONSOR allowlisted, shared.
fun setup_acl(scenario: &mut ts::Scenario) {
    scenario.next_tx(ADMIN);
    admin_service::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let mut acl = scenario.take_shared<AdminACL>();
    acl.add_sponsors(vector[SPONSOR], scenario.ctx());
    ts::return_shared(acl);
    scenario.next_tx(ADMIN);
}

fun ctx_for(sender: address, sponsor: Option<address>): TxContext {
    tx_context::create(
        sender,
        x"0000000000000000000000000000000000000000000000000000000000000001",
        0,
        0,
        0,
        1_000,
        1_000,
        1_000_000,
        sponsor,
    )
}

// === Signed mode ===

#[test]
fun one_proof_satisfies_both_parties() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_signed());
    let p = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    let mut ship = docked_request(SHIP);
    let mut structure = docked_request(STRUCTURE);
    svc::verify_interaction(&mut ship, &p);
    svc::verify_interaction(&mut structure, &p);
    finish(ship);
    finish(structure);
    assert!(cfg.is_nonce_used(1));
    teardown(scenario, cfg, clock);
}

#[test, expected_failure(abort_code = svc::ENonceUsed)]
fun replayed_nonce_aborts() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_signed());
    let _ = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    let _ = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = svc::ENotSender)]
fun proof_for_another_sender_aborts() {
    let (mut scenario, mut cfg, clock) = setup(OTHER, svc::mode_signed());
    let _ = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = svc::EExpired)]
fun proof_after_deadline_aborts() {
    let (mut scenario, mut cfg, mut clock) = setup(PLAYER, svc::mode_signed());
    clock.set_for_testing(DEADLINE + 1);
    let _ = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = svc::EBadSignature)]
fun signature_over_other_payload_aborts() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_signed());
    let _ = cfg.verify_docking(PAYLOAD_2, SIG_1, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = svc::ENotParty)]
fun proof_does_not_cover_a_third_entity() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_signed());
    let p = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    let mut stranger = docked_request(STRANGER);
    svc::verify_interaction(&mut stranger, &p);
    abort
}

#[test]
fun reusable_proof_verifies_repeatedly_without_nonce() {
    let (mut scenario, cfg, clock) = setup(PLAYER, svc::mode_signed());
    5u64.do!(|_| {
        let p = cfg.verify_docking_reusable(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
        let mut ship = docked_request(SHIP);
        svc::verify_interaction(&mut ship, &p);
        finish(ship);
    });
    assert!(!cfg.is_nonce_used(1));
    teardown(scenario, cfg, clock);
}

#[test, expected_failure(abort_code = svc::ENotSigned)]
fun signed_proof_rejected_in_attested_mode() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_attested());
    let _ = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    abort
}

// === Attested mode ===

#[test]
fun attested_by_allowlisted_sponsor() {
    let (mut scenario, cfg, clock) = setup(PLAYER, svc::mode_attested());
    setup_acl(&mut scenario);
    let acl = scenario.take_shared<AdminACL>();
    let ctx = ctx_for(PLAYER, option::some(SPONSOR));
    let mut ship = docked_request(SHIP);
    let mut structure = docked_request(STRUCTURE);
    svc::verify_interaction_attested(&mut ship, &cfg, &acl, &ctx);
    svc::verify_interaction_attested(&mut structure, &cfg, &acl, &ctx);
    finish(ship);
    finish(structure);
    ts::return_shared(acl);
    teardown(scenario, cfg, clock);
}

#[test]
fun attested_by_admin_sender_without_sponsor() {
    let (mut scenario, cfg, clock) = setup(ADMIN, svc::mode_attested());
    setup_acl(&mut scenario);
    let acl = scenario.take_shared<AdminACL>();
    let mut ship = docked_request(SHIP);
    svc::verify_interaction_attested(&mut ship, &cfg, &acl, &ctx_for(ADMIN, option::none()));
    finish(ship);
    ts::return_shared(acl);
    teardown(scenario, cfg, clock);
}

#[test, expected_failure(abort_code = svc::ENotAttestedCaller)]
fun attested_rejects_unsponsored_player() {
    let (mut scenario, cfg, _clock) = setup(PLAYER, svc::mode_attested());
    setup_acl(&mut scenario);
    let acl = scenario.take_shared<AdminACL>();
    let mut ship = docked_request(SHIP);
    svc::verify_interaction_attested(&mut ship, &cfg, &acl, &ctx_for(PLAYER, option::none()));
    abort
}

#[test, expected_failure(abort_code = svc::ENotAttestedCaller)]
fun attested_rejects_unlisted_sponsor() {
    let (mut scenario, cfg, _clock) = setup(PLAYER, svc::mode_attested());
    setup_acl(&mut scenario);
    let acl = scenario.take_shared<AdminACL>();
    let mut ship = docked_request(SHIP);
    svc::verify_interaction_attested(&mut ship, &cfg, &acl, &ctx_for(PLAYER, option::some(OTHER)));
    abort
}

#[test, expected_failure(abort_code = svc::ENotAttested)]
fun attested_rejected_in_signed_mode() {
    let (mut scenario, cfg, _clock) = setup(PLAYER, svc::mode_signed());
    setup_acl(&mut scenario);
    let acl = scenario.take_shared<AdminACL>();
    let mut ship = docked_request(SHIP);
    svc::verify_interaction_attested(
        &mut ship,
        &cfg,
        &acl,
        &ctx_for(PLAYER, option::some(SPONSOR)),
    );
    abort
}

#[test]
fun admin_switches_attested_to_signed() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_attested());
    setup_acl(&mut scenario);
    scenario.next_tx(ADMIN);
    let acl = scenario.take_shared<AdminACL>();
    cfg.set_mode(&acl, svc::mode_signed(), scenario.ctx());
    ts::return_shared(acl);
    scenario.next_tx(PLAYER);
    let _ = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    teardown(scenario, cfg, clock);
}

#[test, expected_failure(abort_code = svc::ENotAdmin)]
fun non_admin_cannot_switch_mode() {
    let (mut scenario, mut cfg, _clock) = setup(PLAYER, svc::mode_attested());
    setup_acl(&mut scenario);
    scenario.next_tx(PLAYER);
    let acl = scenario.take_shared<AdminACL>();
    cfg.set_mode(&acl, svc::mode_signed(), scenario.ctx());
    abort
}

// === Nonce pruning ===

#[test]
fun expired_nonce_is_pruned_and_proof_still_rejected() {
    let (mut scenario, mut cfg, mut clock) = setup(PLAYER, svc::mode_signed());
    let _ = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    clock.set_for_testing(DEADLINE + 1);
    cfg.prune_nonces(vector[1], &clock);
    assert!(!cfg.is_nonce_used(1));
    teardown(scenario, cfg, clock);
}

#[test, expected_failure(abort_code = svc::EExpired)]
fun pruned_proof_cannot_be_replayed() {
    let (mut scenario, mut cfg, mut clock) = setup(PLAYER, svc::mode_signed());
    let _ = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    clock.set_for_testing(DEADLINE + 1);
    cfg.prune_nonces(vector[1], &clock);
    let _ = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = svc::ENonceLive)]
fun live_nonce_cannot_be_pruned() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_signed());
    let _ = cfg.verify_docking(PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    cfg.prune_nonces(vector[1], &clock);
    abort
}

// === Docked session (experiment) ===

#[test]
fun session_satisfies_many_requests_after_one_verify() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_signed());
    dock_session::dock(&mut cfg, PAYLOAD_2, SIG_2, &clock, scenario.ctx());
    scenario.next_tx(PLAYER);
    let session = scenario.take_shared<DockSession>();
    assert!(session.expires_ms() == DEADLINE);
    10u64.do!(|_| {
        let mut ship = docked_request(SHIP);
        let mut structure = docked_request(STRUCTURE);
        dock_session::verify_docked(&mut ship, &session, &clock, scenario.ctx());
        dock_session::verify_docked(&mut structure, &session, &clock, scenario.ctx());
        finish(ship);
        finish(structure);
    });
    session.undock(scenario.ctx());
    teardown(scenario, cfg, clock);
}

#[test, expected_failure(abort_code = dock_session::ESessionExpired)]
fun expired_session_aborts() {
    let (mut scenario, mut cfg, mut clock) = setup(PLAYER, svc::mode_signed());
    dock_session::dock(&mut cfg, PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    scenario.next_tx(PLAYER);
    let session = scenario.take_shared<DockSession>();
    clock.set_for_testing(DEADLINE + 1);
    let mut ship = docked_request(SHIP);
    dock_session::verify_docked(&mut ship, &session, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = svc::ENotParty)]
fun session_does_not_cover_a_third_entity() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_signed());
    dock_session::dock(&mut cfg, PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    scenario.next_tx(PLAYER);
    let session = scenario.take_shared<DockSession>();
    let mut stranger = docked_request(STRANGER);
    dock_session::verify_docked(&mut stranger, &session, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = dock_session::ENotSessionHolder)]
fun session_used_by_another_sender_aborts() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_signed());
    dock_session::dock(&mut cfg, PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    scenario.next_tx(OTHER);
    let session = scenario.take_shared<DockSession>();
    let mut ship = docked_request(SHIP);
    dock_session::verify_docked(&mut ship, &session, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = dock_session::ENotSessionHolder)]
fun session_cannot_be_undocked_by_another_sender() {
    let (mut scenario, mut cfg, clock) = setup(PLAYER, svc::mode_signed());
    dock_session::dock(&mut cfg, PAYLOAD_1, SIG_1, &clock, scenario.ctx());
    scenario.next_tx(OTHER);
    let session = scenario.take_shared<DockSession>();
    session.undock(scenario.ctx());
    abort
}
