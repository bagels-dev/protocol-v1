pragma solidity 0.5.16;

import './public.sol';

contract StrategyLiquidate is Ownable, ReentrancyGuard, LiqStrategy {
  using SafeToken for address;

  IMdexFactory public factory;
  IMdexRouter public router;
  address public wbnb;

  mapping(address => bool) public whitelistedTokens;

  /// @dev Create a new liquidate strategy instance.
  /// @param _router The Uniswap router smart contract.
  constructor(IMdexRouter _router) public {
    factory = IMdexFactory(_router.factory());
    router = _router;
    wbnb = _router.WBNB();
  }

  /// @dev Set whitelisted tokens
  /// @param tokens Token list to set whitelist status
  /// @param statuses Status list to set tokens to
  function setWhitelistTokens(address[] calldata tokens, bool[] calldata statuses)
    external
    onlyOwner
  {
    require(tokens.length == statuses.length, 'tokens & statuses length mismatched');
    for (uint idx = 0; idx < tokens.length; idx++) {
      whitelistedTokens[tokens[idx]] = statuses[idx];
    }
  }

  /// @dev Execute worker strategy. Take LP tokens. Return BNB.
  /// @param data Extra calldata information passed along to this strategy.
  function execute(
    address, /* user */
    uint, /* debt */
    bytes calldata data
  ) external payable nonReentrant {
    // 1. Find out what farming token we are dealing with.
    (address fToken, uint minBNB) = abi.decode(data, (address, uint));
    require(whitelistedTokens[fToken], 'token not whitelisted');
    IMdexPair lpToken = IMdexPair(factory.getPair(fToken, wbnb));
    // 2. Remove all liquidity back to BNB and farming tokens.
    lpToken.approve(address(router), uint(-1));
    router.removeLiquidityETH(fToken, lpToken.balanceOf(address(this)), 0, 0, address(this), now);
    // 3. Convert farming tokens to BNB.
    address[] memory path = new address[](2);
    path[0] = fToken;
    path[1] = wbnb;
    fToken.safeApprove(address(router), 0);
    fToken.safeApprove(address(router), uint(-1));
    router.swapExactTokensForETH(fToken.myBalance(), 0, path, address(this), now);
    // 4. Return all BNB back to the original caller.
    uint balance = address(this).balance;
    require(balance >= minBNB, 'insufficient BNB received');
    SafeToken.safeTransferETH(msg.sender, balance);
  }

  /// @dev Recover ERC20 tokens that were accidentally sent to this smart contract.
  /// @param token The token contract. Can be anything. This contract should not hold ERC20 tokens.
  /// @param to The address to send the tokens to.
  /// @param value The number of tokens to transfer to `to`.
  function recover(
    address token,
    address to,
    uint value
  ) external onlyOwner nonReentrant {
    token.safeTransfer(to, value);
  }

  function() external payable {}
}
