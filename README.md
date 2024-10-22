<p align="center">
  <h1 align="center">strk-liquid-staking</h1>
</p>

**Liquid staking protocol for STRK**

## Introduction

This repository contains the implementation of a liquid staking protocol for STRK. By default, any STRK tokens staked or delegated to the [STRK staking protocol](https://github.com/starknet-io/SNIPs/blob/main/SNIPS/snip-18.md) become non-transferrable, and are subject to a fixed delay (currently 21 days) upon withdrawal. The liquid staking protocol acts as a proxy for token delegation, and issues deposit certificate tokens to users, where such tokens can be freely transferred and traded. The withdrawal process is also optimized from a fixed delay of 21 days to one where the worst case is 21 days, with the best case being immediate.
