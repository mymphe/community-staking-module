// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import { QueueLib } from "../src/lib/QueueLib.sol";

contract QueueLibTest is Test {
    bytes32 p0 = keccak256("0x00"); // 0x27489e20a0060b723a1748bdff5e44570ee9fae64141728105692eac6031e8a4
    bytes32 p1 = keccak256("0x01"); // 0xe127292c8f7eb20e1ae830ed6055b6eb36e261836100610d12677231d0791f7f
    bytes32 p2 = keccak256("0x02"); // 0xd3974deccfd8aa6b77f0fcc2c0014e6e0574d32e56c1d75717d2667b529cd073

    bytes32 nil = bytes32(0);
    bytes32 buf;

    using QueueLib for QueueLib.Queue;
    QueueLib.Queue q;

    function test_enqueue() public {
        assertEq(q.peek(), nil);

        q.enqueue(p0);
        q.enqueue(p1);

        assertEq(q.peek(), p0);
        assertEq(q.at(p0), p1);
    }

    function test_dequeue() public {
        assertTrue(q.isEmpty());

        q.enqueue(p0);
        q.enqueue(p1);
        q.enqueue(p2);

        assertFalse(q.isEmpty());

        buf = q.dequeue();
        assertEq(buf, p0);
        assertEq(q.peek(), p1);

        buf = q.dequeue();
        assertEq(buf, p1);
        assertEq(q.peek(), p2);

        q.dequeue();
        assertEq(q.peek(), nil);
        assertTrue(q.isEmpty());
    }

    function test_list() public {
        q.enqueue(p0);
        q.enqueue(p1);
        q.enqueue(p2);

        {
            (bytes32[] memory items, uint256 count) = q.list(q.front, 2);
            assertEq(count, 2);
            assertEq(items[0], p0);
            assertEq(items[1], p1);
        }

        {
            (bytes32[] memory items, uint256 count) = q.list(p1, 999);
            assertEq(count, 1);
            assertEq(items[0], p2);
        }

        q.dequeue();

        {
            (bytes32[] memory items, uint256 count) = q.list(q.front, 1);
            assertEq(count, 1);
            assertEq(items[0], p1);
        }
    }

    function test_remove() public {
        q.enqueue(p0);
        q.enqueue(p1);
        q.enqueue(p2);
        // [+*p0, p1, p2]

        q.remove(p0, p1);
        // [+*p0, p2]

        q.dequeue();
        // [+p0, *p2]
        buf = q.dequeue();
        // [p0, +*p2]
        assertEq(buf, p2);

        q.enqueue(p1);
        // [p0, +p2, *p1]
        assertEq(q.peek(), p1);

        q.remove(p2, p1);
        // [p0, +*p2]
        assertEq(q.peek(), nil);
        assertTrue(q.isEmpty());

        q.remove(p0, p2);
        // [+*p0]
        assertEq(q.peek(), nil);
    }

    // TODO: test with revert on library call
}
