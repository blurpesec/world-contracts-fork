#[test_only]
module world::test_helpers;

use sui::test_scenario as ts;
use world::{
    authority::{Self, AdminCap, ServerAddressRegistry},
    location::{Self, LocationProof},
    world::{Self, GovernorCap}
};

public fun governor(): address { @0xA }

public fun admin(): address { @0xB }

public fun user_a(): address { @0xC }

public fun user_b(): address { @0xD }

public fun server_admin(): address {
    @0x93d3209c7f138aded41dcb008d066ae872ed558bd8dcb562da47d4ef78295333
}

public fun get_verified_location_hash(): vector<u8> {
    x"16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049"
}

/// Initialize world and create admin cap for ADMIN
public fun setup_world(ts: &mut ts::Scenario) {
    ts::next_tx(ts, governor());
    {
        world::init_for_testing(ts.ctx());
        authority::init_for_testing(ts.ctx());
    };

    ts::next_tx(ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(ts);
        authority::create_admin_cap(&gov_cap, admin(), ts.ctx());
        ts::return_to_sender(ts, gov_cap);
    };
}

/// Create and transfer an owner cap for a specific object id
public fun setup_owner_cap(ts: &mut ts::Scenario, owner: address, object_id: ID) {
    ts::next_tx(ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let owner_cap = authority::create_owner_cap(&admin_cap, object_id, ts.ctx());
        authority::transfer_owner_cap(owner_cap, &admin_cap, owner);
        ts::return_to_sender(ts, admin_cap);
    };
}

public fun setup_owner_cap_for_user_a(ts: &mut ts::Scenario, object_id: ID) {
    setup_owner_cap(ts, user_a(), object_id);
}

// functions to get off-chain verified values for signaure proof

public fun register_server_address(ts: &mut ts::Scenario) {
    ts::next_tx(ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(ts);
        let mut server_registry = ts::take_shared<ServerAddressRegistry>(ts);
        authority::create_admin_cap(&gov_cap, server_admin(), ts.ctx());
        authority::register_server_address(&mut server_registry, &gov_cap, server_admin());
        ts::return_to_sender(ts, gov_cap);
        ts::return_shared(server_registry);
    };
}

public fun get_storage_unit_id(): ID {
    let storage_unit_id_bytes = x"5743208d4f4efbb0e783d3b1bc4f81d522ad73dc44b4052e21c5465df3bba061";
    let storage_unit_id = object::id_from_bytes(storage_unit_id_bytes);
    storage_unit_id
}

public fun construct_location_proof(location_hash: vector<u8>): LocationProof {
    let character_id = object::id_from_bytes(
        x"0000000000000000000000000000000000000000000000000000000000000002",
    );
    let data = x"";
    let signature =
        x"0026ce00ad44629213f249ec3ee833aaf28bc115d3b781ca0a146a6e22a4016205f992d07c62f8d067d0baecb397bcc5a692a3bae5ff2e33eb6b42fdb94db6f50ba94e21ea26cc336019c11a5e10c4b39160188dda0f6b4bfe198dd689db8f3df9";
    let deadline_ms: u64 = 1763408644339;
    let proof = location::create_location_proof(
        server_admin(),
        server_admin(), // ideally this is the player
        get_storage_unit_id(),
        location_hash,
        character_id,
        0u64,
        data,
        deadline_ms,
        signature,
    );
    proof
}
