// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import { NodeOperator } from "../interfaces/ICSModule.sol";
import { TransientUintUintMap, TransientUintUintMapLib } from "./TransientUintUintMapLib.sol";

// Batch is an uint256 as it's the internal data type used by solidity.
// Batch is a packed value, consisting of the following fields:
//    - uint64  nodeOperatorId
//    - uint64  keysCount -- count of keys enqueued by the batch
//    - uint128 next -- index of the next batch in the queue
type Batch is uint256;

/// @notice Batch of the operator with index 0, with no keys in it and the next Batch' index 0 is meaningless.
function isNil(Batch self) pure returns (bool) {
    return Batch.unwrap(self) == 0;
}

/// @dev Syntactic sugar for the type.
function unwrap(Batch self) pure returns (uint256) {
    return Batch.unwrap(self);
}

function noId(Batch self) pure returns (uint64 n) {
    assembly {
        n := shr(192, self)
    }
}

function keys(Batch self) pure returns (uint64 n) {
    assembly {
        n := shl(64, self)
        n := shr(192, n)
    }
}

function next(Batch self) pure returns (uint128 n) {
    assembly {
        n := self // uint128(self)
    }
}

// TODO: add notice that keys count cast is unsafe
function setKeys(Batch self, uint256 keysCount) pure returns (Batch) {
    assembly {
        self := or(
            and(
                self,
                0xffffffffffffffff0000000000000000ffffffffffffffffffffffffffffffff
            ),
            shl(128, and(keysCount, 0xffffffffffffffff))
        ) // self.keys = keysCount
    }

    return self;
}

// TODO: can be unsafe if the From batch is previous to the self
function setNext(Batch self, Batch from) pure returns (Batch) {
    assembly {
        self := or(
            and(
                self,
                0xffffffffffffffffffffffffffffffff00000000000000000000000000000000
            ),
            and(
                from,
                0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff
            )
        ) // self.next = from.next
    }
    return self;
}

/// @dev Instantiate a new Batch to be added to the queue. The `next` field will be determined upon the enqueue.
/// @dev Parameters are uint256 to make usage easier.
function createBatch(
    uint256 nodeOperatorId,
    uint256 keysCount
) pure returns (Batch item) {
    // @dev No need to safe cast due to internal logic
    nodeOperatorId = uint64(nodeOperatorId);
    keysCount = uint64(keysCount);

    assembly {
        item := shl(128, keysCount) // `keysCount` in [64:127]
        item := or(item, shl(192, nodeOperatorId)) // `nodeOperatorId` in [0:63]
    }
}

using { noId, keys, setKeys, setNext, next, isNil, unwrap } for Batch global;
using QueueLib for QueueLib.Queue;

/// @author madlabman
library QueueLib {
    struct Queue {
        // Pointer to the item to be dequeued.
        uint128 head;
        // Tracks the total number of batches enqueued.
        uint128 length;
        // Mapping saves a little in costs and allows easily fallback to a zeroed batch on out-of-bounds access.
        mapping(uint128 => Batch) queue;
    }

    // TODO: consider adding a full batch info
    event BatchEnqueued(uint256 indexed nodeOperatorId, uint256 count);

    error InvalidIndex();
    error QueueIsEmpty();
    error QueueLookupNoLimit();

    //////
    /// External methods
    //////
    function normalize(
        Queue storage self,
        mapping(uint256 => NodeOperator) storage nodeOperators,
        uint256 nodeOperatorId
    ) external {
        NodeOperator storage no = nodeOperators[nodeOperatorId];
        uint32 depositable = no.depositableValidatorsCount;
        uint32 enqueued = no.enqueuedCount;

        if (enqueued < depositable) {
            uint32 count;
            unchecked {
                count = depositable - enqueued;
            }
            no.enqueuedCount = depositable;
            self.enqueue(nodeOperatorId, count);
            emit BatchEnqueued(nodeOperatorId, count);
        }
    }

    function clean(
        Queue storage self,
        mapping(uint256 => NodeOperator) storage nodeOperators,
        uint256 maxItems
    ) external returns (uint256 toRemove) {
        if (maxItems == 0) revert QueueLookupNoLimit();

        Batch prev;
        uint128 indexOfPrev;

        uint128 head = self.head;
        uint128 curr = head;

        TransientUintUintMap queueLookup = TransientUintUintMapLib.create();

        for (uint256 i; i < maxItems; ++i) {
            Batch item = self.queue[curr];
            if (item.isNil()) {
                return toRemove;
            }

            NodeOperator storage no = nodeOperators[item.noId()];
            if (queueLookup.get(item.noId()) >= no.depositableValidatorsCount) {
                // NOTE: Since we reached that point there's no way for a Node Operator to have a depositable batch
                // later in the queue, and hence we don't update _queueLookup for the Node Operator.
                if (curr == head) {
                    self.dequeue();
                    head = self.head;
                } else {
                    // There's no `prev` item while we call `dequeue`, and removing an item will keep the `prev` intact
                    // other than changing its `next` field.
                    prev = prev.setNext(item);
                    self.queue[indexOfPrev] = prev;
                }

                unchecked {
                    // We assume that the invariant `enqueuedCount` >= `keys` is kept.
                    // @dev No need to safe cast due to internal logic
                    // TODO: consider move enqueuedCount update from unchecked
                    no.enqueuedCount -= uint32(item.keys());
                    ++toRemove;
                }
            } else {
                queueLookup.add(item.noId(), item.keys());
                indexOfPrev = curr;
                prev = item;
            }

            curr = item.next();
        }
    }

    /////
    /// Internal methods
    /////
    function enqueue(
        Queue storage self,
        uint256 nodeOperatorId,
        uint256 keysCount
    ) internal returns (Batch item) {
        // TODO: consider better naming for `length`
        uint128 length = self.length;
        item = createBatch(nodeOperatorId, keysCount);

        assembly {
            item := or(
                and(
                    item,
                    0xffffffffffffffffffffffffffffffff00000000000000000000000000000000
                ),
                add(length, 1)
            ) // item.next = self.length+1;
        }

        self.queue[length] = item;
        unchecked {
            ++self.length;
        }
    }

    // TODO: consider emiting an event here
    function dequeue(Queue storage self) internal returns (Batch item) {
        item = peek(self);

        if (item.isNil()) {
            revert QueueIsEmpty();
        }

        self.head = item.next();
    }

    function peek(Queue storage self) internal view returns (Batch) {
        return self.queue[self.head];
    }

    function at(
        Queue storage self,
        uint128 index
    ) internal view returns (Batch) {
        return self.queue[index];
    }
}
