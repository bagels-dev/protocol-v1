
pragma solidity ^0.5.16;

import './public.sol';

contract MdxStrategyWithdrawMinimizeTrading is Ownable, ReentrancyGuard, Strategy {
    using SafeToken for address;
    using SafeMath for uint256;

    IMdexFactory public factory;
    IMdexRouter public router;
    address public wbnb;

    /// @dev Create a new withdraw minimize trading strategy instance for mdx.
    /// @param _router The mdx router smart contract.
    constructor(IMdexRouter _router) public {
        factory = IMdexFactory(_router.factory());
        router = _router;
        wbnb = _router.WBNB();
    }

    /// @dev Execute worker strategy. Take LP tokens. Return debt token + token want back.
    /// @param user User address to withdraw liquidity.
    /// @param borrowToken The token user borrow from bank.
    /// @param debt User's debt amount.
    /// @param data Extra calldata information passed along to this strategy.
    function execute(address user, address borrowToken, uint256 /* borrow */, uint256 debt, bytes calldata data)
        external
        payable
        nonReentrant
    {
        // 1. Find out lpToken and liquidity.
        // whichWantBack: 0:token0;1:token1;2:token what surplus.
        (address token0, address token1, uint whichWantBack) = abi.decode(data, (address, address, uint));

        // is borrowToken is BNB.
        bool isBorrowBNB = borrowToken == address(0);
        require(borrowToken == token0 || borrowToken == token1 || isBorrowBNB, "borrowToken not token0 and token1");
        // the relative token when token0 or token1 is bnb.
        address bnbRelative = address(0);
        {
            if (token0 == address(0)){
                token0 = wbnb;
                bnbRelative = token1;
            }
            if (token1 == address(0)){
                token1 = wbnb;
                bnbRelative = token0;
            }
        }
        address tokenUserWant = whichWantBack == uint(0) ? token0 : token1;

        IMdexPair lpToken = IMdexPair(factory.getPair(token0, token1));
        token0 = lpToken.token0();
        token1 = lpToken.token1();

        {
            lpToken.approve(address(router), uint256(-1));
            router.removeLiquidity(token0, token1, lpToken.balanceOf(address(this)), 0, 0, address(this), now);
        }
        {
            borrowToken = isBorrowBNB ? wbnb : borrowToken;
            address tokenRelative = borrowToken == token0 ? token1 : token0;

            swapIfNeed(borrowToken, tokenRelative, debt);

            if (isBorrowBNB) {
                IWBNB(wbnb).withdraw(debt);
                SafeToken.safeTransferETH(msg.sender, debt);
            } else {
                SafeToken.safeTransfer(borrowToken, msg.sender, debt);
            }
        }

        // 2. swap remaining token to what user want.
        if (whichWantBack != uint(2)) {
            address tokenAnother = tokenUserWant == token0 ? token1 : token0;
            uint256 anotherAmount = tokenAnother.myBalance();
            if(anotherAmount > 0){
                tokenAnother.safeApprove(address(router), 0);
                tokenAnother.safeApprove(address(router), uint256(-1));

                address[] memory path = new address[](2);
                path[0] = tokenAnother;
                path[1] = tokenUserWant;
                router.swapExactTokensForTokens(anotherAmount, 0, path, address(this), now);
            }
        }

        // 3. send all tokens back.
        if (bnbRelative == address(0)) {
            token0.safeTransfer(user, token0.myBalance());
            token1.safeTransfer(user, token1.myBalance());
        } else {
            safeUnWrapperAndAllSend(wbnb, user);
            safeUnWrapperAndAllSend(bnbRelative, user);
        }
    }

    /// swap if need.
    function swapIfNeed(address borrowToken, address tokenRelative, uint256 debt) internal {
        uint256 borrowTokenAmount = borrowToken.myBalance();
        if (debt > borrowTokenAmount) {
            tokenRelative.safeApprove(address(router), 0);
            tokenRelative.safeApprove(address(router), uint256(-1));

            uint256 remainingDebt = debt.sub(borrowTokenAmount);
            address[] memory path = new address[](2);
            path[0] = tokenRelative;
            path[1] = borrowToken;
            router.swapTokensForExactTokens(remainingDebt, tokenRelative.myBalance(), path, address(this), now);
        }
    }

    /// get token balance, if is WBNB un wrapper to BNB and send to 'to'
    function safeUnWrapperAndAllSend(address token, address to) internal {
        uint256 total = SafeToken.myBalance(token);
        if (total > 0) {
            if (token == wbnb) {
                IWBNB(wbnb).withdraw(total);
                SafeToken.safeTransferETH(to, total);
            } else {
                SafeToken.safeTransfer(token, to, total);
            }
        }
    }

    /// @dev Recover ERC20 tokens that were accidentally sent to this smart contract.
    /// @param token The token contract. Can be anything. This contract should not hold ERC20 tokens.
    /// @param to The address to send the tokens to.
    /// @param value The number of tokens to transfer to `to`.
    function recover(address token, address to, uint256 value) external onlyOwner nonReentrant {
        token.safeTransfer(to, value);
    }

    function() external payable {}
}
