// Copyright (c) Electric Brain, LLC.
// SPDX-License-Identifier: Apache-2.0

/// Building the a drand lottery implementation
/// We will use the same model as Powerball, but invoke the same drand based mechanism 
/// from https://github.com/MystenLabs/sui/blob/682431233d0a5e067afe56173059aba798027890/sui_programmability/examples/games/sources/drand_based_lottery.move#L4

/// This is a continuous lottery implementation, where one lottery starts and will be funded,
/// and then continue to run until the numbers get hit.
module lottery::lottery {
    use lottery::drand_lib::{derive_randomness, verify_drand_signature, safe_selection};
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::package::{Self};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::dynamic_object_field as dof;
    use sui::event;
    use std::vector as vec;
    use sui::vec_set::{Self, VecSet};
    use lottery::big_queue::{Self, BigQueue};
    use std::vector;
    use sui::event::emit;
    use std::option::{Self, Option};

    // --------------- Events ---------------
    struct TicketPurchased<phantom T> has copy, store, drop {
        id: ID, 
        /// Each number is stored in the index, the vector must match exactly 
        picks: Picks,
        lottery_id: ID,
        /// The round this ticket is for
        round: u64,
        /// Issued at a certain time
        timestamp_issued: u64        
    }

    struct TicketResult<phantom T> has copy, store, drop {
        player: address,
        reward_structure: RewardStructure,
        amount_won: u64,
        picks: Picks
    }

    /// The result for each round of drawings, we will post up the results.
    struct RoundResult<phantom T> has copy, store, drop {
        round: u64,
        lottery_id: ID,
        results: Picks,
        timestamp_drawn: u64,
    }

    struct RoundStarted<phantom T> has copy, store, drop {
        round: u64,
        lottery_id: ID,
        next_drawing_time: u64,
    }

    struct LotteryCreated<phantom T> has copy, store, drop {
        lottery_id: ID,
        initial_prize_amount: u64,
    }

    struct RedeemEvent<phantom T> has copy, drop {
        player: address,
        amount: u64
    }

    // --------------- Errors ---------------
    const ELotteryNotInProgress: u64 = 0;
    const EInvalidPurchase: u64 = 1;
    const EInvalidNumberSelection: u64 = 3;
    const EWrongLottery: u64 = 4;
    const EMinimumJackpotNotHit: u64 = 5;
    const ELotteryNotSettled: u64 = 6;
    const EWrongRound: u64 = 7;
    const EJackpotHit: u64 = 8;
    const ELotteryNotExists: u64 = 9;

    // --------------- Name Tag ---------------
    
    struct LOTTERY has drop {}

    // --------------- Structs ---------------

    struct LotteryStoreAdminCap has key, store {
        id: UID,
    }

    struct LotteryStore has key, store {
        id: UID,
        is_closed: bool,
    }

    /// Individual lottery hosted as a dof within the lottery store.
    /// The user selects a ticket of 5 numbers from 0 - 34, any 
    /// combination of these numbers that hit are valid. The special 
    /// ball will be a random number from 0 - 9. We will use the last ball 
    /// as the special ball similar to the golden ball of the power ball 
    /// lottery. We currently plan to run a drawing every single day 
    /// at 00:00 UTC time, and potentially live stream this drawing. 
    /// 
    /// We will close each lottery at 23:00 the day of the drawing so we will
    /// stop selling tickets if clock is past the time
    /// 
    /// Consideration, do we want to add an extra type to have different arrays?
    struct Lottery<phantom T> has key, store {
        id: UID,
        /// Total balance pool in the current 
        lottery_prize_pool: Balance<T>,
        /// Minimum jackpot paid out
        minimum_jackpot: u64,
        /// 50% of the tickets sold will be added to the lottery fees
        lottery_fees: Balance<T>,
        /// The round of the of current jackpot
        current_round: u64,
        ticket_cost: u64,
        /// Uses a vector to store the different types of payouts prizes for each reward type
        /// The 0 index is the easiest prize and goes up to 8 prizes, and the 9th prize is a jackpot
        reward_structure_table: Table<RewardStructure, u64>,
        /// Count of normal balls
        normal_ball_count: u8,
        /// Range that the balls can roll assuming 0 to the number inclusive
        max_normal_ball: u8,
        /// Special ball range assuming 0 to the number inclusive
        max_special_ball: u8,
        /// Timestamp for drawing time, if the timestamp has never updated then no 
        /// one can ever buy new tickets
        drawing_time_ms: u64,
        /// Mapping of Tickets to the index
        tickets: BigQueue<TicketReceipt>,
        /// A store of each winning ticket and the balance.
        winning_tickets: Table<ID, Balance<T>>,
        /// The current jackpot winners
        jackpot_winners: Table<ID, bool>,
        /// A table of the current lottery iteration and if it was settled
        rounds_settled: Table<u64, bool>,
        /// A table of redemptions for the round and if its allowed
        redemptions_allowed: Table<u64, bool>,
    }

