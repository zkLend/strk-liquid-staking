/// A standard ERC20 token representing ownership in the stake pool.
///
/// The only extension on top of the ERC20 standard is the `Pool` contract's ability to:
///
/// - mint and burn tokens;
/// - upgrade the contract.
#[starknet::contract]
pub mod StakedToken {
    use starknet::ClassHash;
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    use strk_liquid_staking::staked_token::interface::IStakedToken;
    use openzeppelin::token::erc20::{ERC20Component, ERC20HooksEmptyImpl};
    use openzeppelin::token::erc20::interface::IERC20Metadata;
    use openzeppelin::upgrades::interface::IUpgradeable;
    use openzeppelin::upgrades::upgradeable::UpgradeableComponent;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20CamelOnlyImpl = ERC20Component::ERC20CamelOnlyImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        pool: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
    }

    pub mod Errors {
        pub const CALLER_NOT_POOL: felt252 = 'ST_CALLER_NOT_POOL';
    }

    #[constructor]
    pub fn constructor(ref self: ContractState) {
        let sender = get_caller_address();
        self.pool.write(sender);
    }

    #[abi(embed_v0)]
    impl StakedTokenImpl of IStakedToken<ContractState> {
        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            let sender = get_caller_address();
            assert(sender == self.pool.read(), Errors::CALLER_NOT_POOL);
            ERC20Component::InternalTrait::mint(ref self.erc20, recipient, amount);
        }

        fn burn(ref self: ContractState, owner: ContractAddress, amount: u256) {
            let sender = get_caller_address();
            assert(sender == self.pool.read(), Errors::CALLER_NOT_POOL);
            ERC20Component::InternalTrait::burn(ref self.erc20, owner, amount);
        }
    }

    #[abi(embed_v0)]
    impl ERC20MetadataImpl of IERC20Metadata<ContractState> {
        fn name(self: @ContractState) -> ByteArray {
            "kSTRK Token"
        }

        fn symbol(self: @ContractState) -> ByteArray {
            "kSTRK"
        }

        fn decimals(self: @ContractState) -> u8 {
            18
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
}
