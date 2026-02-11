/// Inventory module — capacity-aware container for `ItemBalance` entries.
///
/// each item in an inventory is represented by an `ItemBalance` keyed by `asset_id` (registered in `ItemRegistry`).
///
/// Bridging items from game to chain and back:
/// - The game is the “trusted bridge” for bringing items from the game to the chain.
/// - **Game → Chain (mint):** admin/sponsor calls `mint` which creates a balance
///   and deposits it into the inventory.
/// - **Chain → Game (burn):** player calls `burn_with_proof` which verifies proximity,
///   splits the balance out of the inventory, and destroys it.
///
/// Transfers between inventories use `deposit` / `withdraw` (no supply change).
///
/// Supply tracking is off-chain via events; `ItemRegistry` is read-only (`&ItemRegistry`)
/// on all paths to prevent shared-object congestion.
///
/// ## First-time item types
///
/// All functions assume the item type is already registered in `ItemRegistry`.
/// For the first mint of a new item type, the backend composes registration and minting
/// atomically in a single PTB — see `item_balance` module docs for the pattern.
module world::inventory;

use sui::{clock::Clock, event, vec_map::{Self, VecMap}};
use world::{
    access::ServerAddressRegistry,
    character::Character,
    in_game_id::{Self, TenantItemId},
    item_balance::{Self, ItemBalance, ItemRegistry},
    location::{Self, Location}
};

// === Errors ===
#[error(code = 0)]
const EInventoryInvalidCapacity: vector<u8> = b"Inventory Capacity cannot be 0";
#[error(code = 1)]
const EInventoryInsufficientCapacity: vector<u8> = b"Insufficient capacity in the inventory";
#[error(code = 2)]
const EItemDoesNotExist: vector<u8> = b"Item not found in inventory";
#[error(code = 3)]
const EInventoryInsufficientQuantity: vector<u8> = b"Insufficient quantity in inventory";
#[error(code = 4)]
const ETenantMismatch: vector<u8> = b"Tenant mismatch";

// === Structs ===

/// Capacity-gated container for item balances.
/// Stored as a dynamic field on parent objects (StorageUnit, etc.) — no `key` ability.
public struct Inventory has store {
    max_capacity: u64,
    used_capacity: u64,
    /// Balances keyed by `asset_id`.  Small-N VecMap is fine for typical inventory sizes.
    balances: VecMap<ID, ItemBalance>,
    /// Per-unit volume locked in at first deposit for each asset slot.
    /// Ensures withdraw/burn frees exactly the capacity that was claimed,
    /// even if the registry volume is changed after deposit.
    slot_volumes: VecMap<ID, u64>,
}

// === Events ===

public struct ItemMintedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    asset_id: ID,
    type_id: u64,
    quantity: u64,
}

public struct ItemBurnedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    asset_id: ID,
    type_id: u64,
    quantity: u64,
}

public struct ItemDepositedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    asset_id: ID,
    type_id: u64,
    quantity: u64,
}

public struct ItemWithdrawnEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    asset_id: ID,
    type_id: u64,
    quantity: u64,
}

public struct InventoryDestroyedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    asset_id: ID,
    type_id: u64,
    quantity: u64,
}

// === View Functions ===

public fun contains_item(inventory: &Inventory, asset_id: ID): bool {
    inventory.balances.contains(&asset_id)
}

public fun max_capacity(inventory: &Inventory): u64 {
    inventory.max_capacity
}

public fun balance_value(inventory: &Inventory, asset_id: ID): u64 {
    if (!inventory.balances.contains(&asset_id)) {
        return 0
    };
    item_balance::value(&inventory.balances[&asset_id])
}

// === Package Functions ===

public(package) fun create(max_capacity: u64): Inventory {
    assert!(max_capacity != 0, EInventoryInvalidCapacity);

    Inventory {
        max_capacity,
        used_capacity: 0,
        balances: vec_map::empty(),
        slot_volumes: vec_map::empty(),
    }
}

