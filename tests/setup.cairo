use core::option::OptionTrait;
use starknet::SyscallResultTrait;
use starknet::contract_address_const;
use starknet::syscalls::deploy_syscall;

use contracts::staking::interface::IStakingDispatcher;
use snforge_std::{DeclareResultTrait, start_cheat_caller_address, stop_cheat_caller_address};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use strk_liquid_staking::pool::interface::{IPoolDispatcher, IPoolDispatcherTrait};

use super::mock::{
    IMockAccountErc20Caller, IMockAccountPoolCaller, IMockAccountStakingCaller, MockAccount,
    create_mock_account
};

#[derive(Drop)]
pub struct Setup {
    pub contracts: SetupContracts,
    pub accounts: SetupAccounts,
}

#[derive(Drop)]
pub struct SetupContracts {
    pub staking: IStakingDispatcher,
    pub strk: IERC20Dispatcher,
    pub pool: IPoolDispatcher,
    pub staked_token: IERC20Dispatcher,
}

#[derive(Drop)]
pub struct SetupAccounts {
    pub strk_faucet: MockAccount,
    pub owner: MockAccount,
    pub staker: MockAccount,
    pub alice: MockAccount,
}

/// Sepolia Staking contract address.
const STAKING_CONTRACT_ADDRESS: felt252 =
    0x03745ab04a431fc02871a139be6b93d9260b0ff3e779ad9c8b377183b23109f1;

/// Sepolia STRK token address.
const STRK_CONTRACT_ADDRESS: felt252 =
    0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d;

/// Account on Sepolia with large STRK balance.
const STRK_SOURCE: felt252 = 0x0590e76a2e65435b7288bf3526cfa5c3ec7748d2f3433a934c931cce62460fc5;

pub fn setup_sepolia() -> Setup {
    let staking_contract = IStakingDispatcher {
        contract_address: STAKING_CONTRACT_ADDRESS.try_into().unwrap()
    };
    let strk_contract = IERC20Dispatcher {
        contract_address: STRK_CONTRACT_ADDRESS.try_into().unwrap()
    };

    let proxy_contract_class = snforge_std::declare("Proxy").unwrap().contract_class().class_hash;
    let staked_token_contract_class = snforge_std::declare("StakedToken")
        .unwrap()
        .contract_class()
        .class_hash;
    let pool_contract_class = snforge_std::declare("Pool").unwrap().contract_class().class_hash;

    let mut owner = create_mock_account(
        strk_contract.contract_address,
        staking_contract.contract_address,
        contract_address_const::<0>(),
        'owner'
    );

    let (pool_contract, _) = deploy_syscall(
        *pool_contract_class,
        0,
        [
            // owner
            owner.address.into(),
            // strk_token
            strk_contract.contract_address.into(),
            // staking_contract
            staking_contract.contract_address.into(),
            // unstake_delay
            5 * 60,
            // proxy_class_hash
            (*proxy_contract_class).into(),
            // staked_token_class_hash
            (*staked_token_contract_class).into(),
            // trench_size
            100_000000000000000000,
        ].span(),
        true
    )
        .unwrap_syscall();
    let pool_contract = IPoolDispatcher { contract_address: pool_contract };

    owner.pool.pool_address = pool_contract.contract_address;

    let strk_faucet = create_mock_account(
        strk_contract.contract_address,
        staking_contract.contract_address,
        pool_contract.contract_address,
        'strk_faucet'
    );
    let staker = create_mock_account(
        strk_contract.contract_address,
        staking_contract.contract_address,
        pool_contract.contract_address,
        'staker'
    );
    let alice = create_mock_account(
        strk_contract.contract_address,
        staking_contract.contract_address,
        pool_contract.contract_address,
        'alice'
    );

    start_cheat_caller_address(strk_contract.contract_address, STRK_SOURCE.try_into().unwrap());
    IERC20DispatcherTrait::transfer(
        strk_contract, strk_faucet.address, 1_000_000_000000000000000000
    );
    stop_cheat_caller_address(strk_contract.contract_address);

    strk_faucet.strk.transfer(staker.address, 1_000000000000000000);
    strk_faucet.strk.transfer(alice.address, 1_000_000000000000000000);

    // `staker` becomes available for delegation
    staker.strk.approve(staking_contract.contract_address, 1_000000000000000000);
    staker.staking.stake(staker.address, staker.address, 1_000000000000000000, true, 0);

    owner.pool.set_staker(staker.address);

    Setup {
        contracts: SetupContracts {
            staking: staking_contract,
            strk: strk_contract,
            pool: pool_contract,
            staked_token: IERC20Dispatcher { contract_address: pool_contract.get_staked_token() },
        },
        accounts: SetupAccounts { strk_faucet, owner, staker, alice }
    }
}
