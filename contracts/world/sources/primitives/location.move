/// This module stores the location hash for location validation.
/// This can be attached to any structure in game, eg: inventory, item, ship etc.
module world::location;

use world::authority::AdminCap;

// === Errors ===
#[error(code = 0)]
const ENotInProximity: vector<u8> = b"Structures are not in proximity";
#[error(code = 1)]
const EInvalidHashLength: vector<u8> = b"Invalid length for SHA256";

// === Structs ===
public struct Location has store {
    structure_id: ID,
    location_hash: vector<u8>, //TODO: do a wrapper for custom hash for type safety later
}

// proof message
// public struct Proof {
//     committment: vector // Poseidon2 hash of the location. Not used now but in future can be replaced with a zk proof https://docs.sui.io/references/framework/sui_sui/poseidon
//     custom_message: String ? "eg: The server attests that this structure is in proximity"
//     proof_deadline: timestamp
//     distance: u64 // optional
//     signature: vector // Trusted server signature is the actual proof
// }

// Should we have a custom message struct instead for signing : or is this a overkill ?
// So that the message is constructed in this format signed and send.
// During verify if the distance is provided then its hashed with the distance during verify_signature else leave empty
// the verify_signature can extract the from address from the Message and verify against the signature public key
// public struct Proof {
//     committment: vector // Poseidon2 hash of the location. Not used now but in future can be replaced with a zk proof https://docs.sui.io/references/framework/sui_sui/poseidon
//     custom_message: Message ? "eg: The server attests that this structure is in proximity"
//     proof_deadline: timestamp
//     distance: u64 // optional , it can be 0 if there is no distance
//     signature: vector // Trusted server signature is the actual proof
// }
// public struct Message {
//     from: address //admin address
//     message: String
//     distance: u64
// }

// === Public Functions ===

// Rewrite the functions.
// A function to verify both strucutres are in same location
// this is only used for ephemeral storage

// A function to verify in_proximity using the sig_verify::verify_signature(message, timestamp, signature, admin_address)
// This function input is Proof and return value is bool
// deconstruct the proof, get the Message. append from, message and distance and send is as message in bytes to sig_verify::verify_signature

// TODO: Should we also add distance param ?
/// Verifies if the locations are in proximity.
/// `proof` - Cryptographic proof of proximity. Currently: Signature from trusted server. Future: Zero-knowledge proof.
public fun verify_proximity(location_a: &Location, location_b: &Location, proof: vector<u8>) {
    assert!(
        in_proximity(location_a.location_hash, location_b.location_hash, proof),
        ENotInProximity,
    );
}

// === View Functions ===
public fun in_proximity(_: vector<u8>, _: vector<u8>, _: vector<u8>): bool {
    //TODO: check location_a and location_b is in same location
    //TODO: verify the signature proof against a trusted server key
    true
}

public fun get_hash(location: &Location): vector<u8> {
    location.location_hash
}

// === Admin Functions ===
public fun update_location(location: &mut Location, _: &AdminCap, location_hash: vector<u8>) {
    assert!(location_hash.length() == 32, EInvalidHashLength);
    location.location_hash = location_hash;
}

// === Package Functions ===
// Accepts a pre computed hash to preserve privacy
public(package) fun attach_location(
    _: &AdminCap,
    structure_id: ID,
    location_hash: vector<u8>,
): Location {
    assert!(location_hash.length() == 32, EInvalidHashLength);
    Location {
        structure_id: structure_id,
        location_hash: location_hash,
    }
}

public(package) fun remove_location(location: Location) {
    let Location { structure_id: _, location_hash: _ } = location;
}
