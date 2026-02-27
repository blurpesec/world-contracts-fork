/// Inventory: on-chain item storage with split/join semantics.
///
/// # Architecture — Coin/Balance pattern
///
/// Items use a two-form design inspired by Sui's `Coin` / `Balance` split:
///
/// - **`ItemEntry`** (at-rest) — lightweight data with `copy, drop, store`. Lives inside
///   the `Inventory` struct. No UID, no object overhead. Analogous to `Balance`.
/// - **`Item`** (in-transit) — a full Sui object with `key, store` and a UID. Created on
///   withdrawal, consumed on deposit. Analogous to `Coin`.
///
/// # Volume versioning — separate entries per volume
///
/// The game server may change an item type's volume between mints. Instead of
/// retroactively recalculating capacity for all existing items (which can silently
/// block deposits or break capacity logic), each distinct volume is stored as a
/// **separate entry** in the vector for that `type_id`:
///
///   `items: VecMap<u64, vector<ItemEntry>>`
///         type_id ──┘        └── stack of entries, one per volume cohort
///
/// **Invariants:**
///   - New entries are always appended (`push_back`), so the **last entry** always
///     carries the latest/newest volume.
///   - If the incoming volume matches the last entry's volume, we join (merge quantity).
///   - If the volume differs, we push a new entry — old entries are grandfathered.
///   - Capacity is always `sum(entry.volume * entry.quantity)` across all entries.
///     No retroactive inflation.
///
/// **Withdrawal (FIFO + latest volume):**
///   - Items are consumed oldest-first (index 0). Capacity is freed at each entry's
///     *own* volume, so old items release exactly the capacity they originally claimed.
///   - The transit `Item` always carries the **latest** volume (from the last entry),
///     ensuring items that land in another inventory reflect the most recent game state.
///
/// # Parent-ID tracking
///
/// Each transit `Item` carries a `parent_id` — the object ID of the assembly
/// (e.g. StorageUnit) the item was withdrawn from. The parent layer uses this on
/// deposit to verify items are returning to their origin. Location data is also
/// attached as metadata but is not used for deposit validation.
///
/// # Bridging
///
/// - **Game → Chain (mint):** The game server calls an admin-gated function to mint
///   items directly into an on-chain inventory.
/// - **Chain → Game (burn):** Burning emits an `ItemBurnedEvent`; the game server
///   listens and creates the item in-game. Requires a proximity proof.
module world::inventory;

use std::string::String;
use sui::{clock::Clock, event, vec_map::{Self, VecMap}};
use world::{
    access::ServerAddressRegistry,
    character::Character,
    in_game_id::TenantItemId,
    location::{Self, Location}
};

// === Errors ===
#[error(code = 0)]
const ETypeIdEmpty: vector<u8> = b"Type ID cannot be empty";
#[error(code = 1)]
const EInventoryInvalidCapacity: vector<u8> = b"Inventory Capacity cannot be 0";
#[error(code = 2)]
const EInventoryInsufficientCapacity: vector<u8> = b"Insufficient capacity in the inventory";
#[error(code = 3)]
const EItemDoesNotExist: vector<u8> = b"Item not found";
#[error(code = 4)]
const EInventoryInsufficientQuantity: vector<u8> = b"Insufficient quantity in inventory";
#[error(code = 5)]
const EItemVolumeMismatch: vector<u8> = b"Item volume must match for join operation";
#[error(code = 6)]
const ETypeIdMismatch: vector<u8> = b"Item type_id must match for join operation";
#[error(code = 7)]
const ESplitQuantityInvalid: vector<u8> =
    b"Split quantity must be greater than 0 and less than item quantity";

// === Structs ===

/// On-chain inventory that tracks items by `type_id`.
///
/// `items` maps each `type_id` to a **vector** of `ItemEntry` values. Multiple
/// entries exist when volume has changed over time — see module docs for details.
///
/// `used_capacity` is the running total of `volume * quantity` across every entry
/// in every type_id vector. It must never exceed `max_capacity`.
public struct Inventory has store {
    max_capacity: u64,
    used_capacity: u64,
    items: VecMap<u64, vector<ItemEntry>>,
}

/// At-rest item data stored inside an `Inventory`.
///
/// Has `copy, drop, store` — no UID, no object overhead. Think of this as the
/// `Balance` to `Item`'s `Coin`. Split and join operate directly on this form.
///
/// Does **not** store location — location is just-in-time metadata injected by the
/// parent layer (e.g. StorageUnit) when creating a transit `Item` on withdrawal.
public struct ItemEntry has copy, drop, store {
    tenant: String,
    type_id: u64,
    item_id: u64,
    volume: u64,
    quantity: u32,
}

