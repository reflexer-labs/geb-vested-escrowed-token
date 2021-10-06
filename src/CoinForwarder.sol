pragma solidity 0.8.6;

abstract contract SAFEEngineLike {
    function approveSAFEModification(address) virtual external;
    function coinBalance(address) virtual public view returns (uint256);
}
abstract contract SystemCoinLike {
    function approve(address,uint256) virtual public view returns (bool);
    function balanceOf(address) virtual public view returns (uint256);
    function transfer(address,uint256) virtual public returns (bool);
}
abstract contract CoinJoinLike {
    function systemCoin() virtual public view returns (address);
    function exit(address, uint256) virtual external;
}
abstract contract veFeeDistributorLike {
    function burn(address _coin) virtual external returns (bool);
}

contract CoinForwarder {
    // --- Variables ---
    // Address that receives and distributes fees
    veFeeDistributorLike public feeDistributor;

    SAFEEngineLike       public safeEngine;
    SystemCoinLike       public systemCoin;
    CoinJoinLike         public coinJoin;

    constructor(
        address feeDistributor_,
        address safeEngine_,
        address coinJoin_
    ) public {
        require(address(CoinJoinLike(coinJoin_).systemCoin()) != address(0), "CoinForwarder/null-system-coin");
        require(feeDistributor_ != address(0), "CoinForwarder/null-fee-distributor");

        safeEngine     = SAFEEngineLike(safeEngine_);
        coinJoin       = CoinJoinLike(coinJoin_);
        systemCoin     = SystemCoinLike(coinJoin.systemCoin());
        feeDistributor = veFeeDistributorLike(feeDistributor_);

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
     * @notice Forward all funds this contract has to feeDistributor
     */
    function forwardCoins() external {
        exitAllCoins();
        if (systemCoin.balanceOf(address(this)) == 0) return;
        systemCoin.approve(address(feeDistributor), systemCoin.balanceOf(address(this)));
        feeDistributor.burn(address(systemCoin));
    }
}
