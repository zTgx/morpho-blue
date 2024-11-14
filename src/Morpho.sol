// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {
    Id,
    IMorphoStaticTyping,
    IMorphoBase,
    MarketParams,
    Position,
    Market,
    Authorization,
    Signature
} from "./interfaces/IMorpho.sol";
import {
    IMorphoLiquidateCallback,
    IMorphoRepayCallback,
    IMorphoSupplyCallback,
    IMorphoSupplyCollateralCallback,
    IMorphoFlashLoanCallback
} from "./interfaces/IMorphoCallbacks.sol";
import {IIrm} from "./interfaces/IIrm.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IOracle} from "./interfaces/IOracle.sol";

import "./libraries/ConstantsLib.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib, WAD} from "./libraries/MathLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

/// @title Morpho
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice The Morpho contract.
contract Morpho is IMorphoStaticTyping {
    using MathLib for uint128;
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using MarketParamsLib for MarketParams;

    /* IMMUTABLES */

    /// @inheritdoc IMorphoBase
    bytes32 public immutable DOMAIN_SEPARATOR;

    /* STORAGE */

    /// @inheritdoc IMorphoBase
    address public owner;
    /// @inheritdoc IMorphoBase
    address public feeRecipient;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => mapping(address => Position)) public position;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => Market) public market;
    /// @inheritdoc IMorphoBase
    mapping(address => bool) public isIrmEnabled;
    /// @inheritdoc IMorphoBase
    mapping(uint256 => bool) public isLltvEnabled;

    /**
    外层映射：第一个 address 表示授权者的地址（即被授权的用户）。
    内层映射：第二个 address 表示被授权的地址（即可以代表授权者进行操作的地址）。
    布尔值：true 表示被授权，false 表示未被授权。

    用户 A 授权用户 B
    用户 A 希望授权用户 B 代表他们进行某些操作（例如提款）。在这种情况下，合约会将 isAuthorized 映射更新为：
    isAuthorized[0xA...][0xB...] = true; // 用户 A 授权用户 B
    这意味着用户 B 现在可以代表用户 A 进行操作。


    用户 B 尝试代表用户 A 进行操作
    当用户 B 试图代表用户 A 进行某个操作时，合约会检查 isAuthorized 映射：
    require(isAuthorized[0xA...][msg.sender], ErrorsLib.UNAUTHORIZED);

    如果 msg.sender 是 0xB...，则检查通过，用户 B 被授权可以进行操作。
    场景 4：用户 A 撤销用户 B 的授权
    如果用户 A 决定不再授权用户 B，合约可以将映射更新为：
    isAuthorized[0xA...][0xB...] = false; // 用户 A 撤销用户 B 的授权
     */
    /// @inheritdoc IMorphoBase
    mapping(address => mapping(address => bool)) public isAuthorized;
    /// @inheritdoc IMorphoBase
    mapping(address => uint256) public nonce;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => MarketParams) public idToMarketParams;

    /* CONSTRUCTOR */

    /// @param newOwner The new owner of the contract.
    constructor(address newOwner) {
        require(newOwner != address(0), ErrorsLib.ZERO_ADDRESS);

        DOMAIN_SEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /* MODIFIERS */

    /// @dev Reverts if the caller is not the owner.
    modifier onlyOwner() {
        require(msg.sender == owner, ErrorsLib.NOT_OWNER);
        _;
    }

    /* ONLY OWNER FUNCTIONS */

    // @zhTian: Warning: The owner can be set to the zero address.

    /// @inheritdoc IMorphoBase
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != owner, ErrorsLib.ALREADY_SET);

        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    // @zhTian
    //  "Interest Rate Model"（利率模型）。
    // 它是一个合约或接口，用于定义和管理市场中的借贷利率。
    // 通过启用 Irm，合约允许将特定的利率模型用于市场创建，从而影响借贷的利率和相关的财务操作。
    /// @inheritdoc IMorphoBase
    function enableIrm(address irm) external onlyOwner {
        require(!isIrmEnabled[irm], ErrorsLib.ALREADY_SET);

        // @zhTian Enables irm as a possible IRM for market creation.
        // Warning: It is not possible to disable an IRM.
        isIrmEnabled[irm] = true;

        emit EventsLib.EnableIrm(irm);
    }

    // @zhTian Liquidation Loan-to-Value -> LLTV
    //  "Liquidation Loan-to-Value"（清算贷款价值比）。
    // 它是一个指标，用于衡量借款人抵押品的价值与其借款金额之间的比例。通过启用 Lltv，合约可以设置特定的清算贷款价值比，以管理借款的风险和清算条件。
    /// @inheritdoc IMorphoBase
    function enableLltv(uint256 lltv) external onlyOwner {
        require(!isLltvEnabled[lltv], ErrorsLib.ALREADY_SET);
        require(lltv < WAD, ErrorsLib.MAX_LLTV_EXCEEDED);

        // Warning: It is not possible to disable a LLTV.
        isLltvEnabled[lltv] = true;

        emit EventsLib.EnableLltv(lltv);
    }

    // @zhTian Sets the newFee for the given market marketParams.

    /// @inheritdoc IMorphoBase
    function setFee(MarketParams memory marketParams, uint256 newFee) external onlyOwner {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(newFee != market[id].fee, ErrorsLib.ALREADY_SET);
        require(newFee <= MAX_FEE, ErrorsLib.MAX_FEE_EXCEEDED);

        // Accrue interest using the previous fee set before changing it.
        _accrueInterest(marketParams, id);

        // Safe "unchecked" cast.
        market[id].fee = uint128(newFee);

        emit EventsLib.SetFee(id, newFee);
    }

    /// @inheritdoc IMorphoBase
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != feeRecipient, ErrorsLib.ALREADY_SET);

        feeRecipient = newFeeRecipient;

        emit EventsLib.SetFeeRecipient(newFeeRecipient);
    }

    /* MARKET CREATION */

    /// @inheritdoc IMorphoBase
    function createMarket(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        require(isIrmEnabled[marketParams.irm], ErrorsLib.IRM_NOT_ENABLED);
        require(isLltvEnabled[marketParams.lltv], ErrorsLib.LLTV_NOT_ENABLED);
        require(market[id].lastUpdate == 0, ErrorsLib.MARKET_ALREADY_CREATED);

        // Safe "unchecked" cast.
        market[id].lastUpdate = uint128(block.timestamp);
        idToMarketParams[id] = marketParams;

        emit EventsLib.CreateMarket(id, marketParams);

        // Call to initialize the IRM in case it is stateful.
        // @zhTian 需要user创建一个 IRM 合约来实现这个 borrowRate 方法，自定义需要的IRM模型
        // 参考 IrmMock 合约
        if (marketParams.irm != address(0)) IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
    }

    /* SUPPLY MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function supply(
        MarketParams memory marketParams, // The market to supply assets to.
        uint256 assets, // The amount of assets to supply.
        uint256 shares, // 要铸造的股份数量。
        address onBehalf, // The address that will own the increased supply position.
        bytes calldata data // 可选的任意数据，用于回调。
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();

        // 确保市场已经创建（即最后更新时间不为零）。
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);

        // 确保用户提供的资产和股份中只有一个是非零的，并且 onBehalf 地址不能为零地址。
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);


        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        // 调用内部函数累积利息，以确保市场的利息是最新的。
        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        else assets = shares.toAssetsUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);

        position[id][onBehalf].supplyShares += shares;
        market[id].totalSupplyShares += shares.toUint128();
        market[id].totalSupplyAssets += assets.toUint128();

        emit EventsLib.Supply(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMorphoSupplyCallback(msg.sender).onMorphoSupply(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /**
    OnBehalf:
    代表账户：onBehalf 是一个地址，通常是一个用户的地址，表示该用户希望从市场中提取资产。这个地址可以是提款者自己，也可以是其他用户的地址。
授权管理：在 DeFi 协议中，用户可以授权其他地址（如智能合约或代理）代表他们进行操作。onBehalf 允许这种授权机制，使得用户可以灵活地管理他们的资产。
     */
    /// @inheritdoc IMorphoBase
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        /**
        1. 计算逻辑的背景
        toSharesUp：用于将资产转换为股份时，向上取整。这是因为在用户提供资产时，合约希望确保用户获得足够的股份，尤其是在流动性提供的情况下。向上取整可以确保用户在提供资产时不会因为小数部分而失去潜在的股份。
        toAssetsDown：用于将股份转换为资产时，向下取整。这是因为在用户提取资产时，合约希望确保不会超出可用的资产数量。向下取整可以防止用户请求超过合约实际可用的资产。

        计算股份：当用户提供资产时，使用 toSharesUp 确保用户获得足够的股份。
        计算资产：当用户请求提取股份时，使用 toAssetsDown 确保不会超出合约的可用资产。

        在 supply 和 repay 方法中，计算的顺序是相反的：
        supply 方法：
        计算股份时使用 toSharesDown，因为在计算股份时，合约希望确保不会过度分配股份。
        计算资产时使用 toAssetsUp，确保用户在提供股份时能够获得足够的资产。
        repay 方法：
        计算股份时使用 toSharesDown，确保不会过度分配股份。
        计算资产时使用 toAssetsUp，确保用户在偿还股份时能够获得足够的资产。
        3. 总结
        toSharesUp 和 toAssetsDown 的使用：在 withdraw 方法中，合约希望确保用户在提供资产时获得足够的股份，而在提取股份时确保不会超出可用资产。因此，使用了向上取整和向下取整的组合。
        supply 和 repay 方法中的逻辑：在这两个方法中，合约的逻辑是确保在计算股份时不会过度分配，而在计算资产时确保用户能够获得足够的资产。        
        
        避免偏差的机制
        向上取整：在提供资产时使用 toSharesUp 确保用户获得足够的股份，避免因小数部分而导致的股份不足。
        向下取整：在提取股份时使用 toAssetsDown 确保用户不会请求超过合约实际可用的资产，避免因小数部分而导致的资产不足。

         */
        if (assets > 0) shares = assets.toSharesUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        else assets = shares.toAssetsDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);

        position[id][onBehalf].supplyShares -= shares;
        market[id].totalSupplyShares -= shares.toUint128();
        market[id].totalSupplyAssets -= assets.toUint128();

        require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        emit EventsLib.Withdraw(id, msg.sender, onBehalf, receiver, assets, shares);

        // 表示将 assets 数量的代币从合约地址转移到 receiver 地址。
        /**
        假设我们有以下情况：
        市场参数：
        marketParams.loanToken = 0xTokenAddress（这是一个 ERC20 代币的合约地址，例如 USDC 的合约地址）。
        用户请求提取的资产：
        assets = 1000（用户希望提取 1000 个代币）。
        接收者地址：
        receiver = 0xReceiverAddress（这是用户指定的接收地址，例如用户的个人钱包地址）。
        执行过程
        当用户调用 withdraw 方法并满足所有条件后，合约会执行以下操作：
        1. 调用 safeTransfer：
        IERC20(0xTokenAddress).safeTransfer(0xReceiverAddress, 1000);
        2. 转账逻辑：
        合约会从其自身的余额中转移 1000 个代币到 0xReceiverAddress。
        safeTransfer 会检查转账是否成功。如果转账失败（例如，合约余额不足），它会抛出错误，防止资产损失。
        结果
        资产转移：用户的接收地址 0xReceiverAddress 将收到 1000 个代币。
        合约余额减少：合约中存储的 0xTokenAddress 代币的余额将减少 1000 个。
        
         */
        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /* BORROW MANAGEMENT */

    /**
    function exampleBorrow() external {
        // 定义市场参数
        MarketParams memory marketParams = MarketParams({
            loanToken: 0xUSDCAddress,          // USDC 的合约地址
            collateralToken: 0xETHAddress,     // ETH 的合约地址
            oracle: 0xChainlinkOracleAddress,   // Chainlink 预言机的合约地址
            irm: 0xCustomIRModelAddress,        // 自定义利率模型的合约地址
            lltv: 75                             // 贷款价值比为 75%
        });

        // 定义借款参数
        uint256 assets = 1000; // 用户希望借入 1000 个 USDC
        uint256 shares = 0;     // 用户不希望借入股份（可以根据实际需求调整）

        // 确保借款者是调用者
        address onBehalf = msg.sender; // 借款者自己
        address receiver = msg.sender;   // 借入的资产将转移到借款者自己

        // 调用借款函数
        borrow(marketParams, assets, shares, onBehalf, receiver);
    }
    
     */
    /// @inheritdoc IMorphoBase
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf, // 表示代表谁进行借款操作的地址。这个地址可以是借款者自己，也可以是其他被授权的地址（例如代理合约）
        address receiver // 表示借入的资产将被转移到哪个地址。这个地址通常是借款者的地址，但也可以是其他地址，例如一个合约地址。
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        else assets = shares.toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        position[id][onBehalf].borrowShares += shares.toUint128();
        market[id].totalBorrowShares += shares.toUint128();
        market[id].totalBorrowAssets += assets.toUint128();

        require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);
        require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        emit EventsLib.Borrow(id, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    // 用于处理用户偿还借款的逻辑。用户可以通过此方法偿还他们在借贷市场中借入的资产和股份。
    /**
    偿还借款：用户可以偿还他们借入的资产（如 USDC）和相应的股份。此方法会更新用户的借款状态、市场的总借款状态，并触发相关事件。
    利息累积：在偿还之前，会先计算并累积利息，以确保用户偿还的金额是最新的。

    function exampleRepay() external {
        // 定义市场参数
        MarketParams memory marketParams = MarketParams({
            loanToken: 0xUSDCAddress,          // USDC 的合约地址
            collateralToken: 0xETHAddress,     // ETH 的合约地址
            oracle: 0xChainlinkOracleAddress,   // Chainlink 预言机的合约地址
            irm: 0xCustomIRModelAddress,        // 自定义利率模型的合约地址
            lltv: 75                             // 贷款价值比为 75%
        });

        // 定义偿还参数
        uint256 assets = 1000; // 用户希望偿还 1000 个 USDC
        uint256 shares = 0;     // 用户不希望偿还股份
        address onBehalf = msg.sender; // 借款者自己
        bytes memory data;      // 可选的任意数据

        // 调用偿还函数
        (uint256 repaidAssets, uint256 repaidShares) = repay(marketParams, assets, shares, onBehalf, data);
        
        // 处理偿还后的逻辑，例如更新状态或发放奖励
        // ...
    }

     */
    /// @inheritdoc IMorphoBase
    function repay(
        MarketParams memory marketParams,
        uint256 assets, // 用户希望偿还的资产数量
        uint256 shares, // 用户希望偿还的股份数量。
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        else assets = shares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        position[id][onBehalf].borrowShares -= shares.toUint128();
        market[id].totalBorrowShares -= shares.toUint128();
        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, assets).toUint128();

        // `assets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Repay(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMorphoRepayCallback(msg.sender).onMorphoRepay(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /* COLLATERAL MANAGEMENT */

    /// @inheritdoc IMorphoBase
    /**
    允许用户向借贷市场提供抵押品（collateral）。通过这个函数，用户可以将资产存入市场，以便在借款时使用。

    Example:

    假设用户 A 希望向市场提供 1000 个 DAI 作为抵押品。以下是一个完整的示例，展示如何使用 supplyCollateral 函数。

    MarketParams memory marketParams = MarketParams({
        loanToken: 0xUSDCAddress,          // 贷款代币的合约地址
        collateralToken: 0xDAIAddress,     // DAI 的合约地址
        oracle: 0xChainlinkOracleAddress,   // 预言机的合约地址
        irm: 0xCustomIRModelAddress,        // 自定义利率模型的合约地址
        lltv: 75                             // 贷款价值比为 75%
    });

    用户 A 调用 supplyCollateral 函数，提供 1000 个 DAI 作为抵押品：

    function exampleSupplyCollateral() external {
        uint256 assets = 1000; // 用户希望提供 1000 个 DAI
        address onBehalf = msg.sender; // 用户 A 自己
        bytes memory data; // 可选的额外数据

        // 调用 supplyCollateral 函数
        supplyCollateral(marketParams, assets, onBehalf, data);
    }

     */
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external
    {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        // Don't accrue interest because it's not required and it saves gas.

        // 将提供的抵押品数量添加到指定地址的抵押品余额中。
        position[id][onBehalf].collateral += assets.toUint128();

        emit EventsLib.SupplyCollateral(id, msg.sender, onBehalf, assets);

        // 调用回调函数，允许用户在提供抵押品后执行自定义逻辑。
        if (data.length > 0) IMorphoSupplyCollateralCallback(msg.sender).onMorphoSupplyCollateral(assets, data);

        // 从调用者的地址转移抵押品到合约地址，确保转账安全。
        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @inheritdoc IMorphoBase
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external
    {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        position[id][onBehalf].collateral -= assets.toUint128();

        require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);

        emit EventsLib.WithdrawCollateral(id, msg.sender, onBehalf, receiver, assets);

        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
    }

    /* LIQUIDATION */

    /**
    用于处理借款人的清算操作。当借款人的抵押品价值不足以覆盖其借款时，其他用户可以通过调用此函数来清算借款人的资产.

    MarketParams memory marketParams：包含与市场相关的参数，例如抵押品代币的地址和预言机地址。
address borrower：需要被清算的借款人的地址。
uint256 seizedAssets：清算过程中被没收的资产数量（抵押品）。
uint256 repaidShares：清算过程中偿还的股份数量。
bytes calldata data：可选的任意数据，通常用于传递给回调函数的信息。

假设用户 A 是借款人，用户 B 是清算者。用户 A 的抵押品价值下降，导致其借款状态不健康。用户 B 通过调用 liquidate 函数来清算用户 A 的资产。

用户 B 需要定义市场参数：
MarketParams memory marketParams = MarketParams({
    loanToken: 0xUSDCAddress,          // 贷款代币的合约地址
    collateralToken: 0xDAIAddress,     // DAI 的合约地址
    oracle: 0xChainlinkOracleAddress,   // 预言机的合约地址
    irm: 0xCustomIRModelAddress,        // 自定义利率模型的合约地址
    lltv: 75                             // 贷款价值比为 75%
});

2. 用户 B 调用 liquidate
用户 B 调用 liquidate 函数，清算用户 A 的资产：

function exampleLiquidate() external {
    address borrower = 0xA...; // 借款人的地址
    uint256 seizedAssets = 1000; // 被没收的资产数量（例如 1000 DAI）
    uint256 repaidShares = 0; // 假设不偿还股份
    bytes memory data; // 可选的额外数据

    // 调用 liquidate 函数
    (uint256 seized, uint256 repaid) = liquidate(marketParams, borrower, seizedAssets, repaidShares, data);
}

结果
用户 B 成功清算用户 A 的资产。
合约更新用户 A 的借款股份和市场的总借款状态。
被没收的资产（例如 1000 DAI）转移给用户 B。
如果提供了额外数据，调用回调函数以执行自定义逻辑。

     */
    /// @inheritdoc IMorphoBase
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(seizedAssets, repaidShares), ErrorsLib.INCONSISTENT_INPUT);

        // 计算并累积借款人的利息。
        _accrueInterest(marketParams, id);

        {
            // 获取抵押品的当前价格
            uint256 collateralPrice = IOracle(marketParams.oracle).price();

            // 检查借款人的状态是否健康
            require(!_isHealthy(marketParams, id, borrower, collateralPrice), ErrorsLib.HEALTHY_POSITION);

            // 计算清算激励因子
            /**
            用于确定在清算过程中给予清算者的激励。这个激励因子可以影响清算者的收益，确保他们在清算不健康借款人时有足够的动机去执行清算操作.

            MAX_LIQUIDATION_INCENTIVE_FACTOR：
这是一个常量，表示清算激励因子的最大值。它限制了清算者可以获得的激励，防止激励过高。


            LIQUIDATION_CURSOR：
这是一个常量，通常用于调整清算激励因子的计算。它可能是一个小于 1 的值，用于控制激励的灵活性。

3. marketParams.lltv：
这是市场的贷款价值比（Loan-to-Value Ratio），表示借款人可以借入的金额与其抵押品价值的比率。它通常是一个百分比值（例如，75% 表示 0.75）。

WAD：
这是一个常量，通常表示一个单位（例如，1e18），用于处理固定点数学运算，以避免浮点数运算带来的精度问题。


////

假设我们有以下常量和参数：
MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.1 * WAD（即 1.1，表示 110% 的激励）
LIQUIDATION_CURSOR = 0.1 * WAD（即 0.1，表示 10% 的调整因子）
marketParams.lltv = 0.75 * WAD（即 0.75，表示 75% 的贷款价值比）
计算步骤
1. 计算 WAD - marketParams.lltv：
    WAD - marketParams.lltv = 1 - 0.75 = 0.25 * WAD
2. 计算 LIQUIDATION_CURSOR.wMulDown(...)：
    LIQUIDATION_CURSOR.wMulDown(WAD - marketParams.lltv) = 0.1 * WAD * 0.25 * WAD = 0.025 * WAD

计算 WAD - LIQUIDATION_CURSOR.wMulDown(...)：
    WAD - LIQUIDATION_CURSOR.wMulDown(...) = 1 - 0.025 = 0.975 * WAD

4. 计算 WAD.wDivDown(...)：
   WAD.wDivDown(0.975 * WAD) = 1 / 0.975 ≈ 1.0256 (约为 102.56%)

5. 最终计算 liquidationIncentiveFactor：
    liquidationIncentiveFactor = UtilsLib.min(1.1 * WAD, 1.0256) = 1.0256 (因为 1.0256 < 1.1)


             */
            // The liquidation incentive factor is min(maxLiquidationIncentiveFactor, 1/(1 - cursor*(1 - lltv))).
            uint256 liquidationIncentiveFactor = UtilsLib.min(
                MAX_LIQUIDATION_INCENTIVE_FACTOR,
                WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - marketParams.lltv))
            );

            if (seizedAssets > 0) {
                // 计算被没收资产的报价。seizedAssets 是被没收的抵押品数量，collateralPrice 是抵押品的当前市场价格，ORACLE_PRICE_SCALE 是一个常量，用于调整价格的比例。

                /**
                
                假设 seizedAssets = 1000（被没收的资产数量），collateralPrice = 2（抵押品的市场价格），ORACLE_PRICE_SCALE = 1e18（用于固定点运算的比例）。
计算：
       seizedAssetsQuoted = 1000.mulDivUp(2, 1e18); // 结果为 2000（在固定点运算中，实际值为 0.000002）

                
                 */
                uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);

