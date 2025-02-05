// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { TransientUintUintMap, TransientUintUintMapLib } from "../src/lib/TransientUintUintMapLib.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

contract TransientUintUintMapLibTest is Test {
    using Strings for uint256;

    function testFuzz_dictAddAndGetValue(
        uint256 k,
        uint256 v,
        uint256 s
    ) public {
        // There's no overflow check in the `add` function.
        unchecked {
            vm.assume(v + s > v);
        }

        uint256 sum = v + s;
        uint256 r;

        TransientUintUintMap dict = TransientUintUintMapLib.create();

        // Adding to the same key should increment the value.
        dict.add(k, v);
        dict.add(k, s);
        r = dict.get(k);
        assertEq(
            r,
            sum,
            string.concat("expected=", sum.toString(), " actual=", r.toString())
        );

        // Consequent read of the same key should return the same value.
        r = dict.get(k);
        assertEq(
            r,
            sum,
            string.concat("expected=", sum.toString(), " actual=", r.toString())
        );
    }

    function testFuzz_noIntersections(uint256 a, uint256 b) public {
        vm.assume(a != b);

        TransientUintUintMap dict1 = TransientUintUintMapLib.create();
        TransientUintUintMap dict2 = TransientUintUintMapLib.create();

        uint256 r;

        dict1.add(a, 1);
        dict2.add(b, 1);

        r = dict1.get(b);
        assertEq(r, 0, string.concat("expected=0 actual=", r.toString()));
        r = dict2.get(a);
        assertEq(r, 0, string.concat("expected=0 actual=", r.toString()));
    }
}