    /// The store receipt that the ticket was purchased for the round
    struct TicketReceipt has store, drop {
        original_ticket_id: ID,
        picks: Picks,
    }

    struct RewardStructureInput has store, drop {
        normal_ball_count: u8,
        special_number_hit: bool,
        balance_paid: u64
    }

    struct RewardStructure has copy, store, drop {
        normal_ball_count: u8,
        special_number_hit: bool,
    }

    struct Picks has copy, store, drop {
        numbers: VecSet<u8>,
        special_number: u8,
    }

    struct Ticket has key, store {
        id: UID,
        /// Each number is stored in the index, the vector must match exactly 
        picks: Picks,
        lottery_id: ID,
        /// The round this ticket is for
        round: u64,
        /// Issued at a certain time
        timestamp_issued: u64
    }

    // --------------- Admin Functions ---------------

    public fun set_store_state(
        _store_cap: &LotteryStoreAdminCap, 
        store: &mut LotteryStore,
        is_closed: bool,
    ) {
        store.is_closed = is_closed;
    }

    public fun withdraw_fees<T>(
        _store_cap: &LotteryStoreAdminCap, 
        lottery: &mut Lottery<T>,
        ctx: &mut TxContext
    ): Coin<T> {
        let quantity = lottery_fees_value(lottery);
        let to_withdraw = balance::split(&mut lottery.lottery_fees, quantity);
        coin::from_balance(to_withdraw, ctx)
    }

    public fun withdraw_all<T>(
        _store_cap: &LotteryStoreAdminCap,
        store: &mut LotteryStore,
        lottery_id: ID,
        ctx: &mut TxContext
    ): Coin<T> {
        let prize_value = lottery_prize_pool<T>(store, lottery_id);
        let fees_value = lottery_fees<T>(store, lottery_id);
        let lottery = borrow_mut_lottery<T>(store, lottery_id);
        let to_withdraw = balance::split(&mut lottery.lottery_fees, fees_value);
        let prize_to_withdraw = balance::split(&mut lottery.lottery_prize_pool, prize_value);
        balance::join<T>(&mut to_withdraw, prize_to_withdraw);
        coin::from_balance(to_withdraw, ctx)
    }
    
    // --------------- Constructor ---------------

    /// We claim the cap for updating display
    fun init(otw: LOTTERY, ctx: &mut TxContext){
        let admin = tx_context::sender(ctx);
        let admin_cap = LotteryStoreAdminCap { id: object::new(ctx) };
        package::claim_and_keep(otw, ctx);
        transfer::transfer(admin_cap, admin);
    }

    // --------------- Public Functions ---------------
    public fun new_reward_structure_input(
        normal_ball_count: u8,
        special_number_hit: bool,
        balance_paid: u64
    ): RewardStructureInput {
        RewardStructureInput {
            normal_ball_count,
            special_number_hit,
            balance_paid
        }
    }

