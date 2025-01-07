use core::starknet::ContractAddress;

#[derive(Drop, Clone, Serde, starknet::Store)]
struct PaymentData {
    pub max_charge_allowed: u256,
    pub next_charge_timestamp: u64,
    pub periodic_table_index: u64,
}

#[starknet::interface]
pub trait IPeriodicPayments<TContractState> {
    fn allowance(
        self: @TContractState, owner: ContractAddress, spender: ContractAddress,
    ) -> PaymentData;
    fn approve(
        ref self: TContractState,
        spender: ContractAddress,
        max_charge_allowed: u256,
        next_charge_timestamp: u64,
    ) -> bool;
    fn charge(ref self: TContractState, from: ContractAddress, value: u256) -> bool;
}

/// Simple contract for managing balance.
#[starknet::contract]
mod PeriodicPayments {
    use core::{
        num::traits::Zero,
        starknet::{
            ContractAddress,
            storage::{
                Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
                StoragePointerWriteAccess, Vec, MutableVecTrait,
            },
            get_block_timestamp, get_caller_address, get_contract_address,
        },
    };
    use starknet::event::EventEmitter;

    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};

    use super::PaymentData;

    #[storage]
    struct Storage {
        token: ERC20ABIDispatcher,
        allowances: Map<(ContractAddress, ContractAddress), PaymentData>,
        periodic_table: Vec<u64>,
    }

    #[event]
    #[derive(Drop, PartialEq, starknet::Event)]
    pub enum Event {
        PaymentApproval: PaymentApproval,
        PaymentTransfer: PaymentTransfer,
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct PaymentApproval {
        #[key]
        pub owner: ContractAddress,
        #[key]
        pub spender: ContractAddress,
        pub max_charge_allowed: u256,
        pub next_charge_timestamp: u64,
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct PaymentTransfer {
        #[key]
        pub from: ContractAddress,
        #[key]
        pub to: ContractAddress,
        pub value: u256,
    }

    pub mod Errors {
        /// Error: Attempted to approve a zero address as a spender.
        pub const APPROVE_TO_ZERO_ADDRESS: felt252 = 'PP: approve to zero address';

        /// Error: The periodic table provided has a length of zero.
        pub const EMPTY_PERIODIC_TABLE: felt252 = 'PP: periodic table length zero';

        /// Error: Attempted to perform a transfer from the zero address.
        pub const TRANSFER_FROM_ZERO_ADDRESS: felt252 = 'PP: transfer from zero address';

        /// Error: Insufficient allowance for the requested transfer.
        pub const INSUFFICIENT_ALLOWANCE: felt252 = 'PP: insufficient allowance';

        /// Error: The provided timestamp is invalid (e.g., in the past).
        pub const INVALID_TIMESTAMP: felt252 = 'PP: invalid timestamp';

        /// Error: Failed to perform the ERC20 `transferFrom` operation.
        pub const TRANSFER_FROM_FAILED: felt252 = 'PP: ERC20 transferFrom failed';

        /// Error: Failed to perform the ERC20 `transfer` operation.
        pub const TRANSFER_FAILED: felt252 = 'PP: ERC20 transfer failed';
    }

    #[constructor]
    fn constructor(ref self: ContractState, token: ContractAddress, mut periodic_table: Span<u64>) {
        assert(periodic_table.len() > 0, Errors::EMPTY_PERIODIC_TABLE);
        self.token.write(ERC20ABIDispatcher { contract_address: token });
        while let Option::Some(interval) = periodic_table.pop_front() {
            self.periodic_table.append().write(*interval);
        }
    }

    #[abi(embed_v0)]
    impl PeriodicPaymentsImpl of super::IPeriodicPayments<ContractState> {
        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> PaymentData {
            self.allowances.read((owner, spender))
        }

        fn approve(
            ref self: ContractState,
            spender: ContractAddress,
            max_charge_allowed: u256,
            next_charge_timestamp: u64,
        ) -> bool {
            assert(!spender.is_zero(), Errors::APPROVE_TO_ZERO_ADDRESS);
            assert(max_charge_allowed > 0, Errors::INSUFFICIENT_ALLOWANCE);
            assert(
                next_charge_timestamp > get_block_timestamp(),
                Errors::INVALID_TIMESTAMP,
            );

            let owner = get_caller_address();

            self
                .allowances
                .write(
                    (owner, spender),
                    PaymentData {
                        max_charge_allowed, next_charge_timestamp, periodic_table_index: 0,
                    },
                );

            self
                .emit(
                    PaymentApproval { owner, spender, max_charge_allowed, next_charge_timestamp },
                );

            true
        }

        fn charge(ref self: ContractState, from: ContractAddress, value: u256) -> bool {
            assert(!from.is_zero(), Errors::TRANSFER_FROM_ZERO_ADDRESS);

            let to = get_caller_address();

            let mut payment_data = self.allowances.read((from, to));
            assert(payment_data.max_charge_allowed >= value, Errors::INSUFFICIENT_ALLOWANCE);
            assert(
                payment_data.next_charge_timestamp <= get_block_timestamp(),
                Errors::INVALID_TIMESTAMP,
            );

            assert(
                self.token.read().transfer_from(from, get_contract_address(), value),
                Errors::TRANSFER_FROM_FAILED,
            );
            assert(self.token.read().transfer(to, value), Errors::TRANSFER_FAILED);

            while payment_data.next_charge_timestamp <= get_block_timestamp() {
                let interval = self.periodic_table.at(payment_data.periodic_table_index).read();
                payment_data.next_charge_timestamp += interval;
                payment_data
                    .periodic_table_index = (payment_data.periodic_table_index + 1) % self
                    .periodic_table
                    .len();
            };

            self.allowances.write((from, to), payment_data);

            self.emit(PaymentTransfer { from, to, value });

            true
        }
    }
}
