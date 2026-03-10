/// Shared types and event for freezing assembly extension configuration.
/// Used by Gate, Turret, and StorageUnit so the owner cannot change the extension after freeze (no rugpull).
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
public fun freeze_extension_config(parent: &mut UID, assembly_id: ID, ctx: &mut TxContext) {
    df::add(parent, ExtensionFrozenKey {}, ExtensionFrozen { id: object::new(ctx) });
    event::emit(ExtensionConfigFrozenEvent { assembly_id });
}
