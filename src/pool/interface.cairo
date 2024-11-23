use starknet::ContractAddress;

use contracts::pool::interface::{IPoolDispatcher as IDelegationPoolDispatcher};
use strk_liquid_staking::proxy::interface::IProxyDispatcher;

#[derive(Drop, Serde, starknet::Store)]
pub struct Proxy {
    pub contract: IProxyDispatcher,
    pub delegation_pool: IDelegationPoolDispatcher,
}

#[derive(Drop, Serde)]
pub struct UnstakeResult {
    pub queue_id: u128,
    pub total_amount: u128,
    pub amount_fulfilled: u128,
}

#[derive(Drop, Serde)]
pub struct WithdrawResult {
    pub fulfilled: u128,
    pub remaining: u128,
}

#[starknet::interface]
pub trait IPool<TContractState> {
    fn stake(ref self: TContractState, amount: u128);

    fn unstake(ref self: TContractState, amount: u128) -> UnstakeResult;

    fn withdraw(ref self: TContractState, queue_id: u128) -> WithdrawResult;

    fn set_staker(ref self: TContractState, staker: ContractAddress);

    fn get_staked_token(self: @TContractState) -> ContractAddress;

    fn get_proxy(self: @TContractState, index: u128) -> Option<Proxy>;

    fn get_total_stake(self: @TContractState) -> u128;

    fn get_open_trench_balance(self: @TContractState) -> u128;
}
