/// A capability proving its holder owns an entity.
///
/// An `AccessCap` is bound to one entity and is `key`-only, so it can never be
/// `public_transfer`ed. A soulbound cap (`transferable: false`) has no transfer
/// path at all; a transferable cap moves only via `transfer_access`. Minting is
/// admin-gated through `entity::mint_access`.
///
/// A cap can be parked on an entity (object-owned, e.g. an SU's cap on a
/// Character) and `borrow`ed for the duration of a transaction by presenting
/// that entity's own cap. The borrow yields a non-droppable `ReturnReceipt` that
/// must be consumed by `return_to` (put it back) or, for a transferable cap,
/// `transfer_with_receipt` (relocate it to another entity).
///
/// A cap can also be parked on any other object, such as a DAO or a builder
/// contract's config, and `borrow_parked` by the module that defines that
/// object. That module decides who may use the cap and for what. The same
/// `ReturnReceipt` forces the cap back before the transaction ends, so the cap
/// still never gains `store`.
module core::access_cap;

use core::{request::Request, requirement::{Self, Requirement}};
use std::internal::Permit;
use sui::{event, transfer::Receiving};

// === Errors ===

#[error(code = 0)]
const ENotOwner: vector<u8> = b"AccessCap does not grant access to this entity";
#[error(code = 1)]
const ENotTransferable: vector<u8> = b"Access cap is soulbound and cannot be transferred";
#[error(code = 2)]
const EWrongVersion: vector<u8> = b"AccessCap version does not match the package version";
#[error(code = 3)]
const EReceiptMismatch: vector<u8> = b"Return receipt does not match the borrowed cap";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

public struct AccessCap has key {
    id: UID,
    version: u64,
    entity: ID,
    transferable: bool,
}

/// Requirement marker: present on a request means "the caller must hold the
/// `AccessCap` for the request's target entity".
public struct Owner() has drop;

/// Requirement marker: the caller must present *any* valid `AccessCap`. Records
/// its `entity()` as the request's authorized entity for downstream use. Does
/// not require the cap to own the target entity.
public struct Caller() has drop;

/// Hot-potato proof that a parked `AccessCap` was borrowed from `origin`. Has no
/// abilities, so the transaction cannot end until it is consumed by `return_to`
/// (put the cap back) or `transfer_with_receipt` (relocate a transferable cap).
public struct ReturnReceipt {
    origin: ID,
    cap_id: ID,
}

// === Events ===

public struct AccessCapCreated has copy, drop {
    cap_id: ID,
    entity: ID,
}

// === Public Functions ===

public fun owner_requirement(): Requirement {
    requirement::from_config(option::none(), Owner())
}

/// Caller requirement: the entity's current cap.
public fun caller_requirement(): Requirement {
    requirement::from_config(option::none(), Caller())
}

public fun transfer_access(cap: AccessCap, new_owner: address) {
    assert!(cap.transferable, ENotTransferable);
    transfer::transfer(cap, new_owner);
}

/// Borrow an `AccessCap` parked on the entity behind `entity_uid`. `entity_cap`
/// must be that entity's own cap (proving the caller owns it); a foreign cap
/// aborts. Returns the parked cap plus a non-droppable `ReturnReceipt` that must
/// be consumed before the transaction ends.
public fun borrow(
    entity_uid: &mut UID,
    entity_cap: &AccessCap,
    ticket: Receiving<AccessCap>,
): (AccessCap, ReturnReceipt) {
    assert!(entity_cap.version == VERSION, EWrongVersion);
    let origin = entity_uid.to_inner();
    assert!(entity_cap.entity == origin, ENotOwner);
    let cap = transfer::receive(entity_uid, ticket);
    let receipt = ReturnReceipt { origin, cap_id: object::id(&cap) };
    (cap, receipt)
}

/// Borrow an `AccessCap` parked on any object. Only the module that defines
/// `parent`'s type can produce its `&mut UID`, so holding it proves control
/// of the parent. That module's own rules (a member list, a vote, a fixed set
/// of upkeep calls) are what gate the cap. `Entity` never hands out its
/// `&mut UID`, so caps parked on an entity still need `entity::borrow_access`.
///
/// The parent's module must not return the cap or the receipt to its caller:
/// whoever holds them can use the cap for anything in that transaction, and
/// can relocate a transferable cap with `transfer_with_receipt`.
public fun borrow_parked(
    parent: &mut UID,
    ticket: Receiving<AccessCap>,
): (AccessCap, ReturnReceipt) {
    let cap = transfer::receive(parent, ticket);
    let receipt = ReturnReceipt { origin: parent.to_inner(), cap_id: object::id(&cap) };
    (cap, receipt)
}

/// Put a borrowed cap back on the entity it came from, consuming the receipt.
/// No transferable check: the cap only ever returns home.
public fun return_to(entity_uid: &mut UID, cap: AccessCap, receipt: ReturnReceipt) {
    let ReturnReceipt { origin, cap_id } = receipt;
    assert!(entity_uid.to_inner() == origin, EReceiptMismatch);
    assert!(object::id(&cap) == cap_id, EReceiptMismatch);
    transfer::transfer(cap, origin.to_address());
}

/// Relocate a borrowed cap to `new_owner` (e.g. another entity), consuming the
/// receipt. Gated on `transferable`, so a soulbound cap can never leave its
/// origin this way.
public fun transfer_with_receipt(cap: AccessCap, receipt: ReturnReceipt, new_owner: address) {
    assert!(cap.transferable, ENotTransferable);
    let ReturnReceipt { origin: _, cap_id } = receipt;
    assert!(object::id(&cap) == cap_id, EReceiptMismatch);
    transfer::transfer(cap, new_owner);
}

// === View Functions ===

public fun version(cap: &AccessCap): u64 {
    cap.version
}

public fun entity(cap: &AccessCap): ID {
    cap.entity
}

public fun is_transferable(cap: &AccessCap): bool {
    cap.transferable
}

// === Package Functions ===

/// Pop the caller requirement. `entity::verify_caller` checks the cap is current.
public(package) fun verify_caller(request: &mut Request, cap: &AccessCap) {
    assert!(cap.version == VERSION, EWrongVersion);
    let (_requirement, frame) = request.take_next(caller_permit());
    request.set_authorized_id(cap.entity);
    frame.destroy_empty_frame();
}

/// Pop the owner requirement for `cap`'s entity. Only `entity::verify_owner`
/// calls it, after which it checks `cap` is the entity's current cap.
public(package) fun verify(request: &mut Request, cap: &AccessCap) {
    assert!(cap.version == VERSION, EWrongVersion);
    let (_requirement, frame) = request.take_next(permit());
    assert!(request.entity_id() == option::some(cap.entity), ENotOwner);
    request.set_authorized_id(cap.entity);
    frame.destroy_empty_frame();
}

/// Mint a cap for `entity` and transfer it to `owner`. Returns the new cap's id.
public(package) fun mint(entity: ID, owner: address, transferable: bool, ctx: &mut TxContext): ID {
    let cap = AccessCap { id: object::new(ctx), version: VERSION, entity, transferable };
    let cap_id = cap.id.to_inner();
    event::emit(AccessCapCreated { cap_id, entity });
    transfer::transfer(cap, owner);
    cap_id
}

// === Private Functions ===

fun permit(): Permit<Owner> {
    internal::permit<Owner>()
}

fun caller_permit(): Permit<Caller> {
    internal::permit<Caller>()
}
