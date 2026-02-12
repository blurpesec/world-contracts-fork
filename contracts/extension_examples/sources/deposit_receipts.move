/// Deposit receipt extension for storage units.
///
/// Locks an `ItemBalance` inside a vault and issues an owned `DepositReceipt` bound to a
/// single storage unit (`assembly_id`). The receipt can be transferred and later
/// redeemed to recover the escrowed balance. Supply accounting remains event-based.
module extension_examples::deposit_receipts;

use sui::{event, object, table::{Self, Table}};
use world::{
    access::{Self as access, OwnerCap},
    character::Character,
    item_balance::{Self as item_balance, ItemBalance, ItemRegistry},
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
const EAssemblyNotAuthorized: vector<u8> = b"OwnerCap not authorized";
#[error(code = 4)]
const ESenderCannotAccessCharacter: vector<u8> = b"Sender cannot access character";

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
public fun lock_and_mint(
    vault: &mut Vault,
    storage_unit: &mut StorageUnit,
    item_registry: &ItemRegistry,
    character: &Character,
    owner_cap: &OwnerCap<StorageUnit>,
    asset_id: ID,
    quantity: u64,
    _auth: DepositReceiptsStorageAbstractionAuth,
    ctx: &mut TxContext,
): DepositReceipt {
    assert!(quantity > 0, EQuantityZero);
    let assembly_id = object::id(storage_unit);
    assert!(access::is_authorized(owner_cap, assembly_id), EAssemblyNotAuthorized);
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);

    let balance = storage_unit.withdraw_item<DepositReceiptsStorageAbstractionAuth>(
        item_registry,
        character,
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

// === Test Functions ===
#[test_only]
public fun escrow_quantity(vault: &Vault, receipt_id: ID): u64 {
    if (!table::contains(&vault.escrows, receipt_id)) {
        return 0
    };
    let entry = table::borrow(&vault.escrows, receipt_id);
    item_balance::value(&entry.balance)
}
