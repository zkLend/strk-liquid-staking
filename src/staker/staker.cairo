/// A proxy account that acts as the staker.
///
/// Despite living in this repo (and used by test cases), this contract is not part of the system,
/// and is not strictly necessary. It acts as the sole staker that the system's proxies delegates to
/// before transitioning to a multi-staker setup.
///
/// The sole purpose of using this contract instead of a normal account contract is to make it
/// easier to manage ownership.
#[starknet::contract]
pub mod Staker {
    use starknet::{ClassHash, ContractAddress, get_contract_address};

    use contracts::staking::interface::{IStakingDispatcher, IStakingDispatcherTrait};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::upgrades::interface::IUpgradeable;
    use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
    use strk_liquid_staking::staker::interface::IStaker;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
    }

    #[constructor]
    pub fn constructor(ref self: ContractState, owner: ContractAddress) {
        OwnableComponent::InternalTrait::initializer(ref self.ownable, owner);
    }

    #[abi(embed_v0)]
    impl StakerImpl of IStaker<ContractState> {
        fn stake(
            ref self: ContractState,
            staking: IStakingDispatcher,
            token: IERC20Dispatcher,
            amount: u128,
        ) {
            OwnableComponent::InternalTrait::assert_only_owner(@self.ownable);

            let this_address = get_contract_address();

            token.approve(staking.contract_address, amount.into());
            staking.stake(this_address, this_address, amount, true, 0);
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            OwnableComponent::InternalTrait::assert_only_owner(@self.ownable);
            UpgradeableComponent::InternalTrait::upgrade(ref self.upgradeable, new_class_hash);
        }
    }
}
