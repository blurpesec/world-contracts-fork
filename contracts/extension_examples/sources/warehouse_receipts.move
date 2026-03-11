/// Vault Receipts extension for StorageUnit — deposit/redeem using warehouse receipts.
///
/// This extension allows players to deposit items into the open inventory and receive
/// a transferable `WarehouseReceipt` (bearer token) representing their deposit.
/// The receipt can be freely transferred, sold, or held, and later redeemed by
/// whoever possesses it to withdraw the deposited items.
///
/// Flow:
/// 1. Player calls `deposit_for_receipt` to move items from owned → open inventory
/// 2. Extension mints a `WarehouseReceipt` and returns it to the caller
/// 3. Receipt holder (anyone) calls `redeem_receipt` to withdraw items into their owned inventory
///
/// Use Cases:
/// - Escrow services
/// - Collateralized lending (receipt as collateral)
/// - Tradeable warehouse receipts
/// - Gift vouchers / claim tickets
///
/// The `WarehouseReceipt` struct and its Coin-like manipulation API (split, join, etc.)
/// live in the sibling `warehouse_receipt` module. This module is the extension that
/// interacts with `StorageUnit` to mint and burn receipts.
///
/// Note: Items with the same `type_id` are pooled in open inventory. If multiple receipts
/// exist for the same type, redemption follows FIFO order from the shared pool.
module extension_examples::warehouse_receipts;

use sui::event;
use world::{
    access::OwnerCap,
    character::Character,
    storage_unit::StorageUnit,
};
use extension_examples::warehouse_receipt::{Self, WarehouseReceipt};

// === Errors ===
#[error(code = 0)]
const EStorageUnitMismatch: vector<u8> = b"Receipt belongs to a different storage unit";

// === Structs ===

/// Witness type for extension authorization
public struct VaultAuth has drop {}

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

/// Deposit items from player's owned inventory into the extension-controlled
/// open inventory and mint a receipt.
/// The receipt is returned to the caller and can be freely traded.
///
/// # Arguments
/// * `storage_unit` - The storage unit to deposit into
/// * `character` - The depositor's character
/// * `owner_cap` - The depositor's OwnerCap (Character or StorageUnit)
/// * `type_id` - The type of items to deposit
/// * `quantity` - The quantity of items to deposit
///
/// # Returns
/// * `WarehouseReceipt` - Bearer token representing the deposit
public fun deposit_for_receipt<T: key>(
    storage_unit: &mut StorageUnit,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
): WarehouseReceipt {
    // Withdraw from player's owned inventory
    let item = storage_unit.withdraw_by_owner(
        character,
        owner_cap,
        type_id,
        quantity,
        ctx,
    );

    // Deposit to open inventory (extension-controlled)
    storage_unit.deposit_to_open_inventory(
        character,
        item,
        VaultAuth {},
        ctx,
    );

    // Mint bearer receipt
    let storage_unit_id = object::id(storage_unit);
    let receipt = warehouse_receipt::mint(storage_unit_id, type_id, quantity, ctx);
    let receipt_id = object::id(&receipt);

    event::emit(ReceiptMintedEvent {
        receipt_id,
        storage_unit_id,
        type_id,
        quantity,
        depositor: ctx.sender(),
    });

    receipt
}

/// Redeem a receipt to withdraw items from open inventory to the redeemer's owned inventory.
/// The receipt is burned upon redemption. Anyone holding the receipt can redeem.
///
/// # Arguments
/// * `receipt` - The bearer receipt to redeem (consumed)
/// * `storage_unit` - The storage unit to withdraw from
/// * `character` - The redeemer's character
public fun redeem_receipt(
    receipt: WarehouseReceipt,
    storage_unit: &mut StorageUnit,
    character: &Character,
    ctx: &mut TxContext,
) {
    let (receipt_id, storage_unit_id, type_id, quantity) = warehouse_receipt::burn(receipt);

    // Verify receipt matches this storage unit
    assert!(storage_unit_id == object::id(storage_unit), EStorageUnitMismatch);

    // Withdraw from open inventory
    let item = storage_unit.withdraw_from_open_inventory<VaultAuth>(
        character,
        VaultAuth {},
        type_id,
        quantity,
        ctx,
    );
    // Deposit to redeemer's owned inventory
    storage_unit.deposit_to_owned<VaultAuth>(
        character,
        item,
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