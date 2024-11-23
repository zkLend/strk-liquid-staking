use core::num::traits::Zero;

use openzeppelin::token::erc20::interface::IERC20DispatcherTrait;
use strk_liquid_staking::pool::interface::IPoolDispatcherTrait;

use super::mock::{IMockAccountErc20Caller, IMockAccountPoolCaller};
use super::setup::{Setup, setup_sepolia};

#[test]
#[fork("SEPOLIA_332200")]
fn test_simple_staking() {
    let Setup { contracts, accounts } = setup_sepolia();

    let amount = 225_000000000000000000_u128;
    accounts.alice.strk.approve(contracts.pool.contract_address, amount.into());
    accounts.alice.pool.stake(amount);

    assert_eq!(contracts.pool.get_total_stake(), amount);
    assert_eq!(contracts.staked_token.balance_of(accounts.alice.address), amount.into());

    let proxy_0 = contracts.pool.get_proxy(0).unwrap();
    let proxy_1 = contracts.pool.get_proxy(1).unwrap();

    assert!(!proxy_0.contract.contract_address.is_zero());
    assert!(!proxy_0.delegation_pool.contract_address.is_zero());
    assert!(!proxy_1.contract.contract_address.is_zero());
    assert!(!proxy_1.delegation_pool.contract_address.is_zero());

    assert!(contracts.pool.get_proxy(2).is_none());
}

#[test]
#[fork("SEPOLIA_332200")]
fn test_fully_fulfilled_unstake() {
    let Setup { contracts, accounts } = setup_sepolia();

    let stake_amount = 225_000000000000000000_u128;
    accounts.alice.strk.approve(contracts.pool.contract_address, stake_amount.into());
    accounts.alice.pool.stake(stake_amount);

    // Alice balance: 775
    // Open trench balance: 25
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 775_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 25_000000000000000000);
    assert_eq!(contracts.pool.get_total_stake(), 225_000000000000000000);

    // Alice withdraws 10 STRK which can be immediately fully fulfilled
    let result = accounts.alice.pool.unstake(10_000000000000000000_u128);
    assert_eq!(result.total_amount, 10_000000000000000000);
    assert_eq!(result.amount_fulfilled, 10_000000000000000000);

    // Alice balance: 785
    // Open trench balance: 15
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 785_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 15_000000000000000000);
    assert_eq!(contracts.pool.get_total_stake(), 215_000000000000000000);
}

#[test]
#[fork("SEPOLIA_332200")]
fn test_partially_fulfilled_unstake() {
    let Setup { contracts, accounts } = setup_sepolia();

    let stake_amount = 225_000000000000000000_u128;
    accounts.alice.strk.approve(contracts.pool.contract_address, stake_amount.into());
    accounts.alice.pool.stake(stake_amount);

    // Alice balance: 775
    // Open trench balance: 25
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 775_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 25_000000000000000000);
    assert_eq!(contracts.pool.get_total_stake(), 225_000000000000000000);

    // Alice withdraws 30 STRK which can be partially fulfilled
    let result = accounts.alice.pool.unstake(30_000000000000000000_u128);
    assert_eq!(result.total_amount, 30_000000000000000000);
    assert_eq!(result.amount_fulfilled, 25_000000000000000000);

    // Alice balance: 800
    // Open trench balance: 0
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 800_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 0);
    assert_eq!(contracts.pool.get_total_stake(), 200_000000000000000000);
}

#[test]
#[fork("SEPOLIA_332200")]
fn test_unfulfilled_unstake() {
    let Setup { contracts, accounts } = setup_sepolia();

    let stake_amount = 200_000000000000000000_u128;
    accounts.alice.strk.approve(contracts.pool.contract_address, stake_amount.into());
    accounts.alice.pool.stake(stake_amount);

    // Alice balance: 800
    // Open trench balance: 0
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 800_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 0);
    assert_eq!(contracts.pool.get_total_stake(), 200_000000000000000000);

    // Alice withdraws 10 STRK where none can be fulfilled
    let result = accounts.alice.pool.unstake(10_000000000000000000_u128);
    assert_eq!(result.total_amount, 10_000000000000000000);
    assert_eq!(result.amount_fulfilled, 0);

    // Alice balance: 800
    // Open trench balance: 0
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 800_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 0);
    assert_eq!(contracts.pool.get_total_stake(), 200_000000000000000000);
}
