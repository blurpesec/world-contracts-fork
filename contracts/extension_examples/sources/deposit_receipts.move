/// Deposit receipt extension for storage units.
///
/// Locks an `ItemBalance` inside a vault and issues an owned `DepositReceipt` bound to a
/// single storage unit (`assembly_id`). The receipt can be transferred and later
/// redeemed to recover the escrowed balance. Supply accounting remains event-based.
module extension_examples::deposit_receipts;

use std::string::String;
use sui::{event, table::{Self, Table}};
use world::{
    access::OwnerCap,
    character::Character,
    item_balance::{Self as item_balance, ItemBalance, ItemData, ItemRegistry},
    storage_unit::StorageUnit
};

// === Errors ===
#[error(code = 0)]
const EQuantityZero: vector<u8> = b"Quantity must be > 0";
#[error(code = 1)]
const EAssemblyMismatch: vector<u8> = b"Receipt assembly mismatch";
#[error(code = 2)]
const EEscrowMissing: vector<u8> = b"Escrow entry not found";
#[error(code = 3)]
const EQuantityTooLarge: vector<u8> = b"Quantity exceeds receipt balance";
#[error(code = 4)]
const EAssetMismatch: vector<u8> = b"Receipts must reference the same asset";
#[error(code = 5)]
const EBatchEmpty: vector<u8> = b"Batch cannot be empty";
#[error(code = 6)]
const EBatchLengthMismatch: vector<u8> = b"Batch input length mismatch";

// === Structs ===

/// Witness type authorized by storage unit owners via `authorize_extension`.
public struct DepositReceiptsStorageAbstractionAuth has drop {}

/// Transferable claim bound to a single storage unit.
public struct DepositReceipt has key, store {
    id: UID,
    assembly_id: ID,
    asset_id: ID,
    quantity: u64,
}

public struct EscrowEntry has store {
    assembly_id: ID,
    balance: ItemBalance,
}

/// Vault holding escrowed item balances keyed by receipt ID.
public struct Vault has key, store {
    id: UID,
    escrows: Table<ID, EscrowEntry>,
}

/// Witness constructor for external callers.
public fun auth(): DepositReceiptsStorageAbstractionAuth {
    DepositReceiptsStorageAbstractionAuth {}
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
    owner: address,
}

// === Public Functions ===

/// Create and return an empty vault (caller may choose to share it).
public fun create_vault(ctx: &mut TxContext): Vault {
    Vault {
        id: object::new(ctx),
        escrows: table::new(ctx),
    }
}

/// Lock assets from a storage unit and mint a transferable receipt.
public fun lock_and_mint<T: key>(
    vault: &mut Vault,
    storage_unit: &mut StorageUnit,
    item_registry: &ItemRegistry,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    asset_id: ID,
    quantity: u64,
    _auth: DepositReceiptsStorageAbstractionAuth,
    ctx: &mut TxContext,
): DepositReceipt {
    assert!(quantity > 0, EQuantityZero);
    let assembly_id = object::id(storage_unit);

    let balance = storage_unit.withdraw_item_by_cap<T, DepositReceiptsStorageAbstractionAuth>(
        item_registry,
        character,
        owner_cap,
        DepositReceiptsStorageAbstractionAuth {},
        asset_id,
        quantity,
        ctx,
    );

    let receipt = DepositReceipt {
        id: object::new(ctx),
        assembly_id,
        asset_id,
        quantity,
    };

    table::add(
        &mut vault.escrows,
        object::id(&receipt),
        EscrowEntry { assembly_id, balance },
    );

    event::emit(ReceiptMintedEvent {
        receipt_id: object::id(&receipt),
        assembly_id,
        asset_id,
        quantity,
        owner: ctx.sender(),
    });

    receipt
}

/// Redeem a receipt and release the escrowed balance.
public fun redeem(
    vault: &mut Vault,
    receipt: DepositReceipt,
    _auth: DepositReceiptsStorageAbstractionAuth,
    ctx: &mut TxContext,
): ItemBalance {
    let receipt_id = object::id(&receipt);
    let expected_assembly = receipt.assembly_id;

    let EscrowEntry { assembly_id, balance } = if (table::contains(&vault.escrows, receipt_id)) {
        table::remove(&mut vault.escrows, receipt_id)
    } else {
        abort EEscrowMissing
    };
    assert!(assembly_id == expected_assembly, EAssemblyMismatch);

    event::emit(ReceiptRedeemedEvent {
        receipt_id,
        assembly_id,
        asset_id: receipt.asset_id,
        quantity: receipt.quantity,
        owner: ctx.sender(),
    });

    let DepositReceipt { id, .. } = receipt;
    id.delete();
    balance
}

