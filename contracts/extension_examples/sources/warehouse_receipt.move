/// Bearer token (warehouse receipt) representing deposited items in a storage unit.
///
/// `WarehouseReceipt` is a transferable, splittable, joinable token — analogous to `Coin`.
/// It tracks a `storage_unit_id`, `type_id`, and `quantity`. The holder can redeem it
/// at the corresponding storage unit via an extension that calls `burn`.
///
/// Mint and burn are `public(package)` — only extension modules in this package can
/// create or destroy receipts. All other operations (split, join, transfer, view) are
/// available to anyone holding a receipt.
module extension_examples::warehouse_receipt;

// === Errors ===
#[error(code = 0)]
const ESplitQuantityInvalid: vector<u8> = b"Split quantity must be > 0 and < receipt quantity";
#[error(code = 1)]
const EJoinMismatch: vector<u8> = b"Receipts must share the same storage unit and type_id";
#[error(code = 2)]
const ENonZeroQuantity: vector<u8> = b"Cannot destroy a receipt with non-zero quantity";
#[error(code = 3)]
const EInvalidArg: vector<u8> = b"Invalid argument";
#[error(code = 4)]
const ENotEnough: vector<u8> = b"Cannot divide into more parts than receipt quantity";

// === Structs ===

/// Bearer token representing deposited items.
/// Whoever holds this receipt can redeem the items from the storage unit.
public struct WarehouseReceipt has key, store {
    id: UID,
    /// The storage unit where the items are deposited
    storage_unit_id: ID,
    /// The type of items deposited
    type_id: u64,
    /// The quantity of items this receipt represents
    quantity: u32,
}

// === Package Functions ===

/// Mint a new warehouse receipt. Only callable within this package.
public(package) fun mint(
    storage_unit_id: ID,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
): WarehouseReceipt {
    WarehouseReceipt {
        id: object::new(ctx),
        storage_unit_id,
        type_id,
        quantity,
    }
}

/// Burn a warehouse receipt, returning its fields. Only callable within this package.
/// The caller is responsible for verifying the receipt matches the target storage unit.
public(package) fun burn(receipt: WarehouseReceipt): (ID, ID, u64, u32) {
    let WarehouseReceipt { id, storage_unit_id, type_id, quantity } = receipt;
    let receipt_id = id.to_inner();
    id.delete();
    (receipt_id, storage_unit_id, type_id, quantity)
}

// === Public Functions ===

/// Split a receipt into two: `self` retains `self.quantity - split_quantity`,
/// and a new receipt is returned with `split_quantity`.
/// All other fields (storage_unit_id, type_id) are copied.
///
/// Analogous to `Coin::split`.
public fun split(
    self: &mut WarehouseReceipt,
    split_quantity: u32,
    ctx: &mut TxContext,
): WarehouseReceipt {
    assert!(split_quantity > 0 && split_quantity < self.quantity, ESplitQuantityInvalid);
    self.quantity = self.quantity - split_quantity;

    WarehouseReceipt {
        id: object::new(ctx),
        storage_unit_id: self.storage_unit_id,
        type_id: self.type_id,
        quantity: split_quantity,
    }
}

/// Split `self` into `n - 1` receipts with equal quantities. The remainder stays
/// in `self`. Analogous to `Coin::divide_into_n`.
public fun divide_into_n(
    self: &mut WarehouseReceipt,
    n: u32,
    ctx: &mut TxContext,
): vector<WarehouseReceipt> {
    assert!(n > 0, EInvalidArg);
    assert!(n <= self.quantity, ENotEnough);

    let split_amount = self.quantity / n;
    let mut i = 0;
    let mut result = vector[];
    while (i < n - 1) {
        result.push_back(self.split(split_amount, ctx));
        i = i + 1;
    };
    result
}

/// Merge `other` into `self`. Both must reference the same storage unit and type_id.
/// `other` is consumed (UID deleted); `self.quantity` increases by `other.quantity`.
///
/// Analogous to `Coin::join`.
#[allow(lint(public_entry))]
public entry fun join(self: &mut WarehouseReceipt, other: WarehouseReceipt) {
    let WarehouseReceipt { id, storage_unit_id, type_id, quantity, .. } = other;
    assert!(storage_unit_id == self.storage_unit_id && type_id == self.type_id, EJoinMismatch);
    id.delete();
    self.quantity = self.quantity + quantity;
}

/// Split `amount` from this receipt and transfer the new receipt to `recipient`.
/// Convenience entry point — no PTB needed for "send some to a friend".
#[allow(lint(public_entry))]
public entry fun split_and_transfer(
    self: &mut WarehouseReceipt,
    amount: u32,
    recipient: address,
    ctx: &mut TxContext,
) {
    transfer::public_transfer(self.split(amount, ctx), recipient);
}

/// Merge a vector of receipts into `self`. All must reference the same
/// storage unit and type_id. Analogous to `sui::pay::join_vec`.
#[allow(lint(public_entry))]
public entry fun join_vec(self: &mut WarehouseReceipt, mut others: vector<WarehouseReceipt>) {
    while (!others.is_empty()) {
        self.join(others.pop_back());
    };
    others.destroy_empty();
}

/// Destroy a zero-quantity receipt. Useful after repeated splits.
#[allow(lint(public_entry))]
public entry fun destroy_zero(receipt: WarehouseReceipt) {
    let WarehouseReceipt { id, quantity, .. } = receipt;
    assert!(quantity == 0, ENonZeroQuantity);
    id.delete();
}

/// Create a zero-quantity receipt for use as a `join` accumulator.
public fun zero(
    storage_unit_id: ID,
    type_id: u64,
    ctx: &mut TxContext,
): WarehouseReceipt {
    WarehouseReceipt {
        id: object::new(ctx),
        storage_unit_id,
        type_id,
        quantity: 0,
    }
}

// === View Functions ===

/// Returns the storage unit ID this receipt is redeemable at
public fun storage_unit_id(self: &WarehouseReceipt): ID {
    self.storage_unit_id
}

/// Returns the item type this receipt represents
public fun type_id(self: &WarehouseReceipt): u64 {
    self.type_id
}

/// Returns the quantity of items this receipt represents
public fun quantity(self: &WarehouseReceipt): u32 {
    self.quantity
}
