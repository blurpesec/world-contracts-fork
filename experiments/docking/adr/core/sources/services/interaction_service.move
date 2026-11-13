/// ADR-0004 interaction proofs (prototype, `Docked` only). Replaces
/// `location_service`'s location-hash `Proximity`.
///
/// A handler pushes an `Interaction<K>` requirement for the relationship its
/// action needs, and the transaction satisfies it in one of two ways, depending
/// on the mode of the per-kind `ProofConfig<K>`:
/// - **Signed:** `verify_docking` checks a server-signed `DockingProof` once per
///   transaction and returns a `Proof<Docked>`. `verify_interaction` then
///   satisfies each request whose entity is a party to that proof.
/// - **Attested:** `verify_interaction_attested` satisfies the requirement when
///   the sender is an admin or the gas sponsor is allowlisted. No proof is
///   involved; the sponsor backend checked the transaction before paying.
///
/// EXPERIMENT additions, not in the ADR:
/// - `verify_docking_reusable`: a signed proof that doesn't consume a nonce, so
///   one payload can back a whole session.
/// - `prune_nonces`: used nonces are stored with their deadline, and anyone can
///   delete expired ones for the storage rebate. A proof past its deadline is
///   rejected anyway, so a pruned nonce can't be replayed.
module adr_core::interaction_service;

use adr_core::{admin_service::AdminACL, request::Request, requirement::{Self, Requirement}};
use std::internal::Permit;
use sui::{bcs, clock::Clock, ed25519, table::{Self, Table}};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"ProofConfig version does not match the package version";
#[error(code = 1)]
const EBadSignature: vector<u8> = b"Proof signature is invalid";
#[error(code = 2)]
const EMalformedPayload: vector<u8> = b"Proof payload has trailing bytes";
#[error(code = 3)]
const ENotSender: vector<u8> = b"Proof was issued to another sender";
#[error(code = 4)]
const EExpired: vector<u8> = b"Proof deadline has passed";
#[error(code = 5)]
const ENonceUsed: vector<u8> = b"Proof nonce was already used";
#[error(code = 6)]
const ENotParty: vector<u8> = b"Request entity is not a party to the proof";
#[error(code = 7)]
const ENotAdmin: vector<u8> = b"Signer is not an admin";
#[error(code = 8)]
const ENotSigned: vector<u8> = b"ProofConfig is not in Signed mode";
#[error(code = 9)]
const ENotAttested: vector<u8> = b"ProofConfig is not in Attested mode";
#[error(code = 10)]
const ENotAttestedCaller: vector<u8> = b"Sender is not an admin and the sponsor is not allowlisted";
#[error(code = 11)]
const EInvalidMode: vector<u8> = b"Unknown ProofConfig mode";
#[error(code = 12)]
const ENonceLive: vector<u8> = b"Nonce deadline has not passed";

// === Constants ===

const VERSION: u64 = 1;
const MODE_ATTESTED: u8 = 0;
const MODE_SIGNED: u8 = 1;

// === Structs ===

/// Relationship kind: a ship docked at a structure (or ship).
public struct Docked() has drop;

/// Requirement marker: the request's entity must be a party to a `K` relationship.
public struct Interaction<phantom K>() has drop;

/// A verified relationship of kind `K` between `a` and `b`. Transaction-scoped.
public struct Proof<phantom K> has drop {
    a: ID,
    b: ID,
}

/// The server-signed payload.
public struct DockingProof has copy, drop {
    creation_id: ID,
    target: ID,
    sender: address,
    deadline_ms: u64,
    nonce: u64,
}

/// Mode, signing key and used nonces for relationship kind `K`.
public struct ProofConfig<phantom K> has key {
    id: UID,
    version: u64,
    mode: u8,
    public_key: vector<u8>,
    /// nonce -> deadline_ms, so expired entries can be pruned.
    used_nonces: Table<u64, u64>,
}

// === Public Functions ===

/// The requirement `withdraw` and `deposit` push: the entity must be docked.
public fun docked_requirement(): Requirement {
    requirement::from_config(option::none(), Interaction<Docked>())
}

/// Signed mode: verify a single-use docking proof, consuming its nonce.
public fun verify_docking(
    cfg: &mut ProofConfig<Docked>,
    payload: vector<u8>,
    sig: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
): Proof<Docked> {
    let p = cfg.consume(payload, sig, clock, ctx);
    Proof { a: p.creation_id, b: p.target }
}

/// EXPERIMENT. Signed mode: verify a docking proof without consuming its nonce.
public fun verify_docking_reusable(
    cfg: &ProofConfig<Docked>,
    payload: vector<u8>,
    sig: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
): Proof<Docked> {
    let p = cfg.check(payload, sig, clock, ctx);
    Proof { a: p.creation_id, b: p.target }
}

/// Satisfy the next `Interaction<K>` requirement with `proof`.
public fun verify_interaction<K>(request: &mut Request, proof: &Proof<K>) {
    satisfy<K>(request, proof.a, proof.b);
}

/// Attested mode: satisfy the next `Interaction<K>` requirement when the sender
/// is an admin or the gas sponsor is allowlisted.
public fun verify_interaction_attested<K>(
    request: &mut Request,
    cfg: &ProofConfig<K>,
    acl: &AdminACL,
    ctx: &TxContext,
) {
    assert!(cfg.version == VERSION, EWrongVersion);
    assert!(cfg.mode == MODE_ATTESTED, ENotAttested);
    let attested = acl.is_admin(ctx.sender()) || ctx.sponsor().is_some_and!(|s| acl.is_sponsor(*s));
    assert!(attested, ENotAttestedCaller);
    let (_requirement, frame) = request.take_next(interaction_permit<K>());
    frame.destroy_empty_frame();
}