    public fun new_reward_structure_input_vector(
        normal_ball_count_vec: vector<u8>,
        special_number_hit_vec: vector<bool>,
        balance_paid_vec: vector<u64>
    ): vector<RewardStructureInput> {

        // Assert lengths of the vectors are all equal
        assert!(vector::length(&normal_ball_count_vec) == vector::length(&special_number_hit_vec), EInvalidNumberSelection);
        assert!(vector::length(&special_number_hit_vec) == vector::length(&balance_paid_vec), EInvalidNumberSelection);

        let idx = 0;
        let reward_vec: vector<RewardStructureInput> = vector[];
        while(idx < vector::length(&normal_ball_count_vec)) {

            let normal_ball_count = *vector::borrow(&normal_ball_count_vec, idx);
            let special_number_hit = *vector::borrow(&special_number_hit_vec, idx);
            let balance_paid = *vector::borrow(&balance_paid_vec, idx);
            let reward_struct = RewardStructureInput {
                normal_ball_count,
                special_number_hit,
                balance_paid
            };
            vector::push_back(&mut reward_vec, reward_struct);
            idx = idx + 1;
        };

        reward_vec
    }
    
    public fun create_store(
        _store_cap: &LotteryStoreAdminCap, 
        ctx: &mut TxContext
    ) {
        transfer::share_object(LotteryStore {
            id: object::new(ctx),
            is_closed: true
        })
    }

    /// Create a lottery and store it as a field in the lottery store
    public fun create_lottery<T>(
        _store_cap: &LotteryStoreAdminCap, 
        store: &mut LotteryStore,
        stake: Coin<T>,
        minimum_jackpot: u64,
        next_round: u64,
        ticket_cost: u64,
        payout_vector: vector<RewardStructureInput>,
        normal_ball_count: u8,
        max_normal_ball: u8,
        max_special_ball: u8,
        drawing_time_ms: u64,
        ctx: &mut TxContext,
    ): ID {
        let stake_amount = coin::value(&stake);
        let balance = coin::into_balance(stake);
        let id = object::new(ctx);
        let lottery_id = object::uid_to_inner(&id);

        let reward_structure_table = table::new(ctx);
        while (vec::length(&payout_vector) > 0) {
            let reward_struct = vec::pop_back(&mut payout_vector);
            table::add(&mut reward_structure_table, RewardStructure {
                normal_ball_count: reward_struct.normal_ball_count,
                special_number_hit: reward_struct.special_number_hit
            }, reward_struct.balance_paid)
        };

        let lottery = Lottery<T> {
            id,
            lottery_prize_pool: balance,
            minimum_jackpot,
            lottery_fees: balance::zero(),
            current_round: next_round,
            ticket_cost,
            reward_structure_table,
            normal_ball_count,
            max_normal_ball,
            max_special_ball,
            drawing_time_ms,
            tickets: big_queue::new(50000, ctx),
            winning_tickets: table::new(ctx),
            jackpot_winners: table::new(ctx),
            rounds_settled: table::new(ctx),
            redemptions_allowed: table::new(ctx),
        };

        table::add(&mut lottery.redemptions_allowed, next_round, false);
        table::add(&mut lottery.rounds_settled, next_round, false);
        dof::add(&mut store.id, lottery_id, lottery);
        event::emit(LotteryCreated<T> {
            lottery_id,
            initial_prize_amount: stake_amount
        });
        lottery_id
    }
    
    fun check_is_valid_numbers<T>(
        numbers: vector<u8>,
        special_number: u8,
        lottery: &Lottery<T>,
    ) {
        // Assert that the lottery is the correct numbers
        let number_length = (vec::length(&numbers) as u8);
        assert!(number_length == lottery.normal_ball_count, EInvalidNumberSelection);
        // Assert that the normal numbers are in range, and then the last one is also in range for special ball
        let idx = 0;
        let numbers_copy: vector<u8> = vector[];
        while (idx < (number_length as u64)) {
            let number = *vec::borrow(&numbers, idx);
            assert!(number <= lottery.max_normal_ball, EInvalidNumberSelection);
            assert!(number >= 0, EInvalidNumberSelection);
            vector::push_back(&mut numbers_copy, number);
            idx = idx + 1;
        };

        idx = 0;
        while (idx < (number_length as u64)) {
            // Assert no duplicates
            let number_copy = vector::pop_back(&mut numbers_copy);
            assert!(!vector::contains(&numbers_copy, &number_copy), EInvalidNumberSelection);
            idx = idx + 1;
        };

        // Assert that the special ball in is range
        assert!(special_number <= lottery.max_special_ball, EInvalidNumberSelection);
        assert!(special_number >= 0, EInvalidNumberSelection);
    }

