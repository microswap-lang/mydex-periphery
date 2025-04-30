// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol'; // Use Uniswap V2 factory interface
import '@openzeppelin/contracts/utils/Address.sol';
import './interfaces/IPancakeRouter02.sol';
import './libraries/PancakeLibrary.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

contract PancakeRouter is IPancakeRouter02 {
    using Address for address payable;

    address public immutable override factory;
    address public immutable override WETH;
    address public immutable override usdtAddress;
    address public immutable override crumbsAddress;
    address public immutable protocolTreasury;
    address public owner;

    uint public usdtThreshold; // Configurable USDT threshold
    uint public crumbsThreshold; // Configurable CRUMBS threshold
    uint public feeBps; // Fee in basis points (e.g., 20 for 0.2%)

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'PancakeRouter: EXPIRED');
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, 'PancakeRouter: ONLY_OWNER');
        _;
    }

    constructor(
        address _factory,
        address _WETH,
        address _usdt,
        address _crumbs,
        address _treasury
    ) {
        factory = _factory;
        WETH = _WETH;
        usdtAddress = _usdt;
        crumbsAddress = _crumbs;
        protocolTreasury = _treasury;
        owner = msg.sender;
        usdtThreshold = 100 * 1e18; // 100 USDT (18 decimals)
        crumbsThreshold = 10000 * 1e18; // 10,000 CRUMBS
        feeBps = 20; // 0.2%
    }

    function setFeeParameters(
        uint _usdtThreshold,
        uint _crumbsThreshold,
        uint _feeBps
    ) external onlyOwner {
        require(_feeBps <= 100, 'PancakeRouter: FEE_TOO_HIGH'); // Cap at 1%
        usdtThreshold = _usdtThreshold;
        crumbsThreshold = _crumbsThreshold;
        feeBps = _feeBps;
    }

    function isFeeExempt(uint amountIn, address tokenIn, address user) public view returns (bool) {
        if (tokenIn == usdtAddress && amountIn <= usdtThreshold) {
            return true;
        }
        try IERC20(crumbsAddress).balanceOf(user) returns (uint crumbsBalance) {
            if (crumbsBalance >= crumbsThreshold) {
                return true;
            }
        } catch {
            // Handle potential malicious token
        }
        return false;
    }

    receive() external payable {
        assert(msg.sender == WETH); // Only accept ETH via WETH
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        (uint reserveA, uint reserveB) = PancakeLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = PancakeLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'PancakeRouter: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = PancakeLibrary.quote(amountBDesired, reserveB, reserveA);
                require(amountAOptimal <= amountADesired, 'PancakeRouter: INSUFFICIENT_A_AMOUNT');
                require(amountAOptimal >= amountAMin, 'PancakeRouter: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = PancakeLibrary.pairFor(factory, tokenA, tokenB);
        IERC20(tokenA).transferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).transferFrom(msg.sender, pair, amountB);
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = PancakeLibrary.pairFor(factory, token, WETH);
        IERC20(token).transferFrom(msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value: amountETH}();
        IWETH(WETH).transfer(pair, amountETH);
        liquidity = IUniswapV2Pair(pair).mint(to);
        if (msg.value > amountETH) payable(msg.sender).sendValue(msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = PancakeLibrary.pairFor(factory, tokenA, tokenB);
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        (address token0,) = PancakeLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'PancakeRouter: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'PancakeRouter: INSUFFICIENT_B_AMOUNT');
    }

    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        IERC20(token).transfer(to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        payable(to).sendValue(amountETH);
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint amountA, uint amountB) {
        address pair = PancakeLibrary.pairFor(factory, tokenA, tokenB);
        uint value = approveMax ? type(uint).max : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint amountToken, uint amountETH) {
        address pair = PancakeLibrary.pairFor(factory, token, WETH);
        uint value = approveMax ? type(uint).max : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        payable(to).sendValue(amountETH);
    }

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint amountETH) {
        address pair = PancakeLibrary.pairFor(factory, token, WETH);
        uint value = approveMax ? type(uint).max : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
    }

    // **** SWAP ****
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = PancakeLibrary.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (0, amountOut) : (amountOut, 0);
            address to = i < path.length - 2 ? PancakeLibrary.pairFor(factory, output, path[i + 2]) : _to;
            IUniswapV2Pair(PancakeLibrary.pairFor(factory, input, output)).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        bool feeExempt = isFeeExempt(amountIn, path[0], msg.sender);
        amounts = PancakeLibrary.getAmountsOut(factory, amountIn, path, feeExempt, feeBps);
        require(amounts[amounts.length - 1] >= amountOutMin, 'PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        if (!feeExempt) {
            uint protocolFee = amounts[0] * 5 / 10000; // 0.05%
            IERC20(path[0]).transferFrom(msg.sender, protocolTreasury, protocolFee);
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0] - protocolFee);
        } else {
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        }
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        bool feeExempt = isFeeExempt(amountInMax, path[0], msg.sender);
        amounts = PancakeLibrary.getAmountsIn(factory, amountOut, path, feeExempt, feeBps);
        require(amounts[0] <= amountInMax, 'PancakeRouter: EXCESSIVE_INPUT_AMOUNT');
        if (!feeExempt) {
            uint protocolFee = amounts[0] * 5 / 10000;
            IERC20(path[0]).transferFrom(msg.sender, protocolTreasury, protocolFee);
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0] - protocolFee);
        } else {
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        }
        _swap(amounts, path, to);
    }

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) returns (uint[] memory amounts) {
        require(path[0] == WETH, 'PancakeRouter: INVALID_PATH');
        bool feeExempt = isFeeExempt(msg.value, path[0], msg.sender);
        amounts = PancakeLibrary.getAmountsOut(factory, msg.value, path, feeExempt, feeBps);
        require(amounts[amounts.length - 1] >= amountOutMin, 'PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        if (!feeExempt) {
            uint protocolFee = amounts[0] * 5 / 10000;
            IWETH(WETH).transfer(protocolTreasury, protocolFee);
            IWETH(WETH).transfer(PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0] - protocolFee);
        } else {
            IWETH(WETH).transfer(PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        }
        _swap(amounts, path, to);
    }

    function swapTokensForExactETH(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        require(path[path.length - 1] == WETH, 'PancakeRouter: INVALID_PATH');
        bool feeExempt = isFeeExempt(amountInMax, path[0], msg.sender);
        amounts = PancakeLibrary.getAmountsIn(factory, amountOut, path, feeExempt, feeBps);
        require(amounts[0] <= amountInMax, 'PancakeRouter: EXCESSIVE_INPUT_AMOUNT');
        if (!feeExempt) {
            uint protocolFee = amounts[0] * 5 / 10000;
            IERC20(path[0]).transferFrom(msg.sender, protocolTreasury, protocolFee);
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0] - protocolFee);
        } else {
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        }
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        payable(to).sendValue(amounts[amounts.length - 1]);
    }

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        require(path[path.length - 1] == WETH, 'PancakeRouter: INVALID_PATH');
        bool feeExempt = isFeeExempt(amountIn, path[0], msg.sender);
        amounts = PancakeLibrary.getAmountsOut(factory, amountIn, path, feeExempt, feeBps);
        require(amounts[amounts.length - 1] >= amountOutMin, 'PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        if (!feeExempt) {
            uint protocolFee = amounts[0] * 5 / 10000;
            IERC20(path[0]).transferFrom(msg.sender, protocolTreasury, protocolFee);
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0] - protocolFee);
        } else {
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        }
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        payable(to).sendValue(amounts[amounts.length - 1]);
    }

    function swapETHForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) returns (uint[] memory amounts) {
        require(path[0] == WETH, 'PancakeRouter: INVALID_PATH');
        bool feeExempt = isFeeExempt(msg.value, path[0], msg.sender);
        amounts = PancakeLibrary.getAmountsIn(factory, amountOut, path, feeExempt, feeBps);
        require(amounts[0] <= msg.value, 'PancakeRouter: EXCESSIVE_INPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        if (!feeExempt) {
            uint protocolFee = amounts[0] * 5 / 10000;
            IWETH(WETH).transfer(protocolTreasury, protocolFee);
            IWETH(WETH).transfer(PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0] - protocolFee);
        } else {
            IWETH(WETH).transfer(PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        }
        _swap(amounts, path, to);
        if (msg.value > amounts[0]) payable(msg.sender).sendValue(msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = PancakeLibrary.sortTokens(input, output);
            IUniswapV2Pair pair = IUniswapV2Pair(PancakeLibrary.pairFor(factory, input, output));
            uint amountInput;
            uint amountOutput;
            {
                (uint reserve0, uint reserve1,) = pair.getReserves();
                (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
                amountInput = IERC20(input).balanceOf(address(pair)) - reserveInput;
                amountOutput = PancakeLibrary.getAmountOut(amountInput, reserveInput, reserveOutput, true, 0); // No fee for fee-on-transfer
            }
            (uint amount0Out, uint amount1Out) = input == token0 ? (0, amountOutput) : (amountOutput, 0);
            address to = i < path.length - 2 ? PancakeLibrary.pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        bool feeExempt = isFeeExempt(amountIn, path[0], msg.sender);
        if (!feeExempt) {
            uint protocolFee = amountIn * 5 / 10000;
            IERC20(path[0]).transferFrom(msg.sender, protocolTreasury, protocolFee);
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amountIn - protocolFee);
        } else {
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amountIn);
        }
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to) - balanceBefore >= amountOutMin,
            'PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) {
        require(path[0] == WETH, 'PancakeRouter: INVALID_PATH');
        uint amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        bool feeExempt = isFeeExempt(amountIn, path[0], msg.sender);
        if (!feeExempt) {
            uint protocolFee = amountIn * 5 / 10000;
            IWETH(WETH).transfer(protocolTreasury, protocolFee);
            IWETH(WETH).transfer(PancakeLibrary.pairFor(factory, path[0], path[1]), amountIn - protocolFee);
        } else {
            IWETH(WETH).transfer(PancakeLibrary.pairFor(factory, path[0], path[1]), amountIn);
        }
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to) - balanceBefore >= amountOutMin,
            'PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        require(path[path.length - 1] == WETH, 'PancakeRouter: INVALID_PATH');
        bool feeExempt = isFeeExempt(amountIn, path[0], msg.sender);
        if (!feeExempt) {
            uint protocolFee = amountIn * 5 / 10000;
            IERC20(path[0]).transferFrom(msg.sender, protocolTreasury, protocolFee);
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amountIn - protocolFee);
        } else {
            IERC20(path[0]).transferFrom(msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amountIn);
        }
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).withdraw(amountOut);
        payable(to).sendValue(amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return PancakeLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountOut)
    {
        return PancakeLibrary.getAmountOut(amountIn, reserveIn, reserveOut, true, 0);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountIn)
    {
        return PancakeLibrary.getAmountIn(amountOut, reserveIn, reserveOut, true, 0);
    }

    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return PancakeLibrary.getAmountsOut(factory, amountIn, path, isFeeExempt(amountIn, path[0], msg.sender), feeBps);
    }

    function getAmountsIn(uint amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return PancakeLibrary.getAmountsIn(factory, amountOut, path, isFeeExempt(0, path[0], msg.sender), feeBps);
    }
}
