/// EXPERIMENT, not in ADR-0004. A docked session: `dock` verifies one Signed-mode
/// docking proof (signature and nonce) and shares a `DockSession`. Until its
/// `expires_ms` (the proof's deadline), `verify_docked` satisfies
/// `Interaction<Docked>` without checking a signature. `undock` deletes it and
/// refunds its storage.
///
/// The session is shared rather than owned: Sui rewrites every owned input on
/// each use, which would charge non-refundable storage on every transfer. A
/// read-only shared input is not rewritten. Only `sender` can use or end it.
module adr_core::dock_session;

use adr_core::{interaction_service::{Self, Docked, ProofConfig}, request::Request};
use sui::{clock::Clock, event};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"DockSession version does not match the package version";
#[error(code = 1)]
const ESessionExpired: vector<u8> = b"Dock session has expired";
#[error(code = 2)]
const ENotSessionHolder: vector<u8> = b"Dock session belongs to another sender";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

/// A verified dock of `creation_id` at `target`, held by `sender` until `expires_ms`.
public struct DockSession has key {
    id: UID,
    version: u64,
    creation_id: ID,
    target: ID,
    sender: address,
    expires_ms: u64,
}

// === Events ===

public struct DockOpened has copy, drop {
    session_id: ID,
    creation_id: ID,
    target: ID,
    sender: address,
    expires_ms: u64,
}

public struct DockClosed has copy, drop {
    session_id: ID,
    creation_id: ID,
    target: ID,
}

// === Public Functions ===

/// Verify a signed docking proof once and share a `DockSession` for its sender.
public fun dock(
    cfg: &mut ProofConfig<Docked>,
    payload: vector<u8>,
    sig: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    transfer::share_object(open(cfg, payload, sig, clock, ctx));
}

/// Satisfy the next `Interaction<Docked>` requirement from a live session.
public fun verify_docked(
    request: &mut Request,
    session: &DockSession,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(session.version == VERSION, EWrongVersion);
    assert!(session.sender == ctx.sender(), ENotSessionHolder);
    assert!(clock.timestamp_ms() <= session.expires_ms, ESessionExpired);
    interaction_service::satisfy<Docked>(request, session.creation_id, session.target);
}

/// End the session and refund its storage. Only its holder can end it, at any
/// time, even after expiry.
public fun undock(session: DockSession, ctx: &TxContext) {
    assert!(session.sender == ctx.sender(), ENotSessionHolder);
    let DockSession { id, creation_id, target, .. } = session;
    event::emit(DockClosed { session_id: id.to_inner(), creation_id, target });
    id.delete();
}

// === View Functions ===

public fun version(s: &DockSession): u64 { s.version }

public fun creation_id(s: &DockSession): ID { s.creation_id }

public fun target(s: &DockSession): ID { s.target }

public fun sender(s: &DockSession): address { s.sender }

public fun expires_ms(s: &DockSession): u64 { s.expires_ms }

// === Private Functions ===

fun open(
    cfg: &mut ProofConfig<Docked>,
    payload: vector<u8>,
    sig: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): DockSession {
    let p = cfg.consume(payload, sig, clock, ctx);
    let session = DockSession {
        id: object::new(ctx),
        version: VERSION,
        creation_id: p.creation_id(),
        target: p.target(),
        sender: p.sender(),
        expires_ms: p.deadline_ms(),
    };
    event::emit(DockOpened {
        session_id: session.id.to_inner(),
        creation_id: session.creation_id,
        target: session.target,
        sender: session.sender,
        expires_ms: session.expires_ms,
    });
    session
}