    public fun buy_ticket<T>(
        store: &mut LotteryStore,
        lottery_id: ID,
        payment: Coin<T>,
        numbers: vector<u8>,
        special_number: u8,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Ticket {
        // Get lottery from the store
        let lottery = borrow_mut_lottery<T>(store, lottery_id);
        let current_round = lottery.current_round;
        // Assert that the lottery is still up for purchase
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time <= lottery.drawing_time_ms, ELotteryNotInProgress);
        // Assert and check the round and redemptions table does not already exists
        // i.e. if it has been settled and allowed (bool: true) already
        assert!(!round_is_settled(lottery, current_round), ELotteryNotSettled);
        assert!(!redemptions_allowed_for_round(lottery, current_round), ELotteryNotSettled);
        check_is_valid_numbers(numbers, special_number, lottery);

        // Assert that the coin is correct for the lottery
        let coin_amount = coin::value(&payment);
        assert!(coin_amount == lottery.ticket_cost, EInvalidPurchase);
        let payment_balance = coin::into_balance(payment);
        let half_coin = balance::split(&mut payment_balance, coin_amount/2);
        // Transfer 50% of the fees to the fee section, and the rest add to the lottery
        balance::join(&mut lottery.lottery_prize_pool, half_coin);
        balance::join(&mut lottery.lottery_fees, payment_balance);

        let id = object::new(ctx);
        let ticket_id = object::uid_to_inner(&id);

        assert!(special_number < lottery.max_special_ball, EInvalidPurchase);
        let numbers_set = vec_set::empty();
        while (vec::length(&numbers) > 0) {
            let num = vec::pop_back(&mut numbers);
            assert!(num < lottery.max_normal_ball, EInvalidPurchase);
            vec_set::insert(&mut numbers_set, num);
        };

        let picks = Picks {
            numbers: numbers_set,
            special_number
        };

        let ticket = Ticket {
            id,
            picks,
            lottery_id,
            round: lottery.current_round,
            timestamp_issued:clock::timestamp_ms(clock)
        };

        // Receipts to lottery store for tracking
        let ticket_recipt = TicketReceipt {
            original_ticket_id: ticket_id,
            picks
        };

        big_queue::push_back(&mut lottery.tickets, ticket_recipt);

        emit(TicketPurchased<T>{
            id: ticket_id,
            picks,
            lottery_id,
            round: lottery.current_round,
            timestamp_issued: clock::timestamp_ms(clock)
        });

        ticket
    }

    fun select_numbers<T>(
        lottery: &Lottery<T>,
        drand_sig: vector<u8>,
    ): Picks {
        let results = vec_set::empty();
        // Choose select numbers in a range 
        let rand_seed = derive_randomness(drand_sig);
        let idx = 0;
        while (idx < lottery.normal_ball_count) {
            // Shuffle the normal ball rolls
            rand_seed = derive_randomness(rand_seed);
            let roll = (safe_selection((lottery.max_normal_ball as u64), &rand_seed) as u8);
            while (vec_set::contains(&results, &roll)) {
                rand_seed = derive_randomness(rand_seed);
                roll = (safe_selection((lottery.max_normal_ball as u64), &rand_seed) as u8);
            };
            vec_set::insert(&mut results, roll);
            idx = idx + 1;
        };

        // Shuffle the seed again
        rand_seed = derive_randomness(rand_seed);
        let special_roll = (safe_selection((lottery.max_special_ball as u64), &rand_seed) as u8);

        Picks {
            numbers: results,
            special_number: special_roll
        }
    }

