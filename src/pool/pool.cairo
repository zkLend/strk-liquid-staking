/// The entrypoint contract users interact with.
///
/// The system implements a trench-based mechanism for managing fund inflows/outflows. See the
/// repository's README for more details.
///
/// At any point in time, STRK tokens residing in this contract is considered to be in the open
/// trench + withdrawable amount. Tokens in active trenches are delegated through proxies deployed
/// by this contract.
///
/// Currently, the system always delegates to a single staker. A future upgrade should add support
/// for multiple stakers for robustness. Notably, the system does not take into account the
/// possibility that a staker would unstake, and thus invalidate the delegations through proxies.
/// This is fine for now as the system utilizes a staker controlled by the system operator, which is
/// guaranteed to stay staked. Therefore, the future upgrade that introduces staker diversity must
/// also add the ability to gracefully handle stakers exiting the protocol.
///
/// This contract is upgradeable (ideally by a DAO/time-locked contract), and also holds the
/// authority to upgrade other components in the system, allowing the system to adapt to future
/// changes in the staking protocol.
#[starknet::contract]
pub mod Pool {
    use core::cmp::min;
    use core::num::traits::Zero;
    use starknet::{ClassHash, ContractAddress};
    use starknet::{
        contract_address_const, get_block_timestamp, get_caller_address, get_contract_address
    };
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess
    };
    use starknet::syscalls::deploy_syscall;

    use contracts::staking::interface::{IStakingDispatcher, IStakingDispatcherTrait};
    use contracts::pool::interface::{
        IPoolDispatcher as IDelegationPoolDispatcher,
        IPoolDispatcherTrait as IDelegationPoolDispatcherTrait
    };
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::upgrades::interface::IUpgradeable;
    use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
    use strk_liquid_staking::pool::interface::{
        CollectRewardsResult, IPool, ProxyStats, UnstakeResult, WithdrawalInfo,
        WithdrawalQueueStats, WithdrawResult,
    };
    use strk_liquid_staking::proxy::interface::{IProxyDispatcher, IProxyDispatcherTrait};
    use strk_liquid_staking::staked_token::interface::{
        IStakedTokenDispatcher, IStakedTokenDispatcherTrait
    };

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent
    );
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        strk_token: IERC20Dispatcher,
        staking_contract: IStakingDispatcher,
        unstake_delay: u64,
        staked_token: IStakedTokenDispatcher,
        trench_size: u128,
        staker: ContractAddress,
        proxy_class_hash: ClassHash,
        total_proxy_count: u128,
        active_proxy_count: u128,
        active_proxies: Map<u128, ActiveProxy>,
        /// The next available index in `inactive_proxies`.
        next_inactive_proxy_index: u128,
        /// Points to the index of the next inactive proxy to be reused in `inactive_proxies`.
        reused_proxy_cursor: u128,
        /// Points to the index of the next inactive proxy to finish unstaking in
        /// `inactive_proxies`.
        exited_proxy_cursor: u128,
        inactive_proxies: Map<u128, InactiveProxy>,
        queued_withdrawal_count: u128,
        active_queued_withdrawal_cursor: u128,
        /// The total size of the withdrawal queue, including the interally-fulfilled but not yet
        /// withdrawn amounts.
        ///
        /// This value is equal to the sum of the `amount_remaining` field of all items in
        /// `queued_withdrawals`.
        withdrawal_queue_total_size: u128,
        /// The size of withdrawable part of the withdrawal queue, where funds are
        /// internally-fulfilled but not yet withdrawn by the recipient.
        ///
        /// This value is equal to the sum of the `amount_withdrawable` field of all items in
        /// `queued_withdrawals`.
        withdrawal_queue_withdrawable_size: u128,
        queued_withdrawals: Map<u128, QueuedWithdrawal>,
    }

    #[derive(Drop, starknet::Store)]
    struct ActiveProxy {
        contract: IProxyDispatcher,
        delegation_pool: IDelegationPoolDispatcher,
    }

    #[derive(Drop, starknet::Store)]
    pub struct InactiveProxy {
        contract: IProxyDispatcher,
        delegation_pool: IDelegationPoolDispatcher,
        initiated_time: u64,
    }


    #[derive(Drop, starknet::Store)]
    struct QueuedWithdrawal {
        recipient: ContractAddress,
        /// The total amount represented by this queue item, _INCLUDING_ the amount represented as
        /// `amount_withdrawable`.
        amount_remaining: u128,
        /// Amount immediately withdrawable _ONLY FOR THE ACTIVE QUEUE ITEM_.
        ///
        /// For non-active queue items, this field _MEANS NOTHING_. For these items:
        ///
        /// - if the item is ahead of the active item, the whole `amount_remaining` is withdrawable;
        /// - if the item is behind the active item, nothing is withdrawable.
        ///
        /// This field is designed like so as an optimization to avoid having to bulk update a large
        /// number of storage slots when many queued items are fulfilled at the same time. With such
        /// a design, only the cursor of the active item as well as the `amount_withdrawable` field
        /// of the newly-active item need to be updated. There's no need to even update the
        /// previously-active item's `amount_withdrawable` field.
        ///
        /// In the ideal case where the whole queue is cleared, there would be no new active item as
        /// the cursor moves to after the last item. In this case, only one storage slot update is
        /// needed.
        amount_withdrawable: u128,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        StakerUpdated: StakerUpdated,
        Staked: Staked,
        Unstaked: Unstaked,
        Withdrawal: Withdrawal,
        UnstakeFinished: UnstakeFinished,
        RewardsCollected: RewardsCollected,
        WithdrawalsFulfilled: WithdrawalsFulfilled,
    }

    #[derive(Drop, starknet::Event)]
    struct StakerUpdated {
        staker: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Staked {
        staker: ContractAddress,
        strk_amount: u128,
        staked_token_amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct Unstaked {
        staker: ContractAddress,
        queue_id: u128,
        staked_token_amount: u128,
        strk_amount: u128,
        fulfilled_amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawal {
        queue_id: u128,
        fulfilled_amount: u128,
        remaining_amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct UnstakeFinished {
        queue_id: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct RewardsCollected {
        collector: ContractAddress,
        total_amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawalsFulfilled {
        last_fulfilled_queue_id: u128,
    }

    pub mod Errors {
        pub const ZERO_TRENCH_SIZE: felt252 = 'PL_ZERO_TRENCH_SIZE';
        pub const DEPLOY_TOKEN_FAILED: felt252 = 'PL_DEPLOY_TOKEN_FAILED';
        pub const DEPLOY_PROXY_FAILED: felt252 = 'PL_DEPLOY_PROXY_FAILED';
        pub const ZERO_STAKER: felt252 = 'PL_ZERO_STAKER';
        pub const ZERO_AMOUNT: felt252 = 'PL_ZERO_AMOUNT';
        pub const TRANSFER_FROM_FAILED: felt252 = 'PL_TRANSFER_FROM_FAILED';
        pub const TRANSFER_FAILED: felt252 = 'PL_TRANSFER_FAILED';
        pub const POOL_BALANCE_OVERFLOW: felt252 = 'PL_POOL_BALANCE_OVERFLOW';
        pub const DELEGATION_NOT_OPEN: felt252 = 'PL_DELEGATION_NOT_OPEN';
        pub const ZERO_RECIPIENT: felt252 = 'PL_ZERO_RECIPIENT';
        pub const MINT_AMOUNT_OVERFLOW: felt252 = 'PL_MINT_AMOUNT_OVERFLOW';
        pub const UNSTAKE_AMOUNT_OVERFLOW: felt252 = 'PL_UNSTAKE_AMOUNT_OVERFLOW';
    }

    #[constructor]
    pub fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        strk_token: ContractAddress,
        staking_contract: ContractAddress,
        unstake_delay: u64,
        proxy_class_hash: ClassHash,
        staked_token_class_hash: ClassHash,
        trench_size: u128,
    ) {
        OwnableComponent::InternalTrait::initializer(ref self.ownable, owner);

        assert(!trench_size.is_zero(), Errors::ZERO_TRENCH_SIZE);

        let (staked_token, _) = deploy_syscall(staked_token_class_hash, 0, [].span(), false)
            .expect(Errors::DEPLOY_TOKEN_FAILED);

        self.strk_token.write(IERC20Dispatcher { contract_address: strk_token });
        self.staking_contract.write(IStakingDispatcher { contract_address: staking_contract });
        self.unstake_delay.write(unstake_delay);
        self.staked_token.write(IStakedTokenDispatcher { contract_address: staked_token });
        self.trench_size.write(trench_size);
        self.proxy_class_hash.write(proxy_class_hash);
    }

    #[abi(embed_v0)]
    impl PoolImpl of IPool<ContractState> {
        fn stake(ref self: ContractState, amount: u128) {
            ReentrancyGuardComponent::InternalTrait::start(ref self.reentrancy_guard);
            EntrypointTrait::stake(ref self, amount);
            ReentrancyGuardComponent::InternalTrait::end(ref self.reentrancy_guard);
        }

        fn unstake(ref self: ContractState, amount: u128) -> UnstakeResult {
            ReentrancyGuardComponent::InternalTrait::start(ref self.reentrancy_guard);
            let ret = EntrypointTrait::unstake(ref self, amount);
            ReentrancyGuardComponent::InternalTrait::end(ref self.reentrancy_guard);
            ret
        }

        fn withdraw(ref self: ContractState, queue_id: u128) -> WithdrawResult {
            ReentrancyGuardComponent::InternalTrait::start(ref self.reentrancy_guard);
            let ret = EntrypointTrait::withdraw(ref self, queue_id);
            ReentrancyGuardComponent::InternalTrait::end(ref self.reentrancy_guard);
            ret
        }

        fn collect_rewards(
            ref self: ContractState, start_index: u128, end_index: u128
        ) -> CollectRewardsResult {
            ReentrancyGuardComponent::InternalTrait::start(ref self.reentrancy_guard);
            let ret = EntrypointTrait::collect_rewards(ref self, start_index, end_index);
            ReentrancyGuardComponent::InternalTrait::end(ref self.reentrancy_guard);
            ret
        }

        fn set_staker(ref self: ContractState, staker: ContractAddress) {
            ReentrancyGuardComponent::InternalTrait::start(ref self.reentrancy_guard);
            EntrypointTrait::set_staker(ref self, staker);
            ReentrancyGuardComponent::InternalTrait::end(ref self.reentrancy_guard);
        }

        fn get_strk_token(self: @ContractState) -> ContractAddress {
            self.strk_token.read().contract_address
        }

        fn get_staked_token(self: @ContractState) -> ContractAddress {
            self.staked_token.read().contract_address
        }

        fn get_unstake_delay(self: @ContractState) -> u64 {
            self.unstake_delay.read()
        }

        fn get_total_stake(self: @ContractState) -> u128 {
            InternalTrait::get_total_stake(self)
        }

        fn get_proxy_stats(self: @ContractState) -> ProxyStats {
            let next_inactive_proxy_index = self.next_inactive_proxy_index.read();
            let reused_proxy_cursor = self.reused_proxy_cursor.read();
            let exited_proxy_cursor = self.exited_proxy_cursor.read();

            ProxyStats {
                total_proxy_count: self.total_proxy_count.read(),
                active_proxy_count: self.active_proxy_count.read(),
                exiting_proxy_count: next_inactive_proxy_index - exited_proxy_cursor,
                standby_proxy_count: exited_proxy_cursor - reused_proxy_cursor,
            }
        }

        fn get_withdrawal_queue_stats(self: @ContractState) -> WithdrawalQueueStats {
            WithdrawalQueueStats {
                total_withdrawal_count: self.queued_withdrawal_count.read(),
                fully_fulfilled_withdrawal_count: self.active_queued_withdrawal_cursor.read(),
            }
        }

        fn get_withdrawal_info(self: @ContractState, queue_id: u128) -> Option<WithdrawalInfo> {
            let queue_item = self.queued_withdrawals.read(queue_id);
            if queue_item.recipient.is_zero() {
                Option::None
            } else {
                let active_cursor = self.active_queued_withdrawal_cursor.read();

                Option::Some(
                    WithdrawalInfo {
                        recipient: queue_item.recipient,
                        amount_remaining: queue_item.amount_remaining,
                        amount_withdrawable: if active_cursor > queue_id {
                            queue_item.amount_remaining
                        } else if active_cursor == queue_id {
                            queue_item.amount_withdrawable
                        } else {
                            0
                        },
                    }
                )
            }
        }

        fn get_open_trench_balance(self: @ContractState) -> u128 {
            InternalTrait::get_open_trench_balance(self)
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            OwnableComponent::InternalTrait::assert_only_owner(@self.ownable);
            UpgradeableComponent::InternalTrait::upgrade(ref self.upgradeable, new_class_hash);
        }
    }

    #[generate_trait]
    impl EntrypointImpl of EntrypointTrait {
        fn stake(ref self: ContractState, amount: u128) {
            let staker = get_caller_address();
            assert(!staker.is_zero(), Errors::ZERO_STAKER);
            assert(!amount.is_zero(), Errors::ZERO_AMOUNT);

            let strk_token = self.strk_token.read();
            let staked_token = self.staked_token.read();

            let pool_size_before = InternalTrait::get_total_stake(@self);

            assert(
                strk_token.transfer_from(staker, get_contract_address(), amount.into()),
                Errors::TRANSFER_FROM_FAILED
            );

            let current_staked_token_supply = IERC20Dispatcher {
                contract_address: staked_token.contract_address
            }
                .total_supply();

            let mint_amount = if current_staked_token_supply.is_zero() {
                // This is the first staker. We match the amount to set the initial exchange rate to
                // exactly 1.
                amount.into()
            } else {
                // Exchange rate stays unchanged
                amount.into() * current_staked_token_supply / pool_size_before.into()
            };

            staked_token.mint(staker, mint_amount);

            self
                .emit(
                    Staked {
                        staker,
                        strk_amount: amount,
                        staked_token_amount: mint_amount
                            .try_into()
                            .expect(Errors::MINT_AMOUNT_OVERFLOW)
                    }
                );

            self.settle_open_trench();
        }

        fn unstake(ref self: ContractState, amount: u128) -> UnstakeResult {
            let staker = get_caller_address();
            assert(!staker.is_zero(), Errors::ZERO_STAKER);
            assert(!amount.is_zero(), Errors::ZERO_AMOUNT);

            let staked_token = self.staked_token.read();
            let staked_token_supply_before_burn = IERC20Dispatcher {
                contract_address: staked_token.contract_address
            }
                .total_supply();
            staked_token.burn(staker, amount.into());

            let pool_size = InternalTrait::get_total_stake(@self);

            let unstake_amount = if staked_token_supply_before_burn == amount.into() {
                // The whole pool is cleared
                pool_size
            } else {
                // Exchange rate stays unchanged
                (Into::<u128, u256>::into(amount)
                    * pool_size.into()
                    / staked_token_supply_before_burn)
                    .try_into()
                    .expect(Errors::UNSTAKE_AMOUNT_OVERFLOW)
            };

            // Queue new withdrawal
            //
            // NOTE: It's technically possible to check whether queuing is needed, as there might be
            //       sufficient balance in the open trench to fulfill the entire amount. However,
            //       keeping branching minimal simplifies code and makes it easier to audit.
            let queue_id = self.queued_withdrawal_count.read();
            self.queued_withdrawal_count.write(queue_id + 1);
            self
                .withdrawal_queue_total_size
                .write(self.withdrawal_queue_total_size.read() + unstake_amount);
            self
                .queued_withdrawals
                .write(
                    queue_id,
                    QueuedWithdrawal {
                        recipient: staker, amount_remaining: unstake_amount, amount_withdrawable: 0,
                    }
                );

            self.settle_open_trench();

            let withdraw_result = InternalTrait::withdraw(ref self, queue_id);
            self
                .emit(
                    Unstaked {
                        staker,
                        queue_id,
                        staked_token_amount: amount,
                        strk_amount: unstake_amount,
                        fulfilled_amount: withdraw_result.fulfilled,
                    }
                );

            if withdraw_result.fulfilled == unstake_amount {
                self.emit(UnstakeFinished { queue_id });
            }

            UnstakeResult {
                queue_id, total_amount: unstake_amount, amount_fulfilled: withdraw_result.fulfilled
            }
        }

        fn withdraw(ref self: ContractState, queue_id: u128) -> WithdrawResult {
            // This is necessary to account for any passive fund inflows
            self.settle_open_trench();

            let result = InternalTrait::withdraw(ref self, queue_id);
            if !result.fulfilled.is_zero() {
                self
                    .emit(
                        Withdrawal {
                            queue_id,
                            fulfilled_amount: result.fulfilled,
                            remaining_amount: result.remaining,
                        }
                    );
            }
            if result.remaining.is_zero() {
                self.emit(UnstakeFinished { queue_id });
            }

            result
        }

        fn collect_rewards(
            ref self: ContractState, start_index: u128, end_index: u128
        ) -> CollectRewardsResult {
            let mut total_amount = 0;

            let end_index = min(end_index, self.active_proxy_count.read());
            for proxy_index in start_index
                ..end_index {
                    let current_proxy = self.active_proxies.read(proxy_index);
                    total_amount += current_proxy
                        .delegation_pool
                        .claim_rewards(current_proxy.contract.contract_address);
                };

            self.emit(RewardsCollected { collector: get_caller_address(), total_amount });

            self.settle_open_trench();

            CollectRewardsResult { total_amount }
        }

        fn set_staker(ref self: ContractState, staker: ContractAddress) {
            OwnableComponent::InternalTrait::assert_only_owner(@self.ownable);
            self.staker.write(staker);
            self.emit(Event::StakerUpdated(StakerUpdated { staker }));
        }
    }

    #[generate_trait]
    impl InteranlImpl of InternalTrait {
        fn settle_open_trench(ref self: ContractState) {
            Self::settle_proxy_exits(ref self);
            Self::fulfill_withdrawal_queue(ref self);

            if !Self::deactivate_proxies(ref self).is_zero() {
                // Attempt to fulfill withdrawals again if rewards are claimed during the process of
                // proxy deactivation.
                Self::fulfill_withdrawal_queue(ref self);
            }

            Self::create_new_trenches(ref self);
        }

        fn settle_proxy_exits(ref self: ContractState) {
            let original_active_cursor = self.exited_proxy_cursor.read();
            let next_inactive_proxy_index = self.next_inactive_proxy_index.read();

            let strk_token = self.strk_token.read();
            let unstake_delay = self.unstake_delay.read();
            let current_timestamp = get_block_timestamp();

            let mut current_active_cursor = original_active_cursor;
            while current_active_cursor < next_inactive_proxy_index {
                let current_proxy = self.inactive_proxies.read(current_active_cursor);
                if current_timestamp < current_proxy.initiated_time + unstake_delay {
                    break;
                }

                current_proxy.contract.exit_action(current_proxy.delegation_pool, strk_token);
                current_active_cursor += 1;
            };

            if original_active_cursor != current_active_cursor {
                self.exited_proxy_cursor.write(current_active_cursor);
            }
        }

        fn fulfill_withdrawal_queue(ref self: ContractState) {
            let queued_count = self.queued_withdrawal_count.read();
            let original_active_cursor = self.active_queued_withdrawal_cursor.read();

            // Queue is not empty
            if original_active_cursor < queued_count {
                let trench_balance = Self::get_open_trench_balance(@self);

                if !trench_balance.is_zero() {
                    let mut disposable_amount = trench_balance;
                    let mut current_active_cursor = original_active_cursor;

                    // When looping there's no need to check whether `disposable_amount` is zero, as
                    // we known it's depleted when we cannot fulfill an entire item.
                    while current_active_cursor < queued_count {
                        let mut active_item = self.queued_withdrawals.read(current_active_cursor);

                        let unfulfilled_amount = active_item.amount_remaining
                            - active_item.amount_withdrawable;

                        let amount_to_fulfill = min(unfulfilled_amount, disposable_amount);
                        disposable_amount -= amount_to_fulfill;

                        if amount_to_fulfill == unfulfilled_amount {
                            // Item fully fulfilled. There's no need to update `amount_withdrawable`
                            // since we're moving the cursor over.
                            current_active_cursor += 1;
                        } else {
                            // Item not fully fulfilled. This item is now the active item. Need to
                            // update `amount_withdrawable` to reflect the fulfillment.
                            active_item.amount_withdrawable += amount_to_fulfill;
                            self.queued_withdrawals.write(current_active_cursor, active_item);

                            break;
                        }
                    };

                    let total_amount_fulfiled = trench_balance - disposable_amount;
                    self
                        .withdrawal_queue_withdrawable_size
                        .write(
                            self.withdrawal_queue_withdrawable_size.read() + total_amount_fulfiled
                        );

                    if current_active_cursor != original_active_cursor {
                        self.active_queued_withdrawal_cursor.write(current_active_cursor);
                        self
                            .emit(
                                WithdrawalsFulfilled {
                                    last_fulfilled_queue_id: current_active_cursor - 1
                                }
                            );
                    }
                }
            }
        }

        fn deactivate_proxies(ref self: ContractState) -> u128 {
            let mut final_rewards_collected = 0;

            let withdrawal_fulfillment_shortfall = self.withdrawal_queue_total_size.read()
                - self.withdrawal_queue_withdrawable_size.read();
            let trench_size = self.trench_size.read();

            let trenches_needed = (withdrawal_fulfillment_shortfall + trench_size - 1)
                / trench_size;
            let exiting_proxy_count = self.get_exiting_proxy_count();

            if exiting_proxy_count != trenches_needed {
                let active_proxy_count_before = self.active_proxy_count.read();
                let first_available_inactive_index = self.next_inactive_proxy_index.read();

                if exiting_proxy_count < trenches_needed {
                    // More proxies need to exit

                    let timestamp = get_block_timestamp();
                    let proxies_to_deactivate = trenches_needed - exiting_proxy_count;

                    for ind in 0
                        ..proxies_to_deactivate {
                            // It's okay to leave storage untouched as `active_proxy_count` acts
                            // as a cursor to the final item. It's also optimal to not clear
                            // storage as Starknet charges for doing so.
                            let current_proxy = self
                                .active_proxies
                                .read(active_proxy_count_before - ind - 1);

                            // Collect any pending rewards before exiting
                            final_rewards_collected += current_proxy
                                .delegation_pool
                                .claim_rewards(current_proxy.contract.contract_address);

                            current_proxy
                                .contract
                                .exit_intent(current_proxy.delegation_pool, trench_size);

                            self
                                .inactive_proxies
                                .write(
                                    first_available_inactive_index + ind,
                                    InactiveProxy {
                                        contract: current_proxy.contract,
                                        delegation_pool: current_proxy.delegation_pool,
                                        initiated_time: timestamp,
                                    }
                                );
                        };
                } else {
                    // Too many proxies exiting; reactivate some
                    let proxies_to_reactivate = exiting_proxy_count - trenches_needed;

                    for ind in 0
                        ..proxies_to_reactivate {
                            let current_proxy = self
                                .inactive_proxies
                                .read(first_available_inactive_index - ind - 1);

                            // Amount of zero means cancelling intent
                            current_proxy.contract.exit_intent(current_proxy.delegation_pool, 0);

                            self
                                .active_proxies
                                .write(
                                    active_proxy_count_before + ind,
                                    ActiveProxy {
                                        contract: current_proxy.contract,
                                        delegation_pool: current_proxy.delegation_pool,
                                    }
                                );
                        }
                }

                self
                    .active_proxy_count
                    .write(active_proxy_count_before + exiting_proxy_count - trenches_needed);
                self
                    .next_inactive_proxy_index
                    .write(first_available_inactive_index + trenches_needed - exiting_proxy_count);
            }

            if !final_rewards_collected.is_zero() {
                self
                    .emit(
                        RewardsCollected {
                            collector: get_caller_address(), total_amount: final_rewards_collected
                        }
                    );
            }

            final_rewards_collected
        }

        fn create_new_trenches(ref self: ContractState) {
            let open_trench_balance = Self::get_open_trench_balance(@self);

            let trench_size = self.trench_size.read();
            let new_trenches_count = open_trench_balance / trench_size;

            if !new_trenches_count.is_zero() {
                let reused_proxy_cursor = self.reused_proxy_cursor.read();

                let reuse_proxy_count = min(
                    self.exited_proxy_cursor.read() - reused_proxy_cursor, new_trenches_count
                );
                let new_proxy_count = new_trenches_count - reuse_proxy_count;

                let strk_token = self.strk_token.read();
                let total_proxy_count_before = self.total_proxy_count.read();
                let active_proxy_count_before = self.active_proxy_count.read();
                let proxy_class = self.proxy_class_hash.read();

                let delegation_pool = IDelegationPoolDispatcher {
                    contract_address: self
                        .staking_contract
                        .read()
                        .staker_info(self.staker.read())
                        .pool_info
                        .expect(Errors::DELEGATION_NOT_OPEN)
                        .pool_contract
                };

                for ind in 0
                    ..new_trenches_count {
                        let new_proxy = if ind < reuse_proxy_count {
                            self.inactive_proxies.read(reused_proxy_cursor + ind).contract
                        } else {
                            let (new_proxy, _) = deploy_syscall(
                                proxy_class,
                                (total_proxy_count_before + ind - reuse_proxy_count).into(),
                                [].span(),
                                false
                            )
                                .expect(Errors::DEPLOY_PROXY_FAILED);
                            IProxyDispatcher { contract_address: new_proxy }
                        };

                        strk_token.transfer(new_proxy.contract_address, trench_size.into());
                        new_proxy.delegate(delegation_pool, strk_token, trench_size);

                        self
                            .active_proxies
                            .write(
                                active_proxy_count_before + ind,
                                ActiveProxy { contract: new_proxy, delegation_pool }
                            );
                    };

                if !reuse_proxy_count.is_zero() {
                    self.reused_proxy_cursor.write(reused_proxy_cursor + reuse_proxy_count);
                }
                if !new_proxy_count.is_zero() {
                    self.total_proxy_count.write(total_proxy_count_before + new_proxy_count);
                }

                self.active_proxy_count.write(active_proxy_count_before + new_trenches_count);
            }
        }

        fn withdraw(ref self: ContractState, queue_id: u128) -> WithdrawResult {
            let active_cursor = self.active_queued_withdrawal_cursor.read();
            let queue_item = self.queued_withdrawals.read(queue_id);
            assert(!queue_item.recipient.is_zero(), Errors::ZERO_RECIPIENT);

            let result = if active_cursor < queue_id {
                // Item fully pending. Nothing to do.

                WithdrawResult { fulfilled: 0, remaining: queue_item.amount_remaining }
            } else if active_cursor > queue_id {
                // Item fully fulfilled. Send funds and remove item.

                self
                    .queued_withdrawals
                    .write(
                        queue_id,
                        QueuedWithdrawal {
                            recipient: contract_address_const::<0>(),
                            amount_remaining: 0,
                            amount_withdrawable: 0,
                        }
                    );

                WithdrawResult { fulfilled: queue_item.amount_remaining, remaining: 0 }
            } else {
                // Item partially fulfilled. Take withdrawable amount.

                let new_remaining = queue_item.amount_remaining - queue_item.amount_withdrawable;

                self
                    .queued_withdrawals
                    .write(
                        queue_id,
                        QueuedWithdrawal {
                            recipient: queue_item.recipient.clone(),
                            amount_remaining: new_remaining,
                            amount_withdrawable: 0,
                        }
                    );

                WithdrawResult {
                    fulfilled: queue_item.amount_withdrawable, remaining: new_remaining
                }
            };

            if !result.fulfilled.is_zero() {
                self
                    .withdrawal_queue_total_size
                    .write(self.withdrawal_queue_total_size.read() - result.fulfilled);
                self
                    .withdrawal_queue_withdrawable_size
                    .write(self.withdrawal_queue_withdrawable_size.read() - result.fulfilled);

                assert(
                    self.strk_token.read().transfer(queue_item.recipient, result.fulfilled.into()),
                    Errors::TRANSFER_FAILED
                );
            }

            result
        }

        fn get_open_trench_balance(self: @ContractState) -> u128 {
            self
                .strk_token
                .read()
                .balance_of(get_contract_address())
                .try_into()
                .expect(Errors::POOL_BALANCE_OVERFLOW)
                - self.withdrawal_queue_withdrawable_size.read()
        }

        fn get_total_stake(self: @ContractState) -> u128 {
            self
                .strk_token
                .read()
                .balance_of(get_contract_address())
                .try_into()
                .expect(Errors::POOL_BALANCE_OVERFLOW)
                + (self.trench_size.read()
                    * (self.active_proxy_count.read() + self.get_exiting_proxy_count()))
                - self.withdrawal_queue_total_size.read()
        }

        fn get_exiting_proxy_count(self: @ContractState) -> u128 {
            self.next_inactive_proxy_index.read() - self.exited_proxy_cursor.read()
        }
    }
}