/// EXPERIMENT. Delete used nonces whose deadline has passed. Anyone can call;
/// the caller receives the storage rebate.
public fun prune_nonces<K>(cfg: &mut ProofConfig<K>, nonces: vector<u64>, clock: &Clock) {
    assert!(cfg.version == VERSION, EWrongVersion);
    let now = clock.timestamp_ms();
    nonces.do!(|n| {
        let deadline = cfg.used_nonces.remove(n);
        assert!(deadline < now, ENonceLive);
    });
}

// === View Functions ===

public fun a<K>(proof: &Proof<K>): ID { proof.a }

public fun b<K>(proof: &Proof<K>): ID { proof.b }

public fun creation_id(p: &DockingProof): ID { p.creation_id }

public fun target(p: &DockingProof): ID { p.target }

public fun sender(p: &DockingProof): address { p.sender }

public fun deadline_ms(p: &DockingProof): u64 { p.deadline_ms }

public fun nonce(p: &DockingProof): u64 { p.nonce }

public fun version<K>(cfg: &ProofConfig<K>): u64 { cfg.version }

public fun mode<K>(cfg: &ProofConfig<K>): u8 { cfg.mode }

public fun public_key<K>(cfg: &ProofConfig<K>): vector<u8> { cfg.public_key }

public fun is_nonce_used<K>(cfg: &ProofConfig<K>, nonce: u64): bool {
    cfg.used_nonces.contains(nonce)
}

public fun mode_attested(): u8 { MODE_ATTESTED }

public fun mode_signed(): u8 { MODE_SIGNED }

// === Admin Functions ===

/// Create and share the `ProofConfig<K>`. Signer must be an admin.
public fun create_config<K>(acl: &AdminACL, mode: u8, public_key: vector<u8>, ctx: &mut TxContext) {
    assert!(acl.is_admin(ctx.sender()), ENotAdmin);
    assert!(mode == MODE_ATTESTED || mode == MODE_SIGNED, EInvalidMode);
    transfer::share_object(ProofConfig<K> {
        id: object::new(ctx),
        version: VERSION,
        mode,
        public_key,
        used_nonces: table::new(ctx),
    });
}

/// Switch `K` between Attested and Signed. Signer must be an admin.
public fun set_mode<K>(cfg: &mut ProofConfig<K>, acl: &AdminACL, mode: u8, ctx: &TxContext) {
    assert!(acl.is_admin(ctx.sender()), ENotAdmin);
    assert!(mode == MODE_ATTESTED || mode == MODE_SIGNED, EInvalidMode);
    cfg.mode = mode;
}

// === Package Functions ===

/// Check the signature and fields, then record the nonce.
public(package) fun consume(
    cfg: &mut ProofConfig<Docked>,
    payload: vector<u8>,
    sig: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
): DockingProof {
    let p = cfg.check(payload, sig, clock, ctx);
    assert!(!cfg.used_nonces.contains(p.nonce), ENonceUsed);
    cfg.used_nonces.add(p.nonce, p.deadline_ms);
    p
}

/// Pop the next `Interaction<K>` requirement; its entity must be `a` or `b`.
public(package) fun satisfy<K>(request: &mut Request, a: ID, b: ID) {
    let (_requirement, frame) = request.take_next(interaction_permit<K>());
    let entity = request.entity_id().destroy_or!(abort ENotParty);
    assert!(entity == a || entity == b, ENotParty);
    frame.destroy_empty_frame();
}

// === Private Functions ===

/// Check mode, signature, sender and deadline. Does not touch the nonce.
fun check(
    cfg: &ProofConfig<Docked>,
    payload: vector<u8>,
    sig: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
): DockingProof {
    assert!(cfg.version == VERSION, EWrongVersion);
    assert!(cfg.mode == MODE_SIGNED, ENotSigned);
    assert!(ed25519::ed25519_verify(&sig, &cfg.public_key, &payload), EBadSignature);

    let mut b = bcs::new(payload);
    let creation_id = object::id_from_address(b.peel_address());
    let target = object::id_from_address(b.peel_address());
    let sender = b.peel_address();
    let deadline_ms = b.peel_u64();
    let nonce = b.peel_u64();
    assert!(b.into_remainder_bytes().is_empty(), EMalformedPayload);

    assert!(sender == ctx.sender(), ENotSender);
    assert!(clock.timestamp_ms() <= deadline_ms, EExpired);
    DockingProof { creation_id, target, sender, deadline_ms, nonce }
}

fun interaction_permit<K>(): Permit<Interaction<K>> {
    internal::permit<Interaction<K>>()
}

// === Test Functions ===

#[test_only]
public fun create_config_for_testing<K>(
    mode: u8,
    public_key: vector<u8>,
    ctx: &mut TxContext,
): ProofConfig<K> {
    ProofConfig<K> {
        id: object::new(ctx),
        version: VERSION,
        mode,
        public_key,
        used_nonces: table::new(ctx),
    }
}

#[test_only]
public fun destroy_config_for_testing<K>(cfg: ProofConfig<K>) {
    let ProofConfig { id, used_nonces, .. } = cfg;
    used_nonces.drop();
    id.delete();
}