// 计算需要偿还的股份数量
/**

假设 liquidationIncentiveFactor = 1.05（清算激励因子），market[id].totalBorrowAssets = 10000（市场的总借款资产），market[id].totalBorrowShares = 5000（市场的总借款股份）。

       uint256 intermediateValue = seizedAssetsQuoted.wDivUp(1.05); // 2000 / 1.05 ≈ 1904.76
       repaidShares = intermediateValue.toSharesUp(10000, 5000); // 将 1904.76 转换为股份

toSharesUp:
根据市场的总借款资产和总借款股份计算出相应的股份数量，确保不会因为小数部分而导致股份不足。
 */
                repaidShares = seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor).toSharesUp(
                    market[id].totalBorrowAssets, market[id].totalBorrowShares
                );
            } else {
                seizedAssets = repaidShares.toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares)
                    .wMulDown(liquidationIncentiveFactor).mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
            }
        }
        uint256 repaidAssets = repaidShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        position[id][borrower].borrowShares -= repaidShares.toUint128();
        market[id].totalBorrowShares -= repaidShares.toUint128();
        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, repaidAssets).toUint128();

        // 假设借款人原本的抵押品为 3000 DAI，被没收的资产为 1000 DAI
        // position[id][borrower].collateral = 3000 - 1000 = 2000 DAI;
        position[id][borrower].collateral -= seizedAssets.toUint128();

        // 如果借款人的抵押品为零，处理坏账（bad debt），并更新市场状态。
        uint256 badDebtShares;
        uint256 badDebtAssets;
        if (position[id][borrower].collateral == 0) {
            badDebtShares = position[id][borrower].borrowShares;

            //  函数确保坏账资产不会超过市场的总借款资产。
            badDebtAssets = UtilsLib.min(
                market[id].totalBorrowAssets,
                badDebtShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares)
            );

            // 从市场的总借款资产中减去坏账资产。
            market[id].totalBorrowAssets -= badDebtAssets.toUint128();

            // 从市场的总供应资产中减去坏账资产。
            market[id].totalSupplyAssets -= badDebtAssets.toUint128();

            // 从市场的总借款股份中减去坏账股份。
            market[id].totalBorrowShares -= badDebtShares.toUint128();

            // 将借款人的借款股份设置为零，表示其债务已被清除。
            position[id][borrower].borrowShares = 0;
        }

        // `repaidAssets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Liquidate(
            id, msg.sender, borrower, repaidAssets, repaidShares, seizedAssets, badDebtAssets, badDebtShares
        );

        IERC20(marketParams.collateralToken).safeTransfer(msg.sender, seizedAssets);

        if (data.length > 0) IMorphoLiquidateCallback(msg.sender).onMorphoLiquidate(repaidAssets, data);

        // 从清算者的地址转移偿还的资产
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets);

        return (seizedAssets, repaidAssets);
    }

    /* FLASH LOANS */

    /**
    
    address token：要借入的代币的地址（例如，USDC、DAI 等）。
    uint256 assets：用户希望借入的资产数量。
    bytes calldata data：可选的任意数据，通常用于传递给回调函数的信息。

    contract UserA is IMorphoFlashLoanCallback {
        function executeFlashLoan(address morpho, address token, uint256 amount) external {
            bytes memory data; // 可选的额外数据

            // 调用闪电贷
            Morphos(morpho).flashLoan(token, amount, data);
        }

        // 实现回调函数
        function onMorphoFlashLoan(uint256 assets, bytes calldata data) external override {
            // 在这里执行自定义逻辑，例如进行套利、交易等

            // 例如，进行某种操作后，归还借入的资产
            // 这里假设我们已经完成了操作并准备归还资产
        }
    }

    function executeFlashLoan(address morpho, address token, uint256 amount) external {
        bytes memory data; // 可选的额外数据

        // 调用闪电贷
        Morphos(morpho).flashLoan(token, amount, data);
    }


    用户 A 借入 1000 个 USDC。
    在 onMorphoFlashLoan 回调中，用户 A 可以执行自定义逻辑（例如套利、交易等）。
    最后，用户 A 必须在同一交易中归还 1000 个 USDC。
     */

    /// @inheritdoc IMorphoBase
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(assets != 0, ErrorsLib.ZERO_ASSETS);

        emit EventsLib.FlashLoan(msg.sender, token, assets);

        IERC20(token).safeTransfer(msg.sender, assets);

        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);

        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /* AUTHORIZATION */

    /// @inheritdoc IMorphoBase
    function setAuthorization(address authorized, bool newIsAuthorized) external {
        require(newIsAuthorized != isAuthorized[msg.sender][authorized], ErrorsLib.ALREADY_SET);

        isAuthorized[msg.sender][authorized] = newIsAuthorized;

        emit EventsLib.SetAuthorization(msg.sender, msg.sender, authorized, newIsAuthorized);
    }

    /**
    
    
    Authorization memory auth = Authorization({
        authorizer: 0xA...,       // 用户 A 的地址
        authorized: 0xB...,       // 用户 B 的地址
        isAuthorized: true,        // 授权状态
        nonce: 1,                  // 随机数
        deadline: block.timestamp + 1 days // 签名有效期为 1 天
    });

    // 用户 A 使用私钥签名授权
    (bytes32 hashStruct, bytes memory signature) = signAuthorization(auth);

    setAuthorizationWithSig(auth, signature);

     */
    /// @inheritdoc IMorphoBase
    function setAuthorizationWithSig(Authorization memory authorization, Signature calldata signature) external {
        /// Do not check whether authorization is already set because the nonce increment is a desired side effect.
        require(block.timestamp <= authorization.deadline, ErrorsLib.SIGNATURE_EXPIRED);
        require(authorization.nonce == nonce[authorization.authorizer]++, ErrorsLib.INVALID_NONCE);

        // EIP712 连上验证流程:
        bytes32 hashStruct = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", DOMAIN_SEPARATOR, hashStruct));

        // 使用 ecrecover 函数从签名中恢复出签名者的地址。
        address signatory = ecrecover(digest, signature.v, signature.r, signature.s);

        require(signatory != address(0) && authorization.authorizer == signatory, ErrorsLib.INVALID_SIGNATURE);
        // EIP712 链上验证结束！！！
        // 函数通过使用 EIP-712 签名标准，提供了一种安全的方式来设置授权。通过验证签名、检查有效性和更新授权状态，该函数确保了授权过程的安全性和可靠性。

        emit EventsLib.IncrementNonce(msg.sender, authorization.authorizer, authorization.nonce);

        isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;

        emit EventsLib.SetAuthorization(
            msg.sender, authorization.authorizer, authorization.authorized, authorization.isAuthorized
        );
    }

    /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
    }

    /* INTEREST MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function accrueInterest(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);

        _accrueInterest(marketParams, id);
    }

    /// @dev Accrues interest for the given market `marketParams`.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _accrueInterest(MarketParams memory marketParams, Id id) internal {
        // 通过 block.timestamp 和 market[id].lastUpdate 计算自上次更新以来经过的时间（elapsed）
        uint256 elapsed = block.timestamp - market[id].lastUpdate;
        if (elapsed == 0) return;

        // 检查利率模型：主要涉及在借贷市场中计算和累积【【【 借款利息 】】】，并处理相关的费用
        // 如果 marketParams.irm 不为零地址，表示存在有效的利率模型，则继续执行。
        if (marketParams.irm != address(0)) {
            // 获取当前的借款利率。
            uint256 borrowRate = IIrm(marketParams.irm).borrowRate(marketParams, market[id]);

            // 计算利息
            // 根据当前的借款资产和计算出的利率计算利息。
            uint256 interest = market[id].totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));

            // 使用借款利率和经过的时间计算利息，并将其添加到市场的总借款资产和总供应资产中。
            market[id].totalBorrowAssets += interest.toUint128();
            market[id].totalSupplyAssets += interest.toUint128();

            // 检查市场是否有费用
            uint256 feeShares;
            if (market[id].fee != 0) {
                uint256 feeAmount = interest.wMulDown(market[id].fee);
                // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
                // that total supply is already increased by the full interest (including the fee amount).
                feeShares =
                    feeAmount.toSharesDown(market[id].totalSupplyAssets - feeAmount, market[id].totalSupplyShares);

                // 将费用股份添加到费用接收者的供应股份中。
                position[id][feeRecipient].supplyShares += feeShares;

                // 将费用股份添加到市场的总供应股份中。
                market[id].totalSupplyShares += feeShares.toUint128();
            }

            emit EventsLib.AccrueInterest(id, borrowRate, interest, feeShares);
        }

        // Safe "unchecked" cast.
        // 更新市场的最后更新时间为当前时间。
        market[id].lastUpdate = uint128(block.timestamp);
    }

    /* HEALTH CHECK */

    /// @dev Returns whether the position of `borrower` in the given market `marketParams` is healthy.
    /// @dev Assumes that the inputs `marketParams` and `id` match.

