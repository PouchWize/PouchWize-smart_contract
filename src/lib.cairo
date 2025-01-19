use starknet::ContractAddress;
use core::array::SpanTrait;
use core::traits::Into;
use core::num::traits::zero::Zero;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
mod PouchwizeToken;

#[starknet::interface]
pub trait IPouchwize<TContractState> {
    // Core lending operations
    fn deposit_collateral(ref self: TContractState, token: ContractAddress, amount: u256);
    fn withdraw_collateral(ref self: TContractState, token: ContractAddress, amount: u256);
    fn request_loan_from_listing(ref self: TContractState, listing_id: u128, amount: u256) -> u128;
    fn repay_loan(ref self: TContractState, loan_id: u128, amount: u256) -> bool;

    // Loan listing management
    fn create_loan_listing(ref self: TContractState, amount: u256, min_amount: u256, max_amount: u256, interest: u16, token: ContractAddress) -> u128;
    fn cancel_loan_listing(ref self: TContractState, listing_id: u128) -> bool;
    fn cancel_loan_request_loan_from_listing(ref self: TContractState, loan_id: u128) -> bool;

    // Risk management
    fn liquidate(ref self: TContractState, loan_id: u128) -> bool;
    fn check_and_liquidate_loans(ref self: TContractState, loan_ids: Array<u128>) -> Array<bool>;

    // Loan status views
    fn get_loan_listing(self: @TContractState, listing_id: u128) -> Pouchwize::LoanListing;
    fn get_loan_details(self: @TContractState, loan_id: u128) -> (u256, u256, u256, u64);
    fn get_loan_health(self: @TContractState, loan_id: u128) -> bool;
    fn get_loan_health_ratio(self: @TContractState, loan_id: u128) -> u16;
    fn get_interest_accrued(self: @TContractState, loan_id: u128) -> u256;

    // User status views
    fn get_user_loan_listings(self: @TContractState, user: ContractAddress) -> Span<u128>;
    fn get_user_active_loans(self: @TContractState, user: ContractAddress) -> Span<u128>;
    fn get_user_health_status(self: @TContractState, user: ContractAddress) -> u8;
    fn get_borrowing_capacity(self: @TContractState, user: ContractAddress, token: ContractAddress) -> u256;

    // Collateral views
    fn get_collateral_balance(self: @TContractState, user: ContractAddress, token: ContractAddress) -> u256;
    fn get_collateral_value(self: @TContractState, token: ContractAddress, amount: u256) -> u256;
    fn get_total_collateral_value(self: @TContractState, user: ContractAddress) -> u256;

    // Protocol metrics
    fn get_total_loans(self: @TContractState) -> u128;
    fn get_total_listings(self: @TContractState) -> u128;
    fn get_available_listings(self: @TContractState) -> Span<u128>;
    fn get_listing_utilization(self: @TContractState, listing_id: u128) -> u256;
    fn get_liquidatable_loans(self: @TContractState) -> Span<u128>;
    fn get_liquidation_bonus(self: @TContractState, loan_id: u128) -> u256;

    // Token Distribution
    fn distribute_test_tokens(ref self: TContractState, recipient: ContractAddress, amount: u256);

}

#[starknet::interface]
pub trait ISwapRouter<TContractState> {
    fn swap_exact_tokens_for_tokens(
        ref self: TContractState, 
        amount_in: u256,
        amount_out_min: u256,
        path: Array<ContractAddress>,
        to: ContractAddress,
        deadline: u64
    ) -> Array<u256>;
}