/// Mints new balance into inventory (Game → Chain bridge).
///
/// Creates an `ItemBalance` and deposits it into the inventory.
/// Capacity is checked using per-unit volume from `ItemRegistry`.
public(package) fun mint(
    inventory: &mut Inventory,
    item_registry: &ItemRegistry,
    asset_id: ID,
    quantity: u64,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
) {
    assert_tenant_match(item_registry, asset_id, assembly_key);

    // Use locked-in volume if slot exists, otherwise lock in from registry
    let unit_volume = if (inventory.slot_volumes.contains(&asset_id)) {
        inventory.slot_volumes[&asset_id]
    } else {
        let vol = item_balance::volume(item_registry, asset_id);
        inventory.slot_volumes.insert(asset_id, vol);
        vol
    };

    let req_capacity = unit_volume * quantity;
    let remaining = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining, EInventoryInsufficientCapacity);

    // Create fresh ItemBalance (supply tracked off-chain via events)
    let balance = item_balance::increase_supply(item_registry, asset_id, quantity);

    // Join into existing slot or insert new
    if (inventory.balances.contains(&asset_id)) {
        let existing = &mut inventory.balances[&asset_id];
        existing.join(balance);
    } else {
        inventory.balances.insert(asset_id, balance);
    };

    inventory.used_capacity = inventory.used_capacity + req_capacity;

    event::emit(ItemMintedEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        asset_id,
        type_id: lookup_type_id(item_registry, asset_id),
        quantity,
    });
}

/// Burns items from inventory with proximity proof (Chain → Game bridge).
///
/// Verifies the location proof, splits the balance out of the inventory,
/// and destroys it.
public(package) fun burn_with_proof(
    inventory: &mut Inventory,
    item_registry: &ItemRegistry,
    asset_id: ID,
    quantity: u64,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    server_registry: &ServerAddressRegistry,
    location: &Location,
    location_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    location::verify_proximity_proof_from_bytes(
        server_registry,
        location,
        location_proof,
        clock,
        ctx,
    );
    burn(inventory, item_registry, asset_id, quantity, assembly_id, assembly_key, character);
}

/// Deposits an `ItemBalance` into inventory (transfer between inventories — no supply change).
///
/// Capacity is checked using per-unit volume from `ItemRegistry`.
public(package) fun deposit(
    inventory: &mut Inventory,
    item_registry: &ItemRegistry,
    balance: ItemBalance,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
) {
    let asset_id = balance.balance_asset_id();
    let quantity = balance.value();
    assert_tenant_match(item_registry, asset_id, assembly_key);

    // Use locked-in volume if slot exists, otherwise lock in from registry
    let unit_volume = if (inventory.slot_volumes.contains(&asset_id)) {
        inventory.slot_volumes[&asset_id]
    } else {
        let vol = item_balance::volume(item_registry, asset_id);
        inventory.slot_volumes.insert(asset_id, vol);
        vol
    };

    let req_capacity = unit_volume * quantity;
    let remaining = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining, EInventoryInsufficientCapacity);

    // Join into existing slot or insert new
    if (inventory.balances.contains(&asset_id)) {
        let existing = &mut inventory.balances[&asset_id];
        existing.join(balance);
    } else {
        inventory.balances.insert(asset_id, balance);
    };

    inventory.used_capacity = inventory.used_capacity + req_capacity;

    event::emit(ItemDepositedEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        asset_id,
        type_id: lookup_type_id(item_registry, asset_id),
        quantity,
    });
}

/// Withdraws an `ItemBalance` from inventory (transfer between inventories — no supply change).
///
/// Splits the requested quantity from the inventory slot.  Removes the slot if fully drained.
public(package) fun withdraw(
    inventory: &mut Inventory,
    item_registry: &ItemRegistry,
    asset_id: ID,
    quantity: u64,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
): ItemBalance {
    assert!(inventory.balances.contains(&asset_id), EItemDoesNotExist);

    let unit_volume = inventory.slot_volumes[&asset_id];

    // Check if withdrawing entire balance
    let full_withdraw = {
        let bal = &inventory.balances[&asset_id];
        bal.value() == quantity
    };

    let withdrawn = if (full_withdraw) {
        let (_, balance) = inventory.balances.remove(&asset_id);
        inventory.slot_volumes.remove(&asset_id);
        balance
    } else {
        let balance = &mut inventory.balances[&asset_id];
        assert!(balance.value() >= quantity, EInventoryInsufficientQuantity);
        balance.split(quantity)
    };

    let freed_capacity = unit_volume * quantity;
    inventory.used_capacity = inventory.used_capacity - freed_capacity;

    event::emit(ItemWithdrawnEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        asset_id,
        type_id: lookup_type_id(item_registry, asset_id),
        quantity,
    });

    withdrawn
}

