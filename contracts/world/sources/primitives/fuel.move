/// Fuel module — time-based fuel consumption for network nodes.
///
/// Fuel is now backed by `ItemBalance` at the deposit/withdraw boundaries:
/// - `deposit()` accepts an `ItemBalance` and adds its value to the internal counter.
/// - `withdraw()` splits fuel out as a fresh `ItemBalance`.
///
/// Internally the burn mechanics operate directly on a `u64` quantity counter —
/// no split/join overhead per tick.  The `asset_id` and `type_id` are cached
/// at deposit time for gas-efficient burn calculations.
///
/// FuelConfig efficiency remains keyed by `type_id` (game-defined numeric id),
/// not by `asset_id`, so the game server can set efficiency before item types are registered.
module world::fuel;

use sui::{clock::Clock, event, table::{Self, Table}};
use world::{
    access::AdminCap,
    in_game_id::{Self, TenantItemId},
    item_balance::{Self, ItemBalance, ItemRegistry}
};

// === Errors ===
#[error(code = 0)]
const ETypeIdEmpty: vector<u8> = b"Fuel Type Id cannot be empty";
#[error(code = 1)]
const EInvalidFuelEfficiency: vector<u8> = b"Invalid Fuel Efficiency";
#[error(code = 2)]
const EIncorrectFuelType: vector<u8> = b"Fuel Efficiency for this fuel type is not configured";
#[error(code = 3)]
const EInsufficientFuel: vector<u8> = b"Insufficient fuel quantity";
#[error(code = 4)]
const EInvalidDepositQuantity: vector<u8> = b"Deposit quantity must be greater than 0";
#[error(code = 5)]
const EInvalidWithdrawQuantity: vector<u8> = b"Withdraw quantity must be greater than 0";
#[error(code = 6)]
const EFuelCapacityExceeded: vector<u8> = b"Fuel capacity would be exceeded";
#[error(code = 7)]
const EInvalidMaxCapacity: vector<u8> = b"Fuel max capacity must be greater than 0";
#[error(code = 8)]
const EInvalidVolume: vector<u8> = b"Fuel volume must be greater than 0";
#[error(code = 9)]
const EFuelTypeMismatch: vector<u8> =
    b"Cannot deposit fuel of different type. Withdraw existing fuel first";
#[error(code = 10)]
const EInvalidBurnRate: vector<u8> = b"Burn rate must be at least the minimum configured burn rate";
#[error(code = 11)]
const EFuelNotBurning: vector<u8> = b"Fuel is not currently burning";
#[error(code = 12)]
const EFuelAlreadyBurning: vector<u8> = b"Fuel is already burning";
#[error(code = 13)]
const ENoFuelToBurn: vector<u8> = b"No fuel available to burn";
#[error(code = 14)]
const ETenantMismatch: vector<u8> = b"Tenant mismatch";

// === Constants ===
const MIN_BURN_RATE_SECONDS: u64 = 60;
const MILLISECONDS_PER_SECOND: u64 = 1000;
const MIN_BURN_RATE_MS: u64 = MIN_BURN_RATE_SECONDS * MILLISECONDS_PER_SECOND;
const MIN_FUEL_EFFICIENCY: u64 = 10;
const MAX_FUEL_EFFICIENCY: u64 = 100;
const PERCENTAGE_DIVISOR: u64 = 100;

// === Structs ===

public struct FuelConfig has key {
    id: UID,
    /// Fuel efficiency percentage (10-100) keyed by game type_id.
    fuel_efficiency: Table<u64, u64>,
}

public struct Fuel has store {
    max_capacity: u64,
    burn_rate_in_ms: u64,
    /// The registered item asset currently loaded.  `none` when no fuel has been deposited yet.
    asset_id: Option<ID>,
    /// Cached `type_id` from `ItemData.key` — used for FuelConfig efficiency lookups.
    /// `none` when no fuel has been deposited yet.
    type_id: Option<u64>,
    /// Current fuel units (decremented by burn mechanics).
    quantity: u64,
    is_burning: bool,
    previous_cycle_elapsed_time: u64,
    burn_start_time: u64,
    last_updated: u64,
}

