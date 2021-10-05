pragma solidity 0.8.6;

abstract contract SAFEEngineLike {
    function approveSAFEModification(address) virtual external;
    function coinBalance(address) virtual public view returns (uint256);
}
abstract contract SystemCoinLike {
    function balanceOf(address) virtual public view returns (uint256);
    function transfer(address,uint256) virtual public returns (bool);
}
abstract contract CoinJoinLike {
    function systemCoin() virtual public view returns (address);
    function exit(address, uint256) virtual external;
}

contract CoinForwarder {
    // --- Variables ---
    // Address that receives forwarded funds
    address         public forwardedCoinReceiver;

    SAFEEngineLike  public safeEngine;
    SystemCoinLike  public systemCoin;
    CoinJoinLike    public coinJoin;

    constructor(
        address forwardedCoinReceiver_,
        address safeEngine_,
        address coinJoin_
    ) public {
        require(address(CoinJoinLike(coinJoin_).systemCoin()) != address(0), "CoinForwarder/null-system-coin");
        require(forwardedCoinReceiver_ != address(0), "CoinForwarder/null-forward-receiver");

        safeEngine            = SAFEEngineLike(safeEngine_);
        coinJoin              = CoinJoinLike(coinJoin_);
        systemCoin            = SystemCoinLike(coinJoin.systemCoin());
        forwardedCoinReceiver = forwardedCoinReceiver_;

        safeEngine.approveSAFEModification(coinJoin_);
    }

    // --- Internal Logic ---
    /**
     * @notice Exit all system coins to the ERC20 form
     */
    function exitAllCoins() internal {
        uint256 internalCoinBalance = safeEngine.coinBalance(address(this));
        coinJoin.exit(address(this), internalCoinBalance);
    }

    // --- Core Logic ---
    /**
     * @notice Forward all funds this contract has to forwardedCoinReceiver
     */
    function forwardCoins() external {
        exitAllCoins();
        systemCoin.transfer(forwardedCoinReceiver, systemCoin.balanceOf(address(this)));
    }
}
