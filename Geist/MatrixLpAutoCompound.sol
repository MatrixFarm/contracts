// File: @openzeppelin/contracts/utils/Pausable.sol
import "./Ownable.sol";
import "./Pausable.sol";
import "./SafeERC20.sol";

pragma solidity ^0.6.0;

interface IUniswapRouterETH {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

pragma solidity ^0.6.0;

interface IUniswapV2Pair {
    function token0() external view returns (address);

    function token1() external view returns (address);
}

pragma solidity ^0.6.0;

interface IMasterChef {
    function pendingScare(uint256 _pid, address _user)
        external
        view
        returns (uint256);

    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function userInfo(uint256 _pid, address _user)
        external
        view
        returns (uint256, uint256);

    function emergencyWithdraw(uint256 _pid) external;
}

pragma solidity ^0.6.0;

contract MatrixLpAutoCompound is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // Matrix contracts
    address public vault;
    address public treasury;

    // Tokens used
    address public wrapped =
        address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public output;
    address public want;
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on
     * Current implementation separates 5% for fees. Can be changed through the constructor
     * Inputs in constructor should be ratios between the Fee and Max Fee, divisble into percents by 10000
     *
     * {callFee} - Percent of the totalFee reserved for the harvester (1000 = 10% of total fee: 0.5% by default)
     * {treasuryFee} - Percent of the totalFee taken by maintainers of the software (9000 = 90% of total fee: 4.5% by default)
     * {securityFee} - Fee taxed when a user withdraws funds. Taken to prevent flash deposit/harvest attacks.
     * These funds are redistributed to stakers in the pool.
     *
     * {totalFee} - divided by 10,000 to determine the % fee. Set to 5% by default and
     * lowered as necessary to provide users with the most competitive APY.
     *
     * {MAX_FEE} - Maximum fee allowed by the strategy. Hard-capped at 5%.
     * {PERCENT_DIVISOR} - Constant used to safely calculate the correct percentages.
     */

    uint256 public callFee = 1000;
    uint256 public treasuryFee = 9000;
    uint256 public securityFee = 10;
    uint256 public totalFee = 450;
    uint256 public constant MAX_FEE = 500;
    uint256 public constant PERCENT_DIVISOR = 10000;

    // Third party contracts
    address public unirouter;
    address public masterchef;
    uint256 public poolId;

    // Routes
    address[] public outputToWrappedRoute;
    address[] public outputToLp0Route;
    address[] public outputToLp1Route;
    address[] customPath;

    // Controllers
    bool public wrappedRoute = true;

    /**
     * {StratHarvest} Event that is fired each time someone harvests the strat.
     * {TotalFeeUpdated} Event that is fired each time the total fee is updated.
     * {CallFeeUpdated} Event that is fired each time the call fee is updated.
     */
    event StratHarvest(address indexed harvester);
    event TotalFeeUpdated(uint256 newFee);
    event CallFeeUpdated(uint256 newCallFee, uint256 newTreasuryFee);

    constructor(
        address _want,
        uint256 _poolId,
        address _masterChef,
        address _output,
        address _uniRouter,
        address _vault,
        address _treasury
    ) public {
        masterchef = _masterChef;
        unirouter = _uniRouter;
        want = _want;
        vault = _vault;
        treasury = _treasury;

        output = _output;
        outputToWrappedRoute = [output, wrapped];

        lpToken0 = IUniswapV2Pair(want).token0();
        lpToken1 = IUniswapV2Pair(want).token1();
        poolId = _poolId;

        if (lpToken0 == wrapped) {
            outputToLp0Route = [output, wrapped];
        } else if (lpToken0 != output) {
            outputToLp0Route = [output, wrapped, lpToken0];
        }

        if (lpToken1 == wrapped) {
            outputToLp1Route = [output, wrapped];
        } else if (lpToken1 != output) {
            outputToLp1Route = [output, wrapped, lpToken1];
        }

        _giveAllowances();
    }

    /**
     * @dev Function to synchronize balances before new user deposit.
     * Can be overridden in the strategy.
     */
    function beforeDeposit() external virtual {}

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        IMasterChef(masterchef).deposit(poolId, wantBal);
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 pairBal = IERC20(want).balanceOf(address(this));

        if (pairBal < _amount) {
            IMasterChef(masterchef).withdraw(poolId, _amount.sub(pairBal));
            pairBal = IERC20(want).balanceOf(address(this));
        }

