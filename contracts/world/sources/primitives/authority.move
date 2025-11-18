/// This module manages issuing capabilities for world objects for access control.
///
/// The module defines three levels of capabilities:
/// - `GovernorCap`: Top-level capability (defined in world module)
/// - `AdminCap`: Mid-level capability that can be created by the Governor
/// - `OwnerCap`: Object-level capability that can be created by Admins
///
/// This hierarchy allows for delegation of permissions:
/// - Governor can create/delete AdminCaps for specific addresses
/// - Admins can create/transfer/delete OwnerCaps
/// Future: Capability registry to support multi party access/shared control. (eg: A capability for corporatio/tribe with multiple members)
/// Capabilities based on different roles/permission in a corporation/tribe.

module world::authority;

use sui::{event, table::{Self, Table}};
use world::world::GovernorCap;

public struct AdminCap has key {
    id: UID,
    admin: address,
}

public struct OwnerCap has key {
    id: UID,
    owned_object_id: ID,
}

/// Registry of authorized server addresses that can sign location proofs.
/// Only the deployer (stored in `admin`) can modify it.
public struct ServerAddressRegistry has key {
    id: UID,
    authorized_address: Table<address, bool>,
}

public struct AdminCapCreatedEvent has copy, drop {
    admin_cap_id: ID,
    admin: address,
}

public struct ServerAddressRegistryCreated has copy, drop {
    server_address_registry_id: ID,
    registry_admin: address,
}

fun init(ctx: &mut TxContext) {
    let deployer = ctx.sender();
    let server_address_registry = ServerAddressRegistry {
        id: object::new(ctx),
        authorized_address: table::new(ctx),
    };

    event::emit(ServerAddressRegistryCreated {
        server_address_registry_id: object::id(&server_address_registry),
        registry_admin: deployer,
    });

    // Share the registry so anyone can read it for verification
    transfer::share_object(server_address_registry);
}

public fun create_admin_cap(_: &GovernorCap, admin: address, ctx: &mut TxContext) {
    let admin_cap = AdminCap {
        id: object::new(ctx),
        admin: admin,
    };
    event::emit(AdminCapCreatedEvent {
        admin_cap_id: object::id(&admin_cap),
        admin: admin,
    });

    transfer::transfer(admin_cap, admin);
}

public fun delete_admin_cap(admin_cap: AdminCap, _: &GovernorCap) {
    let AdminCap { id, .. } = admin_cap;
    id.delete();
}

public fun create_owner_cap(_: &AdminCap, owned_object_id: ID, ctx: &mut TxContext): OwnerCap {
    OwnerCap {
        id: object::new(ctx),
        owned_object_id: owned_object_id,
    }
}

public fun transfer_owner_cap(owner_cap: OwnerCap, _: &AdminCap, owner: address) {
    transfer::transfer(owner_cap, owner);
}

public fun register_server_address(
    server_address_registry: &mut ServerAddressRegistry,
    _: &GovernorCap,
    server_address: address,
) {
    table::add(&mut server_address_registry.authorized_address, server_address, true);
}

public fun remove_server_address(
    server_address_registry: &mut ServerAddressRegistry,
    _: &GovernorCap,
    server_address: address,
) {
    table::remove(&mut server_address_registry.authorized_address, server_address);
}

/// Checks if an address is an authorized server address.
public fun is_authorized_server_address(
    server_address_registry: &ServerAddressRegistry,
    address: address,
): bool {
    table::contains(&server_address_registry.authorized_address, address)
}

// Ideally only the owner can delete the owner cap
public fun delete_owner_cap(owner_cap: OwnerCap, _: &AdminCap) {
    let OwnerCap { id, .. } = owner_cap;
    id.delete();
}

// Checks if the `OwnerCap` is allowed to access the object with the given `object_id`.
/// Returns true iff the `OwnerCap` has mutation access for the specified object.
public fun is_authorized(owner_cap: &OwnerCap, object_id: ID): bool {
    owner_cap.owned_object_id == object_id
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
