use core::num::traits::Bounded;
use starknet::get_block_timestamp;

use openzeppelin::token::erc20::interface::IERC20DispatcherTrait;
use snforge_std::start_cheat_block_timestamp_global;
use strk_liquid_staking::pool::interface::{IPoolDispatcherTrait, ProxyStats};

use super::mock::{IMockAccountErc20Caller, IMockAccountPoolCaller};
use super::setup::{Setup, setup_sepolia};

#[test]
#[fork("SEPOLIA_332200")]
fn test_simple_staking() {
    let Setup { contracts, accounts } = setup_sepolia();

    let amount = 225_000000000000000000_u128;
    accounts.alice.strk.approve(contracts.pool.contract_address, Bounded::MAX);
    accounts.alice.pool.stake(amount);

    assert_eq!(contracts.pool.get_total_stake(), amount);
    assert_eq!(contracts.staked_token.balance_of(accounts.alice.address), amount.into());
    assert_eq!(contracts.pool.get_open_trench_balance(), 25_000000000000000000);
}

#[test]
#[fork("SEPOLIA_332200")]
fn test_fully_fulfilled_unstake() {
    let Setup { contracts, accounts } = setup_sepolia();

    let stake_amount = 225_000000000000000000_u128;
    accounts.alice.strk.approve(contracts.pool.contract_address, Bounded::MAX);
    accounts.alice.pool.stake(stake_amount);

    // Alice balance: 775
    // Open trench balance: 25
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 775_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 25_000000000000000000);
    assert_eq!(contracts.pool.get_total_stake(), 225_000000000000000000);

    // Alice withdraws 10 STRK which can be immediately fully fulfilled
    let result = accounts.alice.pool.unstake(10_000000000000000000);
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
    accounts.alice.strk.approve(contracts.pool.contract_address, Bounded::MAX);
    accounts.alice.pool.stake(stake_amount);

    // Alice balance: 775
    // Open trench balance: 25
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 775_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 25_000000000000000000);
    assert_eq!(contracts.pool.get_total_stake(), 225_000000000000000000);

    // Alice withdraws 30 STRK which can be partially fulfilled
    let result = accounts.alice.pool.unstake(30_000000000000000000);
    assert_eq!(result.total_amount, 30_000000000000000000);
    assert_eq!(result.amount_fulfilled, 25_000000000000000000);

    // Alice balance: 800
    // Open trench balance: 0
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 800_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 0);
    assert_eq!(contracts.pool.get_total_stake(), 195_000000000000000000);

    // Immediately withdrawing yields nothing
    assert_eq!(accounts.alice.pool.withdraw(0).fulfilled, 0);
    assert_eq!(contracts.pool.get_withdrawal_queue_stats().fully_fulfilled_withdrawal_count, 0);

    // Can withdraw after 5 minutes as the inactive proxy exits
    start_cheat_block_timestamp_global(get_block_timestamp() + 300);
    assert_eq!(accounts.alice.pool.withdraw(0).fulfilled, 5_000000000000000000);
    assert_eq!(contracts.pool.get_withdrawal_queue_stats().fully_fulfilled_withdrawal_count, 1);

    // Alice balance: 805
    // Open trench balance: 95
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 805_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 95_000000000000000000);
    assert_eq!(contracts.pool.get_total_stake(), 195_000000000000000000);
}

#[test]
#[fork("SEPOLIA_332200")]
fn test_unfulfilled_unstake() {
    let Setup { contracts, accounts } = setup_sepolia();

    let stake_amount = 800_000000000000000000_u128;
    accounts.alice.strk.approve(contracts.pool.contract_address, Bounded::MAX);
    accounts.alice.pool.stake(stake_amount);

    // Alice balance: 200
    // Open trench balance: 0
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 200_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 0);
    assert_eq!(contracts.pool.get_total_stake(), 800_000000000000000000);

    // Alice withdraws 410 STRK where none can be fulfilled
    let result = accounts.alice.pool.unstake(410_000000000000000000);
    assert_eq!(result.total_amount, 410_000000000000000000);
    assert_eq!(result.amount_fulfilled, 0);

    // Alice balance: 200
    // Open trench balance: 0
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 200_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 0);
    assert_eq!(contracts.pool.get_total_stake(), 390_000000000000000000);

    // Immediately withdrawing yields nothing
    assert_eq!(accounts.alice.pool.withdraw(0).fulfilled, 0);

    // Can withdraw after 5 minutes as the inactive proxy exits
    start_cheat_block_timestamp_global(get_block_timestamp() + 300);
    assert_eq!(accounts.alice.pool.withdraw(0).fulfilled, 410_000000000000000000);

    // Alice balance: 610
    // Open trench balance: 90
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 610_000000000000000000);
    assert_eq!(contracts.pool.get_open_trench_balance(), 90_000000000000000000);
    assert_eq!(contracts.pool.get_total_stake(), 390_000000000000000000);
}

