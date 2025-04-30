// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./interfaces/IPancakeFactory.sol";
import "./interfaces/IPancakePair.sol";
import "./libraries/PancakeLibrary.sol";
import "./interfaces/IWETH.sol";

contract PancakeRouter {
    using SafeMath for uint256;

    address public immutable factory;
    address public immutable WETH;
    address public immutable CRUMBS;
    address public immutable USDT;
    address public immutable treasury;

    uint256 public constant FEE_DENOMINATOR = 10000; // for basis points
    uint256 public constant LIQUIDITY_FEE = 15; // 0.15%
    uint256 public constant TREASURY_FEE = 5;   // 0.05%

    constructor(
        address _factory,
        address _WETH,
        address _CRUMBS,
        address _USDT,
        address _treasury
    ) {
        factory = _factory;
        WETH = _WETH;
        CRUMBS = _CRUMBS;
        USDT = _USDT;
        treasury = _treasury;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from WETH contract
    }

    // ===== FEE EXEMPTION CHECK =====

    function isFeeExempt(address user, uint256 usdtValue) public view returns (bool) {
        uint256 crumbsBalance = IERC20(CRUMBS).balanceOf(user);
        return (crumbsBalance >= 10_000 * 1e18) && (usdtValue < 100 * 1e18);
    }

    // ===== SWAP FUNCTION =====

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts) {
        require(block.timestamp <= deadline, "EXPIRED");

        // calculate USD value of swap
        uint256 usdtValue = estimateUSDTValue(amountIn, path);
        bool feeExempt = isFeeExempt(msg.sender, usdtValue);

        uint amountAfterFee = amountIn;

        if (!feeExempt) {
            uint liquidityFee = amountIn.mul(LIQUIDITY_FEE).div(FEE_DENOMINATOR);
            uint treasuryFee = amountIn.mul(TREASURY_FEE).div(FEE_DENOMINATOR);
            amountAfterFee = amountIn.sub(liquidityFee).sub(treasuryFee);

            // transfer fees
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), liquidityFee);
            IERC20(path[0]).transferFrom(msg.sender, treasury, treasuryFee);
        }

        amounts = PancakeLibrary.getAmountsOut(factory, amountAfterFee, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "INSUFFICIENT_OUTPUT");

        // main input transfer
        IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amountAfterFee);

        _swap(amounts, path, to);
    }

    function estimateUSDTValue(uint amountIn, address[] memory path) internal view returns (uint256 usdtValue) {
        if (path[0] == USDT) {
            return amountIn;
        }

        address ;
        route[0] = path[0];
        route[1] = USDT;

        uint[] memory out = PancakeLibrary.getAmountsOut(factory, amountIn, route);
        return out[1];
    }

    function _swap(
        uint[] memory amounts,
        address[] memory path,
        address _to
    ) internal {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = PancakeLibrary.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) =
                input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));

            address to = i < path.length - 2
                ? PancakeLibrary.pairFor(factory, output, path[i + 2])
                : _to;

            IPancakePair(PancakeLibrary.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }
}
