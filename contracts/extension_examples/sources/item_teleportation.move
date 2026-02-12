/// Item Deposit Receipts: Withdraw items into transferable receipts.
///
/// `DepositReceipt` wraps a `BoundBalance` into a transferable object.
/// Receipts are bound to their origin storage unit — they can ONLY be redeemed
/// back into the same storage unit they were withdrawn from.
///
/// ## Deposit Receipt Flow (same storage unit)
///
/// 1. **Lock** items in storage_unit_A via `lock_and_mint` → get `DepositReceipt`
/// 2. **Transfer** the receipt to anyone (it's a first-class Sui object)
/// 3. **Redeem** into storage_unit_A via `redeem_to_storage` → items return to A
///
/// ## Cross-Assembly Transfer (requires proximity)
///
/// For transferring items between different storage units, use the
/// `storage_unit::transfer_item` function which enforces digital physics
/// by requiring a proximity proof.
module extension_examples::item_teleportation;

use std::string::String;
use sui::event;
use world::{
    character::Character,
    item_balance::{Self, ItemData, ItemRegistry},
    storage_unit::{Self, StorageUnit, BoundBalance}
};

// === Errors ===
#[error(code = 0)]
const EQuantityZero: vector<u8> = b"Quantity must be > 0";
#[error(code = 1)]
const EBatchEmpty: vector<u8> = b"Batch cannot be empty";
#[error(code = 2)]
const EBatchLengthMismatch: vector<u8> = b"Batch input length mismatch";

// === Structs ===

/// Witness type authorized by storage unit owners via `authorize_extension`.
public struct DepositReceiptsAuth has drop {}

/// Transferable receipt wrapping a BoundBalance.
/// Bound to its origin storage unit — can only be redeemed there.
public struct DepositReceipt has key, store {
    id: UID,
    /// The wrapped bound balance (includes origin storage_unit_id).
    bound: BoundBalance,
}

// === Events ===

public struct ReceiptMintedEvent has copy, drop {
    receipt_id: ID,
    assembly_id: ID,
    asset_id: ID,
    quantity: u64,
    owner: address,
}

public struct ReceiptRedeemedEvent has copy, drop {
    receipt_id: ID,
    assembly_id: ID,
    asset_id: ID,
    quantity: u64,
    redeemer: address,
}

/// Witness constructor for external callers.
public fun auth(): DepositReceiptsAuth {
    DepositReceiptsAuth {}
}

// === View Functions (mirrors Coin) ===

/// Returns the receipt's value (quantity of items).
public fun value(self: &DepositReceipt): u64 {
    self.bound.bound_value()
}

/// Returns the asset ID for this receipt.
public fun asset_id(self: &DepositReceipt): ID {
    self.bound.bound_asset_id()
}

/// Returns the storage unit ID this receipt is bound to.
public fun origin_storage_unit_id(self: &DepositReceipt): ID {
    self.bound.bound_storage_unit_id()
}

/// Returns an immutable reference to the embedded bound balance.
public fun bound_balance(self: &DepositReceipt): &BoundBalance {
    &self.bound
}

/// View the underlying item metadata for a receipt.
public fun item_data(registry: &ItemRegistry, receipt: &DepositReceipt): &ItemData {
    item_balance::item_data(registry, receipt.bound.bound_asset_id())
}

/// Returns the item name for a receipt.
public fun item_name(registry: &ItemRegistry, receipt: &DepositReceipt): String {
    item_balance::data_name(item_data(registry, receipt))
}

/// Returns the metadata URL for a receipt.
public fun item_url(registry: &ItemRegistry, receipt: &DepositReceipt): String {
    item_balance::data_url(item_data(registry, receipt))
}

// === Mint / Redeem (Storage Unit Integration) ===

