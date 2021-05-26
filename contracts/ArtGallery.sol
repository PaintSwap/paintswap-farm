// SPDX-License-Identifier: GPL-3.0-or-later Or MIT
pragma solidity >=0.8.0 <0.9.0;

import "./interface/IArtGallery.sol";
import "./interface/IBep20.sol";
import "./helper/Ownable.sol";

contract ArtGallery is IArtGallery, Ownable {
    struct ArtEntry {
        uint256 amount; // How much to lock
        uint256 unlockTime; // When it is unlocked
    }

    // A wrapper around a mapping, enabling FIFO
    struct Collection {
        mapping(uint256 => ArtEntry) queue;
        uint256 first;
        uint256 count;
    }

    IBEP20 private immutable brush;
    uint256 public immutable lockDuration;

    mapping(address => Collection) private lockedUp;

    constructor(address _brush, uint256 _lockDuration) {
        brush = IBEP20(_brush);
        lockDuration = _lockDuration;
    }

    function lock(address _painter, uint256 _amount)
        external
        override
        onlyOwner
    {
        require(_amount > 0);
        Collection storage collection = lockedUp[_painter];
        collection.queue[collection.count] = ArtEntry({
            amount: _amount,
            unlockTime: block.timestamp + lockDuration
        });
        ++collection.count;
    }

    function isUnlockable(uint256 _unlockTime) public view returns (bool) {
        return block.timestamp >= _unlockTime;
    }

    // Always use inspect() first to avoid spending gas without any unlocks
    function unlock() external {
        uint256 unlockedAmount;

        Collection storage collection = lockedUp[msg.sender];
        uint256 count = collection.count;
        while (collection.first < count) {
            ArtEntry storage entry = collection.queue[collection.first];
            if (!isUnlockable(entry.unlockTime)) {
                break;
            }
            unlockedAmount += entry.amount;
            delete collection.queue[collection.first];
            ++collection.first;
        }

        if (unlockedAmount > 0) {
            safeBrushTransfer(msg.sender, unlockedAmount);
        }
    }

    function inspect(address _painter)
        public
        view
        returns (
            uint256 lockedCount, // How many art pieces are locked
            uint256 lockedAmount, // How much is locked in total
            uint256 unlockableCount,
            uint256 unlockableAmount,
            uint256 nextUnlockTime, // 0 if nothing locked; does not represent an immediate unlockable
            uint256 nextUnlockAmount
        )
    {
        Collection storage collection = lockedUp[_painter];
        for (uint256 i = collection.first; i < collection.count; ++i) {
            ArtEntry storage entry = collection.queue[i];
            if (isUnlockable(entry.unlockTime)) {
                ++unlockableCount;
                unlockableAmount += entry.amount;
            } else {
                ++lockedCount;
                lockedAmount += entry.amount;
                if (lockedCount == 1) {
                    nextUnlockTime = entry.unlockTime;
                    nextUnlockAmount = entry.amount;
                }
            }
        }
    }

    // Safe brush transfer function, just in case if rounding error causes the gallery to not have enough BRUSHs.
    function safeBrushTransfer(address _to, uint256 _amount) internal {
        require(_amount > 0);
        uint256 brushBal = brush.balanceOf(address(this));
        if (_amount > brushBal) {
            brush.transfer(_to, brushBal);
        } else {
            brush.transfer(_to, _amount);
        }
    }
}
