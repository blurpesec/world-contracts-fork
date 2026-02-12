/// Item Teleportation: Lock items in one storage unit, redeem them in another.
///
/// `DepositReceipt` wraps an `ItemBalance` into a transferable object.
/// Unlike `deposit_receipts`, teleportation receipts are NOT bound to any
/// specific storage unit — they can be redeemed into ANY authorized storage unit.
///
/// ## Teleportation Flow
///
/// 1. **Lock** items in storage_unit_A via `lock_and_mint` → get `DepositReceipt`
/// 2. **Transfer** the receipt to anyone (it's a first-class Sui object)
/// 3. **Redeem** into storage_unit_B via `redeem_to_storage` → items appear in B
///
/// This enables instant cross-location item transfer without physical travel.
module extension_examples::item_teleportation;

use std::string::String;
use sui::event;
use world::{
    character::Character,
    item_balance::{Self, ItemBalance, ItemData, ItemRegistry},
    storage_unit::StorageUnit
};

// === Errors ===
#[error(code = 0)]
const EQuantityZero: vector<u8> = b"Quantity must be > 0";
#[error(code = 1)]
const EAssetMismatch: vector<u8> = b"Receipts must reference the same asset";
#[error(code = 3)]
const EBatchEmpty: vector<u8> = b"Batch cannot be empty";
#[error(code = 4)]
const EBatchLengthMismatch: vector<u8> = b"Batch input length mismatch";
#[error(code = 5)]
const ENonZero: vector<u8> = b"Cannot destroy non-zero receipt";

// === Structs ===

/// Witness type authorized by storage unit owners via `authorize_extension`.
public struct DepositReceiptsAuth has drop {}

/// Transferable receipt wrapping an ItemBalance for teleportation.
/// NOT bound to any specific storage unit — can be redeemed anywhere.
public struct DepositReceipt has key, store {
    id: UID,
    /// The wrapped item balance.
    balance: ItemBalance,
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
    self.balance.value()
}

/// Returns the asset ID for this receipt.
public fun asset_id(self: &DepositReceipt): ID {
    self.balance.balance_asset_id()
}

/// Returns an immutable reference to the embedded balance.
public fun balance(self: &DepositReceipt): &ItemBalance {
    &self.balance
}

/// View the underlying item metadata for a receipt.
public fun item_data(registry: &ItemRegistry, receipt: &DepositReceipt): &ItemData {
    item_balance::item_data(registry, receipt.balance.balance_asset_id())
}

/// Returns the item name for a receipt.
public fun item_name(registry: &ItemRegistry, receipt: &DepositReceipt): String {
    item_balance::data_name(item_data(registry, receipt))
}

/// Returns the metadata URL for a receipt.
public fun item_url(registry: &ItemRegistry, receipt: &DepositReceipt): String {
    item_balance::data_url(item_data(registry, receipt))
}

// === Balance Morphing ===

/// Wrap an `ItemBalance` into a `DepositReceipt` to make it transferable.
public fun from_balance(balance: ItemBalance, ctx: &mut TxContext): DepositReceipt {
    DepositReceipt {
        id: object::new(ctx),
        balance,
    }
}

/// Consume the receipt and return the embedded balance.
public fun into_balance(receipt: DepositReceipt): ItemBalance {
    let DepositReceipt { id, balance } = receipt;
    id.delete();
    balance
}

// === Split / Join (mirrors Coin, self-contained) ===

/// Split `amount` from the receipt into a new receipt.
public fun split(self: &mut DepositReceipt, amount: u64, ctx: &mut TxContext): DepositReceipt {
    DepositReceipt {
        id: object::new(ctx),
        balance: self.balance.split(amount),
    }
}

/// Consume receipt `other` and add its value to `self`.
/// Aborts if `asset_id` doesn't match.
public fun join(self: &mut DepositReceipt, other: DepositReceipt) {
    let DepositReceipt { id, balance } = other;
    assert!(balance.balance_asset_id() == self.balance.balance_asset_id(), EAssetMismatch);
    id.delete();
    self.balance.join(balance);
}

/// Create a zero-value receipt for the given asset.
public fun zero(asset_id: ID, ctx: &mut TxContext): DepositReceipt {
    DepositReceipt {
        id: object::new(ctx),
        balance: item_balance::zero(asset_id),
    }
}

/// Destroy a receipt with zero value. Mirrors `coin::destroy_zero`.
public fun destroy_zero(receipt: DepositReceipt) {
    let DepositReceipt { id, balance, .. } = receipt;
    assert!(balance.value() == 0, ENonZero);
    id.delete();
    balance.destroy_zero();
}

// === Mint / Redeem (Storage Unit Integration) ===

/// Lock assets from a storage unit and mint a transferable receipt.
/// The balance is withdrawn and embedded directly in the receipt.
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

    let balance = storage_unit.withdraw_item<DepositReceiptsAuth>(
        item_registry,
        character,
        DepositReceiptsAuth {},
        asset_id,
        quantity,
        ctx,
    );

    let receipt = DepositReceipt {
        id: object::new(ctx),
        balance,
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

/// Redeem a receipt and return the embedded balance.
public fun redeem(receipt: DepositReceipt): ItemBalance {
    into_balance(receipt)
}

/// Redeem a receipt directly into ANY storage unit.
/// This is the "teleportation" endpoint — items locked in storage_unit_A
/// can be redeemed into storage_unit_B.
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
    let asset_id = receipt.balance.balance_asset_id();
    let quantity = receipt.balance.value();

    event::emit(ReceiptRedeemedEvent {
        receipt_id,
        assembly_id: target_assembly_id,
        asset_id,
        quantity,
        redeemer: ctx.sender(),
    });

    let balance = into_balance(receipt);

    storage_unit.deposit_item<DepositReceiptsAuth>(
        item_registry,
        character,
        balance,
        DepositReceiptsAuth {},
        ctx,
    );
}

// === Batch Operations ===

/// Lock multiple item types and mint receipts in one call.
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

/// Redeem multiple receipts in one call.
public fun batch_redeem(receipts: vector<DepositReceipt>): vector<ItemBalance> {
    assert!(receipts.length() > 0, EBatchEmpty);

    let mut balances = vector::empty<ItemBalance>();
    receipts.do!(|receipt| {
        balances.push_back(redeem(receipt));
    });

    balances
}

/// Join multiple receipts of the same asset into one.
public fun join_vec(mut receipts: vector<DepositReceipt>): DepositReceipt {
    assert!(receipts.length() > 0, EBatchEmpty);

    let mut target = receipts.pop_back();

    while (!receipts.is_empty()) {
        target.join(receipts.pop_back());
    };
    receipts.destroy_empty();

    target
}

/// Split a receipt into `n` receipts with equal values.
/// Remainder stays in the original receipt. Mirrors `coin::divide_into_n`.
public fun divide_into_n(
    self: &mut DepositReceipt,
    n: u64,
    ctx: &mut TxContext,
): vector<DepositReceipt> {
    assert!(n > 0, EQuantityZero);

    let total = self.value();
    let split_amount = total / n;

    vector::tabulate!(n - 1, |_| self.split(split_amount, ctx))
}

// === Test Functions ===
#[test_only]
public fun test_mint(
    asset_id: ID,
    _quantity: u64,
    ctx: &mut TxContext,
): DepositReceipt {
    DepositReceipt {
        id: object::new(ctx),
        balance: item_balance::zero(asset_id),
    }
}
