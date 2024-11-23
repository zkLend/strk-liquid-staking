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
    use contracts::staking::interface::IStakingDispatcherTrait;
    use core::num::traits::Zero;
    use starknet::{ClassHash, ContractAddress};
    use starknet::{get_caller_address, get_contract_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess
    };
    use starknet::syscalls::deploy_syscall;

    use contracts::staking::interface::IStakingDispatcher;
    use contracts::pool::interface::{IPoolDispatcher as IDelegationPoolDispatcher};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::upgrades::interface::IUpgradeable;
    use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
    use strk_liquid_staking::pool::interface::{IPool, Proxy};
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

        fn unstake(ref self: ContractState, amount: u128) -> u128 {
            ReentrancyGuardComponent::InternalTrait::start(ref self.reentrancy_guard);
            let ret = EntrypointTrait::unstake(ref self, amount);
            ReentrancyGuardComponent::InternalTrait::end(ref self.reentrancy_guard);
            ret
        }

        fn withdraw(ref self: ContractState, withdrawal_id: u128) {
            ReentrancyGuardComponent::InternalTrait::start(ref self.reentrancy_guard);
            EntrypointTrait::withdraw(ref self, withdrawal_id);
            ReentrancyGuardComponent::InternalTrait::end(ref self.reentrancy_guard);
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

        fn unstake(ref self: ContractState, amount: u128) -> u128 {
            0
        }

        fn withdraw(ref self: ContractState, withdrawal_id: u128) {}

        fn set_staker(ref self: ContractState, staker: ContractAddress) {
            self.staker.write(staker);
            self.emit(Event::StakerUpdated(StakerUpdated { staker }));
        }
    }

    #[generate_trait]
    impl InteranlImpl of InternalTrait {
        fn settle_open_trench(ref self: ContractState) {
            let strk_token = self.strk_token.read();
            let trench_size = self.trench_size.read();

            // TODO: take withdrawable amount into account
            let open_trench_balance: u128 = strk_token
                .balance_of(get_contract_address())
                .try_into()
                .expect(Errors::POOL_BALANCE_OVERFLOW);
            let new_trenches_count = open_trench_balance / trench_size;

            if !new_trenches_count.is_zero() {
                // TODO: take inactive proxies into account

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
    }
}