// === Events ===

public enum Action has copy, drop, store {
    DEPOSITED,
    WITHDRAWN,
    BURNING_STARTED,
    BURNING_STOPPED,
    BURNING_UPDATED,
    DELETED,
}

public struct FuelEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    asset_id: ID,
    type_id: u64,
    old_quantity: u64,
    new_quantity: u64,
    is_burning: bool,
    action: Action,
}

public struct FuelEfficiencySetEvent has copy, drop {
    fuel_type_id: u64,
    efficiency: u64,
}

public struct FuelEfficiencyRemovedEvent has copy, drop {
    fuel_type_id: u64,
}

// === View Functions ===

public fun fuel_efficiency(fuel_config: &FuelConfig, fuel_type_id: u64): u64 {
    if (fuel_config.fuel_efficiency.contains(fuel_type_id)) {
        *fuel_config.fuel_efficiency.borrow(fuel_type_id)
    } else {
        abort EIncorrectFuelType
    }
}

public fun quantity(fuel: &Fuel): u64 {
    fuel.quantity
}

public fun fuel_asset_id(fuel: &Fuel): Option<ID> {
    fuel.asset_id
}

public fun type_id(fuel: &Fuel): Option<u64> {
    fuel.type_id
}

public fun is_burning(fuel: &Fuel): bool {
    fuel.is_burning
}

/// Checks if fuel has enough quantity to cover units that would be consumed at current time.
public fun has_enough_fuel(fuel: &Fuel, fuel_config: &FuelConfig, clock: &Clock): bool {
    if (!fuel.is_burning) return false;

    let (units_to_consume, _) = calculate_units_to_consume(
        fuel,
        fuel_config,
        clock.timestamp_ms(),
    );

    fuel.quantity >= units_to_consume
}

/// Checks if fuel state needs to be updated based on elapsed time since last update.
/// Returns true if there are fuel units that need to be consumed.
public fun need_update(fuel: &Fuel, fuel_config: &FuelConfig, clock: &Clock): bool {
    if (!fuel.is_burning) return false;

    let (units_to_consume, _) = calculate_units_to_consume(
        fuel,
        fuel_config,
        clock.timestamp_ms(),
    );

    units_to_consume > 0
}

// === Admin Functions ===

/// Sets or updates the fuel efficiency percentage for a fuel type (10-100%).
public fun set_fuel_efficiency(
    fuel_config: &mut FuelConfig,
    _: &AdminCap,
    fuel_type_id: u64,
    fuel_efficiency: u64,
) {
    assert!(fuel_type_id != 0, ETypeIdEmpty);
    assert!(
        fuel_efficiency >= MIN_FUEL_EFFICIENCY && fuel_efficiency <= MAX_FUEL_EFFICIENCY,
        EInvalidFuelEfficiency,
    );
    if (fuel_config.fuel_efficiency.contains(fuel_type_id)) {
        fuel_config.fuel_efficiency.remove(fuel_type_id);
    };
    fuel_config.fuel_efficiency.add(fuel_type_id, fuel_efficiency);
    event::emit(FuelEfficiencySetEvent {
        fuel_type_id,
        efficiency: fuel_efficiency,
    });
}

/// Removes the fuel efficiency configuration for a fuel type.
public fun unset_fuel_efficiency(fuel_config: &mut FuelConfig, _: &AdminCap, fuel_type_id: u64) {
    assert!(fuel_type_id != 0, ETypeIdEmpty);
    fuel_config.fuel_efficiency.remove(fuel_type_id);
    event::emit(FuelEfficiencyRemovedEvent {
        fuel_type_id,
    });
}

// === Package Functions ===