    /// Helper function here to grab the roll of the ticket and return the balance,
    /// If the result is not in the table, this is an auto loss ticket.
    /// Returns the prize_balance and also if it is a jackpot
    fun get_ticket_result<T>(
        guessed_picks: Picks,
        actual_picks: &Picks,
        lottery: &Lottery<T>,
    ): (u64, bool) {

        let normal_ball_count = 0;
        let guessed_nums = vec_set::into_keys(guessed_picks.numbers);
        while (vec::length(&guessed_nums) > 0) {
            let curr_guess = vec::pop_back(&mut guessed_nums);
            if (vec_set::contains(&actual_picks.numbers, &curr_guess)) {
                normal_ball_count = normal_ball_count + 1;
            };
        };

        let special_number_hit = false;
        if (guessed_picks.special_number == actual_picks.special_number) {
            special_number_hit = true;
        };
        // Jackpot got hit
        if (normal_ball_count == lottery.normal_ball_count && special_number_hit) {
            return (0, true)
        };

        let matched_structure = RewardStructure {
            normal_ball_count,
            special_number_hit
        };

        // Locate the prize balance that should be won
        if (table::contains(&lottery.reward_structure_table, matched_structure)) {
            let reward = *table::borrow(&lottery.reward_structure_table, matched_structure);
            return (reward, false)
        };
        return (0, false)
    }

    /// Settlement function for the lottery
    public fun settle_or_continue<T>(
        _store_cap: &LotteryStoreAdminCap,
        store: &mut LotteryStore,
        lottery_id: ID,
        drand_sig: vector<u8>,
        game_round: u64,
        page_size: Option<u64>,
        clock: &Clock,
    ) {
        // Get lottery from the store
        let lottery = borrow_mut_lottery<T>(store, lottery_id);
        assert!(game_round == lottery.current_round, EWrongRound);
        // Assert the game is not already settled
        assert!(!round_is_settled(lottery, game_round), ELotteryNotSettled);

        verify_drand_signature(drand_sig, lottery.current_round);

        let result_rolls = select_numbers(lottery, drand_sig);

        let end_target = 0;
        if (option::is_some(&page_size)) {
            let page = *option::borrow(&page_size);
            end_target = big_queue::length(&lottery.tickets) - page;
        };

        // Settle backwards so indices do not change
        while (big_queue::length(&lottery.tickets) > end_target) {
            let receipt = big_queue::pop_front(&mut lottery.tickets);
            let (prize_amount, is_jackpot) = get_ticket_result(receipt.picks, &result_rolls, lottery);

            // Jackpot case where we don't take coins
            if (is_jackpot) {
                table::add(&mut lottery.jackpot_winners, receipt.original_ticket_id, true);
            } else {
                if (prize_amount > 0) {
                    let balance_won = balance::split(&mut lottery.lottery_prize_pool, prize_amount);
                    table::add(&mut lottery.winning_tickets, receipt.original_ticket_id, balance_won);
                }
            }
        };

        // Only happens if there are no tickets left to process in this round
        if (big_queue::length(&lottery.tickets) == 0) {
            *table::borrow_mut(&mut lottery.rounds_settled, game_round) = true;

            emit(RoundResult<T>{
                round: game_round,
                lottery_id: object::id(lottery),
                results: result_rolls,
                timestamp_drawn: clock::timestamp_ms(clock)
            });
        };
    }

    /// Allow redemptions for a given game round set of tickets
    public fun allow_redemptions_for_round<T>(
        _store_cap: &LotteryStoreAdminCap,
        store: &mut LotteryStore,
        lottery_id: ID,
        game_round: u64,
    ) {
        // Get lottery from the store
        let lottery = borrow_mut_lottery<T>(store, lottery_id);
        
        // Assert that the lottery has been settled by checking if the table exists and round bool is true
        assert!(round_is_settled(lottery, game_round), ELotteryNotSettled);

        if (table::length(&lottery.jackpot_winners) > 0) {
            assert!(balance::value(&lottery.lottery_prize_pool) >= lottery.minimum_jackpot, EMinimumJackpotNotHit);
        };

        *table::borrow_mut(&mut lottery.redemptions_allowed, game_round) = true;
    }

    // Update lottery to the next drawing time
    public fun set_next_round_and_drawing_time<T>(
        store: &mut LotteryStore,
        lottery_id: ID,
        _store_cap: &LotteryStoreAdminCap, 
        next_drawing_time_ms: u64,
        next_round: u64,
    ) {
        // Get lottery from the store
        let lottery = borrow_mut_lottery<T>(store, lottery_id);
        let current_round = lottery.current_round;
        assert!(redemptions_allowed_for_round(lottery, current_round), ELotteryNotSettled);
        assert!(table::length(&lottery.jackpot_winners) == 0, EJackpotHit);

        lottery.drawing_time_ms = next_drawing_time_ms;
        lottery.current_round = next_round;

        table::add(&mut lottery.rounds_settled, next_round, false);
        table::add(&mut lottery.redemptions_allowed, next_round, false);

        emit(RoundStarted<T> {
            round: next_round,
            lottery_id: object::id(lottery),
            next_drawing_time: next_drawing_time_ms
        });
    }


