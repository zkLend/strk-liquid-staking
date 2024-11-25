use contracts::staking::interface::IStakingDispatcher;
use openzeppelin::token::erc20::interface::IERC20Dispatcher;

#[starknet::interface]
pub trait IStaker<TContractState> {
    fn stake(
        ref self: TContractState,
        staking: IStakingDispatcher,
        token: IERC20Dispatcher,
        amount: u128,
    );
}