/// Creates a new fuel container with specified capacity and burn rate (in milliseconds).
public(package) fun create(max_capacity: u64, burn_rate_in_ms: u64): Fuel {
    assert!(max_capacity > 0, EInvalidMaxCapacity);
    assert!(burn_rate_in_ms >= MIN_BURN_RATE_MS, EInvalidBurnRate);
    Fuel {
        max_capacity,
        burn_rate_in_ms,
        asset_id: option::none(),
        type_id: option::none(),
        quantity: 0,
        is_burning: false,
        previous_cycle_elapsed_time: 0,
        burn_start_time: 0,
        last_updated: 0,
    }
}

/// Deposits fuel from an `ItemBalance`.
///
/// The balance is consumed: its `(asset_id, value)` are extracted and the value
/// is added to the internal quantity counter.  The `ItemRegistry` is used to
/// look up `type_id` and `volume` for validation.
///
/// If the fuel tank is empty, initialises the fuel type.  Otherwise verifies
/// the deposited type matches the existing fuel.
public(package) fun deposit(
    fuel: &mut Fuel,
    item_registry: &ItemRegistry,
    balance: ItemBalance,
    assembly_id: ID,
    assembly_key: TenantItemId,
    clock: &Clock,
) {
    let (asset_id, deposit_quantity) = balance.into_parts();
    assert!(deposit_quantity > 0, EInvalidDepositQuantity);

    // Look up item metadata and verify tenant
    let data = item_balance::item_data(item_registry, asset_id);
    let item_tenant = in_game_id::type_tenant(&data.data_key());
    assert!(item_tenant == in_game_id::tenant(&assembly_key), ETenantMismatch);
    let type_id = in_game_id::type_id(&data.data_key());
    let unit_volume = data.data_volume();
    assert!(unit_volume > 0, EInvalidVolume);

    // Initialize or verify fuel type matches
    if (fuel.asset_id.is_none() || fuel.quantity == 0) {
        if (fuel.is_burning) {
            // Reset time tracking — burning continues with new fuel
            fuel.burn_start_time = clock.timestamp_ms();
            fuel.previous_cycle_elapsed_time = 0;
        } else {
            fuel.burn_start_time = 0;
            fuel.previous_cycle_elapsed_time = 0;
        };
        fuel.asset_id = option::some(asset_id);
        fuel.type_id = option::some(type_id);
    } else {
        assert!(*fuel.type_id.borrow() == type_id, EFuelTypeMismatch);
    };

    // Capacity check
    let old_quantity = fuel.quantity;
    let new_quantity = fuel.quantity + deposit_quantity;
    assert!(unit_volume * new_quantity <= fuel.max_capacity, EFuelCapacityExceeded);
    fuel.quantity = new_quantity;

    event::emit(FuelEvent {
        assembly_id,
        assembly_key,
        asset_id,
        type_id,
        old_quantity,
        new_quantity,
        is_burning: fuel.is_burning,
        action: Action::DEPOSITED,
    });
}

/// Withdraws fuel as an `ItemBalance`.
public(package) fun withdraw(
    fuel: &mut Fuel,
    quantity: u64,
    assembly_id: ID,
    assembly_key: TenantItemId,
): ItemBalance {
    assert!(quantity > 0, EInvalidWithdrawQuantity);
    assert!(fuel.quantity >= quantity, EInsufficientFuel);
    assert!(fuel.asset_id.is_some(), ETypeIdEmpty);

    let old_quantity = fuel.quantity;
    fuel.quantity = fuel.quantity - quantity;

    let asset_id = *fuel.asset_id.borrow();

    event::emit(FuelEvent {
        assembly_id,
        assembly_key,
        asset_id,
        type_id: *fuel.type_id.borrow(),
        old_quantity,
        new_quantity: fuel.quantity,
        is_burning: fuel.is_burning,
        action: Action::WITHDRAWN,
    });

    item_balance::new(asset_id, quantity)
}