/// Transit form of an item — created on withdraw, consumed on deposit.
///
/// Carries a fresh UID so it can be transferred between inventories as a
/// first-class Sui object. Destroyed (UID deleted) when deposited.
///
/// `parent_id` is the object ID of the assembly this item was withdrawn from
/// (e.g. a StorageUnit). The parent layer checks this on deposit to ensure items
/// return to their origin.
public struct Item has key, store {
    id: UID,
    parent_id: ID,
    tenant: String,
    type_id: u64,
    item_id: u64,
    volume: u64,
    quantity: u32,
    location: Location,
}

// === Events ===
public struct ItemMintedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemBurnedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemDepositedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemWithdrawnEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemDestroyedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

// === View Functions ===
public fun tenant(item: &Item): String {
    item.tenant
}

public fun contains_item(inventory: &Inventory, type_id: u64): bool {
    inventory.items.contains(&type_id)
}

/// Returns the location hash from the transit Item (metadata only, not used for
/// deposit validation — parent_id is used instead).
public fun get_item_location_hash(item: &Item): vector<u8> {
    item.location.hash()
}

/// Returns the object ID of the assembly this item was withdrawn from.
public fun parent_id(item: &Item): ID {
    item.parent_id
}

public fun max_capacity(inventory: &Inventory): u64 {
    inventory.max_capacity
}

public fun type_id(item: &Item): u64 {
    item.type_id
}

public fun quantity(item: &Item): u32 {
    item.quantity
}

// === Package Functions ===

/// Split off `quantity` units from an entry, returning a new `ItemEntry`.
/// Both the source and the result will have non-zero quantity after the split.
public(package) fun split(entry: &mut ItemEntry, quantity: u32): ItemEntry {
    assert!(quantity > 0 && entry.quantity > quantity, ESplitQuantityInvalid);
    entry.quantity = entry.quantity - quantity;
    ItemEntry {
        tenant: entry.tenant,
        type_id: entry.type_id,
        item_id: entry.item_id,
        volume: entry.volume,
        quantity,
    }
}

/// Merge `other` into this entry. Both must have the same `type_id` **and** `volume`.
///
/// The volume check is defensive — callers (deposit/mint) only invoke `join` after
/// verifying volumes match. It guards against accidental misuse.
public(package) fun join(entry: &mut ItemEntry, other: ItemEntry) {
    assert!(entry.type_id == other.type_id, ETypeIdMismatch);
    assert!(entry.volume == other.volume, EItemVolumeMismatch);
    entry.quantity = entry.quantity + other.quantity;
}

public(package) fun create(max_capacity: u64): Inventory {
    assert!(max_capacity != 0, EInventoryInvalidCapacity);

    Inventory {
        max_capacity,
        used_capacity: 0,
        items: vec_map::empty(),
    }
}

/// Mints items into inventory (Game → Chain bridge).
///
/// Capacity cost is always `volume * quantity` of the *incoming* items only — no
/// retroactive recalculation of existing entries.
///
/// If the type_id already exists:
///   - Same volume as the last entry → join (increase quantity in place).
///   - Different volume → push a new entry (old-volume items are grandfathered).
/// Otherwise, creates a new vector with a single entry.
public(package) fun mint_items(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    tenant: String,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
) {
    assert!(type_id != 0, ETypeIdEmpty);

    let req_capacity = calculate_volume(volume, quantity);
    let remaining = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining, EInventoryInsufficientCapacity);
    // Capacity update happens before the mutable borrow of `items` to satisfy
    // the borrow checker — both operations touch `inventory`, but sequentially.
    inventory.used_capacity = inventory.used_capacity + req_capacity;

    if (inventory.items.contains(&type_id)) {
        let entries = &mut inventory.items[&type_id];
        let last_idx = entries.length() - 1;
        let last_volume = entries[last_idx].volume;
        let emit_item_id = entries[last_idx].item_id;

        if (last_volume == volume) {
            event::emit(ItemMintedEvent {
                assembly_id,
                assembly_key,
                character_id: character.id(),
                character_key: character.key(),
                item_id: emit_item_id,
                type_id,
                quantity,
            });
            let last = &mut entries[last_idx];
            last.quantity = last.quantity + quantity;
        } else {
            event::emit(ItemMintedEvent {
                assembly_id,
                assembly_key,
                character_id: character.id(),
                character_key: character.key(),
                item_id,
                type_id,
                quantity,
            });
            entries.push_back(ItemEntry { tenant, type_id, item_id, volume, quantity });
        };
    } else {
        event::emit(ItemMintedEvent {
            assembly_id,
            assembly_key,
            character_id: character.id(),
            character_key: character.key(),
            item_id,
            type_id,
            quantity,
        });
        inventory
            .items
            .insert(type_id, vector[ItemEntry { tenant, type_id, item_id, volume, quantity }]);
    };
}

