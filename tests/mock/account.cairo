use starknet::ContractAddress;

use contracts::types::{Amount, Commission};

#[starknet::interface]
pub trait IMockAccountContract<TContractState> {
    fn erc20_approve(
        ref self: TContractState, contract: ContractAddress, spender: ContractAddress, amount: u256
    ) -> bool;

    fn erc20_transfer(
        ref self: TContractState,
        contract: ContractAddress,
        recipient: ContractAddress,
        amount: u256
    ) -> bool;

    fn staking_stake(
        ref self: TContractState,
        contract: ContractAddress,
        reward_address: ContractAddress,
        operational_address: ContractAddress,
        amount: Amount,
        pool_enabled: bool,
        commission: Commission,
    );

    fn pool_stake(ref self: TContractState, contract: ContractAddress, amount: u128);

    fn pool_unstake(ref self: TContractState, contract: ContractAddress, amount: u128) -> u128;

    fn pool_withdraw(ref self: TContractState, contract: ContractAddress, withdrawal_id: u128);

    fn pool_set_staker(
        ref self: TContractState, contract: ContractAddress, staker: ContractAddress
    );
}

#[starknet::contract]
pub mod MockAccountContract {
    use starknet::ContractAddress;

    use contracts::types::{Amount, Commission};
    use contracts::staking::interface::{IStakingDispatcher, IStakingDispatcherTrait};
    use strk_liquid_staking::interfaces::{IERC20Dispatcher, IERC20DispatcherTrait};
    use strk_liquid_staking::pool::interface::{IPoolDispatcher, IPoolDispatcherTrait};

    use super::IMockAccountContract;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl MockAccountContractImpl of IMockAccountContract<ContractState> {
        fn erc20_approve(
            ref self: ContractState,
            contract: ContractAddress,
            spender: ContractAddress,
            amount: u256
        ) -> bool {
            IERC20Dispatcher { contract_address: contract }.approve(spender, amount)
        }

        fn erc20_transfer(
            ref self: ContractState,
            contract: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            IERC20Dispatcher { contract_address: contract }.transfer(recipient, amount)
        }

        fn staking_stake(
            ref self: ContractState,
            contract: ContractAddress,
            reward_address: ContractAddress,
            operational_address: ContractAddress,
            amount: Amount,
            pool_enabled: bool,
            commission: Commission,
        ) {
            IStakingDispatcher { contract_address: contract }
                .stake(reward_address, operational_address, amount, pool_enabled, commission);
        }

        fn pool_stake(ref self: ContractState, contract: ContractAddress, amount: u128) {
            IPoolDispatcher { contract_address: contract }.stake(amount)
        }

        fn pool_unstake(ref self: ContractState, contract: ContractAddress, amount: u128) -> u128 {
            IPoolDispatcher { contract_address: contract }.unstake(amount)
        }

        fn pool_withdraw(ref self: ContractState, contract: ContractAddress, withdrawal_id: u128) {
            IPoolDispatcher { contract_address: contract }.withdraw(withdrawal_id)
        }

        fn pool_set_staker(
            ref self: ContractState, contract: ContractAddress, staker: ContractAddress
        ) {
            IPoolDispatcher { contract_address: contract }.set_staker(staker);
        }
    }
}