/// Starts burning fuel. Consumes 1 unit immediately and sets burn_start_time.
/// Requires fuel quantity > 0 or previous_cycle_elapsed_time > 0.
public(package) fun start_burning(
    fuel: &mut Fuel,
    assembly_id: ID,
    assembly_key: TenantItemId,
    clock: &Clock,
) {
    assert!(!fuel.is_burning, EFuelAlreadyBurning);
    assert!(fuel.asset_id.is_some(), ETypeIdEmpty);
    assert!(fuel.quantity > 0 || fuel.previous_cycle_elapsed_time > 0, ENoFuelToBurn);

    let old_quantity = fuel.quantity;
    fuel.is_burning = true;
    fuel.burn_start_time = clock.timestamp_ms();
    if (fuel.quantity != 0) {
        // todo : fix bug: consider previous cycle elapsed time
        fuel.quantity = fuel.quantity - 1; // Consume 1 unit to start the clock
    };

    event::emit(FuelEvent {
        assembly_id,
        assembly_key,
        asset_id: *fuel.asset_id.borrow(),
        type_id: *fuel.type_id.borrow(),
        old_quantity,
        new_quantity: fuel.quantity,
        is_burning: fuel.is_burning,
        action: Action::BURNING_STARTED,
    });
}

/// Stops burning fuel. Saves remaining elapsed time for next burn cycle.
public(package) fun stop_burning(
    fuel: &mut Fuel,
    assembly_id: ID,
    assembly_key: TenantItemId,
    fuel_config: &FuelConfig,
    clock: &Clock,
) {
    assert!(fuel.is_burning, EFuelNotBurning);

    let current_time_ms = clock.timestamp_ms();
    let (units_to_consume, remaining_elapsed_ms) = calculate_units_to_consume(
        fuel,
        fuel_config,
        current_time_ms,
    );

    if (fuel.quantity >= units_to_consume) {
        fuel.previous_cycle_elapsed_time = remaining_elapsed_ms;
    } else {
        fuel.previous_cycle_elapsed_time = 0;
    };
    fuel.burn_start_time = 0;
    fuel.is_burning = false;

    event::emit(FuelEvent {
        assembly_id,
        assembly_key,
        asset_id: *fuel.asset_id.borrow(),
        type_id: *fuel.type_id.borrow(),
        old_quantity: fuel.quantity,
        new_quantity: fuel.quantity,
        is_burning: fuel.is_burning,
        action: Action::BURNING_STOPPED,
    });
}

/// Destroys the fuel container.
///
/// If fuel remains, destroys the balance via `ItemRegistry` (supply tracked off-chain).
/// Consumed fuel (burned over time) is NOT recovered — it represents on-chain consumption.
public(package) fun delete(
    fuel: Fuel,
    item_registry: &ItemRegistry,
    assembly_id: ID,
    assembly_key: TenantItemId,
) {
    let Fuel {
        asset_id,
        type_id,
        quantity,
        ..,
    } = fuel;

    // Decrease supply for remaining (unburned) fuel
    if (quantity > 0 && asset_id.is_some()) {
        let balance = item_balance::new(*asset_id.borrow(), quantity);
        item_balance::decrease_supply(item_registry, balance);
    };

    let event_asset_id = if (asset_id.is_some()) {
        *asset_id.borrow()
    } else {
        object::id_from_address(@0x0)
    };

    let event_type_id = if (type_id.is_some()) {
        *type_id.borrow()
    } else {
        0
    };

    event::emit(FuelEvent {
        assembly_id,
        assembly_key,
        asset_id: event_asset_id,
        type_id: event_type_id,
        old_quantity: quantity,
        new_quantity: 0,
        is_burning: false,
        action: Action::DELETED,
    });
}

