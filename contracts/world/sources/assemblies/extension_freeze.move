/// Shared types and event for freezing assembly extension configuration.
/// Used by Gate, Turret, and StorageUnit so the owner cannot change the extension after freeze (no rugpull).
///
/// **Tradeoff:** Once frozen, the assembly cannot be re-authorised to a different or fixed extension package.
/// If a bug is found in the extension code, the owner cannot point this assembly at a fixed version; they would
/// need to use a new assembly (e.g. anchor a new gate) and authorise the fixed extension there. Freeze only
/// after the extension is audited/tested and you are comfortable with this permanence.
module world::extension_freeze;

use sui::{dynamic_field as df, event};

/// Dynamic field key for the "extension config frozen" slot on an assembly.
public struct ExtensionFrozenKey has copy, drop, store {}

/// Marker value stored as a dynamic field when extension config is frozen.
public struct ExtensionFrozen has key, store {
    id: UID,
}

/// Emitted when an assembly's extension configuration is frozen.
public struct ExtensionConfigFrozenEvent has copy, drop {
    assembly_id: ID,
}

/// Returns true if the given object has its extension config frozen (dynamic field present).
public fun is_extension_frozen(object: &UID): bool {
    df::exists_<ExtensionFrozenKey>(object, ExtensionFrozenKey {})
}

/// Adds the frozen marker and emits the event. Call from Gate/Turret/StorageUnit after auth and extension checks.
/// One-time and irreversible: the assembly will stay on this extension package; no upgrade path if the extension has a bug.
public fun freeze_extension_config(parent: &mut UID, assembly_id: ID, ctx: &mut TxContext) {
    df::add(parent, ExtensionFrozenKey {}, ExtensionFrozen { id: object::new(ctx) });
    event::emit(ExtensionConfigFrozenEvent { assembly_id });
}
