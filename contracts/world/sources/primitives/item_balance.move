/// Tenant-fungible item balance system modeled after `sui::balance`.
///
/// Instead of using a Move type parameter `T` to identify the asset (like `Balance<T>`),
/// assets are identified by a data-driven `asset_id: ID`.  The `asset_id` is a deterministic
/// address derived from `(ItemRegistry.id, TenantTypeId)` — so it can be pre-computed off-chain.
///
/// ## Key types
///
/// - `ItemRegistry`  — shared object holding all item metadata (as dynamic fields).
///   The single source of truth for item types.  Read-only after registration.
/// - `ItemData`      — per-(tenant, type_id) metadata stored inside `ItemRegistry`.
/// - `ItemBalance`   — lightweight, storable balance value (`asset_id` + `value`).
///
/// ## Registration flow
///
/// 1. Admin calls `register_item_type` with `(type_id, tenant, name, volume, …)`.
/// 2. A deterministic `asset_id` is derived via `derived_object::claim` on the registry.
/// 3. `ItemData` is stored as a dynamic field on the registry keyed by `asset_id`.
/// 4. `asset_id` is returned and emitted in `ItemTypeRegisteredEvent`.
///
/// ## Mint / Burn (package-internal)
///
/// - `increase_supply` creates a new `ItemBalance` (validates asset exists).
/// - `decrease_supply` destroys an `ItemBalance` (validates asset exists).
///
/// Supply tracking is intentionally off-chain (via events) to avoid contention
/// on the `ItemRegistry` shared object during high-throughput game bridge operations.
///
/// ## Composing registration with operations (PTB pattern)
///
/// Registration (`register_item_type`) requires `&mut ItemRegistry` and is a one-time
/// admin operation per item type.  All other paths — mint, burn, deposit, withdraw —
/// use `&ItemRegistry` (immutable) to avoid shared-object contention.
///
/// Rather than creating combined "register-and-mint" functions (which would couple
/// assembly modules to registration parameters and reintroduce `&mut` on hot paths),
/// the backend composes these atomically via Sui Programmable Transaction Blocks (PTBs):
///
/// ```
/// // Single PTB — atomic, no new contract surface:
/// let asset_id = item_balance::register_item_type(
///     &mut registry, &admin_cap, type_id, tenant, name, volume, mass, url,
/// );
/// storage_unit::game_item_to_chain_inventory(
///     &mut storage_unit, &registry, asset_id, quantity, …,
/// );
/// ```
///
/// This keeps each function single-responsibility, avoids leaking registration parameters
/// into every assembly module, and ensures `&mut ItemRegistry` is only held for the
/// registration call — releasing it before any high-throughput operation begins.
///
/// ## Balance API (public)
///
/// `zero`, `join`, `split`, `withdraw_all`, `destroy_zero`, `into_parts` — mirrors `sui::balance`.
///
/// References:
/// - `sui::balance` docs: https://docs.sui.io/references/framework/sui_sui/balance
module world::item_balance;

use std::string::String;
use sui::{derived_object, dynamic_field as df, event, table::{Self, Table}};
use world::{access::AdminCap, in_game_id::{Self, TenantTypeId}};

// === Errors ===
#[error(code = 0)]
const ETypeIdEmpty: vector<u8> = b"Type ID cannot be empty";
#[error(code = 1)]
const EAlreadyRegistered: vector<u8> = b"Item type already registered";
#[error(code = 3)]
const ENotEnough: vector<u8> = b"Not enough balance";
#[error(code = 4)]
const EAssetMismatch: vector<u8> = b"Asset mismatch";
#[error(code = 5)]
const EAssetNotRegistered: vector<u8> = b"Asset not registered";
#[error(code = 6)]
const ENonZero: vector<u8> = b"Cannot destroy non-zero balance";
#[error(code = 7)]
const ETenantEmpty: vector<u8> = b"Tenant cannot be empty";

// === Structs ===

/// Shared registry holding all item type metadata.
///
/// Item metadata is stored as dynamic fields keyed by `asset_id: ID`.
/// Derived-object claim markers (keyed by `TenantTypeId`) co-exist on the same UID
/// and prevent duplicate registrations.
///
/// After registration, this object is read-only for all player-facing operations,
/// eliminating contention on the hot path.
public struct ItemRegistry has key {
    id: UID,
    /// Reverse lookup: (tenant, type_id) → asset_id.
    asset_ids: Table<TenantTypeId, ID>,
}

