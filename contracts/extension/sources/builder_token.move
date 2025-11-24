module extension::builder_token;

use std::option;
use sui::{coin::{Self, TreasuryCap}, url};

public struct BUILDER_TOKEN has drop {}

public struct Treasury has key {
    id: UID,
    cap: TreasuryCap<BUILDER_TOKEN>,
}

fun init(witness: BUILDER_TOKEN, ctx: &mut TxContext) {
    let (mut treasury_cap, metadata) = coin::create_currency<BUILDER_TOKEN>(
        witness,
        9,
        b"SLAY",
        b"SLAY Token",
        b"Just a demo token.",
        option::some(url::new_unsafe_from_bytes(b"https://i.imgur.com/ss7FYtZ.png")),
        ctx,
    );

    mint(&mut treasury_cap, 1_000_000_000 * 1_00, ctx.sender(), ctx);

    let treasury = Treasury {
        id: object::new(ctx),
        cap: treasury_cap,
    };

    transfer::public_freeze_object(metadata);
    transfer::share_object(treasury);
}

public(package) fun mint(
    treasury_cap: &mut coin::TreasuryCap<BUILDER_TOKEN>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    let coin = coin::mint(treasury_cap, amount, ctx);
    transfer::public_transfer(coin, recipient);
}

public fun borrow_cap_mut(treasury: &mut Treasury): &mut TreasuryCap<BUILDER_TOKEN> {
    &mut treasury.cap
}
