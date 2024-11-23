use starknet::ContractAddress;

use contracts::pool::interface::{IPoolDispatcher as IDelegationPoolDispatcher};
use strk_liquid_staking::proxy::interface::IProxyDispatcher;

#[derive(Drop, Serde, starknet::Store)]
pub struct Proxy {
    pub contract: IProxyDispatcher,
    pub delegation_pool: IDelegationPoolDispatcher,
}

#[starknet::interface]
pub trait IPool<TContractState> {
    fn stake(ref self: TContractState, amount: u128);

    fn unstake(ref self: TContractState, amount: u128) -> u128;

    fn withdraw(ref self: TContractState, withdrawal_id: u128);

    fn set_staker(ref self: TContractState, staker: ContractAddress);

    fn get_staked_token(self: @TContractState) -> ContractAddress;

    fn get_proxy(self: @TContractState, index: u128) -> Option<Proxy>;
}