/// Per-(tenant, type_id) item metadata.  Stored as a dynamic field on `ItemRegistry`,
/// keyed by the deterministic `asset_id`.
public struct ItemData has store {
    /// Deterministic ID derived from `(ItemRegistry.id, TenantTypeId)`.
    asset_id: ID,
    /// The registration key.
    key: TenantTypeId,
    /// Human-readable name.
    name: String,
    /// Per-unit volume used for inventory capacity accounting.
    volume: u64,
    /// Per-unit mass (reserved for future use).
    mass: u64,
    /// Off-chain metadata URL.
    url: String,
}

/// Storable balance for a specific `asset_id`.
///
/// Modeled after `sui::balance::Balance<T>`, but identified by data (`asset_id`)
/// rather than a Move type parameter.  Not a standalone object — always embedded
/// inside another struct (Inventory, Fuel, etc.).
public struct ItemBalance has store {
    asset_id: ID,
    value: u64,
}

// === Events ===

public struct ItemTypeRegisteredEvent has copy, drop {
    asset_id: ID,
    key: TenantTypeId,
    name: String,
    volume: u64,
    mass: u64,
    url: String,
}

public struct ItemMetadataUpdatedEvent has copy, drop {
    asset_id: ID,
    name: String,
    volume: u64,
    mass: u64,
    url: String,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(ItemRegistry {
        id: object::new(ctx),
        asset_ids: table::new(ctx),
    });
}

// === Registration (Admin) ===

/// Register a new item type for a tenant.
///
/// The `asset_id` is derived deterministically from `(ItemRegistry.id, TenantTypeId{type_id, tenant})`.
/// Returns the `asset_id` so the caller (and the emitted event) can reference it immediately.
public fun register_item_type(
    item_registry: &mut ItemRegistry,
    _: &AdminCap,
    type_id: u64,
    tenant: String,
    name: String,
    volume: u64,
    mass: u64,
    url: String,
): ID {
    assert!(type_id != 0, ETypeIdEmpty);
    assert!(tenant.length() > 0, ETenantEmpty);

    let key = in_game_id::create_type_key(type_id, tenant);

    // derived_object::claim adds a (TenantTypeId -> true) marker on item_registry.id
    // and returns a UID at the deterministic derived address.
    assert!(!derived_object::exists(&item_registry.id, key), EAlreadyRegistered);
    let uid = derived_object::claim(&mut item_registry.id, key);
    let asset_id = object::uid_to_inner(&uid);
    uid.delete(); // safe: the claim marker lives on item_registry.id, not on this UID

    // Store metadata as a dynamic field keyed by asset_id
    let data = ItemData { asset_id, key, name, volume, mass, url };
    df::add(&mut item_registry.id, asset_id, data);

    // Store reverse lookup
    item_registry.asset_ids.add(key, asset_id);

    event::emit(ItemTypeRegisteredEvent { asset_id, key, name, volume, mass, url });
    asset_id
}

/// Update the metadata for an existing item type.
///
/// **Volume caveat:** changing `volume` does NOT retroactively adjust `used_capacity`
/// on inventories that already hold this item.  Existing balances keep their original
/// capacity footprint until they are withdrawn and re-deposited.  Only future
/// deposit / mint operations will use the new volume for capacity checks.
public fun update_item_metadata(
    item_registry: &mut ItemRegistry,
    _: &AdminCap,
    asset_id: ID,
    name: String,
    volume: u64,
    mass: u64,
    url: String,
) {
    assert!(df::exists_(&item_registry.id, asset_id), EAssetNotRegistered);
    let data = df::borrow_mut<ID, ItemData>(&mut item_registry.id, asset_id);
    data.name = name;
    data.volume = volume;
    data.mass = mass;
    data.url = url;

    event::emit(ItemMetadataUpdatedEvent { asset_id, name, volume, mass, url });
}

// === ItemData View Functions ===

/// Borrow the full metadata for an asset.
public fun item_data(registry: &ItemRegistry, asset_id: ID): &ItemData {
    assert!(df::exists_(&registry.id, asset_id), EAssetNotRegistered);
    df::borrow(&registry.id, asset_id)
}

/// Check whether an asset_id has been registered.
public fun item_exists(registry: &ItemRegistry, asset_id: ID): bool {
    df::exists_(&registry.id, asset_id)
}

