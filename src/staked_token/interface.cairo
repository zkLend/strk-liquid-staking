use starknet::ContractAddress;

#[starknet::interface]
pub trait IStakedToken<TContractState> {
    fn mint(ref self: TContractState, recipient: ContractAddress, amount: u256);

    fn burn(ref self: TContractState, owner: ContractAddress, amount: u256);
}
