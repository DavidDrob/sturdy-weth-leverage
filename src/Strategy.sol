// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMockSwap} from "./interfaces/mock/IMockSwap.sol";

// import {ISilo} from "@silo/interfaces/ISilo.sol";
import {ISilo} from "./interfaces/ISilo.sol";
import {ISiloRepository} from "./interfaces/ISiloRepository.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

contract Strategy is BaseStrategy {
    using SafeERC20 for ERC20;

    // tokens
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant EZ_ETH = 0x2416092f143378750bb29b79eD961ab195CcEea5;

    // protocols
    ISilo public constant SILO = ISilo(0x12ee4BE944b993C81b6840e088bA1dCc57F07B1D);
    ISiloRepository public constant SILO_REPOSITORY = ISiloRepository(0xD2767dAdED5910bbc205811FdbD2eEFd460AcBe9);
    IMockSwap public mockSwap;

    constructor(
        address _asset,
        string memory _name
    ) BaseStrategy(_asset, _name) {
        IERC20(WETH).approve(address(SILO), type(uint256).max);
        IERC20(EZ_ETH).approve(address(SILO), type(uint256).max);
    }

    function updateMockSwap(address newMockSwap) public onlyManagement {
        // approve ezETH
        if (IERC20(EZ_ETH).allowance(address(this), address(mockSwap)) > 0) {
            IERC20(EZ_ETH).approve(address(mockSwap), 0);
        }
        IERC20(EZ_ETH).approve(newMockSwap, type(uint256).max);

        // approve wETH
        if (IERC20(WETH).allowance(address(this), address(mockSwap)) > 0) {
            IERC20(WETH).approve(address(mockSwap), 0);
        }
        IERC20(WETH).approve(newMockSwap, type(uint256).max);

        mockSwap = IMockSwap(newMockSwap);
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        uint256 _lastOut = mockSwap.swap_weth_for_ezeth(_amount);

        if (SILO.depositPossible(EZ_ETH, address(this))) {
            // 3x leverage
            for (uint i = 0; i < 3; i++) {
                SILO.deposit(EZ_ETH, _lastOut, true);

                // wETH and ezETH are almost 1:1
                // 20% extra for extra safety
                uint256 _max_ltv = SILO_REPOSITORY.getMaximumLTV(address(SILO), WETH);
                uint256 _borrow_amount = ((_max_ltv - 0.20e18) * _amount) / 1e18;

                (uint _wETHOut,) = SILO.borrow(WETH, _borrow_amount);

                _lastOut = mockSwap.swap_weth_for_ezeth(_wETHOut);
            }

            SILO.deposit(EZ_ETH, _lastOut, true);
        }
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // SILO.withdraw(address(WETH), _amount, true);
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        console2.log(IERC20(0xEEf2282949f4a1545AAB9824A88bA35A3fE2D990).balanceOf(address(this)));

        console2.log("HARVEST");
        uint256[] memory feesHarvested = SILO.harvestProtocolFees();
        for (uint i = 0; i < feesHarvested.length; i++) {
            console2.log(feesHarvested[i]);
        }

        _totalAssets = asset.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // NOTE: Withdraw limitations such as liquidity constraints should be accounted for HERE
        //  rather than _freeFunds in order to not count them as losses on withdraws.

        // TODO: If desired implement withdraw limit logic and any needed state variables.

        // EX:
        // if(yieldSource.notShutdown()) {
        //    return asset.balanceOf(address(this)) + asset.balanceOf(yieldSource);
        // }
        return type(uint256).max;
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
    function _tend(uint256 _totalIdle) internal override {}
    */

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    function _tendTrigger() internal view override returns (bool) {}
    */

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
    function _emergencyWithdraw(uint256 _amount) internal override {
        TODO: If desired implement simple logic to free deployed funds.

        EX:
            _amount = min(_amount, aToken.balanceOf(address(this)));
            _freeFunds(_amount);
    }

    */
}
