use starknet::contract_address_const;

use super::mock::{IMockAccountErc20Caller, IMockAccountStakingCaller};
use super::setup::{Setup, setup_sepolia};

#[test]
#[fork("SEPOLIA_332200")]
fn test_simple_staking() {
    let Setup { contracts, accounts } = setup_sepolia();

    let amount = 1_000000000000000000_u128;
    accounts.alice.strk.approve(contracts.staking.contract_address, amount.into());
    accounts
        .alice
        .staking
        .stake(contract_address_const::<1>(), contract_address_const::<1>(), amount, true, 0);
}
