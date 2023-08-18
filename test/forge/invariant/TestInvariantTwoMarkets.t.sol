// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "test/forge/InvariantBase.sol";

contract TwoMarketsInvariantTest is InvariantBaseTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketLib for Market;

    Irm internal irm2;
    Market public market2;
    Id public id2;

    function setUp() public virtual override {
        super.setUp();

        irm2 = new Irm(morpho);
        vm.label(address(irm2), "IRM2");

        market2 = Market(address(borrowableToken), address(collateralToken), address(oracle), address(irm2), LLTV + 1);
        id2 = market2.id();

        vm.startPrank(OWNER);
        morpho.enableIrm(address(irm2));
        morpho.enableLltv(LLTV + 1);
        morpho.createMarket(market2);
        vm.stopPrank();

        _targetDefaultSenders();

        _approveSendersTransfers(targetSenders());
        _supplyHighAmountOfCollateralForAllSenders(targetSenders(), market);
        _supplyHighAmountOfCollateralForAllSenders(targetSenders(), market2);

        // High price because of the 1e36 price scale
        oracle.setPrice(1e40);

        _weightSelector(this.setMarketFee.selector, 5);
        _weightSelector(this.supplyOnMorpho.selector, 20);
        _weightSelector(this.borrowOnMorpho.selector, 15);
        _weightSelector(this.repayOnMorpho.selector, 10);
        _weightSelector(this.withdrawOnMorpho.selector, 15);
        _weightSelector(this.supplyCollateralOnMorpho.selector, 20);
        _weightSelector(this.withdrawCollateralOnMorpho.selector, 15);
        _weightSelector(this.newBlock.selector, 10);

        blockNumber = block.number;
        timestamp = block.timestamp;

        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    function chooseMarket(bool changeMarket) internal view returns(Market memory chosenMarket, Id chosenId){
        if (!changeMarket) {
            chosenMarket = market;
            chosenId = id;
        } else {
            chosenMarket = market2;
            chosenId = id2;
        }
    }

    function setMarketFee(uint256 newFee) public {
        setCorrectBlock();

        newFee = bound(newFee, 0.1e18, MAX_FEE);

        vm.prank(OWNER);
        morpho.setFee(market, newFee);
    }

    function supplyOnMorpho(uint256 amount, bool changeMarket) public {
        setCorrectBlock();

        (Market memory chosenMarket,) = chooseMarket(changeMarket);

        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        borrowableToken.setBalance(msg.sender, amount);
        vm.prank(msg.sender);
        morpho.supply(chosenMarket, amount, 0, msg.sender, hex"");
    }

    function withdrawOnMorpho(uint256 amount, bool changeMarket) public {
        setCorrectBlock();
        morpho.accrueInterest(market);

        (Market memory chosenMarket, Id chosenId) = chooseMarket(changeMarket);

        uint256 availableLiquidity = morpho.totalSupply(chosenId) - morpho.totalBorrow(chosenId);
        if (morpho.supplyShares(chosenId, msg.sender) == 0) return;
        if (availableLiquidity == 0) return;

        morpho.accrueInterest(market);
        uint256 supplierBalance = morpho.supplyShares(chosenId, msg.sender).toAssetsDown(
            morpho.totalSupply(chosenId), morpho.totalSupplyShares(chosenId)
        );
        amount = bound(amount, 1, min(supplierBalance, availableLiquidity));

        vm.prank(msg.sender);
        morpho.withdraw(chosenMarket, amount, 0, msg.sender, msg.sender);
    }

    function borrowOnMorpho(uint256 amount, bool changeMarket) public {
        setCorrectBlock();
        morpho.accrueInterest(market);

        (Market memory chosenMarket, Id chosenId) = chooseMarket(changeMarket);

        uint256 availableLiquidity = morpho.totalSupply(chosenId) - morpho.totalBorrow(chosenId);
        if (availableLiquidity == 0) return;

        morpho.accrueInterest(market);
        amount = bound(amount, 1, availableLiquidity);

        vm.prank(msg.sender);
        morpho.borrow(chosenMarket, amount, 0, msg.sender, msg.sender);
    }

    function repayOnMorpho(uint256 amount, bool changeMarket) public {
        setCorrectBlock();
        morpho.accrueInterest(market);

        (Market memory chosenMarket, Id chosenId) = chooseMarket(changeMarket);

        if (morpho.borrowShares(chosenId, msg.sender) == 0) return;

        morpho.accrueInterest(market);
        amount = bound(
            amount,
            1,
            morpho.borrowShares(chosenId, msg.sender).toAssetsDown(
                morpho.totalBorrow(chosenId), morpho.totalBorrowShares(chosenId)
            )
        );

        borrowableToken.setBalance(msg.sender, amount);
        vm.prank(msg.sender);
        morpho.repay(chosenMarket, amount, 0, msg.sender, hex"");
    }

    function supplyCollateralOnMorpho(uint256 amount, bool changeMarket) public {
        setCorrectBlock();

        (Market memory chosenMarket,) = chooseMarket(changeMarket);

        amount = bound(amount, 1, MAX_TEST_AMOUNT);
        collateralToken.setBalance(msg.sender, amount);

        vm.prank(msg.sender);
        morpho.supplyCollateral(chosenMarket, amount, msg.sender, hex"");
    }

    function withdrawCollateralOnMorpho(uint256 amount, bool changeMarket) public {
        setCorrectBlock();
        morpho.accrueInterest(market);

        (Market memory chosenMarket,) = chooseMarket(changeMarket);

        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        vm.prank(msg.sender);
        morpho.withdrawCollateral(chosenMarket, amount, msg.sender, msg.sender);
    }

    function invariantMorphoBalance() public {
        uint256 marketAvailableAmount = morpho.totalSupply(id) - morpho.totalBorrow(id);
        uint256 market2AvailableAmount = morpho.totalSupply(id2) - morpho.totalBorrow(id2);
        assertEq(marketAvailableAmount + market2AvailableAmount, borrowableToken.balanceOf(address(morpho)));
    }
}