/// Destroys the inventory and burns all remaining balances.
public(package) fun delete(
    inventory: Inventory,
    item_registry: &ItemRegistry,
    assembly_id: ID,
    assembly_key: TenantItemId,
) {
    let Inventory {
        mut balances,
        mut slot_volumes,
        ..,
    } = inventory;

    while (!balances.is_empty()) {
        let (asset_id, balance) = balances.pop();
        let quantity = balance.value();

        event::emit(InventoryDestroyedEvent {
            assembly_id,
            assembly_key,
            asset_id,
            type_id: lookup_type_id(item_registry, asset_id),
            quantity,
        });

        item_balance::decrease_supply(item_registry, balance);
    };
    balances.destroy_empty();
    // Clean up slot_volumes – entries may already have been removed during
    // full withdrawals/burns, but any remaining are discarded here.
    while (!slot_volumes.is_empty()) {
        slot_volumes.pop();
    };
    slot_volumes.destroy_empty();
}

// FUTURE: transfer items between inventory, eg: inventory to inventory on-chain.
// This needs location proof and distance to enforce digital physics.

// === Private Functions ===

/// Looks up the game `type_id` for a registered asset.
fun lookup_type_id(item_registry: &ItemRegistry, asset_id: ID): u64 {
    in_game_id::type_id(&item_balance::item_data(item_registry, asset_id).data_key())
}

/// Asserts that the item's tenant matches the assembly's tenant.
fun assert_tenant_match(item_registry: &ItemRegistry, asset_id: ID, assembly_key: TenantItemId) {
    let item_tenant = in_game_id::type_tenant(
        &item_balance::item_data(item_registry, asset_id).data_key(),
    );
    let assembly_tenant = in_game_id::tenant(&assembly_key);
    assert!(item_tenant == assembly_tenant, ETenantMismatch);
}

/// Internal burn: splits balance from inventory and destroys it.
fun burn(
    inventory: &mut Inventory,
    item_registry: &ItemRegistry,
    asset_id: ID,
    quantity: u64,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
) {
    assert!(inventory.balances.contains(&asset_id), EItemDoesNotExist);

    let unit_volume = inventory.slot_volumes[&asset_id];

    // Check if burning entire balance
    let full_burn = {
        let bal = &inventory.balances[&asset_id];
        assert!(bal.value() >= quantity, EInventoryInsufficientQuantity);
        bal.value() == quantity
    };

    let burned = if (full_burn) {
        let (_, balance) = inventory.balances.remove(&asset_id);
        inventory.slot_volumes.remove(&asset_id);
        balance
    } else {
        let balance = &mut inventory.balances[&asset_id];
        balance.split(quantity)
    };

    let freed_capacity = unit_volume * quantity;
    inventory.used_capacity = inventory.used_capacity - freed_capacity;

    // Destroy the balance (supply tracked off-chain via events)
    item_balance::decrease_supply(item_registry, burned);

    event::emit(ItemBurnedEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        asset_id,
        type_id: lookup_type_id(item_registry, asset_id),
        quantity,
    });
}

// === Test Functions ===
#[test_only]
public fun remaining_capacity(inventory: &Inventory): u64 {
    inventory.max_capacity - inventory.used_capacity
}

#[test_only]
public fun used_capacity(inventory: &Inventory): u64 {
    inventory.used_capacity
}

#[test_only]
public fun item_quantity(inventory: &Inventory, asset_id: ID): u64 {
    if (!inventory.balances.contains(&asset_id)) {
        return 0
    };
    item_balance::value(&inventory.balances[&asset_id])
}

#[test_only]
public fun inventory_item_length(inventory: &Inventory): u64 {
    inventory.balances.length()
}

#[test_only]
public fun burn_items_test(
    inventory: &mut Inventory,
    item_registry: &ItemRegistry,
    asset_id: ID,
    quantity: u64,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
) {
    burn(inventory, item_registry, asset_id, quantity, assembly_id, assembly_key, character);
}

#[test_only]
public fun burn_with_proof_test(
    inventory: &mut Inventory,
    item_registry: &ItemRegistry,
    asset_id: ID,
    quantity: u64,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    server_registry: &ServerAddressRegistry,
    location: &Location,
    location_proof: vector<u8>,
    ctx: &mut TxContext,
) {
    location::verify_proximity_proof_from_bytes_without_deadline(
        server_registry,
        location,
        location_proof,
        ctx,
    );
    burn(inventory, item_registry, asset_id, quantity, assembly_id, assembly_key, character);
}
