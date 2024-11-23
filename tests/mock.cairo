use starknet::ContractAddress;
use starknet::SyscallResultTrait;
use starknet::syscalls::deploy_syscall;

use contracts::types::{Amount, Commission};
use snforge_std::DeclareResultTrait;

mod account;
use account::{IMockAccountContractDispatcher, IMockAccountContractDispatcherTrait};

#[derive(Drop)]
pub struct MockAccount {
    pub address: ContractAddress,
    pub strk: MockAccountErc20Caller,
    pub staking: MockAccountStakingCaller,
    pub pool: MockAccountPoolCaller,
}

#[derive(Drop)]
pub struct MockAccountErc20Caller {
    pub account_address: ContractAddress,
    pub token_address: ContractAddress,
}

#[derive(Drop)]
pub struct MockAccountStakingCaller {
    pub account_address: ContractAddress,
    pub staking_address: ContractAddress,
}

#[derive(Drop)]
pub struct MockAccountPoolCaller {
    pub account_address: ContractAddress,
    pub pool_address: ContractAddress,
}

pub trait IMockAccountErc20Caller {
    fn approve(self: @MockAccountErc20Caller, spender: ContractAddress, amount: u256) -> bool;

    fn transfer(self: @MockAccountErc20Caller, recipient: ContractAddress, amount: u256) -> bool;
}

pub trait IMockAccountStakingCaller {
    fn stake(
        self: @MockAccountStakingCaller,
        reward_address: ContractAddress,
        operational_address: ContractAddress,
        amount: Amount,
        pool_enabled: bool,
        commission: Commission,
    );
}

pub trait IMockAccountPoolCaller {
    fn stake(self: @MockAccountPoolCaller, amount: u128);

    fn unstake(self: @MockAccountPoolCaller, amount: u128) -> u128;

    fn withdraw(self: @MockAccountPoolCaller, withdrawal_id: u128);

    fn set_staker(self: @MockAccountPoolCaller, staker: ContractAddress);
}

pub fn create_mock_account(
    strk_address: ContractAddress,
    staking_address: ContractAddress,
    pool_address: ContractAddress,
    salt: felt252
) -> MockAccount {
    let mock_account_contract_class = snforge_std::declare("MockAccountContract")
        .unwrap()
        .contract_class()
        .class_hash;

    let (deployed_address, _) = deploy_syscall(*mock_account_contract_class, salt, [].span(), true)
        .unwrap_syscall();

    MockAccount {
        address: deployed_address,
        strk: MockAccountErc20Caller {
            account_address: deployed_address, token_address: strk_address
        },
        staking: MockAccountStakingCaller { account_address: deployed_address, staking_address },
        pool: MockAccountPoolCaller { account_address: deployed_address, pool_address }
    }
}

impl IMockAccountErc20CallerImpl of IMockAccountErc20Caller {
    fn approve(self: @MockAccountErc20Caller, spender: ContractAddress, amount: u256) -> bool {
        IMockAccountContractDispatcher { contract_address: *self.account_address }
            .erc20_approve(*self.token_address, spender, amount)
    }

    fn transfer(self: @MockAccountErc20Caller, recipient: ContractAddress, amount: u256) -> bool {
        IMockAccountContractDispatcher { contract_address: *self.account_address }
            .erc20_transfer(*self.token_address, recipient, amount)
    }
}

impl IMockAccountStakingCallerImpl of IMockAccountStakingCaller {
    fn stake(
        self: @MockAccountStakingCaller,
        reward_address: ContractAddress,
        operational_address: ContractAddress,
        amount: Amount,
        pool_enabled: bool,
        commission: Commission,
    ) {
        IMockAccountContractDispatcher { contract_address: *self.account_address }
            .staking_stake(
                *self.staking_address,
                reward_address,
                operational_address,
                amount,
                pool_enabled,
                commission
            )
    }
}

impl IMockAccountPoolCallerImpl of IMockAccountPoolCaller {
    fn stake(self: @MockAccountPoolCaller, amount: u128) {
        IMockAccountContractDispatcher { contract_address: *self.account_address }
            .pool_stake(*self.pool_address, amount)
    }

    fn unstake(self: @MockAccountPoolCaller, amount: u128) -> u128 {
        IMockAccountContractDispatcher { contract_address: *self.account_address }
            .pool_unstake(*self.pool_address, amount)
    }

    fn withdraw(self: @MockAccountPoolCaller, withdrawal_id: u128) {
        IMockAccountContractDispatcher { contract_address: *self.account_address }
            .pool_withdraw(*self.pool_address, withdrawal_id)
    }

    fn set_staker(self: @MockAccountPoolCaller, staker: ContractAddress) {
        IMockAccountContractDispatcher { contract_address: *self.account_address }
            .pool_set_staker(*self.pool_address, staker)
    }
}
