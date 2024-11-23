/// An essentially state-less contract whose sole purpose is to allow `Pool` to have multiple
/// identities when participating in the staking protocol.
///
/// The proxy contract simply does whatever `Pool` asks it to do. It doesn't even keep track of the
/// amount it delegates. It's also upgradeable by `Pool`.
///
/// Technically, this contract could have been implemented as having a single arbitrary execution
/// entrypoint and it'd be more future-proof. However, keeping the feature set limited helps keep
/// the contract attack surface smaller and easier to audit.
#[starknet::contract]
pub mod Proxy {
    use starknet::ClassHash;
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    use contracts::pool::interface::{
        IPoolDispatcher as IDelegationPoolDispatcher,
        IPoolDispatcherTrait as IDelegationPoolDispatcherTrait
    };
    use openzeppelin::security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::upgrades::interface::IUpgradeable;
    use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
    use strk_liquid_staking::proxy::interface::IProxy;

    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent
    );
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[storage]
    struct Storage {
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        pool: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
    }

    pub mod Errors {
        pub const CALLER_NOT_POOL: felt252 = 'PX_CALLER_NOT_POOL';
        pub const APPROVE_FAILED: felt252 = 'PX_APPROVE_FAILED';
    }

    #[constructor]
    pub fn constructor(ref self: ContractState) {
        let sender = get_caller_address();
        self.pool.write(sender);
    }

    #[abi(embed_v0)]
    impl ProxyImpl of IProxy<ContractState> {
        fn delegate(
            ref self: ContractState,
            delegation_pool: IDelegationPoolDispatcher,
            token: IERC20Dispatcher,
            amount: u128
        ) {
            ReentrancyGuardComponent::InternalTrait::start(ref self.reentrancy_guard);
            EntrypointTrait::delegate(ref self, delegation_pool, token, amount);
            ReentrancyGuardComponent::InternalTrait::end(ref self.reentrancy_guard);
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            let sender = get_caller_address();
            assert(sender == self.pool.read(), Errors::CALLER_NOT_POOL);
            UpgradeableComponent::InternalTrait::upgrade(ref self.upgradeable, new_class_hash);
        }
    }

    #[generate_trait]
    impl EntrypointImpl of EntrypointTrait {
        fn delegate(
            ref self: ContractState,
            delegation_pool: IDelegationPoolDispatcher,
            token: IERC20Dispatcher,
            amount: u128
        ) {
            let sender = get_caller_address();
            assert(sender == self.pool.read(), Errors::CALLER_NOT_POOL);

            assert(
                token.approve(delegation_pool.contract_address, amount.into()),
                Errors::APPROVE_FAILED
            );

            // Rewards go directly into `Pool`
            delegation_pool.enter_delegation_pool(sender, amount);
        }
    }
}
