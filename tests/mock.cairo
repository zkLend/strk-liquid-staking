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
}

#[derive(Drop)]
pub struct MockAccountErc20Caller {
    account_address: ContractAddress,
    token_address: ContractAddress,
}

#[derive(Drop)]
pub struct MockAccountStakingCaller {
    account_address: ContractAddress,
    staking_address: ContractAddress,
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

pub fn create_mock_account(
    strk_address: ContractAddress, staking_address: ContractAddress, salt: felt252
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
        staking: MockAccountStakingCaller {
            account_address: deployed_address, staking_address: staking_address
        }
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
