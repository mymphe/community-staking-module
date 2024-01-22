// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.21;

/// @author madlabman
library QueueLib {
    error NullItem();
    error AlreadyEnqueued();
    error LimitNotSet();
    error WrongPointer();
    error QueueIsEmpty();

    bytes32 public constant NULL_POINTER = bytes32(0);

    // @dev Queue is a linked list of items
    // @dev front and back are pointers
    struct Queue {
        mapping(bytes32 => bytes32) queue;
        bytes32 front;
        bytes32 back;
    }

    function enqueue(Queue storage self, bytes32 item) internal {
        if (item == NULL_POINTER) {
            revert NullItem();
        }
        if (self.queue[item] != NULL_POINTER) {
            revert AlreadyEnqueued();
        }

        if (self.front == self.queue[self.front]) {
            self.queue[self.front] = item;
        }

        self.queue[self.back] = item;
        self.back = item;
    }

    function dequeue(
        Queue storage self
    ) internal notEmpty(self) returns (bytes32 item) {
        item = self.queue[self.front];
        self.front = item;
    }

    function peek(Queue storage self) internal view returns (bytes32) {
        return self.queue[self.front];
    }

    function at(
        Queue storage self,
        bytes32 pointer
    ) internal view returns (bytes32) {
        return self.queue[pointer];
    }

    // @dev returns items array of size `limit` and actual count of items
    // @dev reverts if the queue is empty
    function list(
        Queue storage self,
        bytes32 pointer,
        uint256 limit
    )
        internal
        view
        notEmpty(self)
        returns (bytes32[] memory items, uint256 /* count */)
    {
        if (limit == 0) {
            revert LimitNotSet();
        }
        items = new bytes32[](limit);

        uint256 i;
        for (; i < limit; i++) {
            bytes32 item = self.queue[pointer];
            if (item == NULL_POINTER) {
                break;
            }

            items[i] = item;
            pointer = item;
        }

        // TODO: resize items array to actual count
        return (items, i);
    }

    function isEmpty(Queue storage self) internal view returns (bool) {
        return self.front == self.back;
    }

    function remove(
        Queue storage self,
        bytes32 pointerToItem,
        bytes32 item
    ) internal {
        if (self.queue[pointerToItem] != item) {
            revert WrongPointer();
        }

        self.queue[pointerToItem] = self.queue[item];
        self.queue[item] = NULL_POINTER;

        if (self.back == item) {
            self.back = pointerToItem;
        }
    }

    modifier notEmpty(Queue storage self) {
        if (isEmpty(self)) {
            revert QueueIsEmpty();
        }
        _;
    }
}