// TODO: remove proximity proof check as it will be handled in the parent module
public(package) fun burn_items_with_proof(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    server_registry: &ServerAddressRegistry,
    location: &Location,
    location_proof: vector<u8>,
    type_id: u64,
    quantity: u32,
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
    burn_items(inventory, assembly_id, assembly_key, character, type_id, quantity);
}

/// Deposits a transit `Item` back into the inventory.
///
/// Destroys the `Item`'s UID, extracts its data into an `ItemEntry`, and either
/// joins into the last entry (if volumes match) or pushes a new entry (if they
/// differ). Capacity cost is only the incoming items — old entries are untouched.
///
/// Parent-ID validation is **not** done here — that is the responsibility of the
/// parent layer (e.g. storage_unit.move) which has access to the assembly's object ID.
public(package) fun deposit_item(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    item: Item,
) {
    let Item { id, parent_id: _, tenant, type_id, item_id, volume, quantity, location } = item;
    id.delete();
    location.remove();

    let req_capacity = calculate_volume(volume, quantity);
    let remaining = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining, EInventoryInsufficientCapacity);
    inventory.used_capacity = inventory.used_capacity + req_capacity;

    let entry = ItemEntry { tenant, type_id, item_id, volume, quantity };

    if (inventory.items.contains(&type_id)) {
        let entries = &mut inventory.items[&type_id];
        let last_idx = entries.length() - 1;
        let last_volume = entries[last_idx].volume;

        if (last_volume == volume) {
            let dep_item_id = entries[last_idx].item_id;
            event::emit(ItemDepositedEvent {
                assembly_id,
                assembly_key,
                character_id: character.id(),
                character_key: character.key(),
                item_id: dep_item_id,
                type_id,
                quantity,
            });
            let last = &mut entries[last_idx];
            last.join(entry);
        } else {
            event::emit(ItemDepositedEvent {
                assembly_id,
                assembly_key,
                character_id: character.id(),
                character_key: character.key(),
                item_id,
                type_id,
                quantity,
            });
            entries.push_back(entry);
        };
    } else {
        event::emit(ItemDepositedEvent {
            assembly_id,
            assembly_key,
            character_id: character.id(),
            character_key: character.key(),
            item_id,
            type_id,
            quantity,
        });
        inventory.items.insert(type_id, vector[entry]);
    };
}

/// Withdraws items from the inventory and wraps them into a transit `Item`.
///
/// **FIFO consumption:** oldest entries (index 0) are drained first. Each entry's
/// capacity is freed at its *own* volume, so grandfathered items release exactly
/// what they originally claimed.
///
/// **Latest-volume assignment:** the resulting `Item` carries the volume of the
/// *last* entry in the vector (the most recent game state), regardless of which
/// entries were consumed. This ensures depositing elsewhere uses the current volume.
///
/// `location_hash` is injected by the parent layer (e.g. StorageUnit) — it is not
/// stored in `ItemEntry` since it is just-in-time metadata for the transit `Item`.
///
/// `assembly_id` doubles as the `parent_id` on the resulting `Item`.
///
/// The entry vector is removed from the VecMap before mutation and re-inserted
/// afterward (if non-empty) to avoid borrow-checker conflicts with `used_capacity`.
public(package) fun withdraw_item(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    type_id: u64,
    quantity: u32,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): Item {
    assert!(inventory.items.contains(&type_id), EItemDoesNotExist);
    assert!(quantity > 0, ESplitQuantityInvalid);

    // Snapshot metadata via an immutable borrow before we mutate.
    let (total_qty, latest_volume, item_id, tenant) = {
        let entries = &inventory.items[&type_id];
        let len = entries.length();
        let first = &entries[0];
        let last = &entries[len - 1];
        (sum_quantity(entries), last.volume, first.item_id, first.tenant)
    };
    assert!(total_qty >= quantity, EInventoryInsufficientQuantity);

    // Remove the vector from VecMap so we can mutate it while also updating
    // `inventory.used_capacity` without conflicting mutable borrows.
    let (_, mut entries) = inventory.items.remove(&type_id);

    let mut remaining = quantity;
    let mut capacity_freed = 0u64;

    while (remaining > 0) {
        let front_qty = entries[0].quantity;
        let front_vol = entries[0].volume;
        if (front_qty <= remaining) {
            // Fully consume this entry.
            capacity_freed = capacity_freed + calculate_volume(front_vol, front_qty);
            remaining = remaining - front_qty;
            entries.remove(0);
        } else {
            // Partially consume — reduce quantity in place.
            capacity_freed = capacity_freed + calculate_volume(front_vol, remaining);
            let front = &mut entries[0];
            front.quantity = front.quantity - remaining;
            remaining = 0;
        };
    };

    inventory.used_capacity = inventory.used_capacity - capacity_freed;

    // Re-insert only if entries remain; otherwise the type_id is fully drained.
    if (!entries.is_empty()) {
        inventory.items.insert(type_id, entries);
    };

    event::emit(ItemWithdrawnEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        item_id,
        type_id,
        quantity,
    });

    Item {
        id: object::new(ctx),
        parent_id: assembly_id,
        tenant,
        type_id,
        item_id,
        volume: latest_volume,
        quantity,
        location: location::attach(location_hash),
    }
}

