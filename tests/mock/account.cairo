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
}

#[starknet::contract]
pub mod MockAccountContract {
    use starknet::ContractAddress;

    use contracts::types::{Amount, Commission};
    use contracts::staking::interface::{IStakingDispatcher, IStakingDispatcherTrait};
    use strk_liquid_staking::interfaces::{IERC20Dispatcher, IERC20DispatcherTrait};

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
    }
}
