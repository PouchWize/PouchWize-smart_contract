use starknet::ContractAddress;

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer_from(ref self: TContractState, from: ContractAddress, to: ContractAddress, amount: u256) -> bool;
    fn decimals(self: @TContractState) -> u8;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, to: ContractAddress, amount: u256) -> bool;

}

#[starknet::interface]
trait IPriceFeed<TContractState> {
    fn get_latest_price(self: @TContractState) -> u256;
}

#[starknet::interface]
trait IRouter<TContractState> {
    fn swap_exact_tokens_for_tokens(
        ref self: TContractState,
        amount_in: u256,
        amount_out_min: u256,
        path: Array<ContractAddress>,
        to: ContractAddress,
        deadline: u256
    ) -> u256;
}

#[starknet::interface]
trait ILendingProtocol<TContractState> {
    fn deposit_collateral(ref self: TContractState, token_address: ContractAddress, amount: u256);
    fn create_lending_request(ref self: TContractState, amount: u128, interest: u16, return_date: u256, loan_currency: ContractAddress);
    fn service_request(ref self: TContractState, request_id: u128, token_address: ContractAddress);
    fn repay_loan(ref self: TContractState, request_id: u128, amount: u256);
    fn liquidate_request(ref self: TContractState, request_id: u128);
    fn get_usd_value(self: @TContractState, token: ContractAddress, amount: u256) -> u256;
    fn get_token_decimal(self: @TContractState, token: ContractAddress) -> u8;
    fn calculate_health_factor(self: @TContractState, user: ContractAddress, additional_borrow: u256) -> u256;
    fn get_account_info(self: @TContractState, user: ContractAddress) -> (u256, u256);
    fn get_user_collateral_tokens(self: @TContractState, user: ContractAddress) -> Array<ContractAddress>;
}

