// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface IMockSwap {
    function swap_ezeth_for_weth(uint256 amountIn) external returns (uint256);

    function swap_weth_for_ezeth(uint256 amountIn) external returns (uint256);
}
