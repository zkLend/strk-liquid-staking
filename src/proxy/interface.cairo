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
}
