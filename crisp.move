/// CRISP -- a mechanism to sell NFTs continuously at a targeted rate over time
/// @TODO: Math
module nfts::crisp {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::balance::Balance;
    use movemate::math;

    #[test_only]
    use sui::test_scenario;

    struct CRISP has key {
        id: UID,

        /// block on which last purchase occured
        lastPurchaseBlock: u64,

        /// block on which we start decaying price
        priceDecayStartBlock: u64,

        /// last minted token ID
        curTokenId: u128,

        /// Starting EMS, before time decay
        nextPurchaseStartingEMS: u64,

        /// Starting price for next purchase, before time decay
        nextPurchaseStartingPrice: u64,

        /// EMS target
        targetEMS: u64,

        /// controls decay of sales in EMS
        saleHalflife: u64,

        /// controls upward price movement.
        priceSpeed: u64,

        /// controls price decay
        priceHalflife: u64,
    }

    public fun create(
        targetBlocksPerSale: u64, saleHalflife: u64, priceSpeed: u64, priceHalflife: u64, startingPrice: u64, ctx: &mut TxContext
    ) {
        let crisp = CRISP {
            id: object::new(ctx),
            lastPurchaseBlock: tx_context::epoch(ctx),
            priceDecayStartBlock = tx_context::epoch(ctx),
            curTokenId = 0,
            nextPurchaseStartingEMS = targetBlocksPerSale / saleHalflife;  // EMS target
            nextPurchaseStartingPrice = startingPrice; // Starting EMS, before time decay

            saleHalflife = saleHalflife; // controls decay of sales in EMS

            priceSpeed = priceSpeed; // controls upward price movement

            priceHalflife = priceHalflife; // controls price decay

        };

        share_object(crisp);
    }

    ///@notice get current EMS based on block number
    public fun get_current_ems(crisp: &CRISP, ctx: &mut TxContext): u64 {
        let blockInterval = tx_context::epoch(ctx) - crisp.lastPurchaseBlock;
        let weightOnPrev = math::exp(2, (-blockInterval / crisp.saleHalflife));
        let result = crisp.nextPurchaseStartingEMS * weightOnPrev;

        return result;
    }

    ///@notice get quote for purchasing in current block, decaying price as needed. Returns 59.18-decimal fixed-point
    public fun get_quote(crisp: &CRISP, ctx: &mut TxContext): u64 {
        let result: u64;

        if (tx_context::epoch(ctx) <= crisp.priceDecayStartBlock) {
            result = crisp.nextPurchaseStartingPrice;
        }
        //decay price if we are past decay start block
        else {
            let decayInterval = tx_context::epoch(ctx) - crisp.priceDecayStartBlock;
            let decay = e_exp(-decayInterval / crisp.priceHalflife);
            result = crisp.nextPurchaseStartingPrice * decay;
        }

        return result;
    }

    ///@notice Get starting price for next purchase before time decay. Returns 59.18-decimal fixed-point
    public fun get_next_starting_price(crisp: &CRISP, lastPurchasePrice: u64): u64 {
        let mismatchRatio = crisp.nextPurchaseStartingEMS / crisp.targetEMS;

        let result: u64;

        if (mismatchRatio > 1) {
            result = lastPurchasePrice * (1 + mismatchRatio * crisp.priceSpeed);
        } else {
            result = lastPurchasePrice;
        }

        return result;
    }

    ///@notice Find block in which time based price decay should start
    public fun get_price_decay_start_block(crisp: &CRISP): u64 {
        let mismatchRatio = crisp.nextPurchaseStartingEMS / crisp.targetEMS;
        //if mismatch ratio above 1, decay should start in future
        let result: u64;

        if (mismatchRatio > 1) {
            result = tx_context::epoch(ctx) + crisp.saleHalflife * mismatchRatio.log2();
        }
        //else decay should start at the current block
        else {
            result = tx_context::epoch(ctx);
        }

        return result;
    }

    ///@notice Pay current price and mint new NFT
    public entry fun mint(crisp: &mut CRISP, ctx: &mut TxContext) {
        let price = get_quote(crisp, ctx);

        if (tx_context::value(ctx) < price) {
            revert InsufficientPayment();
        }

        _mint(tx_context::sender(ctx), crisp.curTokenId++);

        //update state
        crisp.nextPurchaseStartingEMS = get_current_ems(crisp, ctx) + 1;
        crisp.nextPurchaseStartingPrice = get_next_starting_price(crisp, price);
        crisp.priceDecayStartBlock = get_price_decay_start_block(crisp);
        crisp.lastPurchaseBlock = tx_context::epoch(ctx);

        //hook for caller to do something with the received ETH based on the price paid
        after_mint(price, ctx);

        //issue refund
        let refund = tx_context::value(ctx) - price;
        let sent = tx_context::send(tx_context::sender(ctx), refund);

        if (!sent) {
            revert FailedToSendEther();
        }
    }

    public fun after_mint(price: u64, ctx: &mut TxContext) {

    }

    /// @dev Calculates the natural exponentiation of a number: ie exp(x) = e^x
    /// @TODO: movemate PR
    public fun e_exp(x: u64, precision: u64): u64 {
        let result = 1;
        let factorial = 1;
        let x_power = 1;
        let i = 0;

        while (i < precision) {
            factorial = factorial * (i + 1);
            x_power = x_power * x;
            result = result + x_power / factorial;
            i = i + 1;
        };

        result
    }

    #[test]
    fun test_end_to_end() {
        let scenario = &mut test_scenario::begin();
        let ctx = test_scenario::ctx(scenario);

        let coin = coin::mint_for_testing<SUI>(1000, ctx);

        let crisp = create(
            3,
            1000,
            0.5,
            0.5,
            ctx
        );

        test_scenario::next_epoch(scenario);
        test_scenario::next_epoch(scenario);

        mint(&mut crisp, ctx);

        test_scenario::end(scenario);
    }
}