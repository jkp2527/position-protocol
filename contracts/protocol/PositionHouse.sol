pragma solidity ^0.8.0;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../interfaces/IPositionManager.sol";
import "./libraries/position/Position.sol";
import "hardhat/console.sol";
import "./PositionManager.sol";
import "./libraries/helpers/Quantity.sol";

contract PositionHouse is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable
{
    using Quantity for int256;
    using Quantity for int128;

    using Position for Position.Data;
    //    enum Side {LONG, SHORT}

    enum PnlCalcOption {
        TWAP,
        SPOT_PRICE,
        ORACLE
    }

    enum LimitOrderType {
        OPEN_LIMIT,
        CLOSE_LIMIT
    }

    struct PositionResp {

        Position.Data position;
        // NOTICE margin to vault can be negative
        int256 marginToVault;

        int256 realizedPnl;

        int256 unrealizedPnl;

        int256 exchangedPositionSize;

        uint256 exchangedQuoteAssetAmount;

        uint256 fundingPayment;

    }

    struct LimitOrderID {
        int128 pip;
        uint64 orderId;
        uint16 leverage;
        LimitOrderType typeLimitOrder;
        // TODO add blockNumber open create a new struct
        uint24 blockNumber;

    }

    struct LimitOrderPending {
        // TODO restruct data
        Position.Side side;
        int256 quantity;
        uint256 openNotional;
        uint256 pip;
        uint256 partialFilled;
        uint256 leverage;
        uint24 blockNumber;

    }

    // Mapping from position manager address of each pair to position data of each trader
    mapping(address => mapping(address => Position.Data)) public positionMap;


    //can update with index => no need delete array when close all
    mapping(address => mapping(address => LimitOrderID[])) public limitOrderMap;

    //    mapping(address => mapping(address => )  )

    uint256 maintenanceMarginRatio;
    uint256 maintenanceMarginRatioConst = 3;
    uint256 partialLiquidationRatio;
    uint256 partialLiquidationRatioConst = 80;
    uint256 liquidationFeeRatio;
    uint256 liquidationFeeRatioConst = 3;

    modifier whenNotPause(){
        //TODO implement
        _;
    }

    event OpenMarket(
        address trader,
        int256 quantity,
        Position.Side side,
        uint256 leverage,
        uint256 priceMarket,
        IPositionManager positionManager
    );
    event OpenLimit(
        uint64 orderId,
        address trader,
        int256 quantity,
        Position.Side side,
        uint256 leverage,
        int128 priceLimit,
        IPositionManager positionManager
    );

    event ChangeMaintenanceMarginRatio (
        uint256 newMaintenanceMarginRatio
    );

    event AddMargin(address trader, uint256 marginAdded, IPositionManager positionManager);

    event RemoveMargin(address trader, uint256 marginRemoved, IPositionManager positionManager);

    function initialize(
        uint256 _maintenanceMarginRatio
    ) public initializer {
        maintenanceMarginRatio = _maintenanceMarginRatio;

    }


    /**
    * @notice open position with price market
    * @param _positionManager IPositionManager address
    * @param _side Side of position LONG or SHORT
    * @param _quantity quantity of size after mul with leverage
    * @param _leverage leverage of position
    */
    function openMarketPosition(
        IPositionManager _positionManager,
        Position.Side _side,
        uint256 _quantity,
        uint256 _leverage
    ) public whenNotPause nonReentrant {
        //check input
        address _trader = _msgSender();
        //TODO check is new Position
        Position.Data memory oldPosition = getPosition(address(_positionManager), _trader);
        PositionResp memory positionResp;
        // check if old position quantity is same side with new
        if (oldPosition.quantity == 0 || oldPosition.side() == _side) {
            console.log("increasePosition ");
            positionResp = increasePosition(_positionManager, _side, int256(_quantity), _leverage);
        } else {
            console.log('open reverse');
            // TODO adjust old position
            positionResp = openReversePosition(_positionManager, _side, _side == Position.Side.LONG ? int256(_quantity) : - int256(_quantity), _leverage);

        }
        console.log("before update open market");
        // update position sate
        positionMap[address(_positionManager)][_trader].update(
            positionResp.position
        );

        // TODO transfer money from trader or pay margin + profit to trader

        if (positionResp.marginToVault > 0) {
            //TODO transfer from trader to vault
        } else if (positionResp.marginToVault < 0) {
            // TODO withdraw to user
        }

        emit OpenMarket(_trader, _side == Position.Side.LONG ? int256(_quantity) : - int256(_quantity), _side, _leverage, positionResp.exchangedQuoteAssetAmount / _quantity, _positionManager);
    }


    /**
    * @notice open position with price limit
    * @param _positionManager IPositionManager address
    * @param _side Side of position LONG or SHORT
    * @param _quantity quantity of size after mul with leverage
    * @param _pip is pip converted from limit price of position
    * @param _leverage leverage of position
    * @param isOpenLimitOrder type openLimit, OPEN or CLOSE
    */
    function openLimitOrder(
        IPositionManager _positionManager,
        Position.Side _side,
        uint256 _quantity,
        int128 _pip,
        uint256 _leverage,
        bool isOpenLimitOrder
    ) public whenNotPause nonReentrant {
        address _trader = _msgSender();
        uint64 _orderId = _positionManager.openLimitPosition(_pip, int256(_quantity).abs128(), _side == Position.Side.LONG ? true : false);

        limitOrderMap[address(_positionManager)][_trader].push(LimitOrderID({
        pip : _pip,
        orderId : _orderId,
        leverage : uint16(_leverage),
        typeLimitOrder : isOpenLimitOrder ? LimitOrderType.OPEN_LIMIT : LimitOrderType.CLOSE_LIMIT,
        blockNumber : 0
        }));

        emit OpenLimit(_orderId, _trader, _side == Position.Side.LONG ? int256(_quantity) : - int256(_quantity), _side, _leverage, _pip, _positionManager);
        // TODO transfer money from trader
    }

    function cancelLimitOrder(IPositionManager _positionManager, int128 pip, uint64 orderId) external {
        _positionManager.cancelLimitOrder(pip, orderId);
        // TODO send back margin to trader
    }


    /**
    * @notice close position with close market
    * @param _positionManager IPositionManager address
    */
    function closePosition(
        IPositionManager _positionManager
    // IMPORTANT update amount quantity want to close (can be 50%, 75%...)
    ) public {

        // check conditions
        requirePositionManager(_positionManager, true);

        address _trader = _msgSender();
        Position.Data memory positionData = getPosition(address(_positionManager), _trader);

        uint256 oldPositionLeverage = positionData.openNotional / positionData.margin;
        PositionResp memory positionResp;
        if (positionData.quantity > 0) {
            openMarketPosition(_positionManager, Position.Side.SHORT, uint256(positionData.quantity), oldPositionLeverage);
        } else {
            openMarketPosition(_positionManager, Position.Side.LONG, uint256(- positionData.quantity), oldPositionLeverage);
        }

    }


    /**
    * @notice close position with close market
    * @param _positionManager IPositionManager address
    * @param _pip limit price want to close
    * @param _quantity want to close
    */
    function closeLimitPosition(IPositionManager _positionManager, int128 _pip, uint256 _quantity) public {

        // check conditions
        requirePositionManager(_positionManager, true);

        address _trader = _msgSender();
        Position.Data memory positionData = getPosition(address(_positionManager), _trader);

        uint256 oldPositionLeverage = positionData.openNotional / positionData.margin;

        if (positionData.quantity > 0) {

            openLimitOrder(_positionManager, Position.Side.SHORT, _quantity, _pip, oldPositionLeverage, false);

        } else {
            openLimitOrder(_positionManager, Position.Side.LONG, _quantity, _pip, oldPositionLeverage, false);

        }
    }

    function claimFund(IPositionManager _positionManager) public {

        address _trader = _msgSender();

        (bool canClaim,int256 amount) = canClaimFund(_positionManager, _trader);

        if (canClaim) {

            // TODO transfer amount fund back to _trader and clean limitOrderMap of _trader

            //TODO check the case close limit partial, should we delete the limit order have been closed

            Position.Data memory positionData = getPosition(address(_positionManager), _trader);

            // ensure no has order any more => after
            if (positionData.quantity == 0) {
                clearPosition(_positionManager, _trader);
            }
        }
    }

    function canClaimFund(IPositionManager _positionManager, address _trader) public view returns (bool canClaim, int256 amount){


        LimitOrderID[] memory listLimitOrder = limitOrderMap[address(_positionManager)][_trader];

        Position.Data memory positionData = getPositionWithoutCloseLimitOrder(address(_positionManager), _trader);
        for (uint i = 0; i < listLimitOrder.length; i ++) {
            (bool isFilled, bool isBuy, uint256 quantity, uint256 partialFilled) = _positionManager.getPendingOrderDetail(listLimitOrder[i].pip, listLimitOrder[i].orderId);
            if (listLimitOrder[i].typeLimitOrder == LimitOrderType.CLOSE_LIMIT && partialFilled > 0) {
                console.log("can claim fund partially filled", partialFilled);
                (amount, positionData) = _calcRealPnL(_positionManager, positionData, partialFilled, listLimitOrder[i].pip, amount);
            } else if (listLimitOrder[i].typeLimitOrder == LimitOrderType.CLOSE_LIMIT && isFilled == true) {
                (amount, positionData) = _calcRealPnL(_positionManager, positionData, quantity, listLimitOrder[i].pip, amount);
            }
        }
        return amount > 0 ? (true, amount) : (false, 0);
    }


    function sumQuantityLimitOrder(IPositionManager _positionManager, address _trader) public view returns (int256 _sumQuantity){

        LimitOrderID[] memory listLimitOrder = limitOrderMap[address(_positionManager)][_trader];

        for (uint i = 0; i < listLimitOrder.length; i ++) {
            (bool isFilled, bool isBuy, uint256 quantity, uint256 partialFilled) = _positionManager.getPendingOrderDetail(listLimitOrder[i].pip, listLimitOrder[i].orderId);

            if (isFilled) {
                _sumQuantity += isBuy ? int256(quantity) : - int256(quantity);
            } else if (!isFilled && partialFilled != 0) {
                _sumQuantity += isBuy ? int256(partialFilled) : - int256(partialFilled);
            }

        }
        return _sumQuantity;
    }

    /**
     * @notice liquidate trader's underwater position. Require trader's margin ratio more than partial liquidation ratio
     * @dev liquidator can NOT open any positions in the same block to prevent from price manipulation.
     * @param _positionManager positionManager address
     * @param _trader trader address
     */
    function liquidate(
        IPositionManager _positionManager,
        address _trader
    ) external {
        requirePositionManager(_positionManager, true);
        (uint256 maintenanceMargin, int256 marginBalance, uint256 marginRatio) = getMaintenanceDetail(_positionManager, _trader);

        // TODO before liquidate should we check can claimFund, because trader has close position limit before liquidate

        // require trader's margin ratio higher than partial liquidation ratio
        requireMoreMarginRatio(marginRatio);

        PositionResp memory positionResp;
        uint256 liquidationPenalty;
        {
            uint256 feeToLiquidator;
            uint256 feeToInsuranceFund;
            // partially liquidate position
            if (marginRatio >= partialLiquidationRatio && marginRatio < 100) {
                console.log("start partial liquidate");
                Position.Data memory positionData = getPosition(address(_positionManager), _trader);
                // TODO define rate of liquidationPenalty
                // calculate amount quantity of position to reduce
                int256 partiallyLiquidateQuantity = positionData.quantity * 20 / 100;
                uint256 oldPositionLeverage = positionData.openNotional / positionData.margin;
                // partially liquidate position by reduce position's quantity
                if (positionData.quantity > 0) {
                    positionResp = partialLiquidate(_positionManager, Position.Side.SHORT, - partiallyLiquidateQuantity, oldPositionLeverage, _trader);
                } else {
                    positionResp = partialLiquidate(_positionManager, Position.Side.LONG, - partiallyLiquidateQuantity, oldPositionLeverage, _trader);
                }

                // half of the liquidationFee goes to liquidator & another half goes to insurance fund
                liquidationPenalty = uint256(- positionResp.marginToVault);
                feeToLiquidator = liquidationPenalty / 2;
                feeToInsuranceFund = liquidationPenalty - feeToLiquidator;
                // update position after reduce quantity and take liquidation fee
                positionMap[address(_positionManager)][_trader].update(
                    positionResp.position
                );
            } else {
                // fully liquidate trader's position
                liquidationPenalty = getPosition(address(_positionManager), _trader).margin;
                clearPosition(_positionManager, _trader);
                feeToLiquidator = liquidationPenalty * liquidationFeeRatioConst / 100;
            }

            // count as bad debt, transfer money to insurance fund and liquidator
            // emit event position liquidated
        }

        // emit event
    }



    /**
     * @notice add margin to decrease margin ratio
     * @param _positionManager IPositionManager address
     * @param _marginAdded added margin
     */
    function addMargin(IPositionManager _positionManager, uint256 _marginAdded) external {

        address _trader = _msgSender();
        Position.Data memory positionData = getPosition(address(_positionManager), _trader);
        positionData.margin = positionData.margin + _positionManager.calcAdjustMargin(_marginAdded);

        positionMap[address(_positionManager)][_trader].update(
            positionData
        );

        // TODO transfer money from trader to protocol


        emit AddMargin(_trader, _marginAdded, _positionManager);

    }


    /**
     * @notice add margin to increase margin ratio
     * @param _positionManager IPositionManager address
     * @param _marginRemoved added margin
     */
    function removeMargin(IPositionManager _positionManager, uint256 _marginRemoved) external {

        address _trader = _msgSender();

        Position.Data memory positionData = getPosition(address(_positionManager), _trader);

        _marginRemoved = _positionManager.calcAdjustMargin(_marginRemoved);
        require(positionData.margin > _marginRemoved, "Margin remove not than old margin");
        (uint256 remainMargin,,) =
        calcRemainMarginWithFundingPayment(positionData.margin, int256(positionData.margin - _marginRemoved));

        positionData.margin = remainMargin;

        positionMap[address(_positionManager)][_trader].update(
            positionData
        );


        // TODO transfer money back to trader

    }

    /**
     * @notice clear all attribute of
     * @param _positionManager IPositionManager address
     * @param _trader address to clean position
     */
    // IMPORTANT UPDATE CLEAR LIMIT ORDER
    function clearPosition(IPositionManager _positionManager, address _trader) internal {
        positionMap[address(_positionManager)][_trader].clear();

        if (limitOrderMap[address(_positionManager)][_trader].length > 0) {
            delete limitOrderMap[address(_positionManager)][_trader];
        }

    }

    function increasePosition(
        IPositionManager _positionManager,
        Position.Side _side,
        int256 _quantity,
        uint256 _leverage
    ) public returns (PositionResp memory positionResp) {
        address _trader = _msgSender();
        Position.Data memory oldPosition = getPosition(address(_positionManager), _trader);
        positionResp.exchangedPositionSize = openMarketOrder(_positionManager, _quantity.abs(), _side);
        if (positionResp.exchangedPositionSize != 0) {
            // NOTICE _newSize from uint256 to int256
            int256 _newSize = oldPosition.quantity + positionResp.exchangedPositionSize - oldPosition.sumQuantityLimitOrder;
            uint256 _currentPrice = _positionManager.getPrice();
            uint256 increaseMarginRequirement = (_quantity).abs() * _currentPrice / _leverage;
            console.log(' increaseMarginRequirement : ', increaseMarginRequirement);
            // TODO update function latestCumulativePremiumFraction
            (uint256 remainMargin, uint256 fundingPayment, uint256 latestCumulativePremiumFraction) =
            calcRemainMarginWithFundingPayment(oldPosition.margin, int256(oldPosition.margin + increaseMarginRequirement));

            (, int256 unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);

            // update positionResp
            positionResp.exchangedQuoteAssetAmount = (_quantity).abs() * _currentPrice;
            positionResp.unrealizedPnl = unrealizedPnl;
            positionResp.realizedPnl = 0;
            positionResp.marginToVault = int256(increaseMarginRequirement);
            positionResp.fundingPayment = fundingPayment;
            positionResp.position = Position.Data(
                _newSize,
                0,
                remainMargin,
                oldPosition.openNotional + positionResp.exchangedQuoteAssetAmount,
                latestCumulativePremiumFraction,
                block.number
            );
        }
    }

    function openReversePosition(
        IPositionManager _positionManager,
        Position.Side _side,
        int256 _quantity,
        uint256 _leverage
    ) internal returns (PositionResp memory positionResp) {

        address _trader = _msgSender();
        PositionResp memory positionResp;
        // TODO calc pnl before check margin to open reverse
        Position.Data memory oldPosition = getPosition(address(_positionManager), _trader);
        console.log("quantity of old position", oldPosition.quantity.abs());
        // margin required to reduce
        console.log("open reverse position _quantity ", _quantity.abs());
        console.log("open reverse position oldPosition.quantity", oldPosition.quantity.abs());


        if (_quantity.abs() < oldPosition.quantity.abs()) {
            console.log("reduce margin requirement");
            uint256 reduceMarginRequirement = oldPosition.margin * _quantity.abs() / oldPosition.quantity.abs();
            // reduce old position only
            positionResp.exchangedPositionSize = openMarketOrder(_positionManager, _quantity.abs(), _side);

            oldPosition = getPosition(address(_positionManager), _trader);

            console.log("get entry price");
            uint256 _entryPrice = oldPosition.getEntryPrice();
            console.log("get position notional and unrealized pnl");
            (, int256 unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);
            positionResp.realizedPnl = unrealizedPnl * int256(positionResp.exchangedPositionSize) / oldPosition.quantity;
            // update old position
            (uint256 remainMargin, uint256 fundingPayment, uint256 latestCumulativePremiumFraction) =
            calcRemainMarginWithFundingPayment(oldPosition.margin, int256(oldPosition.margin - reduceMarginRequirement));

            // _entryPrice =
            positionResp.exchangedQuoteAssetAmount = _quantity.abs() * _entryPrice;
            positionResp.fundingPayment = fundingPayment;
            // NOTICE margin to vault can be negative
            positionResp.marginToVault = - (int256(reduceMarginRequirement) + positionResp.realizedPnl);

            console.log("old quantity | margin ", uint256(oldPosition.quantity), remainMargin);


            console.log("new quantity | _quantity open", uint256(oldPosition.quantity + _quantity), uint256(- _quantity));

            console.log("oldPosition.sumQuantityLimitOrder", uint256(- oldPosition.sumQuantityLimitOrder));


            // NOTICE calc unrealizedPnl after open reverse
            positionResp.unrealizedPnl = unrealizedPnl - positionResp.realizedPnl;
            positionResp.position = Position.Data(
                oldPosition.quantity + _quantity - oldPosition.sumQuantityLimitOrder,
                0,
                remainMargin,
                oldPosition.openNotional - _quantity.abs() * _entryPrice,
                0,
                0
            );
            return positionResp;
        }
        //        }
        // if new position is larger then close old and open new
        return closeAndOpenReversePosition(_positionManager, _side, _quantity, _leverage);
    }

    function closeAndOpenReversePosition(
        IPositionManager _positionManager,
        Position.Side _side,
        int256 _quantity,
        uint256 _leverage
    ) internal returns (PositionResp memory positionResp) {
        address _trader = _msgSender();
        // TODO change to TWAP
        PositionResp memory closePositionResp = internalClosePosition(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);
        uint256 _currentPrice = _positionManager.getPrice();
        uint256 openNotional = _quantity.abs() * _currentPrice - closePositionResp.exchangedQuoteAssetAmount;
        // if remain exchangedQuoteAssetAmount is too small (eg. 1wei) then the required margin might be 0
        // then the positionHouse will stop opening position
        if (openNotional < _leverage) {
            positionResp = closePositionResp;
        } else {

            //            int256 _quantityConverted = _side == Position.Side.SHORT ? - int256(openNotional / _currentPrice) : int256(openNotional / _currentPrice);
            PositionResp memory increasePositionResp = increasePosition(_positionManager, _side, _quantity - closePositionResp.exchangedPositionSize, _leverage);
            positionResp = PositionResp({
            // IMPORTANT update positionResp include closePositionResp
            position : increasePositionResp.position,
            exchangedQuoteAssetAmount : closePositionResp.exchangedQuoteAssetAmount + increasePositionResp.exchangedQuoteAssetAmount,
            fundingPayment : closePositionResp.fundingPayment + increasePositionResp.fundingPayment,
            exchangedPositionSize : closePositionResp.exchangedPositionSize + increasePositionResp.exchangedPositionSize,
            realizedPnl : closePositionResp.realizedPnl + increasePositionResp.realizedPnl,
            unrealizedPnl : 0,
            marginToVault : closePositionResp.marginToVault + increasePositionResp.marginToVault
            });
        }
        return positionResp;
    }

    function internalClosePosition(
        IPositionManager _positionManager,
        address _trader,
        PnlCalcOption _pnlCalcOption
    ) internal returns (PositionResp memory positionResp) {
        Position.Data memory oldPosition = getPosition(address(_positionManager), _trader);
        requirePositionSize(oldPosition.quantity);
        if (oldPosition.quantity > 0) {
            // sell
            positionResp.exchangedPositionSize = openMarketOrder(_positionManager, oldPosition.quantity.abs(), Position.Side.SHORT);
        } else {
            // buy
            positionResp.exchangedPositionSize = openMarketOrder(_positionManager, oldPosition.quantity.abs(), Position.Side.LONG);
        }

        uint256 _currentPrice = _positionManager.getPrice();
        (, int256 unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(_positionManager, _trader, _pnlCalcOption);
        (
        uint256 remainMargin,
        uint256 fundingPayment,
        uint256 latestCumulativePremiumFraction
        ) = calcRemainMarginWithFundingPayment(oldPosition.margin, unrealizedPnl);

        positionResp.realizedPnl = unrealizedPnl;
        positionResp.fundingPayment = fundingPayment;
        // NOTICE remainMargin can be negative
        positionResp.marginToVault = int256(remainMargin);
        positionResp.unrealizedPnl = 0;
        positionResp.exchangedQuoteAssetAmount = oldPosition.quantity.abs() * _currentPrice;
        clearPosition(_positionManager, _trader);
    }

    // TODO add size limit position when trader has limit order

    function getPendingOrder(
        IPositionManager positionManager,
        int128 pip,
        uint256 orderId
    ) public view returns (
        bool isFilled,
        bool isBuy,
        uint256 size,
        uint256 partialFilled
    ){
        // TODO replace with pending position
        return positionManager.getPendingOrderDetail(pip, uint64(orderId));
    }


    function getListOrderPending(IPositionManager _positionManager) public view returns (LimitOrderPending[] memory listPendingPositionData){
        address _trader = _msgSender();
        LimitOrderID[] memory listLimitOrder = limitOrderMap[address(_positionManager)][_trader];


        uint index = 0;
        for (uint i = 0; i < listLimitOrder.length; i++) {

            (bool isFilled, bool isBuy,
            uint256 quantity, uint256 partialFilled) = _positionManager.getPendingOrderDetail(listLimitOrder[i].pip, listLimitOrder[i].orderId);
            if (!isFilled) {

                listPendingPositionData[index] = LimitOrderPending({
                side : isBuy ? Position.Side.LONG : Position.Side.SHORT,
                quantity : int256(quantity),
                openNotional : quantity * _positionManager.pipToPrice(listLimitOrder[i].pip),
                pip : _positionManager.pipToPrice(listLimitOrder[i].pip),
                partialFilled : partialFilled,
                leverage : listLimitOrder[i].leverage,
                blockNumber : listLimitOrder[i].blockNumber
                });
                index++;
            }

        }

    }

    function getPosition(
        address positionManager,
        address _trader
    ) public view returns (Position.Data memory positionData){
        positionData = positionMap[positionManager][_trader];
        int256 quantityMarket = positionData.quantity;
        LimitOrderID[] memory listLimitOrder = limitOrderMap[positionManager][_trader];
        IPositionManager _positionManager = IPositionManager(positionManager);
        console.log("limit order length", listLimitOrder.length);
        for (uint i = 0; i < listLimitOrder.length; i++) {
            positionData = _accumulateLimitOrderToPositionData(_positionManager, listLimitOrder[i], positionData);
        }
        console.log("positionData.quantity ", uint256(positionData.quantity));
        console.log("quantityMarket ", uint256(quantityMarket));

        positionData.sumQuantityLimitOrder = positionData.quantity - quantityMarket;
    }

    function getPositionIncludePending(
        address positionManager,
        address _trader
    ) public view returns (Position.Data memory positionData){
        positionData = positionMap[positionManager][_trader];
        int256 quantityMarket = positionData.quantity;
        LimitOrderID[] memory listLimitOrder = limitOrderMap[positionManager][_trader];
        IPositionManager _positionManager = IPositionManager(positionManager);
        console.log("limit order length", listLimitOrder.length);
        for (uint i = 0; i < listLimitOrder.length; i++) {
            positionData = _accumulateLimitOrderToPositionData(_positionManager, listLimitOrder[i], positionData);
        }
        console.log("positionData.quantity ", uint256(positionData.quantity));
        console.log("quantityMarket ", uint256(quantityMarket));

        positionData.sumQuantityLimitOrder = positionData.quantity - quantityMarket;
    }


    function getPositionNotionalAndUnrealizedPnl(
        IPositionManager positionManager,
        address _trader,
        PnlCalcOption _pnlCalcOption
    ) public view returns
    (
        uint256 positionNotional,
        int256 unrealizedPnl
    ){
        Position.Data memory position = getPosition(address(positionManager), _trader);
        uint256 oldPositionNotional = position.openNotional;
        if (_pnlCalcOption == PnlCalcOption.TWAP) {
            // TODO get twap price
        } else if (_pnlCalcOption == PnlCalcOption.SPOT_PRICE) {
            positionNotional = positionManager.getPrice() * position.quantity.abs();
        } else {
            // TODO get oracle price
        }
        if (position.side() == Position.Side.LONG) {
            unrealizedPnl = int256(positionNotional) - int256(oldPositionNotional);
        } else {
            unrealizedPnl = int256(oldPositionNotional) - int256(positionNotional);
        }

    }

    function getLiquidationPrice(
        IPositionManager positionManager,
        address _trader,
        PnlCalcOption _pnlCalcOption
    ) public view returns (uint256 liquidationPrice){
        Position.Data memory positionData = getPosition(address(positionManager), _trader);
        (uint256 maintenanceMargin,,) = getMaintenanceDetail(positionManager, _trader);
        // NOTICE get maintenance margin of positionManager
        // calculate marginBalance = initialMargin + unrealizedPnl
        // maintenanceMargin = initialMargin * maintenanceMarginRatio
        // if maintenanceMargin / marginBalance = 100% then the position will be liquidate
        if (positionData.side() == Position.Side.LONG) {
            // int256(positionNotional) - int256(oldPositionNotional) = positionData.margin * maintenanceMarginRatioConst - positionData.margin
            //  => positionData.quantity * liquidatePrice - positionData.openNotional = positionData.margin * maintenanceMarginRatioConst - positionData.margin
            liquidationPrice = (maintenanceMargin - positionData.margin + positionData.openNotional) / positionData.quantity.abs();
        } else {
            // int256(oldPositionNotional) - int256(positionNotional) = positionData.margin * maintenanceMarginRatioConst - positionData.margin
            // => positionData.openNotional - positionData.quantity * liquidatePrice = positionData.margin * maintenanceMarginRatioConst - positionData.margin
            liquidationPrice = (positionData.openNotional - maintenanceMargin + positionData.margin) / positionData.quantity.abs();
        }
    }

    /**
     * @notice get all information to maintaining position
     * @param _positionManager positionManager address
     * @param _trader trader address
     */
    function getMaintenanceDetail(
        IPositionManager _positionManager,
        address _trader
    ) public view returns (uint256 maintenanceMargin, int256 marginBalance, uint256 marginRatio) {
        Position.Data memory positionData = getPosition(address(_positionManager), _trader);
        // TODO update maintenanceMarginRatioConst
        console.log("get maintenance detail", positionData.margin);
        maintenanceMargin = positionData.margin * maintenanceMarginRatioConst / 100;
        (, int256 unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);
        marginBalance = int256(positionData.margin) + unrealizedPnl;
        if (marginBalance <= 0) {
            marginRatio = 100;
        } else {
            marginRatio = maintenanceMargin * 100 / uint256(marginBalance);
        }

    }


    //
    // REQUIRE FUNCTIONS
    //

    function requirePositionManager(
        IPositionManager positionManager,
        bool open
    ) private view {

    }

    // TODO define criteria
    function requireMoreMarginRatio(uint256 _marginRatio) private view {
        require(_marginRatio >= 80, "Margin ratio not meet criteria");
    }

    function requirePositionSize(
        int256 _quantity
    ) private pure {
        require(_quantity != 0, "positionSize is 0");
    }


    function changeMaintenanceMarginRatio(uint256 newMaintenanceMarginRatio) external initializer {
        maintenanceMarginRatio = newMaintenanceMarginRatio;
        emit ChangeMaintenanceMarginRatio(newMaintenanceMarginRatio);
    }


    //
    // INTERNAL FUNCTION OF POSITION HOUSE
    //

    function openMarketOrder(
        IPositionManager _positionManager,
        uint256 _quantity,
        Position.Side _side
    ) internal returns (int256 exchangedQuantity){
        uint256 exchangedSize = _positionManager.openMarketPosition(_quantity, _side == Position.Side.LONG);
        require(exchangedSize == _quantity, "not enough liquidity to fulfill order");
        exchangedQuantity = _side == Position.Side.LONG ? int256(exchangedSize) : - int256(exchangedSize);


    }

    function isNewPosition(
        IPositionManager _positionManager,
        address _trader
    ) internal view returns (bool) {
        return positionMap[address(_positionManager)][_trader].quantity != 0;
    }

    function calcRemainMarginWithFundingPayment(
        uint256 oldPositionMargin, int256 deltaMargin
    ) internal view returns (uint256 remainMargin, uint256 fundingPayment, uint256 latestCumulativePremiumFraction){

        remainMargin = uint256(deltaMargin);
        fundingPayment = 0;
        latestCumulativePremiumFraction = 0;
    }

    function partialLiquidate(
        IPositionManager _positionManager,
        Position.Side _side,
        int256 _quantity,
        uint256 _leverage,
        address _trader
    ) internal returns (PositionResp memory positionResp){
        Position.Data memory oldPosition = getPosition(address(_positionManager), _trader);
        positionResp.exchangedPositionSize = openMarketOrder(_positionManager, _quantity.abs(), _side);
        uint256 _entryPrice = oldPosition.getEntryPrice();
        (, int256 unrealizedPnl) = getPositionNotionalAndUnrealizedPnl(_positionManager, _trader, PnlCalcOption.SPOT_PRICE);
        positionResp.realizedPnl = 0;
        uint256 remainMargin = oldPosition.margin * (100 - liquidationFeeRatioConst) / 100;
        positionResp.exchangedQuoteAssetAmount = _quantity.abs() * _entryPrice;
        positionResp.fundingPayment = 0;
        positionResp.marginToVault = int256(remainMargin) - int256(oldPosition.margin);
        positionResp.unrealizedPnl = unrealizedPnl;
        positionResp.position = Position.Data(
        // from oldPosition.quantity - _quantity to +
            oldPosition.quantity + _quantity,
            0,
            remainMargin,
            oldPosition.openNotional - _quantity.abs() * _entryPrice,
            0,
            0
        );
        return positionResp;
    }

    function getPositionWithoutCloseLimitOrder(
        address positionManager,
        address _trader
    ) internal view returns (Position.Data memory positionData){
        positionData = positionMap[positionManager][_trader];
        LimitOrderID[] memory listLimitOrder = limitOrderMap[positionManager][_trader];
        IPositionManager _positionManager = IPositionManager(positionManager);
        for (uint i = 0; i < listLimitOrder.length; i++) {
            if (listLimitOrder[i].typeLimitOrder == LimitOrderType.OPEN_LIMIT) {
                positionData = _accumulateLimitOrderToPositionData(_positionManager, listLimitOrder[i], positionData);
            }
        }
    }

    function _accumulateLimitOrderToPositionData(IPositionManager _positionManager, LimitOrderID memory limitOrder, Position.Data memory positionData) internal view returns (Position.Data memory) {
        (bool isFilled, bool isBuy,
        uint256 quantity, uint256 partialFilled) = _positionManager.getPendingOrderDetail(limitOrder.pip, limitOrder.orderId);
        console.log("line 859 quantity", quantity, partialFilled);
        if (isFilled) {
            console.log("into full fill");
            int256 _orderQuantity = isBuy ? int256(quantity) : - int256(quantity);
            uint256 _orderNotional = quantity * _positionManager.pipToPrice(limitOrder.pip);
            // IMPORTANT UPDATE FORMULA WITH LEVERAGE
            uint256 _orderMargin = _orderNotional / limitOrder.leverage;
            positionData = positionData.accumulateLimitOrder(_orderQuantity, _orderMargin, _orderNotional);
        } else if (!isFilled && partialFilled != 0) {
            console.log("into partial fill");
            int256 _partialQuantity = isBuy ? int256(partialFilled) : - int256(partialFilled);
            uint256 _partialOpenNotional = partialFilled * _positionManager.pipToPrice(limitOrder.pip);
            uint256 _partialMargin = _partialOpenNotional / limitOrder.leverage;
            positionData = positionData.accumulateLimitOrder(_partialQuantity, _partialMargin, _partialOpenNotional);
        }
        return positionData;
    }

    function _calcRealPnL(IPositionManager _positionManager, Position.Data memory positionData, uint256 amountFilled, int128 pip, int256 amount) public view returns (int256, Position.Data memory)  {
        if (positionData.side() == Position.Side.LONG) {
            uint256 notionalWhenFilled = amountFilled * _positionManager.pipToPrice(pip);
            int256 realizedPnl = int256(notionalWhenFilled) - int256(positionData.openNotional) / positionData.quantity * int256(amountFilled);
            int256 realizedMargin = int256(positionData.margin) * int256(amountFilled) / positionData.quantity;
            amount = amount + realizedPnl + realizedMargin;
            positionData.openNotional = (positionData.openNotional / uint256(positionData.quantity)) * uint256(positionData.quantity - int256(amountFilled));
            positionData.quantity = positionData.quantity - int256(amountFilled);
            positionData.margin = positionData.margin - uint256(realizedMargin);
        } else {
            uint256 notionalWhenFilled = amountFilled * _positionManager.pipToPrice(pip);
            int256 realizedPnl = int256(positionData.openNotional) / (- positionData.quantity) * int256(amountFilled) - int256(notionalWhenFilled);
            int256 realizedMargin = int256(positionData.margin) * int256(amountFilled) / (-positionData.quantity);
            amount = amount + realizedPnl + realizedMargin;
            positionData.openNotional = (positionData.openNotional / uint256(-positionData.quantity)) * uint256(-positionData.quantity - int256(amountFilled));
            positionData.quantity = positionData.quantity + int256(amountFilled);
            positionData.margin = positionData.margin - uint256(realizedMargin);

        }
        return (amount, positionData);
    }
}
