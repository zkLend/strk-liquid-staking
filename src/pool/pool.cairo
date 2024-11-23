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
    use starknet::{contract_address_const, get_caller_address, get_contract_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess
    };
    use starknet::syscalls::deploy_syscall;

    use contracts::staking::interface::{IStakingDispatcher, IStakingDispatcherTrait};
    use contracts::pool::interface::{IPoolDispatcher as IDelegationPoolDispatcher};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::upgrades::interface::IUpgradeable;
    use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
    use strk_liquid_staking::pool::interface::{IPool, Proxy, UnstakeResult, WithdrawResult};
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
        staked_token: IStakedTokenDispatcher,
        trench_size: u128,
        staker: ContractAddress,
        proxy_class_hash: ClassHash,
        proxy_count: u128,
        proxies: Map<u128, Proxy>,
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
        // TODO: add events for offchain indexing
    }

    #[derive(Drop, starknet::Event)]
    struct StakerUpdated {
        staker: ContractAddress,
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
        pub const NOT_RECIPIENT: felt252 = 'PL_NOT_RECIPIENT';
    }

    #[constructor]
    pub fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        strk_token: ContractAddress,
        staking_contract: ContractAddress,
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

        fn set_staker(ref self: ContractState, staker: ContractAddress) {
            ReentrancyGuardComponent::InternalTrait::start(ref self.reentrancy_guard);
            EntrypointTrait::set_staker(ref self, staker);
            ReentrancyGuardComponent::InternalTrait::end(ref self.reentrancy_guard);
        }

        fn get_staked_token(self: @ContractState) -> ContractAddress {
            self.staked_token.read().contract_address
        }

        fn get_proxy(self: @ContractState, index: u128) -> Option<Proxy> {
            if index < self.proxy_count.read() {
                Option::Some(self.proxies.read(index))
            } else {
                Option::None
            }
        }

        fn get_total_stake(self: @ContractState) -> u128 {
            // TODO: account for amount pending withdrawal
            self
                .strk_token
                .read()
                .balance_of(get_contract_address())
                .try_into()
                .expect(Errors::POOL_BALANCE_OVERFLOW)
                + (self.trench_size.read() * self.proxy_count.read())
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

            assert(
                strk_token.transfer_from(staker, get_contract_address(), amount.into()),
                Errors::TRANSFER_FROM_FAILED
            );

            // TODO: calculate correct proportional amount
            staked_token.mint(staker, amount.into());

            self.settle_open_trench();
        }

        fn unstake(ref self: ContractState, amount: u128) -> UnstakeResult {
            let staker = get_caller_address();
            assert(!staker.is_zero(), Errors::ZERO_STAKER);
            assert(!amount.is_zero(), Errors::ZERO_AMOUNT);

            let staked_token = self.staked_token.read();
            staked_token.burn(staker, amount.into());

            // TODO: calculate correct proportional amount
            let unstake_amount = amount;

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

            let withdraw_result = self.withdraw_checked(queue_id);
            UnstakeResult {
                queue_id, total_amount: unstake_amount, amount_fulfilled: withdraw_result.fulfilled
            }
        }

        fn withdraw(ref self: ContractState, queue_id: u128) -> WithdrawResult {
            // This is necessary to account for any passive fund inflows
            self.settle_open_trench();

            let staker = get_caller_address();
            assert(!staker.is_zero(), Errors::ZERO_STAKER);

            let queue_item = self.queued_withdrawals.read(queue_id);
            assert(staker == queue_item.recipient, Errors::NOT_RECIPIENT);

            self.withdraw_checked(queue_id)
        }

        fn set_staker(ref self: ContractState, staker: ContractAddress) {
            self.staker.write(staker);
            self.emit(Event::StakerUpdated(StakerUpdated { staker }));
        }
    }

    #[generate_trait]
    impl InteranlImpl of InternalTrait {
        fn settle_open_trench(ref self: ContractState) {
            Self::fulfill_withdrawal_queue(ref self);
            Self::create_new_trenches(ref self);
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
                    while current_active_cursor <= queued_count {
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
                    }
                }
            }
        }

        fn create_new_trenches(ref self: ContractState) {
            let open_trench_balance = Self::get_open_trench_balance(@self);

            let trench_size = self.trench_size.read();
            let new_trenches_count = open_trench_balance / trench_size;

            if !new_trenches_count.is_zero() {
                // TODO: take inactive proxies into account

                let strk_token = self.strk_token.read();
                let mut ind_proxy = self.proxy_count.read();
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

                for _ in 0
                    ..new_trenches_count {
                        let (new_proxy, _) = deploy_syscall(
                            proxy_class, ind_proxy.into(), [].span(), false
                        )
                            .expect(Errors::DEPLOY_PROXY_FAILED);
                        let new_proxy = IProxyDispatcher { contract_address: new_proxy };

                        strk_token.transfer(new_proxy.contract_address, trench_size.into());
                        new_proxy.delegate(delegation_pool, strk_token, trench_size);

                        self
                            .proxies
                            .write(ind_proxy, Proxy { contract: new_proxy, delegation_pool });
                        ind_proxy += 1;
                    };

                self.proxy_count.write(ind_proxy);
            }
        }

        fn withdraw_checked(ref self: ContractState, queue_id: u128) -> WithdrawResult {
            let active_cursor = self.active_queued_withdrawal_cursor.read();
            let queue_item = self.queued_withdrawals.read(queue_id);

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
    }
}
