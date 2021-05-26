// SPDX-License-Identifier: GPL-3.0-or-later Or MIT

pragma solidity >=0.8.0 <0.9.0;

import "./helper/SafeERC20.sol";
import "./helper/Ownable.sol";

/**
 * @title TokenVesting
 * @dev A token holder contract that can release its token balance gradually like a
 * typical vesting scheme, with a cliff and vesting period. Optionally revocable by the
 * owner.
 */
contract TokenVesting is Ownable {
    // The vesting schedule is time-based (i.e. using block timestamps as opposed to e.g. block numbers), and is
    // therefore sensitive to timestamp manipulation (which is something miners can do, to a certain degree). Therefore,
    // it is recommended to avoid using short time durations (less than a minute). Typical vesting schemes, with a cliff
    // period of a year and a duration of four years, are safe to use.
    // solhint-disable not-rely-on-time

    using SafeERC20 for IERC20;

    event TokensReleased(address token, uint256 amount);
    event TokenVestingRevoked(address token);

    // beneficiary of tokens after they are released
    address public beneficiary;

    // Durations and timestamps are expressed in UNIX time, the same units as block.timestamp.
    uint256 public cliff;
    uint256 public start;
    uint256 public duration;

    bool public revocable;

    mapping (address => uint256) public released;
    mapping (address => bool) public revoked;

    /**
     * @dev Creates a vesting contract that vests its balance of any ERC20 token to the
     * beneficiary, gradually in a linear fashion until start + duration. By then all
     * of the balance will have vested.
     * @param _beneficiary address of the beneficiary to whom vested tokens are transferred
     * @param _cliffDuration duration in seconds of the cliff in which tokens will begin to vest
     * @param _start the time (as Unix time) at which point vesting starts
     * @param _duration duration in seconds of the period in which the tokens will vest
     * @param _revocable whether the vesting is revocable or not
     */
    constructor (address _beneficiary, uint256 _start, uint256 _cliffDuration, uint256 _duration, bool _revocable) {
        require(_beneficiary != address(0));
        require(_cliffDuration <= _duration);
        require(_duration > 0);
        require(_start + _duration > block.timestamp);

        beneficiary = _beneficiary;
        revocable = _revocable;
        duration = _duration;
        cliff = _start + _cliffDuration;
        start = _start;
    }

    /**
     * @notice Transfers vested tokens to beneficiary.
     * @param _token ERC20 token which is being vested
     */
    function release(IERC20 _token) public {
        uint256 _unreleased = releasableAmount_(_token);

        require(_unreleased > 0);

        released[address(_token)] = released[address(_token)] + _unreleased;

        _token.safeTransfer(beneficiary, _unreleased);

        emit TokensReleased(address(_token), _unreleased);
    }

    /**
     * @notice Allows the owner to revoke the vesting. Tokens already vested
     * remain in the contract, the rest are returned to the owner.
     * @param _token ERC20 token which is being vested
     */
    function revoke(IERC20 _token) public onlyOwner {
        require(revocable);
        require(!revoked[address(_token)]);

        uint256 _balance = _token.balanceOf(address(this));

        uint256 _unreleased = releasableAmount_(_token);
        uint256 _refund = _balance - _unreleased;

        revoked[address(_token)] = true;

        _token.safeTransfer(owner(), _refund);

        emit TokenVestingRevoked(address(_token));
    }

    /**
     * @dev Calculates the amount that has already vested but hasn't been released yet.
     * @param _token ERC20 token which is being vested
     */
    function releasableAmount_(IERC20 _token) public view returns (uint256) {
        return vestedAmount_(_token) - released[address(_token)];
    }

    /**
     * @dev Calculates the amount that has already vested.
     * @param _token ERC20 token which is being vested
     */
    function vestedAmount_(IERC20 _token) private view returns (uint256) {
        uint256 _currentBalance = _token.balanceOf(address(this));
        uint256 _totalBalance = _currentBalance + released[address(_token)];

        if (block.timestamp < cliff) {
            return 0;
        } else if (block.timestamp >= (start + duration) || revoked[address(_token)]) {
            return _totalBalance;
        } else {
            return _totalBalance * (block.timestamp - start) / duration;
        }
    }
}