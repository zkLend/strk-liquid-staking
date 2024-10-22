<p align="center">
  <h1 align="center">strk-liquid-staking</h1>
</p>

**Liquid staking protocol for STRK**

## Introduction

This repository contains the implementation of a liquid staking protocol for STRK. By default, any STRK tokens staked or delegated to the [STRK staking protocol](https://github.com/starknet-io/SNIPs/blob/main/SNIPS/snip-18.md) become non-transferrable, and are subject to a fixed delay (currently 21 days) upon withdrawal. The liquid staking protocol acts as a proxy for token delegation, and issues deposit certificate tokens to users, where such tokens can be freely transferred and traded. The withdrawal process is also optimized from a fixed delay of 21 days to one where the worst case is 21 days, with the best case being immediate.

## Architecture

In a nutshell, the protocol functions by collecting funds from users and _delegating_ them to a pool of diversified stakers. Upon fund collection, deposit certificate tokens are issued that represent claims on the pool of funds. The protocol periodically collects rewards from said delegations, increasing the size of the pool, and hence the value of each deposit certificate token. This process is illustrated in the following diagram:

```
                         ┌──────Rewards────────────────────┐
                         │ ┌────Rewards────────┐           │
                         │ │                   │           │
                         │ │                 ┌─┴────────┐  │
   ┌───Certificate───┐   │ │            ┌────► Staker 1 │  │
   │                 │   │ │            │    └──────────┘  │
   │ ┌────Stake────┐ │   │ │            │                  │
   │ │             │ │   │ │            │                  │
┌──▼─┴─┐         ┌─▼─┴───▼─▼┐           │    ┌──────────┐  │
│ User │         │ Protocol ├─Delegate──┼────► Staker 2 ├──┘
└──▲─┬─┘         └─▲─┬─────▲┘           │    └──────────┘
   │ │             │ │     │            │
   │ └───Unstake───┘ │     │            │
   │                 │     │            │    ┌──────────┐
   └────STRK─Token───┘     │            └────► Staker 3 │
                           │                 └─┬────────┘
                           │                   │
                           └────Rewards────────┘
```

The diagram above, however, is an oversimplification. Due to the fixed delay imposed on undelegation, the protocol employes a [trenching mechanism](#trenching) to handle fund inflows and outflows.

## Trenching

The need for trenching arises from the fact that partial undelegation requests are not queued. Whenever a new undelegation request is made, the current in-flight request is overwritten and the whole 21-day countdown restarts. While this works fine for individuals, it apparently wouldn't work for the liquid staking protocol where frequent withdrawals are expected.

As a result, instead of treating the whole pool of funds as one, the protocol divides it into _trenches_, with each trench being of a fixed size. The protocol only delegates or undelegates in the unit of trenches. A trench that is not full is called an _open trench_. There's _always_ an open trench in the protocol. When the protocol is first deployed, it contains a single trench that's open and empty.

### Deposit

No delegation happens before this first trench is fully filled:

```
               ┌─Trench─#0─────────────────────┬────────────────────┐              ┌────────────┐
               │                               │                    │              │            │
               │                               │                    │              │  Staker 1  │
───Deposit─────►                               │                    │              │            │
               │                               │                    │              └────────────┘
               │         Filled                │       Empty        │
               │                               │                    │
               │                               │                    │
               │                               │                    │
               │                               │                    │
               └───────────────────────────────┴────────────────────┘
```

When a deposit causes the open trench to be full, delegation happens atomically. Excess deposit, if any, goes into the newly open trench:

```
               ┌─Trench─#0──────────────────────────────────────────┐              ┌────────────┐
               │                                                    │              │            │
               │                                                    ├──────────────►  Staker 1  │
───Deposit─┬───►                                                    │              │            │
           │   │                                                    │              └────────────┘
           │   │                       Full                         │
           │   │                                                    │
           │   │                                                    │
           │   │                                                    │
           │   │                                                    │
           │   └────────────────────────────────────────────────────┘
           │
           │
           │   ┌─Trench─#1─────────────────────┬────────────────────┐
           │   │                               │                    │
           │   │                               │                    │
           └───►                               │                    │
               │                               │                    │
               │         Filled                │       Empty        │
               │                               │                    │
               │                               │                    │
               │                               │                    │
               │                               │                    │
               └───────────────────────────────┴────────────────────┘
```

### Reward collection

Staking rewards collected go into the open trench:

```
┌─Trench─#0──────────────────────────────────────────┐              ┌────────────┐
│                                                    │              │            │
│                                                    ├───Delegated──►  Staker 1  │
│                                                    │              │            │
│                                                    │              └─────┬──────┘
│                       Full                         │                    │
│                                                    │                    │
│                                                    │                    │
│                                                    │                    │
│                                                    │                    │
└────────────────────────────────────────────────────┘                    │
                                                                          │
                                                                          │
┌─Trench─#1──────────────────────┬───────────────────┐                    │
│                                │                   │                    │
│                                │                   │                    │
│                                │                   │                    │
│                                │                   │                    │
│            Filled              │       Empty       ◄─────Rewards────────┘
│                                │                   │
│                                │                   │
│                                │                   │
│                                │                   │
└────────────────────────────────┴───────────────────┘
```

> [!NOTE]
>
> Any action that causes a trench to become full results in delegation, including reward collections.

### Withdrawal

The protocol maintains a _withdrawal queue_. Whenever a user makes a withdrawal request by burning the deposit certificate token, the following happens:

1. If the queue is empty, the protocol takes as much funds as needed from the open trench in an attempt to fulfill the request.
2. If the request is still not fulfilled after step 1, it's queued to wait for a fulfillment.

There are several ways that withdrawal requests in the queue can be fulfilled:

- **New deposits**

  The [Deposit](#deposit) section from above is another oversimplification. When the protocol receives a new deposit, instead of directly filling a trench, it would attempt to fulfill as many withdrawal requests as possible. Only when the queue becomes empty the excess deposits would be directed into a trench.

- **Trench deactivation**

  Whenever a new item is queued into the withdrawal queue, the protocol checks whether the _inflight undelegating trenches_ represent enough funds to cover all requests in the queue. If not, the undelegation process is started for more trenches.

  When a trench finishes the undelegation delay, its funds are used to fulfill the withdrawal queue. Excess funds, if any, go into the open trench.

### Invariants

Based on the above rules, given a trench size of _T_, it can be concluded that these invariants hold at any given moment in the protocol.

1. Either the open trench or the withdrawal queue is empty.
2. Denote as _U_ the number of inflight undelegating trenches, and _W_ the total amount of funds in the withdrawal queue, then this holds: `W <= U * T`.

> [!NOTE]
>
> It's possible that there are more inflight undelegating trenches than needed for the entirety of the withdrawal queue (i.e. `W <= (U - 1) * T`). This is normal and can be caused by the queue being (partially) fulfilled by new deposits.

### Trench size considerations

It's important to decide on a trench size that's well balanced. Since the open trench does not earn rewards, a trench size that's too large causes the overall yield of the protocol to be unnecessarily low; on the other hand, a trench size that's too small causes additional operational overhead as more contract calls are involved in routine actions such as reward collections.

In the future, the ability to change the trench size should be developed to allow the protocol to scale efficiently.