/// Look up the `asset_id` for a `(type_id, tenant)` pair.  Aborts if not registered.
public fun asset_id_for(registry: &ItemRegistry, type_id: u64, tenant: String): ID {
    let key = in_game_id::create_type_key(type_id, tenant);
    assert!(registry.asset_ids.contains(key), EAssetNotRegistered);
    *registry.asset_ids.borrow(key)
}

/// Check whether a `(type_id, tenant)` pair has been registered.
public fun is_type_registered(registry: &ItemRegistry, type_id: u64, tenant: String): bool {
    let key = in_game_id::create_type_key(type_id, tenant);
    registry.asset_ids.contains(key)
}

// Accessors on ItemData
public fun data_asset_id(data: &ItemData): ID { data.asset_id }

public fun data_key(data: &ItemData): TenantTypeId { data.key }

public fun data_name(data: &ItemData): String { data.name }

public fun data_volume(data: &ItemData): u64 { data.volume }

public fun data_mass(data: &ItemData): u64 { data.mass }

public fun data_url(data: &ItemData): String { data.url }

/// Convenience: look up per-unit volume for an asset directly.
public fun volume(registry: &ItemRegistry, asset_id: ID): u64 {
    item_data(registry, asset_id).volume
}

// === Balance API (public) ===

public fun balance_asset_id(b: &ItemBalance): ID { b.asset_id }

public fun value(b: &ItemBalance): u64 { b.value }

/// Consume a balance and return its `(asset_id, value)` parts.
public fun into_parts(b: ItemBalance): (ID, u64) {
    let ItemBalance { asset_id, value } = b;
    (asset_id, value)
}

/// Create a zero-value balance for the given asset.
public fun zero(asset_id: ID): ItemBalance {
    ItemBalance { asset_id, value: 0 }
}

/// Merge `other` into `self`.  Aborts if the asset ids differ.  Returns the new total.
public fun join(self: &mut ItemBalance, other: ItemBalance): u64 {
    let ItemBalance { asset_id, value } = other;
    assert!(self.asset_id == asset_id, EAssetMismatch);
    self.value = self.value + value;
    self.value
}

/// Split `value` units out of `self` into a new balance.  Aborts if insufficient.
public fun split(self: &mut ItemBalance, value: u64): ItemBalance {
    assert!(self.value >= value, ENotEnough);
    self.value = self.value - value;
    ItemBalance { asset_id: self.asset_id, value }
}

/// Withdraw the entire balance, leaving `self` at zero.
public fun withdraw_all(self: &mut ItemBalance): ItemBalance {
    let value = self.value;
    split(self, value)
}

/// Destroy a zero-value balance.  Aborts if `value != 0`.
public fun destroy_zero(balance: ItemBalance) {
    assert!(balance.value == 0, ENonZero);
    let ItemBalance { .. } = balance;
}

// === Mint / Burn API (package-internal) ===

/// Create a new `ItemBalance` for `asset_id` (validates asset is registered).
///
/// Package-internal: called by `inventory::mint` during the game-to-chain bridge.
/// Supply is tracked off-chain via `ItemMintedEvent`.
public(package) fun increase_supply(
    registry: &ItemRegistry,
    asset_id: ID,
    value: u64,
): ItemBalance {
    assert!(df::exists_(&registry.id, asset_id), EAssetNotRegistered);
    ItemBalance { asset_id, value }
}

/// Destroy a balance and return the burned value (validates asset is registered).
///
/// Package-internal: called by `inventory::burn` during the chain-to-game bridge.
/// Supply is tracked off-chain via `ItemBurnedEvent`.
public(package) fun decrease_supply(registry: &ItemRegistry, balance: ItemBalance): u64 {
    let ItemBalance { asset_id, value } = balance;
    assert!(df::exists_(&registry.id, asset_id), EAssetNotRegistered);
    value
}

/// Create an `ItemBalance` directly (no supply change).
///
/// Package-internal: used for moving balances between containers.
public(package) fun new(asset_id: ID, value: u64): ItemBalance {
    ItemBalance { asset_id, value }
}

// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun test_increase_supply(registry: &ItemRegistry, asset_id: ID, value: u64): ItemBalance {
    increase_supply(registry, asset_id, value)
}

#[test_only]
public fun test_decrease_supply(registry: &ItemRegistry, balance: ItemBalance): u64 {
    decrease_supply(registry, balance)
}
