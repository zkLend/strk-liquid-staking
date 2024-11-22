use core::option::OptionTrait;

use contracts::staking::interface::{IStakingDispatcher};
use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address};
use strk_liquid_staking::interfaces::{IERC20Dispatcher, IERC20DispatcherTrait};

use super::mock::{IMockAccountErc20Caller, MockAccount, create_mock_account};

#[derive(Drop)]
pub struct Setup {
    pub contracts: SetupContracts,
    pub accounts: SetupAccounts,
}

#[derive(Drop)]
pub struct SetupContracts {
    pub staking: IStakingDispatcher,
    pub strk: IERC20Dispatcher,
}

#[derive(Drop)]
pub struct SetupAccounts {
    pub strk_faucet: MockAccount,
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

    let strk_faucet = create_mock_account(
        strk_contract.contract_address, staking_contract.contract_address, 'strk_faucet'
    );
    let alice = create_mock_account(
        strk_contract.contract_address, staking_contract.contract_address, 'alice'
    );

    start_cheat_caller_address(strk_contract.contract_address, STRK_SOURCE.try_into().unwrap());
    IERC20DispatcherTrait::transfer(
        strk_contract, strk_faucet.address, 1_000_000_000000000000000000
    );
    stop_cheat_caller_address(strk_contract.contract_address);

    strk_faucet.strk.transfer(alice.address, 1_000_000000000000000000);

    Setup {
        contracts: SetupContracts { staking: staking_contract, strk: strk_contract, },
        accounts: SetupAccounts { strk_faucet, alice }
    }
}

