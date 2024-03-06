// Copyright (c) Electric Brain, LLC.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module lottery::lottery_test {
    use lottery::lottery::{
        LotteryStoreAdminCap, LotteryStore, init_for_testing, settle_or_continue_for_testing,
        create_lottery, create_store, create_test_reward_struct, set_store_state, buy_ticket, 
        lottery_prize_pool, lottery_fees, allow_redemptions_for_round, redeem, set_next_round_and_drawing_time,
        Ticket, ELotteryNotInProgress, ELotteryNotSettled, transfer_optional_coin, get_lottery_queue_size};
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use sui::object::{ID};
    use sui::coin::{Self};
    use std::option;

    #[test_only] use sui::test_scenario::{Scenario};
    #[test_only] use sui::coin::{mint_for_testing};
    use sui::test_scenario as ts;
    use sui::sui::SUI;

    const OWNER: address = @0xF;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;
    const CAT: address = @0xCCCC;

    // CONSTANTS
    const MIN_JACKPOT: u64 = 10000;
    const NORMAL_BALL_COUNT: u8 = 2;
    const MAX_NORMAL_BALL: u8 = 5;
    const MAX_SPECIAL_BALL: u8 = 5;
    const STARTING_PRIZE_POOL: u64 = 20000;
    const TICKET_COST: u64 = 10;
    const LOTTERY_END_TIME: u64 = 10;
    const HALF_TICKET_COST: u64 = 5;

    #[test_only]
    public fun setup_lottery(
        scenario: &mut Scenario
    ): ID {
        let lottery_id: ID;
        ts::next_tx(scenario, OWNER);
        {
            init_for_testing(ts::ctx(scenario));
        };
        ts::next_tx(scenario, OWNER);
        {
            // create clock
            let clock = clock::create_for_testing(ts::ctx(scenario));
            clock::set_for_testing(&mut clock, 0);
            clock::share_for_testing(clock);
        };
        ts::next_tx(scenario, OWNER);
        {
            let lottery_cap: LotteryStoreAdminCap = ts::take_from_sender(scenario);
            create_store(&lottery_cap, ts::ctx(scenario));
            ts::return_to_sender(scenario, lottery_cap);
        };
        ts::next_tx(scenario, OWNER);
        {
            let lottery_cap: LotteryStoreAdminCap = ts::take_from_sender(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            let funding_coin = mint_for_testing<SUI>(STARTING_PRIZE_POOL, ts::ctx(scenario));
            let payout_vector = create_test_reward_struct();

            lottery_id = create_lottery<SUI>(
                &lottery_cap,
                &mut store,
                funding_coin,
                MIN_JACKPOT,
                1,
                TICKET_COST,
                payout_vector,
                NORMAL_BALL_COUNT,
                MAX_NORMAL_BALL,
                MAX_SPECIAL_BALL,
                LOTTERY_END_TIME,
                ts::ctx(scenario)
            );

            // Open the store
            set_store_state(
                &lottery_cap,
                &mut store,
                true
            );

            ts::return_to_sender(scenario, lottery_cap);
            ts::return_shared(store);

        };
        lottery_id
    }

    // Test to handle entire flow 
    // Because of the set up of 2 ball counts only with a max of 2, the winning 
    // ticket is always going to be 0, 1 and special_number: 0.
    // We write some tests here that handle the below cases.
    // Note that the case of duplicates is already handled by the VecSet
    // This is the roll for this test (0, 2) and (4)
    // [debug] 0x0::lottery::Picks {
    //   numbers: 0x2::vec_set::VecSet<u8> {
    //     contents: 0x0002
    //   },
    //   special_number: 4
    // }
    #[test]
    fun test_buy_ticket_and_evaluate() {
        let scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let lottery_id = setup_lottery(scenario);
        ts::next_tx(scenario, ALICE);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 1];
            let special_number = 1;
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            
            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );

            // Since submitted a losing ticket on purpose check that the losing ticket doesn't take balance
            let lottery_prize_pool = lottery_prize_pool<SUI>(&store, lottery_id);
            let lottery_fees = lottery_fees<SUI>(&store, lottery_id);
            assert!(lottery_prize_pool == STARTING_PRIZE_POOL + HALF_TICKET_COST, 0);
            assert!(lottery_fees == HALF_TICKET_COST, 0);

            // Transfer ticket to Alice
            transfer::public_transfer(ticket, ALICE);

            ts::return_shared(clock);
            ts::return_shared(store);
        };
        ts::next_tx(scenario, OWNER);
        {
            let lottery_cap: LotteryStoreAdminCap = ts::take_from_sender(scenario);
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);

            clock::increment_for_testing(&mut clock, 15);

            settle_or_continue_for_testing<SUI>(
                &lottery_cap,
                &mut store,
                lottery_id,
                b"testdrand",
                1,
                option::none(),
                &clock
            );
            // Since submitting a ticket that wins the 1 tier
            let lottery_prize_pool = lottery_prize_pool<SUI>(&store, lottery_id);
            assert!(lottery_prize_pool == STARTING_PRIZE_POOL + 4, 0);
            allow_redemptions_for_round<SUI>(
                &lottery_cap, 
                &mut store,
                lottery_id,
                1
            );
            ts::return_shared(clock);
            ts::return_shared(store);
            ts::return_to_sender(scenario, lottery_cap);
        };
        ts::next_tx(scenario, ALICE);
        {
            let ticket: Ticket = ts::take_from_sender(scenario);
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            
            let option_coin = redeem<SUI>(
                ticket,
                &mut store,
                lottery_id,
                ts::ctx(scenario)
            );

            let coin_value = option::borrow(&option_coin);
            assert!(coin::value(coin_value) == 1, 0);
            transfer_optional_coin(
                &mut option_coin,
                ts::ctx(scenario)
            );
            option::destroy_none(option_coin);

            ts::return_shared(clock);
            ts::return_shared(store);
        };
        
        ts::end(scenario_val);
    }

    // Test claim round and jackpot hits
    #[test]
    fun test_buy_ticket_and_hit_jackpot() {
        let scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let lottery_id = setup_lottery(scenario);
        ts::next_tx(scenario, ALICE);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 2];
            let special_number = 4;
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);

            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );

            // Since submitted a losing ticket on purpose check that the losing ticket doesn't take balance
            let lottery_prize_pool = lottery_prize_pool<SUI>(&store, lottery_id);
            let lottery_fees = lottery_fees<SUI>(&store, lottery_id);
            assert!(lottery_prize_pool == STARTING_PRIZE_POOL + HALF_TICKET_COST, 0);
            assert!(lottery_fees == HALF_TICKET_COST, 0);
            // Transfer ticket to Alice
            transfer::public_transfer(ticket, ALICE);
            ts::return_shared(clock);
            ts::return_shared(store);   
        };
        ts::next_tx(scenario, OWNER);
        {
            let lottery_cap: LotteryStoreAdminCap = ts::take_from_sender(scenario);
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            clock::increment_for_testing(&mut clock, 15);

            settle_or_continue_for_testing<SUI>(
                &lottery_cap,
                &mut store,
                lottery_id,
                b"testdrand",
                1,
                option::none(),
                &clock
            );
            // Since submitting a ticket that wins the 1 tier
            let lottery_prize_pool = lottery_prize_pool<SUI>(&store, lottery_id);
            // Cause we don't take coins assert that this is still there
            assert!(lottery_prize_pool == STARTING_PRIZE_POOL + HALF_TICKET_COST, 0);
            allow_redemptions_for_round<SUI>(
                &lottery_cap, 
                &mut store,
                lottery_id,
                1
            );
            ts::return_shared(clock);
            ts::return_shared(store);   
            ts::return_to_sender(scenario, lottery_cap);
        };
        ts::next_tx(scenario, ALICE);
        {
            let ticket: Ticket = ts::take_from_sender(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            let clock: Clock = ts::take_shared(scenario);

            let option_coin = redeem<SUI>(
                ticket,
                &mut store,
                lottery_id,
                ts::ctx(scenario)
            );
            let coin_value = option::borrow(&option_coin);
            assert!(coin::value(coin_value) == STARTING_PRIZE_POOL + HALF_TICKET_COST, 0);
            transfer_optional_coin(
                &mut option_coin,
                ts::ctx(scenario)
            );
            option::destroy_none(option_coin);

            let lottery_prize_pool = lottery_prize_pool<SUI>(&store, lottery_id);
            assert!(lottery_prize_pool == 0, 0);
            ts::return_shared(store);
            ts::return_shared(clock);
        };
        ts::end(scenario_val);
    }

    // Test claim round and jackpot hits
    #[test]
    fun test_buy_ticket_and_hit_jackpot_multiple_winners() {
        let scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let lottery_id = setup_lottery(scenario);

        ts::next_tx(scenario, ALICE);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 2];
            let special_number = 4;
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );
            // Transfer ticket to Alice
            transfer::public_transfer(ticket, ALICE);
            ts::return_shared(clock);
            ts::return_shared(store);
        };
        ts::next_tx(scenario, BOB);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 2];
            let special_number = 4;
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );
            // Transfer ticket to Alice
            transfer::public_transfer(ticket, BOB);
            ts::return_shared(clock);
            ts::return_shared(store);
        };
        ts::next_tx(scenario, CAT);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 2];
            let special_number = 4;
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );
            // Transfer ticket to Alice
            transfer::public_transfer(ticket, CAT);
            ts::return_shared(clock);
            ts::return_shared(store);
        };
        ts::next_tx(scenario, OWNER);
        {
            let lottery_cap: LotteryStoreAdminCap = ts::take_from_sender(scenario);
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            clock::increment_for_testing(&mut clock, 15);
            settle_or_continue_for_testing<SUI>(
                &lottery_cap,
                &mut store,
                lottery_id,
                b"testdrand",
                1,
                option::none(),
                &clock
            );
            allow_redemptions_for_round<SUI>(
                &lottery_cap, 
                &mut store,
                lottery_id,
                1
            );
            ts::return_to_sender(scenario, lottery_cap);
            ts::return_shared(clock);
            ts::return_shared(store);
        };
        ts::next_tx(scenario, ALICE);
        {
            let ticket: Ticket = ts::take_from_sender(scenario);
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            let lottery_prize_pool = lottery_prize_pool<SUI>(&store, lottery_id);
            let option_coin = redeem<SUI>(
                ticket,
                &mut store,
                lottery_id,
                ts::ctx(scenario)
            );
            let coin_value = option::borrow(&option_coin);
            assert!(coin::value(coin_value) == (lottery_prize_pool)/ 3, 0);
            transfer_optional_coin(
                &mut option_coin,
                ts::ctx(scenario)
            );
            option::destroy_none(option_coin);

            ts::return_shared(clock);
            ts::return_shared(store);
        };
        ts::next_tx(scenario, BOB);
        {
            let ticket: Ticket = ts::take_from_sender(scenario);
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            let lottery_prize_pool = lottery_prize_pool<SUI>(&store, lottery_id);
            let option_coin = redeem<SUI>(
                ticket,
                &mut store,
                lottery_id,
                ts::ctx(scenario)
            );
            let coin_value = option::borrow(&option_coin);
            assert!(coin::value(coin_value) == (lottery_prize_pool)/ 2, 0);
            transfer_optional_coin(
                &mut option_coin,
                ts::ctx(scenario)
            );
            option::destroy_none(option_coin);

            ts::return_shared(clock);
            ts::return_shared(store);
        };
        ts::next_tx(scenario, CAT);
        {
            let ticket: Ticket = ts::take_from_sender(scenario);
            let clock: Clock = ts::take_shared(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            let lottery_prize_pool = lottery_prize_pool<SUI>(&store, lottery_id);
            let option_coin = redeem<SUI>(
                ticket,
                &mut store,
                lottery_id,
                ts::ctx(scenario)
            );
            let coin_value = option::borrow(&option_coin);
            assert!(coin::value(coin_value) == lottery_prize_pool, 0);
            transfer_optional_coin(
                &mut option_coin,
                ts::ctx(scenario)
            );
            option::destroy_none(option_coin);

            let lottery_prize_pool = lottery_prize_pool<SUI>(&store, lottery_id);
            assert!(lottery_prize_pool == 0, 0);
            ts::return_shared(clock);
            ts::return_shared(store);
        };
        ts::end(scenario_val);
    }

    // Test round claim and move on to next round
    #[test]
    fun test_move_to_next_round() {
        let scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let lottery_id = setup_lottery(scenario);

        ts::next_tx(scenario, ALICE);
        let clock: Clock = ts::take_shared(scenario);
        let store: LotteryStore = ts::take_shared(scenario);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 1];
            let special_number = 4;

            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );
            // Transfer ticket to Alice
            transfer::public_transfer(ticket, ALICE);
        };
        ts::next_tx(scenario, OWNER);
        {
            let lottery_cap: LotteryStoreAdminCap = ts::take_from_sender(scenario);
            clock::increment_for_testing(&mut clock, 15);
            settle_or_continue_for_testing<SUI>(
                &lottery_cap,
                &mut store,
                lottery_id,
                b"testdrand",
                1,
                option::none(),
                &clock
            );
            allow_redemptions_for_round<SUI>(
                &lottery_cap, 
                &mut store,
                lottery_id,
                1
            );
            ts::return_to_sender(scenario, lottery_cap);
        };
        ts::next_tx(scenario, OWNER);
        {
            let lottery_cap: LotteryStoreAdminCap = ts::take_from_sender(scenario);
            // Start round 2 of the lottery
            set_next_round_and_drawing_time<SUI>(
                &mut store,
                lottery_id,
                &lottery_cap,
                15,
                2
            );
            ts::return_to_sender(scenario, lottery_cap);
        };
        ts::next_tx(scenario, ALICE);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 1];
            let special_number = 4;
            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );
            // Transfer ticket to Alice
            transfer::public_transfer(ticket, ALICE);
        };
        ts::return_shared(clock);
        ts::return_shared(store);
        ts::end(scenario_val);
    }

    // Test round claim and move on to next round
    #[test]
    fun test_move_to_next_round_with_pagination() {
        let scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let lottery_id = setup_lottery(scenario);

        ts::next_tx(scenario, ALICE);
        let clock: Clock = ts::take_shared(scenario);
        let store: LotteryStore = ts::take_shared(scenario);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 1];
            let special_number = 4;

            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );
            let ticket_2 = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario)),
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );

            // Transfer ticket to Alice
            transfer::public_transfer(ticket, ALICE);
            transfer::public_transfer(ticket_2, ALICE);
        };
        ts::next_tx(scenario, OWNER);
        {
            let lottery_cap: LotteryStoreAdminCap = ts::take_from_sender(scenario);
            clock::increment_for_testing(&mut clock, 15);
            settle_or_continue_for_testing<SUI>(
                &lottery_cap,
                &mut store,
                lottery_id,
                b"testdrand",
                1,
                option::some(1),
                &clock
            );
            
            // assert that queue has some size left
            assert!(get_lottery_queue_size<SUI>(&store, lottery_id) == 1, 0);
            
            settle_or_continue_for_testing<SUI>(
                &lottery_cap,
                &mut store,
                lottery_id,
                b"testdrand",
                1,
                option::some(1),
                &clock
            );

            allow_redemptions_for_round<SUI>(
                &lottery_cap, 
                &mut store,
                lottery_id,
                1
            );
            ts::return_to_sender(scenario, lottery_cap);
        };
        ts::next_tx(scenario, OWNER);
        {
            let lottery_cap: LotteryStoreAdminCap = ts::take_from_sender(scenario);
            // Start round 2 of the lottery
            set_next_round_and_drawing_time<SUI>(
                &mut store,
                lottery_id,
                &lottery_cap,
                15,
                2
            );
            ts::return_to_sender(scenario, lottery_cap);
        };
        ts::next_tx(scenario, ALICE);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 1];
            let special_number = 4;
            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );
            // Transfer ticket to Alice
            transfer::public_transfer(ticket, ALICE);
        };
        ts::return_shared(clock);
        ts::return_shared(store);
        ts::end(scenario_val);
    }

    // Test try to buy ticket after expiration
    #[test]
    #[expected_failure(abort_code = ELotteryNotInProgress)]
    fun test_buy_ticket_after_time() {
        let scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let lottery_id = setup_lottery(scenario);

        ts::next_tx(scenario, ALICE);
        let clock: Clock = ts::take_shared(scenario);
        let store: LotteryStore = ts::take_shared(scenario);
        clock::set_for_testing(&mut clock, 11);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 1];
            let special_number = 4;

            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );
            // Transfer ticket to Alice
            transfer::public_transfer(ticket, ALICE);
        };
        ts::return_shared(clock);
        ts::return_shared(store);
        ts::end(scenario_val);
    }

    // Test try to redeem before redeptioms are allowed
    #[test]
    #[expected_failure(abort_code = ELotteryNotSettled)]
    fun test_invalid_redemptions() {
        let scenario_val = ts::begin(OWNER);
        let scenario = &mut scenario_val;
        let lottery_id = setup_lottery(scenario);
        ts::next_tx(scenario, ALICE);
        {
            let ticket_coin = mint_for_testing<SUI>(TICKET_COST, ts::ctx(scenario));
            let number_choice: vector<u8> = vector[0, 1];
            let special_number = 1;
            let store: LotteryStore = ts::take_shared(scenario);
            let clock: Clock = ts::take_shared(scenario);
            let ticket = buy_ticket<SUI>(
                &mut store,
                lottery_id,
                ticket_coin,
                number_choice,
                special_number,
                &clock,
                ts::ctx(scenario)
            );

            // Since submitted a losing ticket on purpose check that the losing ticket doesn't take balance
            let lottery_prize_pool = lottery_prize_pool<SUI>(&store, lottery_id);
            let lottery_fees = lottery_fees<SUI>(&store, lottery_id);
            assert!(lottery_prize_pool == STARTING_PRIZE_POOL + HALF_TICKET_COST, 0);
            assert!(lottery_fees == HALF_TICKET_COST, 0);
            ts::return_shared(clock);
            ts::return_shared(store);
            // Transfer ticket to Alice
            transfer::public_transfer(ticket, ALICE);
        };
        ts::next_tx(scenario, OWNER);
        {
            let lottery_cap: LotteryStoreAdminCap = ts::take_from_sender(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            let clock: Clock = ts::take_shared(scenario);
            clock::increment_for_testing(&mut clock, 15);
            settle_or_continue_for_testing<SUI>(
                &lottery_cap,
                &mut store,
                lottery_id,
                b"testdrand",
                1,
                option::none(),
                &clock
            );
            std::debug::print(&b"tes");
            ts::return_to_sender(scenario, lottery_cap);
            ts::return_shared(clock);
            ts::return_shared(store);
        };
        ts::next_tx(scenario, ALICE);
        {
            let ticket: Ticket = ts::take_from_sender(scenario);
            let store: LotteryStore = ts::take_shared(scenario);
            let clock: Clock = ts::take_shared(scenario);
            let option_coin = redeem<SUI>(
                ticket,
                &mut store,
                lottery_id,
                ts::ctx(scenario)
            );
            let coin_value = option::borrow(&option_coin);
            assert!(coin::value(coin_value) == 1, 0);
            transfer_optional_coin(
                &mut option_coin,
                ts::ctx(scenario)
            );
            option::destroy_none(option_coin);

            ts::return_shared(clock);
            ts::return_shared(store);
        };
        ts::end(scenario_val);
    }

}