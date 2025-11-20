module world::gate;

use std::type_name::{Self, TypeName};
use sui::event;
use world::{
    authority::{Self, OwnerCap, AdminCap},
    location::{Self, Location},
    status::{Self, AssemblyStatus, Status}
};

// === Errors ===
#[error(code = 0)]
const EAccessNotAuthorized: vector<u8> = b"Owner Access not authorised for this Gate";
#[error(code = 1)]
const EExtensionNotAuthorized: vector<u8> =
    b"Access only authorised for the custom contract of the registered type";
#[error(code = 2)]
const ENotLinkedToEachOther: vector<u8> = b"Gates not linked to each other";
#[error(code = 3)]
const ENotLinked: vector<u8> = b"Gate not linked";

// === Structs ===
public struct Gate has key {
    id: UID,
    type_id: u64,
    item_id: u64,
    max_jump_distance: u64,
    status: AssemblyStatus,
    location: Location,
    linked_gate: Option<ID>, // change it to array if it can be linked to multiple gates
    extension: Option<TypeName>,
}

// Seperate ds struct

// === Events ===
public struct GateCreatedEvent has copy, drop {
    gate_id: ID,
    type_id: u64,
    item_id: u64,
    max_jump_distance: u64,
    status: Status,
    location_hash: vector<u8>,
}

// === Public Functions ===
// disabling owner cap temporarily
public fun authorize_extension<Auth: drop>(gate: &mut Gate) {
    // assert!(authority::is_authorized(owner_cap, object::id(gate)), EAccessNotAuthorized);
    gate.extension.swap_or_fill(type_name::with_defining_ids<Auth>());
}

public fun online(gate: &mut Gate) {}

public fun link_gates(source_gate: &mut Gate, destination_gate: &mut Gate) {
    // todo: add asserts
    // cannot link if its already linked
    // can link only if its online
    // should be owner capped
    // can link only if its under a min distance. add a proof for distance
    source_gate.linked_gate.swap_or_fill(object::id(destination_gate));
    destination_gate.linked_gate.swap_or_fill(object::id(source_gate));
}

public fun unlink_gates(source_gate: &mut Gate, destination_gate: &mut Gate) {
    // todo: add asserts
    // cannot unlink if its not already linked to each other
    // can link only if its online ?
    // should be owner capped
    source_gate.linked_gate = option::none(); // does this remove the link ?
    destination_gate.linked_gate = option::none();
}

// This function is called in client using the registered typed witness
// there are chances that builders who extend this dont assert for if its linked
// So this should be asserted in the client PTB
// how can we handle this on-chain ?
// OR create a hot potato pattern that this witness needs to be returned and consumed by the 3rd party function in the same transaction
public fun jump<Auth: drop>(
    source_gate: &Gate,
    destination_gate: &Gate,
    canJump: bool,
    _: Auth,
    _: &TxContext,
): bool {
    assert!(
        source_gate.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    if (source_gate.linked_gate.is_some()) {
        let linked_id = *source_gate.linked_gate.borrow();
        assert!(linked_id == object::id(destination_gate), ENotLinkedToEachOther);
    } else {
        abort ENotLinked
    };

    true
}

// === View Functions ===

public fun status(gate: &Gate): &AssemblyStatus {
    &gate.status
}

public fun location(gate: &Gate): &Location {
    &gate.location
}

// === Admin Functions ===
public fun create_gate(
    admin_cap: &AdminCap,
    type_id: u64,
    item_id: u64,
    max_jump_distance: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): Gate {
    let assembly_uid = object::new(ctx);
    let assembly_id = object::uid_to_inner(&assembly_uid);
    let gate = Gate {
        id: assembly_uid,
        type_id,
        item_id,
        max_jump_distance,
        status: status::anchor(admin_cap, assembly_id),
        location: location::attach_location(admin_cap, assembly_id, location_hash),
        linked_gate: option::none(),
        extension: option::none(),
    };

    event::emit(GateCreatedEvent {
        gate_id: assembly_id,
        type_id,
        item_id,
        max_jump_distance,
        status: status::status(&gate.status),
        location_hash: gate.location.hash(),
    });
    gate
}

public fun share_gate(gate: Gate, _: &AdminCap) {
    transfer::share_object(gate);
}