/// Lock assets from a storage unit and mint a transferable receipt.
/// The receipt is bound to this storage unit and can only be redeemed here.
public fun lock_and_mint(
    storage_unit: &mut StorageUnit,
    item_registry: &ItemRegistry,
    character: &Character,
    asset_id: ID,
    quantity: u64,
    _auth: DepositReceiptsAuth,
    ctx: &mut TxContext,
): DepositReceipt {
    assert!(quantity > 0, EQuantityZero);
    let assembly_id = object::id(storage_unit);

    let bound = storage_unit.withdraw_item<DepositReceiptsAuth>(
        item_registry,
        character,
        DepositReceiptsAuth {},
        asset_id,
        quantity,
        ctx,
    );

    let receipt = DepositReceipt {
        id: object::new(ctx),
        bound,
    };

    event::emit(ReceiptMintedEvent {
        receipt_id: object::id(&receipt),
        assembly_id,
        asset_id,
        quantity,
        owner: ctx.sender(),
    });

    receipt
}

/// Redeem a receipt back into its origin storage unit.
/// The receipt can ONLY be deposited into the storage unit it was withdrawn from.
public fun redeem_to_storage(
    storage_unit: &mut StorageUnit,
    item_registry: &ItemRegistry,
    character: &Character,
    receipt: DepositReceipt,
    _auth: DepositReceiptsAuth,
    ctx: &mut TxContext,
) {
    let target_assembly_id = object::id(storage_unit);
    let receipt_id = object::id(&receipt);
    let asset_id = receipt.bound.bound_asset_id();
    let quantity = receipt.bound.bound_value();

    event::emit(ReceiptRedeemedEvent {
        receipt_id,
        assembly_id: target_assembly_id,
        asset_id,
        quantity,
        redeemer: ctx.sender(),
    });

    let DepositReceipt { id, bound } = receipt;
    id.delete();

    // This will abort if target_assembly_id != bound.storage_unit_id
    storage_unit.deposit_item<DepositReceiptsAuth>(
        item_registry,
        character,
        bound,
        DepositReceiptsAuth {},
        ctx,
    );
}

// === Batch Operations ===

/// Lock multiple item types and mint receipts in one call.
/// All receipts are bound to this storage unit.
public fun batch_lock(
    storage_unit: &mut StorageUnit,
    item_registry: &ItemRegistry,
    character: &Character,
    asset_ids: vector<ID>,
    quantities: vector<u64>,
    _auth: DepositReceiptsAuth,
    ctx: &mut TxContext,
): vector<DepositReceipt> {
    assert!(asset_ids.length() > 0, EBatchEmpty);
    assert!(asset_ids.length() == quantities.length(), EBatchLengthMismatch);

    let mut receipts = vector::empty<DepositReceipt>();
    asset_ids.zip_do!(quantities, |asset_id, quantity| {
        receipts.push_back(
            lock_and_mint(
                storage_unit,
                item_registry,
                character,
                asset_id,
                quantity,
                DepositReceiptsAuth {},
                ctx,
            ),
        );
    });

    receipts
}

/// Redeem multiple receipts back to a storage unit in one call.
/// All receipts must have originated from this storage unit.
public fun batch_redeem(
    storage_unit: &mut StorageUnit,
    item_registry: &ItemRegistry,
    character: &Character,
    receipts: vector<DepositReceipt>,
    _auth: DepositReceiptsAuth,
    ctx: &mut TxContext,
) {
    assert!(receipts.length() > 0, EBatchEmpty);

    receipts.do!(|receipt| {
        redeem_to_storage(
            storage_unit,
            item_registry,
            character,
            receipt,
            DepositReceiptsAuth {},
            ctx,
        );
    });
}

// === Test Functions ===
#[test_only]
public fun test_mint(
    storage_unit_id: ID,
    asset_id: ID,
    ctx: &mut TxContext,
): DepositReceipt {
    DepositReceipt {
        id: object::new(ctx),
        bound: storage_unit::test_create_bound_balance(
            storage_unit_id,
            item_balance::zero(asset_id),
        ),
    }
}