#[starknet::contract]
pub mod Pouchwize {
    use super::*;
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};
    use core::starknet::storage::{
        StoragePointerReadAccess,
        StoragePointerWriteAccess,
        StorageMapReadAccess,
        StorageMapWriteAccess,
        Map,
    };
    use starknet::syscalls::{deploy_syscall};

    const COLLATERAL_RATIO: u16 = 125; // Collateral ratio of 125% (100/0.80) for 80% borrowing power
    const LIQUIDATION_THRESHOLD: u16 = 115;
    const LIQUIDATION_BONUS: u16 = 10;
    const INITIAL_LENDING_SUPPLY: u256 = 1000000000000000000000000; // 1 million tokens
    const INITIAL_COLLATERAL_SUPPLY: u256 = 1000000000000000000000000; // 1 million tokens
    const INITIAL_EXCHANGE_RATE: u256 = 800000000000000000; // Collateral ratio of 125% (100/0.80) for 80% borrowing power
    const CLASS_HASH: felt252 = 0x00b04520f6d2f39687102e8f2ae7bc2d6de54c00e09d91f62afc68d4efb8e7b3;


    #[storage]
    pub struct Storage {
        admin: ContractAddress,
        loans: Map::<u128, Loan>,
        loan_count: u128,
        collateral_balances: Map::<(ContractAddress, ContractAddress), u256>,
        lending_token: ContractAddress,
        collateral_token: ContractAddress,
        initialized: bool,
        loan_listings: Map::<u128, LoanListing>,
        listing_count: u128,
        swap_router: ContractAddress,
        interest_accrued: Map::<u128, u256>,
        liquidation_locks: Map::<u128, bool>,
        lending_token_supply: u256,
        collateral_token_supply: u256,
        exchange_rate: u256,  // Rate between collateral and lending tokens (fixed point with 18 decimals)

    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        LoanListingCreated: LoanListingCreated,
        LoanCancelled: LoanCancelled,
        CollateralDeposited: CollateralDeposited,
        CollateralWithdrawn: CollateralWithdrawn,
        LoanCreated: LoanCreated,
        LoanRepaid: LoanRepaid,
        LoanLiquidated: LoanLiquidated,
        LoanHealthCompromised: LoanHealthCompromised 
    }

    #[derive(Drop, starknet::Event)]
    pub struct CollateralDeposited {
        user: ContractAddress,
        token: ContractAddress,
        amount: u256
    }

    #[derive(Drop, starknet::Event)]
    pub struct CollateralWithdrawn {
        user: ContractAddress,
        token: ContractAddress,
        amount: u256
    }

    #[derive(Drop, starknet::Event)]
    pub struct LoanCreated {
        loan_id: u128,
        borrower: ContractAddress,
        amount: u256,
        collateral: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    pub struct LoanRepaid {
        loan_id: u128,
        amount: u256
    }

    #[derive(Drop, starknet::Event)]
    pub struct LoanLiquidated {
        loan_id: u128,
        liquidator: ContractAddress,
        collateral_amount: u256
    }

    #[derive(Drop, starknet::Event)]
    pub struct LoanHealthCompromised {
        loan_id: u128,
        borrower: ContractAddress,
        current_collateral_value: u256,
        required_collateral_value: u256
    }

    #[derive(Drop, starknet::Event)]
    pub struct LoanListingCreated {
        listing_id: u128,
        author: ContractAddress,
        amount: u256,
        interest: u16
    }

    #[derive(Drop, starknet::Event)]
    pub struct InterestAccrued {
        loan_id: u128,
        amount: u256,
        timestamp: u64
    }

    #[derive(Drop, starknet::Event)]
    pub struct LoanCancelled {
        loan_id: u128
    }
    

    #[derive(Drop, Copy, Serde, starknet::Store)]
    pub struct Loan {
        borrower: ContractAddress,
        amount: u256,
        collateral: ContractAddress,
        active: bool,
        timestamp: u64,
        listing_id: u128
    }

    #[derive(Drop, Copy, Serde, starknet::Store)]
    pub struct LoanListing {
        author: ContractAddress,
        amount: u256,
        min_amount: u256, 
        max_amount: u256,
        interest: u16,
        return_date: u64,
        token_address: ContractAddress,
        status: u8
    }

    #[derive(Drop, Copy, Serde, starknet::Store)]
    pub struct CollateralInfo {
        token: ContractAddress,
        amount: u256,
        locked: bool
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        assert(!self.initialized.read(), 'Already initialized');
        
        // Set Sepolia ETH as lending token and STRK as collateral token
        self.lending_token.write(0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7.try_into().unwrap());
        self.collateral_token.write(0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d.try_into().unwrap());
        
        // Set initial exchange rate
        self.exchange_rate.write(INITIAL_EXCHANGE_RATE);
        self.initialized.write(true);
    }

    


    #[generate_trait]
    pub impl SwapOperations of SwapOperationsTrait {
        fn execute_swap(
            ref self: ContractState,
            token_in: ContractAddress,
            token_out: ContractAddress,
            amount_in: u256,
            min_amount_out: u256
        ) -> u256 {
            let router = ISwapRouterDispatcher { contract_address: self.swap_router.read() };
            let mut path = ArrayTrait::new();
            path.append(token_in);
            path.append(token_out);
            
            let deadline = get_block_timestamp() + 300;
            let amounts = router.swap_exact_tokens_for_tokens(
                amount_in,
                min_amount_out,
                path,
                get_contract_address(),
                deadline
            );
            
            // Get last element correctly using span
            let amounts_span = amounts.span();
            *amounts_span.at(amounts_span.len() - 1)
        }
    }

    #[generate_trait]
    impl TokenManagement of TokenManagementTrait {
        fn deploy_tokens(
            ref self: ContractState,
            lending_name: felt252,
            lending_symbol: felt252,
            collateral_name: felt252,
            collateral_symbol: felt252
        ) {
            let contract_address = get_contract_address();
            
            // Deploy lending token
            let lending_token = self._deploy_single_token(
                lending_name,
                lending_symbol,
                INITIAL_LENDING_SUPPLY,
                contract_address
            );
            self.lending_token.write(lending_token);
            self.lending_token_supply.write(INITIAL_LENDING_SUPPLY);

            // Deploy collateral token
            let collateral_token = self._deploy_single_token(
                collateral_name,
                collateral_symbol,
                INITIAL_COLLATERAL_SUPPLY,
                contract_address
            );
            self.collateral_token.write(collateral_token);
            self.collateral_token_supply.write(INITIAL_COLLATERAL_SUPPLY);

            // Set initial exchange rate
            self.exchange_rate.write(INITIAL_EXCHANGE_RATE);
        }

        fn _deploy_single_token(
            self: @ContractState,
            name: felt252,
            symbol: felt252,
            supply: u256,
            recipient: ContractAddress
        ) -> ContractAddress {
            let mut calldata = ArrayTrait::new();
            calldata.append(name);
            calldata.append(symbol);
            calldata.append(supply.low.into());
            calldata.append(supply.high.into());
            calldata.append(recipient.into());
        
            let (deployed_address, _) = deploy_syscall(
                CLASS_HASH.try_into().unwrap(),
                0,
                calldata.span(),
                false
            ).unwrap();
        
            deployed_address
        }
        
    }

    #[generate_trait]
    impl TokenExchange of TokenExchangeTrait {
        fn get_collateral_to_lending_value(
            self: @ContractState,
            collateral_amount: u256
        ) -> u256 {
            let rate = self.exchange_rate.read();
            (collateral_amount * rate) / 1000000000000000000 // Adjust for 18 decimals
        }

        fn get_lending_to_collateral_value(
            self: @ContractState,
            lending_amount: u256
        ) -> u256 {
            let rate = self.exchange_rate.read();
            (lending_amount * 1000000000000000000) / rate // Adjust for 18 decimals
        }
    }


    #[generate_trait]
    pub impl SafeERC20Transfer of SafeERC20TransferTrait {
        fn safe_transfer(
            self: @ContractState,
            token: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let initial_balance = token_dispatcher.balance_of(recipient);
            let success = token_dispatcher.transfer(recipient, amount);
            
            if !success {
                let final_balance = token_dispatcher.balance_of(recipient);
                return final_balance - initial_balance == amount;
            }
            success
        }
    }

    #[generate_trait]
    impl TokenDistribution of TokenDistributionTrait {
        fn distribute_test_tokens(
            ref self: ContractState,
            recipient: ContractAddress,
            amount: u256
        ) {
            let lending_token = IERC20Dispatcher { contract_address: self.lending_token.read() };
            let collateral_token = IERC20Dispatcher { contract_address: self.collateral_token.read() };
            
            lending_token.transfer(recipient, amount);
            collateral_token.transfer(recipient, amount);
        }
    }


    #[generate_trait]
    impl CollateralManagement of CollateralManagementTrait {
        fn get_minimum_required_collateral(self: @ContractState, user: ContractAddress) -> u256 {
            let active_loans = self.get_user_active_loans(user);
            let mut total_required: u256 = 0;
            
            let mut i = 0;
            loop {
                if i >= active_loans.len() {
                    break;
                }
                let loan_id = *active_loans.at(i);
                let loan = self.loans.read(loan_id);
                total_required += (loan.amount * COLLATERAL_RATIO.into()) / 100;
                i += 1;
            };
            
            total_required
        }
    }



    #[abi(embed_v0)]
    impl Pouchwize of super::IPouchwize<ContractState> {
        // Core lending operations
        fn deposit_collateral(ref self: ContractState, token: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            assert(token == self.collateral_token.read(), 'Invalid collateral token');
            assert(amount > 0, 'Amount must be positive');
            
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            let success = token_dispatcher.transfer_from(caller, get_contract_address(), amount);
            assert(success, 'Transfer failed');
            
            let current_balance = self.collateral_balances.read((caller, token));
            self.collateral_balances.write((caller, token), current_balance + amount);
            
            self.emit(Event::CollateralDeposited(CollateralDeposited { 
                user: caller, 
                token, 
                amount 
            }));
        }
    
        fn withdraw_collateral(ref self: ContractState, token: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            assert(token == self.collateral_token.read(), 'Invalid collateral token');
            
            let current_balance = self.collateral_balances.read((caller, token));
            assert(current_balance >= amount, 'Insufficient balance');
            
            // Check if withdrawal would compromise loan health
            let lending_value = self.get_collateral_to_lending_value(amount);
            assert(
                self.get_total_collateral_value(caller) - lending_value >= 
                self.get_minimum_required_collateral(caller),
                'Would breach collateral ratio'
            );
            
            self.collateral_balances.write((caller, token), current_balance - amount);
            let success = self.safe_transfer(token, caller, amount);
            assert(success, 'Transfer failed');
            
            self.emit(Event::CollateralWithdrawn(CollateralWithdrawn { 
                user: caller, 
                token, 
                amount 
            }));
        }

        fn request_loan_from_listing(ref self: ContractState, listing_id: u128, amount: u256) -> u128 {
            let caller = get_caller_address();
            let listing = self.loan_listings.read(listing_id);
            assert(listing.status == 0, 'Listing not available');
            assert(amount >= listing.min_amount && amount <= listing.max_amount, 'Invalid amount');
            
            let loan_id = self.loan_count.read() + 1;
            self.loan_count.write(loan_id);
            
            let loan = Loan {
                borrower: caller,
                amount,
                collateral: listing.token_address,
                active: true,
                timestamp: get_block_timestamp(),
                listing_id
            };
            
            self.loans.write(loan_id, loan);
            self.emit(LoanCreated { 
                loan_id, 
                borrower: caller, 
                amount, 
                collateral: listing.token_address 
            });
            
            loan_id
        }
        fn repay_loan(ref self: ContractState, loan_id: u128, amount: u256) -> bool {
            let loan = self.loans.read(loan_id);
            assert(loan.active, 'Loan not active');
            let caller = get_caller_address();
            assert(caller == loan.borrower, 'Not loan owner');
            
            let token_dispatcher = IERC20Dispatcher { contract_address: self.lending_token.read() };
            let success = token_dispatcher.transfer_from(caller, get_contract_address(), amount);
            assert(success, 'Transfer failed');
            
            if amount >= loan.amount {
                let mut loan = loan;
                loan.active = false;
                self.loans.write(loan_id, loan);
            }
            
            self.emit(Event::LoanRepaid(LoanRepaid { loan_id, amount }));
            true
        }

        // Loan listing management
        fn create_loan_listing(
            ref self: ContractState, 
            amount: u256, 
            min_amount: u256, 
            max_amount: u256, 
            interest: u16, 
            token: ContractAddress
        ) -> u128 {
            assert(amount > 0, 'Invalid amount');
            assert(min_amount <= max_amount, 'Invalid amount range');
            assert(!token.is_zero(), 'Invalid token');
            
            let listing_id = self.listing_count.read() + 1;
            self.listing_count.write(listing_id);
            
            let listing = LoanListing {
                author: get_caller_address(),
                amount,
                min_amount,
                max_amount,
                interest,
                return_date: get_block_timestamp() + 86400, // 24 hours
                token_address: token,
                status: 0
            };
            
            self.loan_listings.write(listing_id, listing);
            self.emit(Event::LoanListingCreated(LoanListingCreated { 
                listing_id,
                author: get_caller_address(),
                amount,
                interest
            }));
            
            listing_id
        }

        fn cancel_loan_listing(ref self: ContractState, listing_id: u128) -> bool {
            let mut listing = self.loan_listings.read(listing_id);
            assert(listing.author == get_caller_address(), 'Not listing owner');
            assert(listing.status == 0, 'Invalid listing status');
            
            listing.status = 2; // Cancelled
            self.loan_listings.write(listing_id, listing);
            self.emit(Event::LoanCancelled(LoanCancelled { loan_id: listing_id }));
            true
        }

        fn cancel_loan_request_loan_from_listing(ref self: ContractState, loan_id: u128) -> bool {
            let mut loan = self.loans.read(loan_id);
            assert(loan.borrower == get_caller_address(), 'Not loan owner');
            assert(loan.active, 'Loan not active');
            
            loan.active = false;
            self.loans.write(loan_id, loan);
            self.emit(Event::LoanCancelled(LoanCancelled { loan_id }));
            true
        }

        // Risk management
        fn liquidate(ref self: ContractState, loan_id: u128) -> bool {
            let loan = self.loans.read(loan_id);
            assert(loan.active, 'Loan not active');
            assert(!self.liquidation_locks.read(loan_id), 'Liquidation locked');
            
            let health_ratio = self.get_loan_health_ratio(loan_id);
            assert(health_ratio < LIQUIDATION_THRESHOLD, 'Healthy loan');
            
            self.liquidation_locks.write(loan_id, true);
            let collateral_amount = self.get_collateral_balance(loan.borrower, loan.collateral);
            let bonus = self.get_liquidation_bonus(loan_id);
            
            // Transfer collateral to liquidator
            let success = self.safe_transfer(loan.collateral, get_caller_address(), collateral_amount + bonus);
            assert(success, 'Transfer failed');
            
            let mut loan = loan;
            loan.active = false;
            self.loans.write(loan_id, loan);
            
            self.emit(Event::LoanLiquidated(LoanLiquidated {
                loan_id,
                liquidator: get_caller_address(),
                collateral_amount
            }));
            
            true
        }

        fn check_and_liquidate_loans(ref self: ContractState, loan_ids: Array<u128>) -> Array<bool> {
            let mut results = ArrayTrait::new();
            let mut i = 0;
            
            loop {
                if i >= loan_ids.len() {
                    break;
                }
                
                let loan_id = *loan_ids.at(i);
                if self.get_loan_health_ratio(loan_id) < LIQUIDATION_THRESHOLD {
                    results.append(self.liquidate(loan_id));
                } else {
                    results.append(false);
                }
                
                i += 1;
            };
            
            results
        }

        fn distribute_test_tokens(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            TokenDistributionTrait::distribute_test_tokens(ref self, recipient, amount)
        }

        // View functions implementation...
        fn get_loan_listing(self: @ContractState, listing_id: u128) -> LoanListing {
            self.loan_listings.read(listing_id)
        }

        fn get_loan_details(self: @ContractState, loan_id: u128) -> (u256, u256, u256, u64) {
            let loan = self.loans.read(loan_id);
            (loan.amount, 
            self.get_collateral_value(loan.collateral, loan.amount),
            self.get_interest_accrued(loan_id),
            loan.timestamp)
        }

        fn get_loan_health(self: @ContractState, loan_id: u128) -> bool {
            self.get_loan_health_ratio(loan_id) >= LIQUIDATION_THRESHOLD
        }

        fn get_loan_health_ratio(self: @ContractState, loan_id: u128) -> u16 {
            let loan = self.loans.read(loan_id);
            let collateral_value = self.get_collateral_value(loan.collateral, loan.amount);
            let loan_value = loan.amount + self.get_interest_accrued(loan_id);
            
            if loan_value == 0 {
                return 0;
            }
            
            ((collateral_value * 100) / loan_value).try_into().unwrap()
        }

        fn get_interest_accrued(self: @ContractState, loan_id: u128) -> u256 {
            self.interest_accrued.read(loan_id)
        }

        // User status views
        fn get_user_loan_listings(self: @ContractState, user: ContractAddress) -> Span<u128> {
            let mut listings = ArrayTrait::new();
            let total_listings = self.listing_count.read();
            
            let mut i: u128 = 1;
            loop {
                if i > total_listings {
                    break;
                }
                let listing = self.loan_listings.read(i);
                if listing.author == user && listing.status == 0 {
                    listings.append(i);
                }
                i += 1;
            };
            
            listings.span()
        }
        
        fn get_user_active_loans(self: @ContractState, user: ContractAddress) -> Span<u128> {
            let mut active_loans = ArrayTrait::new();
            let total_loans = self.loan_count.read();
            
            let mut i: u128 = 1;
            loop {
                if i > total_loans {
                    break;
                }
                let loan = self.loans.read(i);
                if loan.borrower == user && loan.active {
                    active_loans.append(i);
                }
                i += 1;
            };
            
            active_loans.span()
        }
        
        fn get_user_health_status(self: @ContractState, user: ContractAddress) -> u8 {
            let active_loans = self.get_user_active_loans(user);
            let mut lowest_health: u16 = 1000; // Start with high value
            
            let mut i = 0;
            loop {
                if i >= active_loans.len() {
                    break;
                }
                let loan_id = *active_loans.at(i);
                let health_ratio = self.get_loan_health_ratio(loan_id);
                if health_ratio < lowest_health {
                    lowest_health = health_ratio;
                }
                i += 1;
            };
            
            if lowest_health >= COLLATERAL_RATIO {
                2 // Healthy
            } else if lowest_health >= LIQUIDATION_THRESHOLD {
                1 // Warning
            } else {
                0 // Liquidatable
            }
        }
        
        fn get_borrowing_capacity(self: @ContractState, user: ContractAddress, token: ContractAddress) -> u256 {
            let collateral_balance = self.get_collateral_balance(user, token);
            let collateral_value = self.get_collateral_value(token, collateral_balance);
            (collateral_value * 80) / 100 // 80% of collateral value
        }
        
        fn get_collateral_value(self: @ContractState, token: ContractAddress, amount: u256) -> u256 {
            self.get_collateral_to_lending_value(amount)
        }
        
        fn get_total_collateral_value(self: @ContractState, user: ContractAddress) -> u256 {
            let collateral_token = self.collateral_token.read();
            let collateral_balance = self.get_collateral_balance(user, collateral_token);
            self.get_collateral_value(collateral_token, collateral_balance)
        }
        
        fn get_available_listings(self: @ContractState) -> Span<u128> {
            let mut available = ArrayTrait::new();
            let total_listings = self.listing_count.read();
            
            let mut i: u128 = 1;
            loop {
                if i > total_listings {
                    break;
                }
                let listing = self.loan_listings.read(i);
                if listing.status == 0 {
                    available.append(i);
                }
                i += 1;
            };
            
            available.span()
        }
        
        fn get_listing_utilization(self: @ContractState, listing_id: u128) -> u256 {
            let listing = self.loan_listings.read(listing_id);
            let total_loans = self.loan_count.read();
            let mut utilized_amount: u256 = 0;
            
            let mut i: u128 = 1;
            loop {
                if i > total_loans {
                    break;
                }
                let loan = self.loans.read(i);
                if loan.listing_id == listing_id && loan.active {
                    utilized_amount += loan.amount;
                }
                i += 1;
            };
            
            (utilized_amount * 100) / listing.amount
        }
        
        fn get_liquidatable_loans(self: @ContractState) -> Span<u128> {
            let mut liquidatable = ArrayTrait::new();
            let total_loans = self.loan_count.read();
            
            let mut i: u128 = 1;
            loop {
                if i > total_loans {
                    break;
                }
                let loan = self.loans.read(i);
                if loan.active && self.get_loan_health_ratio(i) < LIQUIDATION_THRESHOLD {
                    liquidatable.append(i);
                }
                i += 1;
            };
            
            liquidatable.span()
        }

        fn get_collateral_balance(self: @ContractState, user: ContractAddress, token: ContractAddress) -> u256 {
            self.collateral_balances.read((user, token))
        }
        
        fn get_total_loans(self: @ContractState) -> u128 {
            self.loan_count.read()
        }
        
        fn get_total_listings(self: @ContractState) -> u128 {
            self.listing_count.read()
        }
        
        fn get_liquidation_bonus(self: @ContractState, loan_id: u128) -> u256 {
            let loan = self.loans.read(loan_id);
            let collateral_value = self.get_collateral_value(loan.collateral, loan.amount);
            (collateral_value * LIQUIDATION_BONUS.into()) / 100
        }
        
    }

}
