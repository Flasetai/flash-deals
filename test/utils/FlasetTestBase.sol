// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FlasetRegistry} from "../../src/FlasetRegistry.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

abstract contract FlasetTestBase is Test {
    FlasetRegistry internal registry;

    MockERC20 internal usdg; // settlement stablecoin stand-in, 6 decimals
    MockERC20 internal weth; // 18 decimals
    MockERC20 internal projectToken; // deal asset, 18 decimals

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");

    uint256 internal sellerKey = 0xA11CE;
    uint256 internal buyerKey = 0xB0B;
    address internal seller = vm.addr(sellerKey);
    address internal buyer = vm.addr(buyerKey);

    function setUp() public virtual {
        vm.warp(1_794_000_000); // 2026-11-06, near the live chain clock

        registry = new FlasetRegistry(admin);

        usdg = new MockERC20("FLASET Mock USDG", "mUSDG", 6);
        weth = new MockERC20("FLASET Mock WETH", "mWETH", 18);
        projectToken = new MockERC20("FLASET Mock Project", "mPRJ", 18);

        vm.startPrank(admin);
        registry.setTokenFlags(address(usdg), registry.SETTLEMENT());
        registry.setTokenFlags(address(weth), registry.CHECKOUT_SOURCE());
        registry.setTokenFlags(address(projectToken), registry.DEAL_ASSET());
        // Unit tests run uncapped; the cap tests set their own caps.
        registry.setTxCap(address(usdg), type(uint256).max);
        registry.setTxCap(address(weth), type(uint256).max);
        registry.setTxCap(address(projectToken), type(uint256).max);
        vm.stopPrank();
    }

    function _uncap(address token) internal {
        vm.prank(admin);
        registry.setTxCap(token, type(uint256).max);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
