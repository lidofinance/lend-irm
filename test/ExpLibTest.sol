// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MathLib, WAD_INT} from "../src/adaptive-curve-irm/libraries/MathLib.sol";
import {ExpLib} from "../src/adaptive-curve-irm/libraries/ExpLib.sol";
import {wadExp} from "../lib/solmate/src/utils/SignedWadMath.sol";
import {ConstantsLib} from "./ConstantsLib.sol";
import {MathLib as MorphoMathLib} from "../lib/morpho-blue/src/libraries/MathLib.sol";

import "../lib/forge-std/src/Test.sol";

contract ExpLibTest is Test {
    using MathLib for int256;
    using MorphoMathLib for uint256;

    /// @dev ln(1e-9) truncated at 2 decimal places.
    int256 internal constant LN_GWEI_INT = -20.72 ether;

    function testWExp(int256 x) public {
        // Bounded to have sub-1% relative error.
        x = bound(x, LN_GWEI_INT, ExpLib.WEXP_UPPER_BOUND);

        assertApproxEqRel(ExpLib.wExp(x), wadExp(x), 0.01 ether);
    }

    function testWExpSmall(int256 x) public {
        x = bound(x, ExpLib.LN_WEI_INT, LN_GWEI_INT);

        assertApproxEqAbs(ExpLib.wExp(x), 0, 1e10);
    }

    function testWExpTooSmall(int256 x) public {
        x = bound(x, type(int256).min, ExpLib.LN_WEI_INT);

        assertEq(ExpLib.wExp(x), 0);
    }

    function testWExpTooLarge(int256 x) public {
        x = bound(x, ExpLib.WEXP_UPPER_BOUND, type(int256).max);

        assertEq(ExpLib.wExp(x), ExpLib.WEXP_UPPER_VALUE);
    }

    /// The multiplication itself is the assertion: under checked arithmetic it reverts if
    /// `WEXP_UPPER_VALUE * 1e18` overflows int256 (mirrors `testWExpWMulMaxRate`).
    function testWExpDoesNotLeadToOverflow() public {
        int256 product = ExpLib.WEXP_UPPER_VALUE * 1e18;
        assertEq(product / 1e18, ExpLib.WEXP_UPPER_VALUE, "round-trips without overflow");
    }

    function testWExpContinuousUpperBound() public {
        assertApproxEqRel(ExpLib.wExp(ExpLib.WEXP_UPPER_BOUND - 1), ExpLib.WEXP_UPPER_VALUE, 1e-10 ether);
        assertEq(_wExpUnbounded(ExpLib.WEXP_UPPER_BOUND), ExpLib.WEXP_UPPER_VALUE);
    }

    /// Deliberate inequality (with testWExpNegative, the suite's only two): exp(x) >= 1 for x >= 0 is a domain
    /// property over ALL of int256 — the clamped edges included — with no exact counterpart (`wadExp` cannot
    /// price the clamped regions, and a same-algorithm reference would be a tautology).
    function testWExpPositive(int256 x) public {
        x = bound(x, 0, type(int256).max);

        assertGe(ExpLib.wExp(x), 1e18);
    }

    /// See testWExpPositive: the mirrored domain property for x <= 0.
    function testWExpNegative(int256 x) public {
        x = bound(x, type(int256).min, 0);

        assertLe(ExpLib.wExp(x), 1e18);
    }

    function testWExpWMulMaxRate() public pure {
        ExpLib.wExp(ExpLib.WEXP_UPPER_BOUND).wMulToZero(ConstantsLib.MAX_RATE_AT_TARGET);
    }

    function _wExpUnbounded(int256 x) internal pure returns (int256) {
        unchecked {
            // Decompose x as x = q * ln(2) + r with q an integer and -ln(2)/2 <= r <= ln(2)/2.
            // q = x / ln(2) rounded half toward zero.
            int256 roundingAdjustment = (x < 0) ? -(ExpLib.LN_2_INT / 2) : (ExpLib.LN_2_INT / 2);
            // Safe unchecked because x is bounded.
            int256 q = (x + roundingAdjustment) / ExpLib.LN_2_INT;
            // Safe unchecked because |q * ln(2) - x| <= ln(2)/2.
            int256 r = x - q * ExpLib.LN_2_INT;

            // Compute e^r with a 2nd-order Taylor polynomial.
            // Safe unchecked because |r| < 1e18.
            int256 expR = WAD_INT + r + (r * r) / WAD_INT / 2;

            // Return e^x = 2^q * e^r.
            if (q >= 0) return expR << uint256(q);
            else return expR >> uint256(-q);
        }
    }
}