    /// Submit and burn the ticket to redeem the prize or jackpot
    public fun redeem<T>(
        ticket: Ticket,
        store: &mut LotteryStore,
        lottery_id: ID,
        ctx: &mut TxContext,
    ): Option<Coin<T>> {
        // Get lottery from the store
        let lottery = borrow_mut_lottery<T>(store, lottery_id);
        assert!(ticket.lottery_id == object::id(lottery), EWrongLottery);
        assert!(redemptions_allowed_for_round(lottery, ticket.round), ELotteryNotSettled);
        let player = tx_context::sender(ctx);
        let ticket_id = object::id(&ticket);
        let Ticket { 
            id, 
            picks: _, 
            lottery_id:  _, 
            round: _, 
            timestamp_issued: _
        } = ticket;        
        object::delete(id);

        // Jackpot case
        if (table::contains(&lottery.jackpot_winners, ticket_id)) {
            let jackpot_winner_count = table::length(&lottery.jackpot_winners);
            // Pop from the table since we have already claimed the jackpot prize
            table::remove(&mut lottery.jackpot_winners, ticket_id);
            let total_jackpot = balance::value(&lottery.lottery_prize_pool);
            // Split the jackpot multiple ways
            let prize_coin = coin::take(&mut lottery.lottery_prize_pool, total_jackpot / jackpot_winner_count, ctx);
            let amount_won = coin::value(&prize_coin);
            event::emit(RedeemEvent<T> {
                player,
                amount: amount_won
            });
            option::some(prize_coin)
        } else if (table::contains(&lottery.winning_tickets, ticket_id)) {
            // Normal case of ticket
            let prize = table::remove(&mut lottery.winning_tickets, ticket_id);
            let prize_value = balance::value(&prize);
            let prize_coin = coin::take(&mut prize, prize_value, ctx);
            let amount_won = coin::value(&prize_coin);
            balance::destroy_zero(prize);
            event::emit(RedeemEvent<T> {
                player,
                amount: amount_won
            });
            option::some(prize_coin)
        } else {
            event::emit(RedeemEvent<T> {
                player,
                amount: 0
            });
            option::none()
        }
    }

    public fun transfer_optional_coin<T>(
        coin_opt: &mut Option<Coin<T>>,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        if (option::is_some(coin_opt)) {
            let coin = option::extract(coin_opt);
            transfer::public_transfer(coin, sender);
        };
    }

    // --------------- House Accessors ---------------

    public fun lottery_exists<T>(store: &LotteryStore, lottery_id: ID): bool {
        dof::exists_with_type<ID, Lottery<T>>(&store.id, lottery_id)
    }

    public fun lottery_prize_pool<T>(store: &LotteryStore, lottery_id: ID): u64 {
        let lottery = dof::borrow<ID, Lottery<T>>(&store.id, lottery_id);
        balance::value(&lottery.lottery_prize_pool)
    }

    public fun lottery_fees<T>(store: &LotteryStore, lottery_id: ID): u64 {
        let lottery = dof::borrow<ID, Lottery<T>>(&store.id, lottery_id);
        balance::value(&lottery.lottery_fees)
    }

    public fun jackpot_winners<T>(store: &LotteryStore, lottery_id: ID): &Table<ID, bool> {
        let lottery = dof::borrow<ID, Lottery<T>>(&store.id, lottery_id);
        &lottery.jackpot_winners
    }

    // --------------- Helper Function ---------------
    fun borrow_mut_lottery<T>(store: &mut LotteryStore, lottery_id: ID): &mut Lottery<T> {
        assert!(lottery_exists<T>(store, lottery_id), ELotteryNotExists);
        dof::borrow_mut<ID, Lottery<T>>(&mut store.id, lottery_id)
    }

