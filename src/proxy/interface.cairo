use contracts::pool::interface::{IPoolDispatcher as IDelegationPoolDispatcher};
use openzeppelin::token::erc20::interface::IERC20Dispatcher;

#[starknet::interface]
pub trait IProxy<TContractState> {
    fn delegate(
        ref self: TContractState,
        delegation_pool: IDelegationPoolDispatcher,
        token: IERC20Dispatcher,
        amount: u128
    );

    fn exit_intent(
        ref self: TContractState, delegation_pool: IDelegationPoolDispatcher, amount: u128
    );

    fn exit_action(
        ref self: TContractState,
        delegation_pool: IDelegationPoolDispatcher,
        token: IERC20Dispatcher,
    );
}
