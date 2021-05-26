// SPDX-License-Identifier: GPL-3.0-or-later Or MIT
pragma solidity >=0.8.0 <0.9.0;

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

contract Disperse {
  function disperseToken(IERC20 token, address[] calldata recipients, uint256[] calldata values) external {
    for (uint256 i = 0; i < recipients.length; ++i) {
      require(token.transferFrom(msg.sender, recipients[i], values[i]));
    }
  }
}
