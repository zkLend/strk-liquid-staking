use starknet::ContractAddress;

#[derive(Debug, Drop, PartialEq, Serde)]
pub struct ProxyStats {
    pub total_proxy_count: u128,
    pub active_proxy_count: u128,
    pub exiting_proxy_count: u128,
    pub standby_proxy_count: u128,
}

#[derive(Debug, Drop, PartialEq, Serde)]
pub struct WithdrawalQueueStats {
    pub total_withdrawal_count: u128,
    pub fully_fulfilled_withdrawal_count: u128,
}

#[derive(Debug, Drop, PartialEq, Serde)]
pub struct WithdrawalInfo {
    pub recipient: ContractAddress,
    /// The total amount represented by this queue item, _INCLUDING_ the amount represented as
    /// `amount_withdrawable`.
    pub amount_remaining: u128,
    /// Amount immediately withdrawable.
    pub amount_withdrawable: u128,
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

#[derive(Drop, Serde)]
pub struct CollectRewardsResult {
    /// The total reward amount collected from proxies, before any commission is charged.
    pub total_amount: u128,
}

#[starknet::interface]
pub trait IPool<TContractState> {
    fn stake(ref self: TContractState, amount: u128);

    fn unstake(ref self: TContractState, amount: u128) -> UnstakeResult;

    fn withdraw(ref self: TContractState, queue_id: u128) -> WithdrawResult;

    fn collect_rewards(
        ref self: TContractState, start_index: u128, end_index: u128
    ) -> CollectRewardsResult;

    fn set_staker(ref self: TContractState, staker: ContractAddress);

    fn get_strk_token(self: @TContractState) -> ContractAddress;

    fn get_staked_token(self: @TContractState) -> ContractAddress;

    fn get_unstake_delay(self: @TContractState) -> u64;

    fn get_total_stake(self: @TContractState) -> u128;

    fn get_proxy_stats(self: @TContractState) -> ProxyStats;

    fn get_withdrawal_queue_stats(self: @TContractState) -> WithdrawalQueueStats;

    fn get_withdrawal_info(self: @TContractState, queue_id: u128) -> Option<WithdrawalInfo>;

    fn get_open_trench_balance(self: @TContractState) -> u128;
}
