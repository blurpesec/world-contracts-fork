/// Vault Receipts extension demonstrating bearer token (deposit receipt) pattern.
///
/// This extension allows players to deposit items into the main inventory and receive
/// a transferable bearer token (DepositReceipt) representing their deposit.
/// The receipt can be freely transferred, sold, or held, and later redeemed by
/// whoever possesses it to withdraw the deposited items.
///
/// Flow:
/// 1. Player calls `deposit_for_receipt` to move items from ephemeral -> main inventory
/// 2. Extension mints a `DepositReceipt` (owned object) and transfers it to the depositor
/// 3. Receipt holder (anyone) can call `redeem_receipt` to withdraw items to their ephemeral
///
/// Use Cases:
/// - Escrow services
/// - Collateralized lending (receipt as collateral)
/// - Tradeable warehouse receipts
/// - Gift vouchers / claim tickets
///
/// Note: Items with the same `type_id` are pooled in main inventory. If multiple receipts
/// exist for the same type, redemption follows FIFO order from the shared pool.
module extension_examples::vault_receipts;

use sui::event;
use world::{
    access::OwnerCap,
    character::Character,
    inventory,
    storage_unit::StorageUnit,
};

// === Errors ===
#[error(code = 0)]
const EStorageUnitMismatch: vector<u8> = b"Receipt belongs to a different storage unit";

// === Structs ===

/// Witness type for extension authorization
public struct VaultAuth has drop {}

/// Bearer token representing deposited items.
/// Whoever holds this receipt can redeem the items from the storage unit.
public struct DepositReceipt has key, store {
    id: UID,
    /// The storage unit where the items are deposited
    storage_unit_id: ID,
    /// The type of items deposited
    type_id: u64,
    /// The quantity of items this receipt represents
    quantity: u32,
    /// Optional: original depositor for tracking/auditing
    depositor: address,
}

// === Events ===

public struct ReceiptMintedEvent has copy, drop {
    receipt_id: ID,
    storage_unit_id: ID,
    type_id: u64,
    quantity: u32,
    depositor: address,
}

public struct ReceiptRedeemedEvent has copy, drop {
    receipt_id: ID,
    storage_unit_id: ID,
    type_id: u64,
    quantity: u32,
    redeemer: address,
}

// === Public Functions ===

/// Returns the VaultAuth witness for extension authorization
public fun vault_auth(): VaultAuth { VaultAuth {} }

/// Deposit items from player's ephemeral inventory into main inventory and mint a receipt.
/// The receipt is transferred to the depositor and can be freely traded.
///
/// # Arguments
/// * `storage_unit` - The storage unit to deposit into
/// * `character` - The depositor's character
/// * `owner_cap` - The depositor's OwnerCap (Character or StorageUnit)
/// * `type_id` - The type of items to deposit
///
/// # Returns
/// * `DepositReceipt` - Bearer token representing the deposit
public fun deposit_for_receipt<T: key>(
    storage_unit: &mut StorageUnit,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    type_id: u64,
    ctx: &mut TxContext,
): DepositReceipt {
    // Withdraw from player's ephemeral inventory
    let (item, item_location) = storage_unit.withdraw_from_owned<VaultAuth, T>(
        character,
        owner_cap,
        VaultAuth {},
        type_id,
        ctx,
    );

    let quantity = inventory::quantity(&item);

    // Deposit to main inventory (extension-controlled)
    storage_unit.deposit_item<VaultAuth>(
        character,
        item,
        item_location,
        VaultAuth {},
        ctx,
    );

    // Mint bearer receipt
    let receipt_uid = object::new(ctx);
    let receipt_id = object::uid_to_inner(&receipt_uid);
    let storage_unit_id = object::id(storage_unit);
    let depositor = ctx.sender();

    event::emit(ReceiptMintedEvent {
        receipt_id,
        storage_unit_id,
        type_id,
        quantity,
        depositor,
    });

    DepositReceipt {
        id: receipt_uid,
        storage_unit_id,
        type_id,
        quantity,
        depositor,
    }
}

/// Redeem a receipt to withdraw items from main inventory to the redeemer's ephemeral.
/// The receipt is burned upon redemption.
///
/// # Arguments
/// * `receipt` - The bearer receipt to redeem (consumed)
/// * `storage_unit` - The storage unit to withdraw from
/// * `character` - The redeemer's character
/// * `owner_cap` - The redeemer's OwnerCap (Character or StorageUnit)
public fun redeem_receipt<T: key>(
    receipt: DepositReceipt,
    storage_unit: &mut StorageUnit,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    ctx: &mut TxContext,
) {
    let DepositReceipt {
        id,
        storage_unit_id,
        type_id,
        quantity,
        ..
    } = receipt;

    let receipt_id = object::uid_to_inner(&id);

    // Verify receipt matches this storage unit
    assert!(storage_unit_id == object::id(storage_unit), EStorageUnitMismatch);

    // Delete the receipt
    id.delete();

    // Withdraw from main inventory
    let (item, item_location) = storage_unit.withdraw_item<VaultAuth>(
        character,
        VaultAuth {},
        type_id,
        ctx,
    );

    // Deposit to redeemer's ephemeral inventory
    let redeemer_cap_id = object::id(owner_cap);
    storage_unit.deposit_to_owned<VaultAuth>(
        character,
        redeemer_cap_id,
        item,
        item_location,
        VaultAuth {},
        ctx,
    );

    event::emit(ReceiptRedeemedEvent {
        receipt_id,
        storage_unit_id,
        type_id,
        quantity,
        redeemer: ctx.sender(),
    });
}

// === View Functions ===

/// Returns the storage unit ID this receipt is redeemable at
public fun receipt_storage_unit_id(receipt: &DepositReceipt): ID {
    receipt.storage_unit_id
}

/// Returns the item type this receipt represents
public fun receipt_type_id(receipt: &DepositReceipt): u64 {
    receipt.type_id
}

/// Returns the quantity of items this receipt represents
public fun receipt_quantity(receipt: &DepositReceipt): u32 {
    receipt.quantity
}

/// Returns the original depositor's address
public fun receipt_depositor(receipt: &DepositReceipt): address {
    receipt.depositor
}