#[test]
#[fork("SEPOLIA_332200")]
fn test_reuse_proxy() {
    let Setup { contracts, accounts } = setup_sepolia();

    let stake_amount = 600_000000000000000000_u128;
    accounts.alice.strk.approve(contracts.pool.contract_address, Bounded::MAX);
    accounts.alice.pool.stake(stake_amount);

    // Alice unstakes 210 to deactivate 3 proxies
    accounts.alice.pool.unstake(210_000000000000000000);
    assert_eq!(
        contracts.pool.get_proxy_stats(),
        ProxyStats {
            total_proxy_count: 6,
            active_proxy_count: 3,
            exiting_proxy_count: 3,
            standby_proxy_count: 0,
        }
    );

    start_cheat_block_timestamp_global(get_block_timestamp() + 300);
    assert_eq!(accounts.alice.pool.withdraw(0).fulfilled, 210_000000000000000000);
    assert_eq!(
        contracts.pool.get_proxy_stats(),
        ProxyStats {
            total_proxy_count: 6,
            active_proxy_count: 3,
            exiting_proxy_count: 0,
            standby_proxy_count: 3,
        }
    );

    // Alices stakes 100, creating 1 new trenches
    let stake_amount = 100_000000000000000000_u128;
    accounts.alice.pool.stake(stake_amount);

    // 1 proxy is reused; 0 new proxies are deployed.
    assert_eq!(
        contracts.pool.get_proxy_stats(),
        ProxyStats {
            total_proxy_count: 6,
            active_proxy_count: 4,
            exiting_proxy_count: 0,
            standby_proxy_count: 2,
        }
    );

    // Alices stakes 300, creating 3 new trenches
    let stake_amount = 300_000000000000000000_u128;
    accounts.alice.pool.stake(stake_amount);

    // 2 proxy is reused; 1 new proxies are deployed.
    assert_eq!(
        contracts.pool.get_proxy_stats(),
        ProxyStats {
            total_proxy_count: 7,
            active_proxy_count: 7,
            exiting_proxy_count: 0,
            standby_proxy_count: 0,
        }
    );
}

#[test]
#[fork("SEPOLIA_332200")]
fn test_staked_token_deflation() {
    let Setup { contracts, accounts } = setup_sepolia();

    accounts.alice.strk.approve(contracts.pool.contract_address, Bounded::MAX);

    // Alice stakes 50 STRK; gets 50 kSTRK back.
    accounts.alice.pool.stake(50_000000000000000000);
    assert_eq!(contracts.staked_token.balance_of(accounts.alice.address), 50_000000000000000000);

    // Simulates a 20% return from rewards by sending unsolicited STRK to pool
    accounts.strk_faucet.strk.transfer(contracts.pool.contract_address, 10_000000000000000000);

    // Exchange rate: 1 kSTRK = 1.2 STRK
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 950_000000000000000000);
    accounts.alice.pool.unstake(10_000000000000000000);
    assert_eq!(contracts.strk.balance_of(accounts.alice.address), 962_000000000000000000);
    assert_eq!(contracts.staked_token.balance_of(accounts.alice.address), 40_000000000000000000);

    // Pool size: 48 STRK; kSTRK supply: 40
    assert_eq!(contracts.pool.get_total_stake(), 48_000000000000000000);

    // Adds 32 STRK to the pool to set exchange rate: 1 kSTRK = 2 STRK
    accounts.strk_faucet.strk.transfer(contracts.pool.contract_address, 32_000000000000000000);

    // Alice puts the 12 STRK back; gets 6 kSTRK only
    accounts.alice.pool.stake(12_000000000000000000);
    assert_eq!(contracts.staked_token.balance_of(accounts.alice.address), 46_000000000000000000);
    assert_eq!(contracts.pool.get_total_stake(), 92_000000000000000000);
}

#[test]
#[fork("SEPOLIA_332200")]
fn test_reward_collection() {
    let Setup { contracts, accounts } = setup_sepolia();

    accounts.alice.strk.approve(contracts.pool.contract_address, Bounded::MAX);

    // Alice stakes 250 STRK
    accounts.alice.pool.stake(250_000000000000000000);

    // Collect rewards after one day
    start_cheat_block_timestamp_global(get_block_timestamp() + 86400);
    assert!(accounts.alice.pool.collect_rewards(0, Bounded::MAX).total_amount > 0);

    // Rewards are collected into the pool
    assert!(contracts.pool.get_total_stake() > 250_000000000000000000);

    // New exchange rate: 1 kSTRK > 1 STRK
    accounts.alice.pool.unstake(10_000000000000000000);
    assert!(contracts.strk.balance_of(accounts.alice.address) > 760_000000000000000000);
}

#[test]
#[fork("SEPOLIA_332200")]
fn test_withdrawal_fulfillment_with_rewards() {
    let Setup { contracts, accounts } = setup_sepolia();

    accounts.alice.strk.approve(contracts.pool.contract_address, Bounded::MAX);

    // Alice stakes 200 STRK
    accounts.alice.pool.stake(200_000000000000000000);

    // Alice unstakes 50 STRK; none is fulfilled
    accounts.alice.pool.unstake(50_000000000000000000);
    assert_eq!(
        contracts.pool.get_withdrawal_info(0).unwrap().amount_remaining, 50_000000000000000000
    );
    assert_eq!(contracts.pool.get_withdrawal_info(0).unwrap().amount_withdrawable, 0);

    // Collect rewards after 4 minutes
    start_cheat_block_timestamp_global(get_block_timestamp() + 240);
    assert!(accounts.alice.pool.collect_rewards(0, Bounded::MAX).total_amount > 0);

    // Rewards are collected into the pool; withdrawal is partially fulfilled
    assert!(contracts.pool.get_withdrawal_info(0).unwrap().amount_withdrawable > 0);

    // Everything is used to partially fulfill withdrawal
    assert_eq!(contracts.pool.get_open_trench_balance(), 0);
}

#[test]
#[fork("SEPOLIA_332200")]
fn test_pre_deactivation_reward_collection() {
    let Setup { contracts, accounts } = setup_sepolia();

    accounts.alice.strk.approve(contracts.pool.contract_address, Bounded::MAX);

    // Alice stakes 250 STRK
    accounts.alice.pool.stake(250_000000000000000000);

    // One day elapses
    start_cheat_block_timestamp_global(get_block_timestamp() + 86400);

    // Alice unstakes 60 STRK to trigger 1 deactivation
    accounts.alice.pool.unstake(60_000000000000000000);

    // Rewards are collected into the pool
    assert!(contracts.pool.get_total_stake() > 190_000000000000000000);
}