    public fun get_lottery_queue_size<T>(store: &LotteryStore, lottery_id: ID): u64 {
        assert!(lottery_exists<T>(store, lottery_id), ELotteryNotExists);
        let lottery = dof::borrow<ID, Lottery<T>>(&store.id, lottery_id);
        big_queue::length(&lottery.tickets)
    }

    public fun redemptions_allowed_for_round<T>(lottery: &Lottery<T>, round: u64): bool {
        *table::borrow(&lottery.redemptions_allowed, round)
    }

    public fun round_is_settled<T>(lottery: &Lottery<T>, round: u64): bool {
        *table::borrow(&lottery.rounds_settled, round)
    }

    public fun lottery_fees_value<T>(lottery: &Lottery<T>): u64 {
        balance::value(&lottery.lottery_fees)
    }

    // --------------- Game Accessors ---------------


    // --------------- Test Only ---------------

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        let admin = tx_context::sender(ctx);
        let admin_cap = LotteryStoreAdminCap { id: object::new(ctx) };
        transfer::public_transfer(admin_cap, admin);
    }

    #[test_only]
    /// Settlement function for the lottery
    public fun settle_or_continue_for_testing<T>(
        _store_cap: &LotteryStoreAdminCap,
        store: &mut LotteryStore,
        lottery_id: ID,
        drand_sig: vector<u8>,
        game_round: u64,
        page_size: Option<u64>,
        clock: &Clock,
    ) {
        // Get lottery from the store
        let lottery = borrow_mut_lottery<T>(store, lottery_id);
        assert!(game_round == lottery.current_round, EWrongRound);
        // Assert the game is not already settled
        assert!(!round_is_settled(lottery, game_round), ELotteryNotSettled);

        // verify_drand_signature(drand_sig, lottery.current_round);

        let result_rolls = select_numbers(lottery, drand_sig);

        let end_target = 0;
        if (option::is_some(&page_size)) {
            let page = *option::borrow(&page_size);
            end_target = big_queue::length(&lottery.tickets) - page;
        };

        // Settle backwards so indices do not change
        while (big_queue::length(&lottery.tickets) > end_target) {
            let receipt = big_queue::pop_front(&mut lottery.tickets);
            let (prize_amount, is_jackpot) = get_ticket_result(receipt.picks, &result_rolls, lottery);

            // Jackpot case where we don't take coins
            if (is_jackpot) {
                table::add(&mut lottery.jackpot_winners, receipt.original_ticket_id, true);
            } else {
                if (prize_amount > 0) {
                    let balance_won = balance::split(&mut lottery.lottery_prize_pool, prize_amount);
                    table::add(&mut lottery.winning_tickets, receipt.original_ticket_id, balance_won);
                }
            }
        };

        // Only happens if there are no tickets left to process in this round
        if (big_queue::length(&lottery.tickets) == 0) {
            *table::borrow_mut(&mut lottery.rounds_settled, game_round) = true;

            emit(RoundResult<T>{
                round: game_round,
                lottery_id: object::id(lottery),
                results: result_rolls,
                timestamp_drawn: clock::timestamp_ms(clock)
            });
        };
    }

    #[test_only]
    /// Test reward structure for 2 balls and 1 special ball
    public fun create_test_reward_struct(): vector<RewardStructureInput> {
        let payout_vector = vector<RewardStructureInput>[];
        let first_prize = RewardStructureInput {
            normal_ball_count: 0,
            special_number_hit: true,
            balance_paid: 1
        };
        let sec_prize = RewardStructureInput {
            normal_ball_count: 1,
            special_number_hit: true,
            balance_paid: 2
        };
        let third_prize = RewardStructureInput {
            normal_ball_count: 1,
            special_number_hit: false,
            balance_paid: 1
        };
        let fourth_prize = RewardStructureInput {
            normal_ball_count: 2,
            special_number_hit: false,
            balance_paid: 5
        };
        vec::push_back(&mut payout_vector, first_prize);
        vec::push_back(&mut payout_vector, sec_prize);
        vec::push_back(&mut payout_vector, third_prize);
        vec::push_back(&mut payout_vector, fourth_prize);
        payout_vector
    }

}