# Deposit Receipts Extension

Overview of the storage-unit deposit receipt extension and its tests.

## Purpose
- Locks an `ItemBalance` from a storage unit into a vault and issues a transferable `DepositReceipt` tied to that storage unit.
- Enables bearer-style redemption: whoever holds the receipt can redeem it to reclaim the escrowed balance.
- Uses a typed witness (`DepositReceiptsStorageAbstractionAuth`) that storage-unit owners must authorize before use.

## Key Flows
- **Lock and mint** (`lock_and_mint` in [contracts/extension_examples/sources/deposit_receipts.move](contracts/extension_examples/sources/deposit_receipts.move))
  - Validates quantity > 0 and that the provided `OwnerCap<StorageUnit>` is authorized for the target assembly.
  - Requires the calling transaction sender to match the `Character` controlling the storage unit.
  - Withdraws the requested item balance from the storage unit using the extension witness, stores it in the vault escrow table keyed by receipt ID, emits `ReceiptMintedEvent`, and returns the owned receipt.
- **Redeem** (`redeem` in [contracts/extension_examples/sources/deposit_receipts.move](contracts/extension_examples/sources/deposit_receipts.move))
  - Removes the escrow entry, verifies the escrowed assembly matches the receipt’s assembly, emits `ReceiptRedeemedEvent`, deletes the receipt object, and returns the escrowed `ItemBalance`.
- **Events and errors**
  - Emits `ReceiptMintedEvent` on lock and `ReceiptRedeemedEvent` on redemption.
  - Guards include zero-quantity, missing escrow, assembly mismatch, unauthorized owner cap, and sender not matching the character.

## Test Coverage
Tests live in [contracts/extension_examples/tests/deposit_receipts_tests.move](contracts/extension_examples/tests/deposit_receipts_tests.move) and use `test_scenario` plus `test_helpers` to spin up characters, network node, storage unit, and a shared vault.
- `lock_mints_receipt`: locks ammo into escrow, verifies escrowed quantity matches the receipt.
- `transfer_then_redeem`: transfers the receipt to another user, redeems as the bearer, checks returned balance and that escrow clears.
- `lock_rejects_wrong_sender` (expected failure): user B cannot lock user A’s storage because sender check aborts.
- `withdraw_after_lock_fails` (expected failure): attempting to withdraw locked items directly from storage inventory after escrow fails.

## Usage Notes
- Storage unit must register the extension witness via `storage_unit::authorize_extension<DepositReceiptsStorageAbstractionAuth>` before locking.
- Vaults are standalone objects created with `create_vault`; callers may choose to share them for multi-user access.
- Receipts are fungible-style claims by quantity and asset ID but remain bound to the originating storage unit via `assembly_id`.
