/// This module holds all the identifiers used in-game to refer to entities and assets.
///
/// Two key types live here:
///
/// - `TenantItemId`  — identifies a unique in-game *entity* (character, assembly, network node, …).
///   Used with `ObjectRegistry` + `derived_object` to produce deterministic on-chain object IDs.
///
/// - `TenantTypeId`  — identifies a *fungible item type* within a tenant (e.g. "ore", "fuel").
///   Used with `ItemRegistry` to register and look up item metadata / supply.
///   A distinct Move type so derived addresses never collide with entity IDs even when
///   the numeric id values happen to be the same.
module world::in_game_id;

use std::string::String;

// === Structs ===

/// Represents a unique in-game entity identifier used to deterministically derive on-chain object IDs.
/// # Arguments
/// * `item_id` - The unique in-game item identifier
/// * `tenant`  - Game server instance e.g. "production" / "development" / "testing"
public struct TenantItemId has copy, drop, store {
    item_id: u64,
    tenant: String,
}

/// Deterministic key for a tenant-fungible item *type*.
///
/// In the "tenant fungibility per type_id" model the asset identity is `(type_id, tenant)`.
/// Because this is a different Move struct from `TenantItemId`, `derived_object` will
/// produce a different address even for the same numeric value — no namespace collisions.
/// # Arguments
/// * `type_id` - The game-defined item type identifier (e.g. fuel type, ore type, …)
/// * `tenant`  - Game server instance
public struct TenantTypeId has copy, drop, store {
    type_id: u64,
    tenant: String,
}

// === View Functions (TenantItemId) ===

public fun item_id(key: &TenantItemId): u64 {
    key.item_id
}

public fun tenant(key: &TenantItemId): String {
    key.tenant
}

// === View Functions (TenantTypeId) ===

public fun type_id(key: &TenantTypeId): u64 {
    key.type_id
}

public fun type_tenant(key: &TenantTypeId): String {
    key.tenant
}

// === Package Functions ===

public(package) fun create_key(item_id: u64, tenant: String): TenantItemId {
    TenantItemId { item_id, tenant }
}

public(package) fun create_type_key(type_id: u64, tenant: String): TenantTypeId {
    TenantTypeId { type_id, tenant }
}
