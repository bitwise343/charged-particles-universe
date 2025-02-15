// SPDX-License-Identifier: MIT

// IonTimelock.sol -- Part of the Charged Particles Protocol
// Copyright (c) 2021 Firma Lux, Inc. <https://charged.fi>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/IIonxTimelock.sol";
import "../lib/BlackholePrevention.sol";

contract IonxTimelock is IIonxTimelock, BlackholePrevention {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  IERC20 public token;
  address public funder;
  address public receiver;
  Portion[] public portions;
  uint256 public totalAmountInTimelock;
  bool public activated;

  /***********************************|
  |          Initialization           |
  |__________________________________*/

  constructor (address _funder, address _receiver, address _token) public {
    require(_funder != address(0x0), "ITL:E-403");
    require(_receiver != address(0x0), "ITL:E-403");
    require(_token != address(0x0), "ITL:E-403");

    token = IERC20(_token);
    funder = _funder;
    receiver = _receiver;
  }


  /***********************************|
  |              Public               |
  |__________________________________*/

  function addPortions(uint256[] memory amounts, uint256[] memory releaseTimes)
    external
    virtual
    override
    onlyFunder
    returns (bool)
  {
    require(amounts.length == releaseTimes.length, "ITL:E-202");

    for (uint i = 0; i < amounts.length; i++) {
      uint256 releaseTime = releaseTimes[i];
      if (i > 0) {
        require(releaseTimes[i] > releaseTimes[i - 1], "ITL:E-204");
      }
      uint256 amount = amounts[i];

      // solhint-disable-next-line not-rely-on-time
      require(releaseTime > block.timestamp, "ITL:E-301");

      portions.push(Portion({
        amount: amount,
        releaseTime: releaseTime,
        claimed: false
      }));

      totalAmountInTimelock = totalAmountInTimelock.add(amount);
    }

    uint256 amountAvailable = token.balanceOf(address(this));
    require(amountAvailable >= totalAmountInTimelock, "ITL:E-411");

    emit PortionsAdded(amounts, releaseTimes);
    return true;
  }

  /**
    * @return releaseTime The time when the next portion of tokens will be released.
    */
  function nextReleaseTime()
    external
    view
    virtual
    override
    returns (uint256 releaseTime)
  {
    uint256 portionCount = portions.length;
    for (uint i = 0; i < portionCount; i++) {
      // solhint-disable-next-line not-rely-on-time
      if (portions[i].releaseTime > block.timestamp) {
        releaseTime = portions[i].releaseTime;
        break;
      }
    }
  }

  /**
    * @return releaseAmount The next amount that will be released.
    */
  function nextReleaseAmount()
    external
    view
    virtual
    override
    returns (uint256 releaseAmount)
  {
    uint256 portionCount = portions.length;
    for (uint i = 0; i < portionCount; i++) {
      // solhint-disable-next-line not-rely-on-time
      if (portions[i].releaseTime > block.timestamp) {
        releaseAmount = portions[i].amount;
        break;
      }
    }
  }

  /**
    * @notice Transfers tokens held by timelock to the receiver.
    */
  function release(uint256 numPortions, uint256 indexOffset)
    external
    virtual
    override
    onlyWhenActivated
    returns (uint256 amount)
  {
    require(numPortions <= portions.length, "ITL:E-201");

    uint256 portionCount = numPortions > 0 ? numPortions : portions.length;
    for (uint i = indexOffset; i < portionCount; i++) {
      // solhint-disable-next-line not-rely-on-time
      if (!portions[i].claimed && portions[i].releaseTime <= block.timestamp) {
        amount = amount.add(portions[i].amount);
        portions[i].claimed = true;

        emit PortionReleased(portions[i].amount, portions[i].releaseTime);
      }
    }

    uint256 amountAvailable = token.balanceOf(address(this));
    require(amount <= amountAvailable, "ITL:E-411");
    totalAmountInTimelock = amountAvailable.sub(amount);
    token.safeTransfer(receiver, amount);
  }

  /**
    * @notice Transfers tokens held by timelock to the receiver.
    */
  function releasePortion(uint256 portionIndex)
    external
    virtual
    override
    onlyWhenActivated
    returns (uint256 amount)
  {
    require(portionIndex >= 0 && portionIndex < portions.length, "ITL:E-201");

    Portion memory _portion = portions[portionIndex];
    require(!_portion.claimed, "ITL:E-431");
    // solhint-disable-next-line not-rely-on-time
    require(_portion.releaseTime <= block.timestamp, "ITL:E-302");

    amount = _portion.amount;
    portions[portionIndex].claimed = true;

    uint256 amountAvailable = token.balanceOf(address(this));
    require(amount <= amountAvailable, "ITL:E-411");
    totalAmountInTimelock = amountAvailable.sub(amount);
    token.safeTransfer(receiver, amount);

    emit PortionReleased(_portion.amount, _portion.releaseTime);
  }


  function withdrawEther(uint256 amount) external {
    _withdrawEther(payable(receiver), amount);
  }

  function withdrawErc20(address tokenAddress, uint256 amount) external {
    require(tokenAddress != address(token), "ITL:E-417");
    _withdrawERC20(payable(receiver), tokenAddress, amount);
  }

  function withdrawERC721(address tokenAddress, uint256 tokenId) external {
    require(tokenAddress != address(token), "ITL:E-417");
    _withdrawERC721(payable(receiver), tokenAddress, tokenId);
  }


  function activateTimelock()
    external
    virtual
    override
    onlyFunder
  {
    activated = true;
  }

  function destroyTimelock()
    external
    virtual
    override
    onlyFunder
  {
    require(!activated, "ITL:E-115");
    uint256 fullAmount = token.balanceOf(address(this));
    token.safeTransfer(funder, fullAmount);
    selfdestruct(payable(funder));
  }

  modifier onlyFunder() {
    require(msg.sender == funder, "ITL:E-103");
    _;
  }

  modifier onlyWhenActivated() {
    require(activated, "ITL:E-116");
    _;
  }
}