/// Redeem multiple receipts in one call.
public fun batch_redeem(
    vault: &mut Vault,
    receipts: vector<DepositReceipt>,
    _auth: DepositReceiptsStorageAbstractionAuth,
    ctx: &mut TxContext,
): vector<ItemBalance> {
    assert!(receipts.length() > 0, EBatchEmpty);

    let mut released = vector::empty<ItemBalance>();
    receipts.do!(|receipt| {
        vector::push_back(
            &mut released,
            redeem(vault, receipt, DepositReceiptsStorageAbstractionAuth {}, ctx),
        );
    });

    released
}

/// Lock multiple item balances and mint receipts in one call.
public fun batch_lock<T: key>(
    vault: &mut Vault,
    storage_unit: &mut StorageUnit,
    item_registry: &ItemRegistry,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    asset_ids: vector<ID>,
    quantities: vector<u64>,
    _auth: DepositReceiptsStorageAbstractionAuth,
    ctx: &mut TxContext,
): vector<DepositReceipt> {
    assert!(asset_ids.length() > 0, EBatchEmpty);
    assert!(asset_ids.length() == quantities.length(), EBatchLengthMismatch);

    let mut receipts = vector::empty<DepositReceipt>();
    asset_ids.zip_do!(quantities, |asset_id, quantity| {
        vector::push_back(
            &mut receipts,
            lock_and_mint(
                vault,
                storage_unit,
                item_registry,
                character,
                owner_cap,
                asset_id,
                quantity,
                DepositReceiptsStorageAbstractionAuth {},
                ctx,
            ),
        );
    });

    receipts
}

/// Split a receipt into two receipts without interacting with the storage unit.
public fun split_receipt(
    vault: &mut Vault,
    receipt: &mut DepositReceipt,
    split_quantity: u64,
    ctx: &mut TxContext,
): DepositReceipt {
    assert!(split_quantity > 0, EQuantityZero);
    assert!(receipt.quantity >= split_quantity, EQuantityTooLarge);

    let receipt_id = object::id(receipt);
    assert!(table::contains(&vault.escrows, receipt_id), EEscrowMissing);

    let split_balance = {
        let entry = table::borrow_mut(&mut vault.escrows, receipt_id);
        assert!(entry.assembly_id == receipt.assembly_id, EAssemblyMismatch);
        item_balance::split(&mut entry.balance, split_quantity)
    };

    receipt.quantity = receipt.quantity - split_quantity;

    let new_receipt = DepositReceipt {
        id: object::new(ctx),
        assembly_id: receipt.assembly_id,
        asset_id: receipt.asset_id,
        quantity: split_quantity,
    };

    table::add(
        &mut vault.escrows,
        object::id(&new_receipt),
        EscrowEntry { assembly_id: receipt.assembly_id, balance: split_balance },
    );

    new_receipt
}

/// Merge one receipt into another when they reference the same assembly and asset.
public fun merge_receipts(
    vault: &mut Vault,
    target: &mut DepositReceipt,
    source: DepositReceipt,
): u64 {
    let target_id = object::id(target);
    let source_id = object::id(&source);

    assert!(table::contains(&vault.escrows, target_id), EEscrowMissing);
    assert!(table::contains(&vault.escrows, source_id), EEscrowMissing);
    assert!(target.assembly_id == source.assembly_id, EAssemblyMismatch);
    assert!(target.asset_id == source.asset_id, EAssetMismatch);

    let source_entry = table::remove(&mut vault.escrows, source_id);
    let EscrowEntry { assembly_id, balance } = source_entry;
    assert!(assembly_id == target.assembly_id, EAssemblyMismatch);

    {
        let target_entry = table::borrow_mut(&mut vault.escrows, target_id);
        assert!(target_entry.assembly_id == target.assembly_id, EAssemblyMismatch);
        item_balance::join(&mut target_entry.balance, balance);
    };

    target.quantity = target.quantity + source.quantity;

    let DepositReceipt { id, .. } = source;
    id.delete();

    target.quantity
}

/// View the underlying item metadata for a receipt.
public fun receipt_item_data(
    registry: &ItemRegistry,
    receipt: &DepositReceipt,
): &ItemData {
    item_balance::item_data(registry, receipt.asset_id)
}

/// Convenience: return the item name for a receipt.
public fun receipt_item_name(registry: &ItemRegistry, receipt: &DepositReceipt): String {
    item_balance::data_name(receipt_item_data(registry, receipt))
}

/// Convenience: return the metadata URL for a receipt.
public fun receipt_item_url(registry: &ItemRegistry, receipt: &DepositReceipt): String {
    item_balance::data_url(receipt_item_data(registry, receipt))
}

// === Test Functions ===
#[test_only]
public fun escrow_quantity(vault: &Vault, receipt_id: ID): u64 {
    if (!table::contains(&vault.escrows, receipt_id)) {
        return 0
    };
    let entry = table::borrow(&vault.escrows, receipt_id);
    item_balance::value(&entry.balance)
}