/**
它会检查借款人的借款股份是否为零，以及根据当前抵押品价格评估借款人的健康状况。




 */
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower) internal view returns (bool) {
        // 如果借款人的借款股份为零，函数返回 true，表示借款人是健康的。因为没有借款意味着没有风险。
        if (position[id][borrower].borrowShares == 0) return true;

        uint256 collateralPrice = IOracle(marketParams.oracle).price();

        return _isHealthy(marketParams, id, borrower, collateralPrice);
    }

    /// @dev Returns whether the position of `borrower` in the given market `marketParams` with the given
    /// `collateralPrice` is healthy.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    /// @dev Rounds in favor of the protocol, so one might not be able to borrow exactly `maxBorrow` but one unit less.

    /**
    
    评估借款人的抵押品是否足以覆盖其借款。


假设我们有以下情况：
市场参数：
marketParams.lltv = 75（即 0.75，表示借款人可以借入其抵押品价值的 75%）。
ORACLE_PRICE_SCALE = 1e18（用于固定点运算的比例）。
借款人状态：
借款人地址为 0xA...。
借款人当前的抵押品为 2000 DAI。
借款人当前的借款股份为 100。
抵押品价格：
当前抵押品价格为 1 DAI。

计算步骤
计算借款金额：
假设市场的总借款资产为 10000 DAI，总借款股份为 5000。
计算借款金额：

     borrowed = uint256(position[id][0xA...].borrowShares).toAssetsUp(10000, 5000);
     // borrowed = (100 / 5000) * 10000 = 200 DAI

2. 计算最大可借金额：
计算抵押品的价值：
     maxBorrow = uint256(position[id][0xA...].collateral).mulDivDown(1, 1e18);
     // maxBorrow = 2000 DAI * 1 = 2000 DAI

    maxBorrow = 2000 DAI * 0.75 = 1500 DAI

3. 健康检查：
检查最大可借金额是否大于已借款金额：
         return 1500 DAI >= 200 DAI; // 返回 true
    
     */
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower, uint256 collateralPrice)
        internal
        view
        returns (bool)
    {
        // 将借款人的股份转换为实际借款金额
        uint256 borrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
            market[id].totalBorrowAssets, market[id].totalBorrowShares
        );

        // 计算借款人可以借入的最大金额，基于其抵押品的价值。
        uint256 maxBorrow = uint256(position[id][borrower].collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(marketParams.lltv);

        // 如果最大可借金额大于或等于已借款金额，
        // 则返回 true，表示借款人是健康的；
        // 否则返回 false。
        return maxBorrow >= borrowed;
    }

    /* STORAGE VIEW */

    // 这个函数的主要目的是允许用户一次性读取多个存储槽的值，并将这些值返回为一个字节数组。

    /// @inheritdoc IMorphoBase
    // bytes32[] calldata slots：这是一个字节数组，包含要读取的存储槽的地址。
    function extSloads(bytes32[] calldata slots) external view returns (bytes32[] memory res) {
        uint256 nSlots = slots.length;

        res = new bytes32[](nSlots);

        for (uint256 i; i < nSlots;) {
            bytes32 slot = slots[i++];

            assembly ("memory-safe") {
                // sload(slot) 用于读取存储槽的值，mstore 用于将值存储到结果数组的相应位置
                // res 是结果数组的内存地址，mul(i, 32) 是当前索引的字节偏移量。
                mstore(add(res, mul(i, 32)), sload(slot))
            }
        }
    }
}