/// Destroys the inventory, emitting an `ItemDestroyedEvent` per entry.
public(package) fun delete(inventory: Inventory, assembly_id: ID, assembly_key: TenantItemId) {
    let Inventory {
        mut items,
        ..,
    } = inventory;

    while (!items.is_empty()) {
        let (_, entries) = items.pop();
        let mut i = 0;
        while (i < entries.length()) {
            event::emit(ItemDestroyedEvent {
                assembly_id,
                assembly_key,
                item_id: entries[i].item_id,
                type_id: entries[i].type_id,
                quantity: entries[i].quantity,
            });
            i = i + 1;
        };
    };
    items.destroy_empty();
}

// FUTURE: transfer items between inventory, eg: inventory to inventory on-chain.
// This needs location proof and distance to enforce digital physics.
// public fun transfer_items() {}

// === Private Functions ===

/// Burns items from on-chain inventory (Chain → Game bridge).
///
/// Same FIFO logic as `withdraw_item` — oldest entries consumed first, capacity
/// freed at each entry's own volume — but no transit `Item` is created. Instead,
/// an `ItemBurnedEvent` is emitted for the game server to pick up.
fun burn_items(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    type_id: u64,
    quantity: u32,
) {
    assert!(inventory.items.contains(&type_id), EItemDoesNotExist);

    let (total_qty, item_id) = {
        let entries = &inventory.items[&type_id];
        (sum_quantity(entries), entries[0].item_id)
    };
    assert!(total_qty >= quantity, EInventoryInsufficientQuantity);

    // Same remove-mutate-reinsert pattern as withdraw_item.
    let (_, mut entries) = inventory.items.remove(&type_id);

    let mut remaining = quantity;
    let mut capacity_freed = 0u64;

    while (remaining > 0) {
        let front_qty = entries[0].quantity;
        let front_vol = entries[0].volume;
        if (front_qty <= remaining) {
            capacity_freed = capacity_freed + calculate_volume(front_vol, front_qty);
            remaining = remaining - front_qty;
            entries.remove(0);
        } else {
            capacity_freed = capacity_freed + calculate_volume(front_vol, remaining);
            let front = &mut entries[0];
            front.quantity = front.quantity - remaining;
            remaining = 0;
        };
    };

    inventory.used_capacity = inventory.used_capacity - capacity_freed;

    if (!entries.is_empty()) {
        inventory.items.insert(type_id, entries);
    };

    event::emit(ItemBurnedEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        item_id,
        type_id,
        quantity,
    });
}

/// Total capacity consumed by a single entry: `volume * quantity`.
fun calculate_volume(volume: u64, quantity: u32): u64 {
    volume * (quantity as u64)
}

/// Sums quantity across all entries in a type_id's vector.
fun sum_quantity(entries: &vector<ItemEntry>): u32 {
    let mut total = 0u32;
    let mut i = 0;
    while (i < entries.length()) {
        total = total + entries[i].quantity;
        i = i + 1;
    };
    total
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

/// Returns the *total* quantity across all volume cohorts for this type_id.
#[test_only]
public fun item_quantity(inventory: &Inventory, type_id: u64): u32 {
    sum_quantity(&inventory.items[&type_id])
}

/// Returns the *latest* volume (last entry) for this type_id.
#[test_only]
public fun item_volume(inventory: &Inventory, type_id: u64): u64 {
    let entries = &inventory.items[&type_id];
    entries[entries.length() - 1].volume
}

/// Number of unique type_ids in the inventory (not total entries).
#[test_only]
public fun inventory_item_length(inventory: &Inventory): u64 {
    inventory.items.length()
}

/// Number of separate volume cohorts stored for this type_id.
/// Returns 1 when all items share the same volume; >1 when volume has changed.
#[test_only]
public fun item_entry_count(inventory: &Inventory, type_id: u64): u64 {
    inventory.items[&type_id].length()
}

#[test_only]
public fun burn_items_test(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    type_id: u64,
    quantity: u32,
) {
    burn_items(inventory, assembly_id, assembly_key, character, type_id, quantity);
}

#[test_only]
public fun burn_items_with_proof_test(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    server_registry: &ServerAddressRegistry,
    location: &Location,
    location_proof: vector<u8>,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    location::verify_proximity_proof_from_bytes_without_deadline(
        server_registry,
        location,
        location_proof,
        ctx,
    );
    burn_items(inventory, assembly_id, assembly_key, character, type_id, quantity);
}
