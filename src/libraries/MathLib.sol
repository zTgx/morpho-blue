// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/**
WAD 是 "Weighted Average Decimal" 的缩写，表示加权平均小数。
WAD 通常是一个常量，用于表示固定点数的基数。它的值通常设定为 1e18。这个常量的主要目的是在进行数学运算时保持高精度，避免浮点数运算带来的精度问题。

假设我们有一个利率为 5% 的情况，我们可以使用 WAD 来表示这个利率：
uint256 interestRate = 5 * WAD / 100; // 5% 的利率表示为 0.05 * WAD


在 Solidity 和 DeFi 中，还有其他类似的常量，例如：
RAY：通常表示 10e27
 ，用于更高精度的固定点数运算。
RAD：通常表示 10e45
 ，用于极高精度的固定点数运算。

RAY 通常被解释为 "Rational Average Yields" 或 "Rational Average Decimal"。
RAD 通常被解释为 "Rational Average Decimal" 或 "Rational Average Division"。

 */
uint256 constant WAD = 1e18;

/// @title MathLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Library to manage fixed-point arithmetic.
library MathLib {
    /// @dev Returns (`x` * `y`) / `WAD` rounded down.
    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    /// @dev Returns (`x` * `WAD`) / `y` rounded down.
    function wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y);
    }

    /// @dev Returns (`x` * `WAD`) / `y` rounded up.
    function wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y);
    }

    /// @dev Returns (`x` * `y`) / `d` rounded down.
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    /// @dev Returns (`x` * `y`) / `d` rounded up.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    /// @dev Returns the sum of the first three non-zero terms of a Taylor expansion of e^(nx) - 1, to approximate a
    /// continuous compound interest rate.
    function wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = mulDivDown(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = mulDivDown(secondTerm, firstTerm, 3 * WAD);

        return firstTerm + secondTerm + thirdTerm;
    }
    /**
    用于计算复利的函数，基于泰勒级数展开（Taylor series expansion）。它通过计算前几项来近似计算复利的结果。

    x：表示利率或增长因子，通常是一个固定点数（例如，1e18 表示 1）。
n：表示时间单位（例如，经过的时间或周期数）。

计算第一项：
uint256 firstTerm = x * n;：计算泰勒级数的第一项，表示在 n 个时间单位内的线性增长。
示例：如果 x = 1e18（表示 1）且 n = 1，则 firstTerm = 1e18 * 1 = 1e18。


计算第二项：
uint256 secondTerm = mulDivDown(firstTerm, firstTerm, 2 * WAD);：计算泰勒级数的第二项，表示二次项的贡献。
示例：如果 firstTerm = 1e18，则：
     secondTerm = mulDivDown(1e18, 1e18, 2 * 1e18) = (1e36 / 2e18) = 0.5e18 = 5e17;

4. 计算第三项：
uint256 thirdTerm = mulDivDown(secondTerm, firstTerm, 3 * WAD);：计算泰勒级数的第三项，表示三次项的贡献。
示例：如果 secondTerm = 5e17 和 firstTerm = 1e18，则：


     thirdTerm = mulDivDown(5e17, 1e18, 3 * 1e18) = (5e35 / 3e18) ≈ 1.66667e17;


5. 返回结果：
return firstTerm + secondTerm + thirdTerm;：将所有项相加，返回复利的近似值。
示例：如果 firstTerm = 1e18，secondTerm = 5e17，thirdTerm ≈ 1.66667e17，则：

     return 1e18 + 5e17 + 1.66667e17 ≈ 1.66667e18;
    
     */
}
