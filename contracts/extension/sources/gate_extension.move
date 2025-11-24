/// 3rd Party extension
module extension::gate_extension;

use extension::builder_token::{Self, BUILDER_TOKEN, Treasury};
use sui::{coin, event};
use world::gate::{Self, Gate};

const JUMP_FEE: u64 = 100_000_000; // 0.1 SLAY tokens

const EInsufficientTokens: u64 = 0;

public struct GateXAuth has drop {}

public struct GateJumpedEvent has copy, drop {
    source_gate: ID,
    destination_gate: ID,
    jumper: address,
    fee_paid: u64,
}

/// Jump between gates by paying SLAY tokens
/// Requires user to own at least JUMP_FEE amount of SLAY tokens
#[allow(lint(self_transfer))]
public fun jump(
    source_gate: &Gate,
    destination_gate: &Gate,
    mut payment: coin::Coin<BUILDER_TOKEN>,
    treasury: &mut Treasury,
    ctx: &mut TxContext,
): bool {
    assert!(coin::value(&payment) >= JUMP_FEE, EInsufficientTokens);
    let fee_coin = coin::split(&mut payment, JUMP_FEE, ctx);

    coin::burn(builder_token::borrow_cap_mut(treasury), fee_coin);

    if (coin::value(&payment) > 0) {
        transfer::public_transfer(payment, ctx.sender());
    } else {
        coin::destroy_zero(payment);
    };

    source_gate.jump(destination_gate, true, GateXAuth {}, ctx);

    event::emit(GateJumpedEvent {
        source_gate: object::id(source_gate),
        destination_gate: object::id(destination_gate),
        jumper: ctx.sender(),
        fee_paid: JUMP_FEE,
    });

    true
}
