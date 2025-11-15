#[test_only]
module world::authority_tests;

use sui::test_scenario as ts;
use world::{authority::{Self, AdminCap}, world::{Self, GovernorCap}};

#[test]
fun create_and_delete_admin_cap() {
    let _governor = @0xA;
    let _admin = @0xB;

    let mut ts = ts::begin(_governor);
    {
        world::init_for_testing(ts::ctx(&mut ts));
    };

    ts::next_tx(&mut ts, _governor);
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(&ts);
        authority::create_admin_cap(&gov_cap, _admin, ts::ctx(&mut ts));

        ts::return_to_sender(&ts, gov_cap);
    };

    ts::next_tx(&mut ts, _governor);
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(&ts);
        let admin_cap = ts::take_from_address<AdminCap>(&ts, _admin);

        authority::delete_admin_cap(admin_cap, &gov_cap);

        ts::return_to_sender(&ts, gov_cap);
    };

    ts::end(ts);
}

#[test]
fun create_tranfer_and_delete_owner_cap() {
    let _governor = @0xA;
    let _admin = @0xB;
    let _userA = @0xC;

    let mut ts = ts::begin(_governor);
    {
        world::init_for_testing(ts::ctx(&mut ts));
    };

    ts::next_tx(&mut ts, _governor);
    {
        let gov_cap = ts::take_from_sender<world::GovernorCap>(&ts);
        authority::create_admin_cap(&gov_cap, _admin, ts::ctx(&mut ts));

        ts::return_to_sender(&ts, gov_cap);
    };

    ts::next_tx(&mut ts, _admin);
    {
        let admin_cap = ts::take_from_sender<authority::AdminCap>(&ts);

        let dummy_character_object_id = object::id_from_address(@0x1234);
        let owner_cap = authority::create_owner_cap(
            &admin_cap,
            dummy_character_object_id,
            ts::ctx(&mut ts),
        );
        authority::transfer_owner_cap(owner_cap, &admin_cap, _userA);

        ts::return_to_sender(&ts, admin_cap);
    };

    ts::next_tx(&mut ts, _admin);
    {
        let owner_cap = ts::take_from_address<authority::OwnerCap>(&ts, _userA);
        let admin_cap = ts::take_from_sender<authority::AdminCap>(&ts);

        // Only possible in tests
        authority::delete_owner_cap(owner_cap, &admin_cap);

        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}