        if (pairBal > _amount) {
            pairBal = _amount;
        }
        uint256 withdrawFee = pairBal.mul(securityFee).div(PERCENT_DIVISOR);
        IERC20(want).safeTransfer(vault, pairBal.sub(withdrawFee));
    }

    // compounds earnings and charges performance fee
    function harvest() external whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");

        IMasterChef(masterchef).deposit(poolId, 0);
        chargeFees();
        addLiquidity();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out fees from the rewards. Set by constructor
     * callFeeToUser is set as a percentage of the fee,
     * as is treasuryFeeToVault
     */
    function chargeFees() internal {
        uint256 toWftm = IERC20(output)
            .balanceOf(address(this))
            .mul(totalFee)
            .div(PERCENT_DIVISOR);
        IUniswapRouterETH(unirouter)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                toWftm,
                0,
                outputToWrappedRoute,
                address(this),
                now.add(600)
            );

        uint256 wftmBal = IERC20(wrapped).balanceOf(address(this));

        uint256 callFeeToUser = wftmBal.mul(callFee).div(PERCENT_DIVISOR);
        IERC20(wrapped).safeTransfer(msg.sender, callFeeToUser);

        uint256 treasuryFeeToVault = wftmBal.mul(treasuryFee).div(
            PERCENT_DIVISOR
        );
        IERC20(wrapped).safeTransfer(treasury, treasuryFeeToVault);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 outputHalf = IERC20(output).balanceOf(address(this)).div(2);

        if (lpToken0 != output) {
            if (wrappedRoute && lpToken0 != wrapped) {
                outputToLp0Route = [output, wrapped, lpToken0];
            } else {
                outputToLp0Route = [output, lpToken0];
            }

            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                outputHalf,
                0,
                outputToLp0Route,
                address(this),
                now
            );
        }

        if (lpToken1 != output) {
            if (wrappedRoute && lpToken1 != wrapped) {
                outputToLp1Route = [output, wrapped, lpToken1];
            } else {
                outputToLp1Route = [output, lpToken1];
            }

            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                outputHalf,
                0,
                outputToLp1Route,
                address(this),
                now
            );
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(
            lpToken0,
            lpToken1,
            lp0Bal,
            lp1Bal,
            1,
            1,
            address(this),
            now
        );
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(masterchef).userInfo(
            poolId,
            address(this)
        );
        return _amount;
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMasterChef(masterchef).emergencyWithdraw(poolId);

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyOwner {
        pause();
        IMasterChef(masterchef).emergencyWithdraw(poolId);
    }

    function pause() public onlyOwner {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyOwner {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(masterchef, uint256(-1));
        IERC20(output).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(masterchef, 0);
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    function setWrappedRoute(bool _bool) external onlyOwner {
        wrappedRoute = _bool;
    }

    // This function exists incase tokens that do not match the want of this strategy accrue.  For example: an amount of
    // tokens sent to this address in the form of an airdrop of a different token type.  This will allow us to convert
    // this token to the want-token of the strategy, allowing the amount to be paid out to stakers in the matching vault.
    function makeCustomTxn(
        address _fromToken,
        address _toToken,
        address _unirouter,
        uint256 _amount
    ) external onlyOwner {
        require(_fromToken != want, "cannot swap want token");
        approveTxnIfNeeded(_fromToken, _unirouter, _amount);

        customPath = [_fromToken, _toToken];

        IUniswapRouterETH(_unirouter).swapExactTokensForTokens(
            _amount,
            0,
            customPath,
            address(this),
            now.add(600)
        );
    }

    function approveTxnIfNeeded(
        address _token,
        address _unirouter,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _unirouter) < _amount) {
            IERC20(_token).safeApprove(_unirouter, uint256(0));
            IERC20(_token).safeApprove(_unirouter, uint256(-1));
        }
    }

    /**
     * @dev updates the total fee, capped at 5%
     */
    function updateTotalFee(uint256 _totalFee)
        external
        onlyOwner
        returns (bool)
    {
        require(_totalFee <= MAX_FEE, "Fee Too High");
        totalFee = _totalFee;
        emit TotalFeeUpdated(totalFee);
        return true;
    }

    /**
     * @dev updates the call fee and adjusts the treasury fee to cover the difference
     */
    function updateCallFee(uint256 _callFee) external onlyOwner returns (bool) {
        callFee = _callFee;
        treasuryFee = PERCENT_DIVISOR.sub(callFee);
        emit CallFeeUpdated(callFee, treasuryFee);
        return true;
    }

    function updateTreasury(address newTreasury)
        external
        onlyOwner
        returns (bool)
    {
        treasury = newTreasury;
        return true;
    }
}
