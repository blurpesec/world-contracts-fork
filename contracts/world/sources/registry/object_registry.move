/// Unified registry to derive all in-game object ids for game assets.
///
/// All game assets (characters, assemblies, network nodes, item types, etc) derive their
/// deterministic object IDs from this single registry using a derivation key. The key type
/// determines the namespace:
///
/// - `TenantItemId`  — unique game entities (characters, assemblies, …)
/// - `TenantTypeId`  — fungible item type registrations
///
/// Because `derived_object` includes the Move type tag in the hash, different key types
/// will never produce colliding addresses even when the numeric values match.
module world::object_registry;

use sui::derived_object;

// === Structs ===
public struct ObjectRegistry has key {
    id: UID,
}

// === View Functions ===

/// Check whether a derived object for `key` has already been claimed under this registry.
/// Generic over key type so both `TenantItemId` and `TenantTypeId` (and any future key) work.
public fun object_exists<K: copy + drop + store>(registry: &ObjectRegistry, key: K): bool {
    derived_object::exists(&registry.id, key)
}

// === Package Functions ===
public(package) fun borrow_registry_id(registry: &mut ObjectRegistry): &mut UID {
    &mut registry.id
}

// === Private Functions ===
fun init(ctx: &mut TxContext) {
    transfer::share_object(ObjectRegistry {
        id: object::new(ctx),
    });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
