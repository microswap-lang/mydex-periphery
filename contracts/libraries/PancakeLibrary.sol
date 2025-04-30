// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IPancakePair.sol";
import "./libraries/SafeMath.sol";

library PancakeLibrary {
    using SafeMath for uint256;

    // PancakeSwap V2 Pair init code hash (unchanged from PCS v2)
    bytes32 internal constant PAIR_INIT_CODE_HASH = 
        hex"00fb7f630766e6a796048ea87d01acd3068e8ff67e3d7ed8858e9d10f44dcf8f8";

    // Sorts token addresses to ensure deterministic ordering
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "PancakeLibrary: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "PancakeLibrary: ZERO_ADDRESS");
    }

    // Calculates the pair address using CREATE2 (no external calls)
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff",
            factory,
            keccak256(abi.encodePacked(token0, token1)),
            PAIR_INIT_CODE_HASH
        )))));
    }

    // Gets reserves from the pair, sorted to match token order
    function getReserves(address factory, address tokenA, address tokenB)
        internal view returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // Given an input amount and reserves, returns the max output accounting for optional fee
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        bool feeExempt,
        uint256 feeBps
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "PancakeLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "PancakeLibrary: INSUFFICIENT_LIQUIDITY");

        uint256 multiplier = feeExempt ? 10000 : (10000 - feeBps);
        uint256 amountInWithFee = amountIn.mul(multiplier);
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(10000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // Given an output amount and reserves, returns the required input accounting for optional fee
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        bool feeExempt,
        uint256 feeBps
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "PancakeLibrary: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "PancakeLibrary: INSUFFICIENT_LIQUIDITY");

        uint256 multiplier = feeExempt ? 10000 : (10000 - feeBps);
        uint256 numerator = reserveIn.mul(amountOut).mul(10000);
        uint256 denominator = (reserveOut.sub(amountOut)).mul(multiplier);
        amountIn = (numerator / denominator).add(1);
    }

    // Chained getAmountOut calls across path
    function getAmountsOut(
        address factory,
        uint256 amountIn,
        address[] memory path,
        bool feeExempt,
        uint256 feeBps
    ) internal view returns (uint256[] memory amounts) {
        require(path.length >= 2, "PancakeLibrary: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut, feeExempt, feeBps);
        }
    }

    // Chained getAmountIn calls across path
    function getAmountsIn(
        address factory,
        uint256 amountOut,
        address[] memory path,
        bool feeExempt,
        uint256 feeBps
    ) internal view returns (uint256[] memory amounts) {
        require(path.length >= 2, "PancakeLibrary: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut, feeExempt, feeBps);
        }
    }

    // Standard quote (no fee consideration)
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        require(amountA > 0, "PancakeLibrary: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "PancakeLibrary: INSUFFICIENT_LIQUIDITY");
        amountB = amountA.mul(reserveB) / reserveA;
    }
}
