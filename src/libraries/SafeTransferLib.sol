// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "../interfaces/IERC20.sol";

import {ErrorsLib} from "../libraries/ErrorsLib.sol";

interface IERC20Internal {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title SafeTransferLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Library to manage transfers of tokens, even if calls to the transfer or transferFrom functions are not
/// returning a boolean.
library SafeTransferLib {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(address(token).code.length > 0, ErrorsLib.NO_CODE);

        (bool success, bytes memory returndata) =
            address(token).call(abi.encodeCall(IERC20Internal.transfer, (to, value)));
        require(success, ErrorsLib.TRANSFER_REVERTED);
        require(returndata.length == 0 || abi.decode(returndata, (bool)), ErrorsLib.TRANSFER_RETURNED_FALSE);
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(address(token).code.length > 0, ErrorsLib.NO_CODE);

        // - 使用 call 方法调用 ERC20 合约的 transferFrom 函数。abi.encodeCall 用于编码函数调用及其参数。
        (bool success, bytes memory returndata) =
        // abi.encodeCall 用于编码函数调用及其参数。
            address(token).call(abi.encodeCall(IERC20Internal.transferFrom, (from, to, value)));
        require(success, ErrorsLib.TRANSFER_FROM_REVERTED);
        require(returndata.length == 0 || abi.decode(returndata, (bool)), ErrorsLib.TRANSFER_FROM_RETURNED_FALSE);
    }
}


/**
call:

使用 call 的方式而不是直接调用 transferFrom 函数的原因主要与 Solidity 的安全性和灵活性有关。以下是一些关键原因：
1. 安全性
防止重入攻击：直接调用外部合约的函数可能会导致重入攻击（Reentrancy Attack），尤其是在涉及资金转移时。使用 call 方法可以更好地控制调用的上下文，减少重入攻击的风险。
检查返回值：使用 call 可以捕获外部合约调用的返回值，并进行相应的检查。这对于确保操作成功至关重要。直接调用函数时，如果外部合约没有返回值，可能会导致意外的行为。
2. 兼容性
ERC20 标准的灵活性：并非所有的 ERC20 实现都遵循相同的返回值约定。有些合约在成功时返回 true，而有些合约可能不返回任何值。使用 call 可以处理这些不同的实现，确保即使在没有返回值的情况下也能正常工作。
3. 动态调用
动态合约地址：在某些情况下，合约地址可能在运行时动态确定。使用 call 可以让你在运行时调用任何合约的函数，而不仅仅是编译时已知的合约。这种灵活性在某些复杂的 DeFi 协议中非常有用。
4. 错误处理
自定义错误处理：通过 call，开发者可以自定义错误处理逻辑。例如，如果 transferFrom 调用失败，可以抛出特定的错误信息，而不是简单地让交易失败。
5. 避免编译时检查
避免编译时检查：直接调用函数时，编译器会进行类型检查和函数存在性检查。如果使用 call，则可以在运行时动态决定调用哪个函数，这在某些情况下是有用的。
示例对比
直接调用
token.transferFrom(from, to, value);

如果 token 合约没有实现 transferFrom，或者返回值不符合预期，可能会导致合约行为不稳定。
使用 call
(bool success, bytes memory returndata) = address(token).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, value));
require(success, "Transfer failed");


通过 call，可以捕获调用的成功与否，并根据返回值进行相应的处理，确保合约的安全性和稳定性。


 */


/**
address的其他属性

1. code
address(token).code：返回与地址 token 相关联的字节码的长度。如果长度大于 0，则表示该地址是一个合约地址；如果为 0，则表示该地址是一个外部账户（EOA）。
2. balance
address(token).balance：返回与地址 token 相关联的以 wei 为单位的以太币余额。可以用来检查某个地址的以太币余额。
3. transfer
address(token).transfer(amount)：将指定数量的以太币从当前合约转移到指定地址。注意，transfer 方法在 Solidity 0.8.0 及以后的版本中不再推荐使用，建议使用 call 方法。
4. send
address(token).send(amount)：将指定数量的以太币发送到指定地址。返回一个布尔值，指示发送是否成功。send 方法也不再推荐使用。
5. call
address(token).call{value: amount}("")：用于调用合约的函数或发送以太币。call 是一种更灵活的方式，可以用于调用合约的任意函数。
6. delegatecall
address(token).delegatecall(...)：用于在当前合约上下文中调用另一个合约的函数。与 call 不同，delegatecall 会保留调用者的上下文。
7. staticcall
address(token).staticcall(...)：用于静态调用合约的函数，确保不会修改状态。
8. isContract
isContract(address account)：虽然不是 address 类型的内置方法，但可以通过 address(account).code.length > 0 来实现，检查给定地址是否是合约地址。


 */