/// Updates fuel consumption state. Consumes units based on elapsed time since last update.
/// If there is not enough fuel to consume, stops burning.
public(package) fun update(
    fuel: &mut Fuel,
    assembly_id: ID,
    assembly_key: TenantItemId,
    fuel_config: &FuelConfig,
    clock: &Clock,
) {
    if (!fuel.is_burning || fuel.burn_start_time == 0) {
        return
    };

    let current_time_ms = clock.timestamp_ms();
    if (fuel.last_updated == current_time_ms) {
        return
    };

    let (units_to_consume, remaining_elapsed_ms) = calculate_units_to_consume(
        fuel,
        fuel_config,
        current_time_ms,
    );

    if (fuel.quantity >= units_to_consume) {
        consume_fuel_units(
            fuel,
            assembly_id,
            assembly_key,
            units_to_consume,
            remaining_elapsed_ms,
            current_time_ms,
        );

        fuel.last_updated = current_time_ms;
    } else {
        stop_burning(fuel, assembly_id, assembly_key, fuel_config, clock);
    }
}

// === Private Functions ===

/// Consumes fuel units based on elapsed time.
fun consume_fuel_units(
    fuel: &mut Fuel,
    assembly_id: ID,
    assembly_key: TenantItemId,
    units_to_consume: u64,
    remaining_elapsed_ms: u64,
    current_time_ms: u64,
) {
    if (units_to_consume > 0) {
        let old_quantity = fuel.quantity;
        fuel.quantity = fuel.quantity - units_to_consume;
        fuel.previous_cycle_elapsed_time = 0;
        fuel.burn_start_time = current_time_ms - remaining_elapsed_ms;
        event::emit(FuelEvent {
            assembly_id,
            assembly_key,
            asset_id: *fuel.asset_id.borrow(),
            type_id: *fuel.type_id.borrow(),
            old_quantity,
            new_quantity: fuel.quantity,
            is_burning: fuel.is_burning,
            action: Action::BURNING_UPDATED,
        });
    };
}

/// Calculates units to consume and remaining elapsed time based on total elapsed time
/// and actual consumption rate.  Accounts for `previous_cycle_elapsed_time`.
fun calculate_units_to_consume(
    fuel: &Fuel,
    fuel_config: &FuelConfig,
    current_time_ms: u64,
): (u64, u64) {
    if (!fuel.is_burning || fuel.burn_start_time == 0) {
        return (0, 0)
    };

    let type_id = *fuel.type_id.borrow();
    let efficiency = if (fuel_config.fuel_efficiency.contains(type_id)) {
        *fuel_config.fuel_efficiency.borrow(type_id)
    } else {
        abort EIncorrectFuelType
    };
    let actual_consumption_rate_ms = (fuel.burn_rate_in_ms * efficiency) / PERCENTAGE_DIVISOR;

    let elapsed_ms = if (current_time_ms > fuel.burn_start_time) {
        current_time_ms - fuel.burn_start_time
    } else {
        0
    };

    let total_elapsed_ms = elapsed_ms + fuel.previous_cycle_elapsed_time;
    let units_to_consume = total_elapsed_ms / actual_consumption_rate_ms;
    let remaining_elapsed_ms = total_elapsed_ms % actual_consumption_rate_ms;

    (units_to_consume, remaining_elapsed_ms)
}

// === Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(FuelConfig {
        id: object::new(ctx),
        fuel_efficiency: table::new(ctx),
    })
}

// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun units_to_consume(
    fuel: &Fuel,
    fuel_config: &FuelConfig,
    current_time_ms: u64,
): (u64, u64) {
    calculate_units_to_consume(fuel, fuel_config, current_time_ms)
}

#[test_only]
public fun burn_start_time(fuel: &Fuel): u64 {
    fuel.burn_start_time
}

#[test_only]
public fun previous_cycle_elapsed_time(fuel: &Fuel): u64 {
    fuel.previous_cycle_elapsed_time
}

#[test_only]
public fun max_capacity(fuel: &Fuel): u64 {
    fuel.max_capacity
}

#[test_only]
public fun burn_rate_in_ms(fuel: &Fuel): u64 {
    fuel.burn_rate_in_ms
}