#[starknet::contract]
    mod LendingProtocol {
        // Core imports
    use core::num::traits::Zero;
    use core::option::OptionTrait;
    use core::traits::{Into, TryInto};
    // Starknet imports
    use starknet::{
        ContractAddress,
        contract_address_const,
        get_caller_address,
        get_block_timestamp,
        get_contract_address
    };

    // Storage imports
    use core::starknet::storage::{
        StoragePointerReadAccess,
        StoragePointerWriteAccess,
        StorageMapReadAccess,
        StorageMapWriteAccess,
        Map,
    };
    // Interface imports
    use super::ILendingProtocol;
    use super::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::{IPriceFeedDispatcher, IPriceFeedDispatcherTrait};
    use super::{IRouterDispatcher, IRouterDispatcherTrait};

    // Constants
    const COLLATERALIZATION_RATIO: u16 = 80;
    const LIQUIDATION_THRESHOLD: u16 = 85;
    const PRECISION: u256 = 1000000;
    const ONE_DAY: u256 = 86400;

    #[storage]
    struct Storage {
        collateral_tokens: Map::<ContractAddress, bool>,
        collateral_balances: Map::<(ContractAddress, ContractAddress), u256>,
        available_balances: Map::<(ContractAddress, ContractAddress), u256>,
        requests: Map::<u128, LendingRequest>,
        next_request_id: u128,
        native_token: ContractAddress,
        price_feeds: Map::<ContractAddress, ContractAddress>,
        user_total_borrows: Map::<ContractAddress, u256>,
        bot_address: ContractAddress,
        router: ContractAddress,
        weth: ContractAddress,
        lending_pools: Map<u128, LendingPool>,
        next_pool_id: u128,
        pool_borrowers: Map<u128, Array<ContractAddress>>,
        user_basenames: Map<ContractAddress, felt252>
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct LendingRequest {
        id: u128,
        borrower: ContractAddress,
        amount: u256,
        interest: u16,
        return_date: u256,
        loan_currency: ContractAddress,
        total_repayment: u256,
        lender: ContractAddress,
        status: RequestStatus,
        collateral_tokens: Array<ContractAddress>
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct LendingPool {
        id: u128,
        lender: ContractAddress,
        total_size: u256,
        interest_rate: u16,
        duration: u256,
        available_amount: u256,
        borrower_allocations: Map<ContractAddress, u256>
    }


    #[derive(Drop, Serde, PartialEq, starknet::Store)]
    #[allow(starknet::store_no_default_variant)]
    enum RequestStatus {
        OPEN,
        SERVICED,
        CLOSED,
        LIQUIDATED
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        CollateralDeposited: CollateralDeposited,
        RequestCreated: RequestCreated,
        RequestServiced: RequestServiced,
        LoanRepayment: LoanRepayment,
        RequestLiquidated: RequestLiquidated
    }

    #[derive(Drop, starknet::Event)]
    struct CollateralDeposited {
        user: ContractAddress,
        token: ContractAddress,
        amount: u256
    }

    #[derive(Drop, starknet::Event)]
    struct RequestCreated {
        borrower: ContractAddress,
        request_id: u128,
        amount: u256,
        interest: u16
    }

    #[derive(Drop, starknet::Event)]
    struct RequestServiced {
        request_id: u128,
        lender: ContractAddress,
        borrower: ContractAddress,
        amount: u256
    }

    #[derive(Drop, starknet::Event)]
    struct LoanRepayment {
        borrower: ContractAddress,
        request_id: u128,
        amount: u256
    }

    #[derive(Drop, starknet::Event)]
    struct RequestLiquidated {
        request_id: u128,
        lender: ContractAddress,
        repayment_amount: u256
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        native_token: ContractAddress,
        bot_address: ContractAddress,
        router: ContractAddress
    ) {
        self.native_token.write(native_token);
        self.bot_address.write(bot_address);
        self.router.write(router);
    }

    #[abi(embed_v0)]
    impl LendingProtocolImpl of ILendingProtocol<ContractState> {
        fn deposit_collateral(ref self: ContractState, token_address: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            
            self._verify_token_allowed(token_address);
            self._verify_amount_greater_than_zero(amount);

            if token_address == self.native_token.read() {
                self._verify_msg_value_matches_amount(amount);
            }

            self._increase_user_collateral_balance(caller, token_address, amount);
            self._increase_available_balance(caller, token_address, amount);

            if token_address != self.native_token.read() {
                self._transfer_from(caller, token_address, amount);
            }

            self.emit(CollateralDeposited { user: caller, token: token_address, amount });
        }

        fn create_lending_request(
            ref self: ContractState, 
            amount: u128, 
            interest: u16, 
            return_date: u256, 
            loan_currency: ContractAddress
        ) {
            let caller = get_caller_address();

            self._verify_token_loanable(loan_currency);
            self._verify_future_date(return_date);
            self._verify_amount_greater_than_zero(amount.into());

            let loan_usd_value = self._get_usd_value(loan_currency, amount.into());
            let collateral_value = self._get_account_collateral_value(caller);
            let max_loan = (collateral_value * COLLATERALIZATION_RATIO.into()) / 100;
            
            self._verify_sufficient_collateral(loan_usd_value, max_loan);

            let request_id = self._generate_request_id();
            let total_repayment = self._calculate_total_repayment(amount.into(), interest, return_date);

            self._create_new_request(
                request_id,
                caller,
                amount.into(),
                interest,
                return_date,
                loan_currency,
                total_repayment
            );

            self._lock_collateral_for_request(request_id, loan_usd_value, max_loan);

            self.emit(RequestCreated { borrower: caller, request_id, amount: amount.into(), interest });
        }

        fn service_request(ref self: ContractState, request_id: u128, token_address: ContractAddress) {
            let caller = get_caller_address();
            let request = self._get_request(request_id);
            
            assert(request.status == RequestStatus::OPEN, 'Request not open');
            assert(request.loan_currency == token_address, 'Token mismatch');
            assert(request.borrower != caller, 'Cannot self fund');
            
            self._verify_lender_balance(token_address, request.amount);
            self._verify_lender_allowance(token_address, request.amount);
            
            self._mark_request_serviced(request_id, caller);
            self._lock_borrower_collateral(request_id);
            
            if token_address == self.native_token.read() {
                self._verify_msg_value(request.amount);
                self._transfer_eth_to_borrower(request.borrower, request.amount);
            } else {
                self._transfer_tokens_to_borrower(token_address, request.borrower, request.amount);
            }
            
            self.emit(RequestServiced { 
                request_id, 
                lender: caller, 
                borrower: request.borrower, 
                amount: request.amount 
            });
        }

        fn repay_loan(ref self: ContractState, request_id: u128, amount: u256) {
            let caller = get_caller_address();
            let request = self._get_request(request_id);
            
            assert(request.status == RequestStatus::SERVICED, 'Request not serviced');
            self._verify_repayment_amount(amount, request.total_repayment);
            
            let remaining = request.total_repayment - amount;
            self._update_repayment_amount(request_id, remaining);
            
            if remaining == 0 {
                self._release_collateral(request_id);
                self._mark_request_closed(request_id);
                self._update_borrower_loan_balance(request.borrower, amount);
            }
            
            self._transfer_repayment_to_lender(request.loan_currency, request.lender, amount);
            
            self.emit(LoanRepayment { borrower: caller, request_id, amount });
        }

        fn liquidate_request(ref self: ContractState, request_id: u128) {
            let caller = get_caller_address();
            assert(caller == self.bot_address.read(), 'Only bot can liquidate');
            
            let request = self._get_request(request_id);
            assert(request.status == RequestStatus::SERVICED, 'Invalid request status');
            
            let health_factor = self.calculate_health_factor(request.borrower, 0);
            assert(health_factor < PRECISION, 'Position is healthy');
            
            let mut total_recovered = 0;
            let mut idx = 0;
            loop {
                if idx >= request.collateral_tokens.len() {
                    break;
                }
                let token = *request.collateral_tokens[idx];
                let amount = self._get_collateral_amount(request_id, token);
                if amount > 0 {
                    let recovered = self._swap_to_loan_currency(token, amount, request.loan_currency);
                    total_recovered += recovered;
                    self._update_collateral_balance(request_id, token, 0);
                }
                idx += 1;
            };
            
            let repayment_amount = min(total_recovered, request.total_repayment);
            self._transfer_repayment(request.loan_currency, request.lender, repayment_amount);
            self._mark_request_liquidated(request_id);
            
            self.emit(RequestLiquidated { request_id, lender: request.lender, repayment_amount });
        }

        fn get_usd_value(self: @ContractState, token: ContractAddress, amount: u256) -> u256 {
            let price_feed = self.price_feeds.read(token);
            let price = self._get_latest_price(price_feed);
            let decimals = self.get_token_decimal(token);
            (price * amount) / pow(10, decimals.into())
        }

        fn get_token_decimal(self: @ContractState, token: ContractAddress) -> u8 {
            if token == self.native_token.read() {
                return 18;
            }
            self._get_token_decimals(token)
        }

        fn calculate_health_factor(
            self: @ContractState,
            user: ContractAddress,
            additional_borrow: u256
        ) -> u256 {
            let (total_borrow, collateral_value) = self.get_account_info(user);
            let adjusted_collateral = (collateral_value * LIQUIDATION_THRESHOLD.into()) / 100;
            
            if total_borrow == 0 && additional_borrow == 0 {
                return adjusted_collateral * PRECISION;
            }
            
            (adjusted_collateral * PRECISION) / (total_borrow + additional_borrow)
        }

        fn get_account_info(self: @ContractState, user: ContractAddress) -> (u256, u256) {
            let total_borrow = self._get_loan_collected_in_usd(user);
            let collateral_value = self._get_account_collateral_value(user);
            (total_borrow, collateral_value)
        }

        fn get_user_collateral_tokens(self: @ContractState, user: ContractAddress) -> Array<ContractAddress> {
            let mut tokens = ArrayTrait::new();
            let mut idx = 0;
            loop {
                if idx >= self._get_collateral_tokens_length() {
                    break;
                }
                let token = self._get_collateral_token_at(idx);
                if self._get_user_collateral_balance(user, token) > 0 {
                    tokens.append(token);
                }
                idx += 1;
            };
            tokens
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _verify_msg_value_matches_amount(ref self: ContractState, amount: u256) {
            let tx_info = starknet::get_tx_info().unbox();
            assert(tx_info.max_fee == amount.into(), 'Value mismatch');
        }

        fn _increase_user_collateral_balance(ref self: ContractState, user: ContractAddress, token: ContractAddress, amount: u256) {
            let current = self.collateral_balances.read((user, token));
            self.collateral_balances.write((user, token), current + amount);
        }

        fn _increase_available_balance(ref self: ContractState, user: ContractAddress, token: ContractAddress, amount: u256) {
            let current = self.available_balances.read((user, token));
            self.available_balances.write((user, token), current + amount);
        }

        fn _transfer_from(ref self: ContractState, from: ContractAddress, token: ContractAddress, amount: u256) {
            // Call ERC20 transfer_from
            let success = IERC20Dispatcher { contract_address: token }.transfer_from(from, get_contract_address(), amount);
            assert(success, 'Transfer failed');
        }

        fn _verify_token_loanable(ref self: ContractState, token: ContractAddress) {
            assert(self.price_feeds.read(token).is_non_zero(), 'Token not loanable');
        }

        fn _verify_future_date(ref self: ContractState, date: u256) {
            let current_time: u256 = get_block_timestamp().into();
            assert(date > current_time + ONE_DAY, 'Invalid return date');
        }

        fn _get_usd_value(self: @ContractState, token: ContractAddress, amount: u256) -> u256 {
            let price_feed = self.price_feeds.read(token);
            let price = self._get_latest_price(price_feed);
            let decimals = self._get_token_decimals(token);
            (price * amount) / pow(10, decimals.into())
        }

        fn _get_account_collateral_value(self: @ContractState, user: ContractAddress) -> u256 {
            let mut total_value = 0;
            let tokens = self.get_user_collateral_tokens(user);
            let mut idx = 0;
            loop {
                if idx >= tokens.len() {
                    break;
                }
                let token = *tokens[idx];
                let balance = self._get_user_collateral_balance(user, token);
                total_value += self._get_usd_value(token, balance);
                idx += 1;
            };
            total_value
        }

        fn _verify_sufficient_collateral(ref self: ContractState, loan_value: u256, max_loan: u256) {
            assert(loan_value <= max_loan, 'Insufficient collateral');
        }

        fn _generate_request_id(ref self: ContractState) -> u128 {
            let current = self.next_request_id.read();
            self.next_request_id.write(current + 1);
            current
        }

        fn _calculate_total_repayment(self: @ContractState, amount: u256, interest: u16, return_date: u256) -> u256 {
            let interest_amount = (amount * interest.into()) / 100;
            amount + interest_amount
        }

        fn _create_new_request(
            ref self: ContractState,
            id: u128,
            borrower: ContractAddress,
            amount: u256,
            interest: u16,
            return_date: u256,
            loan_currency: ContractAddress,
            total_repayment: u256
        ) {
            let request = LendingRequest {
                id,
                borrower,
                amount,
                interest,
                return_date,
                loan_currency,
                total_repayment,
                lender: contract_address_const::<0>(),
                status: RequestStatus::OPEN,
                collateral_tokens: ArrayTrait::new()
            };
            self.requests.write(id, request);
        }

        fn _lock_collateral_for_request(ref self: ContractState, request_id: u128, loan_value: u256, max_loan: u256) {
            let request = self.requests.read(request_id);
            let mut tokens = self.get_user_collateral_tokens(request.borrower);
            let mut idx = 0;
            loop {
                if idx >= tokens.len() {
                    break;
                }
                let token = *tokens[idx];
                let available = self.available_balances.read((request.borrower, token));
                if available > 0 {
                    let to_lock = min(available, (loan_value * available) / max_loan);
                    self.available_balances.write((request.borrower, token), available - to_lock);
                    tokens.append(token);
                }
                idx += 1;
            };
            let mut request = self.requests.read(request_id);
            request.collateral_tokens = tokens;
            self.requests.write(request_id, request);
        }

        fn _get_latest_price(self: @ContractState, price_feed: ContractAddress) -> u256 {
            // Call price feed contract
            IPriceFeedDispatcher { contract_address: price_feed }.get_latest_price()
        }

        fn _get_token_decimals(self: @ContractState, token: ContractAddress) -> u8 {
            IERC20Dispatcher { contract_address: token }.decimals()
        }

        fn _get_user_collateral_balance(self: @ContractState, user: ContractAddress, token: ContractAddress) -> u256 {
            self.collateral_balances.read((user, token))
        }

        fn _get_loan_collected_in_usd(self: @ContractState, user: ContractAddress) -> u256 {
            self.user_total_borrows.read(user)
        }

        fn _get_request(self: @ContractState, request_id: u128) -> LendingRequest {
            self.requests.read(request_id)
        }

        fn _mark_request_serviced(ref self: ContractState, request_id: u128, lender: ContractAddress) {
            let mut request = self.requests.read(request_id);
            request.status = RequestStatus::SERVICED;
            request.lender = lender;
            self.requests.write(request_id, request);
        }

        fn _mark_request_closed(ref self: ContractState, request_id: u128) {
            let mut request = self.requests.read(request_id);
            request.status = RequestStatus::CLOSED;
            self.requests.write(request_id, request);
        }

        fn _verify_token_allowed(ref self: ContractState, token: ContractAddress) {
            let is_allowed = self.collateral_tokens.read(token);
            assert(is_allowed, 'Token not allowed as collateral');
        }
                
        fn _verify_amount_greater_than_zero(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'Amount must be greater than 0');
        }
    
        fn _verify_lender_balance(ref self: ContractState, token: ContractAddress, amount: u256) {
            let lender = get_caller_address();
            let balance = IERC20Dispatcher { contract_address: token }.balance_of(lender);
            assert(balance >= amount, 'Insufficient balance');
        }
    
        fn _verify_lender_allowance(ref self: ContractState, token: ContractAddress, amount: u256) {
            let lender = get_caller_address();
            let allowance = IERC20Dispatcher { contract_address: token }.allowance(lender, get_contract_address());
            assert(allowance >= amount, 'Insufficient allowance');
        }
    
        fn _lock_borrower_collateral(ref self: ContractState, request_id: u128) {
            let request = self._get_request(request_id);
            let mut idx = 0;
            loop {
                if idx >= request.collateral_tokens.len() {
                    break;
                }
                let token = *request.collateral_tokens[idx];
                let amount = self._get_collateral_amount(request_id, token);
                self.collateral_balances.write((request.borrower, token), amount);
                idx += 1;
            };
        }
    
        fn _verify_msg_value(ref self: ContractState, amount: u256) {
            assert(starknet::get_tx_info().unbox().max_fee == amount.into(), 'Invalid msg value');
        }

        fn _transfer_tokens_to_borrower(ref self: ContractState, token: ContractAddress, to: ContractAddress, amount: u256) {
            let success = IERC20Dispatcher { contract_address: token }.transfer(to, amount);
            assert(success, 'Transfer failed');
        }
    
        fn _verify_repayment_amount(ref self: ContractState, amount: u256, total: u256) {
            assert(amount <= total, 'Invalid repayment amount');
        }
    
        fn _update_repayment_amount(ref self: ContractState, request_id: u128, amount: u256) {
            let mut request = self._get_request(request_id);
            request.total_repayment = amount;
            self.requests.write(request_id, request);
        }    
        fn _release_collateral(ref self: ContractState, request_id: u128) {
            let request = self._get_request(request_id);
            let mut idx = 0;
            loop {
                if idx >= request.collateral_tokens.len() {
                    break;
                }
                let token = *request.collateral_tokens[idx];
                let amount = self._get_collateral_amount(request_id, token);
                self.available_balances.write((request.borrower, token), amount);
                idx += 1;
            };
        }
    
        fn _update_borrower_loan_balance(ref self: ContractState, borrower: ContractAddress, amount: u256) {
            let current = self.user_total_borrows.read(borrower);
            self.user_total_borrows.write(borrower, current - amount);
        }
    
        fn _transfer_repayment_to_lender(ref self: ContractState, token: ContractAddress, lender: ContractAddress, amount: u256) {
            if token == self.native_token.read() {
                // Handle native token transfer
            } else {
                let success = IERC20Dispatcher { contract_address: token }.transfer(lender, amount);
                assert(success, 'Transfer failed');
            }
        }
    
        fn _get_collateral_amount(self: @ContractState, request_id: u128, token: ContractAddress) -> u256 {
            self.collateral_balances.read((self._get_request(request_id).borrower, token))
        }

        fn _update_collateral_balance(ref self: ContractState, request_id: u128, token: ContractAddress, amount: u256) {
            let request = self._get_request(request_id);
            self.collateral_balances.write((request.borrower, token), amount);
        }
    
        fn _transfer_repayment(ref self: ContractState, token: ContractAddress, to: ContractAddress, amount: u256) {
            if token == self.native_token.read() {
                // Handle native token transfer
            } else {
                let success = IERC20Dispatcher { contract_address: token }.transfer(to, amount);
                assert(success, 'Transfer failed');
            }
        }
    
        fn _mark_request_liquidated(ref self: ContractState, request_id: u128) {
            let mut request = self._get_request(request_id);
            request.status = RequestStatus::LIQUIDATED;
            self.requests.write(request_id, request);
        }
    
        fn _get_collateral_token_at(self: @ContractState, index: usize) -> ContractAddress {
            let token_bool = self.collateral_tokens.read(ContractAddress::from_felt252(index.into()));
            // Remove the try_into and use direct conversion
            ContractAddress::from_felt252(index.into())
        }
    
        fn _get_collateral_token_at(self: @ContractState, index: usize) -> ContractAddress {
            let token_bool = self.collateral_tokens.read(index.try_into().unwrap());
            assert(token_bool, 'Invalid token');
            ContractAddress::from_felt252(index.into())
        }
    
        fn _swap_to_loan_currency(ref self: ContractState, token_in: ContractAddress, amount_in: u256, token_out: ContractAddress) -> u256 {
            let mut path = ArrayTrait::new();
            path.append(token_in);
            path.append(token_out);
            
            let deadline: u256 = get_block_timestamp().into();
            
            IRouterDispatcher { contract_address: self.router.read() }
                .swap_exact_tokens_for_tokens(amount_in, 0, path, get_contract_address(), deadline)
        }
    
        fn _transfer_eth_to_borrower(ref self: ContractState, borrower: ContractAddress, amount: u256) {
            // Implementation for transferring native token
            // This would typically involve system calls specific to the L2
        }
    }
    
    fn pow(base: u256, exponent: u256) -> u256 {
        let mut result = 1_u256;
        let mut base = base;
        let mut exponent = exponent;

        while exponent > 0 {
            if exponent % 2 == 1 {
                result *= base;
            }
            base *= base;
            exponent /= 2;
        };

        result
    }

    // Function to find minimum of two numbers
    fn min(a: u256, b: u256) -> u256 {
        if a < b {
            a
        } else {
            b
        }
    }
}

