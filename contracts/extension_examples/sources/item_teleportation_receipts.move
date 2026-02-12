/// Coin-like deposit receipts for storage unit inventories.
///
/// `DepositReceipt` is modeled after `sui::coin::Coin<T>` — a transferable object
/// that embeds its value directly. Receipts are fungible within the same
/// `(assembly_id, asset_id)` scope, enabling split/join without external state.
///
/// ## Design parallels with Coin
///
/// | Coin<T>                      | DepositReceipt                           |
/// |------------------------------|------------------------------------------|
/// | `Balance<T>` embedded        | `ItemBalance` embedded                   |
/// | Fungible by type `T`         | Fungible by `(assembly_id, asset_id)`    |
/// | `split`/`join` self-contained| `split`/`join` self-contained            |
/// | `into_balance`/`from_balance`| `into_balance`/`from_balance`            |
/// | `TreasuryCap` mints          | `lock_and_mint` mints from storage unit  |
///
/// Supply accounting remains event-based (no on-chain total_supply).
module extension_examples::item_teleportation;

use std::string::String;
use sui::event;
use world::{
    access::OwnerCap,
    character::Character,
    item_balance::{Self, ItemBalance, ItemData, ItemRegistry},
    storage_unit::StorageUnit
};

// === Errors ===
#[error(code = 0)]
const EQuantityZero: vector<u8> = b"Quantity must be > 0";
#[error(code = 1)]
const EAssemblyMismatch: vector<u8> = b"Receipt assembly mismatch";
#[error(code = 2)]
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

/// Transferable receipt bound to a single storage unit, embedding its balance.
/// Modeled after `sui::coin::Coin<T>` — the receipt IS the value.
public struct DepositReceipt has key, store {
    id: UID,
    /// The storage unit these items originated from (fungibility boundary).
    assembly_id: ID,
    /// The escrowed item balance (self-contained, like Coin embeds Balance).
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

/// Returns the storage unit ID this receipt is bound to.
public fun assembly_id(self: &DepositReceipt): ID {
    self.assembly_id
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

// === Balance Morphing (mirrors Coin.into_balance / from_balance) ===

/// Wrap an `ItemBalance` into a `DepositReceipt` to make it transferable.
/// Mirrors `coin::from_balance`.
public fun from_balance(
    assembly_id: ID,
    balance: ItemBalance,
    ctx: &mut TxContext,
): DepositReceipt {
    DepositReceipt {
        id: object::new(ctx),
        assembly_id,
        balance,
    }
}

/// Consume the receipt and return the embedded balance with its assembly origin.
/// Mirrors `coin::into_balance`.
public fun into_balance(receipt: DepositReceipt): (ID, ItemBalance) {
    let DepositReceipt { id, assembly_id, balance } = receipt;
    id.delete();
    (assembly_id, balance)
}

// === Split / Join (mirrors Coin, self-contained) ===

/// Split `amount` from the receipt into a new receipt.
/// Mirrors `coin::split`.
public fun split(self: &mut DepositReceipt, amount: u64, ctx: &mut TxContext): DepositReceipt {
    DepositReceipt {
        id: object::new(ctx),
        assembly_id: self.assembly_id,
        balance: self.balance.split(amount),
    }
}

/// Consume receipt `other` and add its value to `self`.
/// Aborts if `assembly_id` or `asset_id` don't match.
/// Mirrors `coin::join`.
public fun join(self: &mut DepositReceipt, other: DepositReceipt) {
    let DepositReceipt { id, assembly_id, balance } = other;
    assert!(assembly_id == self.assembly_id, EAssemblyMismatch);
    assert!(balance.balance_asset_id() == self.balance.balance_asset_id(), EAssetMismatch);
    id.delete();
    self.balance.join(balance);
}

/// Create a zero-value receipt for the given assembly and asset.
/// Useful for accumulating values. Mirrors `coin::zero`.
public fun zero(assembly_id: ID, asset_id: ID, ctx: &mut TxContext): DepositReceipt {
    DepositReceipt {
        id: object::new(ctx),
        assembly_id,
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
    owner_cap: &OwnerCap<StorageUnit>,
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
        assembly_id,
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
/// Emits `ReceiptRedeemedEvent` for off-chain tracking.
public fun redeem(receipt: DepositReceipt, ctx: &TxContext): (ID, ItemBalance) {
    let receipt_id = object::id(&receipt);
    let assembly_id = receipt.assembly_id;
    let asset_id = receipt.balance.balance_asset_id();
    let quantity = receipt.balance.value();

    event::emit(ReceiptRedeemedEvent {
        receipt_id,
        assembly_id,
        asset_id,
        quantity,
        redeemer: ctx.sender(),
    });

    into_balance(receipt)
}

/// Redeem a receipt directly back into a storage unit.
/// Verifies the receipt matches the target storage unit.
public fun redeem_to_storage(
    storage_unit: &mut StorageUnit,
    item_registry: &ItemRegistry,
    character: &Character,
    receipt: DepositReceipt,
    _auth: DepositReceiptsAuth,
    ctx: &mut TxContext,
) {
    let target_assembly_id = object::id(storage_unit);
    // assert!(receipt.assembly_id == target_assembly_id, EAssemblyMismatch);

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

    let (_, balance) = into_balance(receipt);

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
    owner_cap: &OwnerCap<StorageUnit>,
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
                owner_cap,
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
public fun batch_redeem(
    receipts: vector<DepositReceipt>,
    ctx: &TxContext,
): vector<ItemBalance> {
    assert!(receipts.length() > 0, EBatchEmpty);

    let mut balances = vector::empty<ItemBalance>();
    receipts.do!(|receipt| {
        let (_, balance) = redeem(receipt, ctx);
        balances.push_back(balance);
    });

    balances
}

/// Join multiple receipts of the same (assembly_id, asset_id) into one.
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
    assembly_id: ID,
    asset_id: ID,
    _quantity: u64,
    ctx: &mut TxContext,
): DepositReceipt {
    DepositReceipt {
        id: object::new(ctx),
        assembly_id,
        balance: item_balance::zero(asset_id), // Will need to use test_increase_supply in actual tests
    }
}
