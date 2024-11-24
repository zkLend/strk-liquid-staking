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
    accounts.alice.strk.approve(contracts.pool.contract_address, amount.into());
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
    accounts.alice.strk.approve(contracts.pool.contract_address, stake_amount.into());
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
    accounts.alice.strk.approve(contracts.pool.contract_address, stake_amount.into());
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

    // Can withdraw after 5 minutes as the inactive proxy exits
    start_cheat_block_timestamp_global(get_block_timestamp() + 300);
    assert_eq!(accounts.alice.pool.withdraw(0).fulfilled, 5_000000000000000000);

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
    accounts.alice.strk.approve(contracts.pool.contract_address, stake_amount.into());
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
    accounts.alice.strk.approve(contracts.pool.contract_address, stake_amount.into());
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

    // Alices stakes 400, creating 4 new trenches
    let stake_amount = 400_000000000000000000_u128;
    accounts.alice.strk.approve(contracts.pool.contract_address, stake_amount.into());
    accounts.alice.pool.stake(stake_amount);

    // 3 proxied are reused. Only 1 new proxy is deployed.
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
