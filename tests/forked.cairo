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

    assert_eq!(contracts.staked_token.balance_of(accounts.alice.address), amount.into());

    let proxy_0 = contracts.pool.get_proxy(0).unwrap();
    let proxy_1 = contracts.pool.get_proxy(1).unwrap();

    assert!(!proxy_0.contract.contract_address.is_zero());
    assert!(!proxy_0.delegation_pool.contract_address.is_zero());
    assert!(!proxy_1.contract.contract_address.is_zero());
    assert!(!proxy_1.delegation_pool.contract_address.is_zero());

    assert!(contracts.pool.get_proxy(2).is_none());
}
