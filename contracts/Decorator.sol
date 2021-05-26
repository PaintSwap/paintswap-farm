// SPDX-License-Identifier: GPL-3.0-or-later Or MIT
pragma solidity >=0.8.0 <0.9.0;

import "./interface/IBep20.sol";
import "./interface/IArtGallery.sol";
import "./interface/IPancakePair.sol";
import "./interface/IPancakeRouter02.sol";
import "./helper/SafeMath.sol";
import "./helper/SafeBEP20.sol";
import "./helper/Ownable.sol";
import "./BrushToken.sol";

// Decorator is the master of Painting. He can use brushes all day and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once BRUSH is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract Decorator is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of BRUSHs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accBrushPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accBrushPerShare` (and `lastRewardTime`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. BRUSHes to distribute per second.
        uint256 lastRewardTime;  // Last timestamp that BRUSH distribution occured.
        uint256 accBrushPerShare;   // Accumulated BRUSHs per share, times 1e12. See below.
    }

    // The $BRUSH token
    BrushToken public brush;

    // The $WFTM token address
    address public wftm;

    // BRUSH tokens created per second.
    uint256 public brushPerSecond;

    // An art gallery where the fruits of your labour are put (50% of the rewards) ready for admiration. Can be collected in 3 months time.
    IArtGallery public artGallery;

    // The router
    IPancakeRouter02 public router;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Example 200 is 0.5%, type(uint).max is 0%
    uint inverseWithdrawFeeSingle;
    uint inverseWithdrawFeeLP;

    bool depositsDisabled;

    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The timestamp when BRUSH mining starts.
    uint256 public startTime;
    // How much of each LP token is eligible for burning
    mapping (IBEP20 => uint) public maxBurnAndBuyBackAmounts;

    struct Set {
        address[] values;
        mapping (address => bool) is_in;
    }

    Set private lps;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        BrushToken _brush,
        IArtGallery _artGallery,
        IPancakeRouter02 _router,
        address _wftm,
        uint256 _brushPerSecond,
        uint256 _startTime
    ) {
        brush = _brush;
        artGallery = _artGallery;
        router = _router;
        brushPerSecond = _brushPerSecond;
        startTime = _startTime;
        wftm = _wftm;
        inverseWithdrawFeeSingle = 200;
        inverseWithdrawFeeLP = 100;
        depositsDisabled = false;

        // brush staking pool
        poolInfo.push(
            PoolInfo({
                lpToken: _brush,
                allocPoint: 200,
                lastRewardTime: startTime,
                accBrushPerShare: 0
            })
        );
        universalApprove(_brush, address(router), type(uint).max);
        totalAllocPoint = 200;
        lps.values.push(address(_brush));
        lps.is_in[address(_brush)] = true;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function poolExists (address _lpToken) public view returns (bool) {
        return lps.is_in[_lpToken];
    }

    // Add a new lp to the pool. Can only be called by the owner. Will fail if it already exists.
    function add(uint256 _allocPoint, IBEP20 _lpToken, bool _withUpdate) public onlyOwner {
        require (!poolExists(address(_lpToken)), "This token already exists");
        address token0 = IPancakePair(address(_lpToken)).token0();
        address token1 = IPancakePair(address(_lpToken)).token1();
        require (token0 == address(brush) || token1 == address(brush) || token0 == wftm || token1 == wftm);
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accBrushPerShare: 0
        }));

        lps.values.push(address(_lpToken));
        lps.is_in[address(_lpToken)] = true;
        universalApprove (_lpToken, address(router), type(uint).max);
        universalApprove (IBEP20(token0), address(router), type(uint).max);
        universalApprove (IBEP20(token1), address(router), type(uint).max);
    }

    // Update the given pool's BRUSH allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        require (poolExists (address(poolInfo[_pid].lpToken)), "pid does not yet exist");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to time.
    function getMultiplier(uint256 _from, uint256 _to) internal view returns (uint256) {
        if (_to < startTime) {
            return 0;
        }
        return _to - _from;
    }

    // View function to see pending BRUSHs on frontend. Locked up rewards are excluded, so this is really / 2 the amount
    // they are entitled too.
    function pendingBrush(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBrushPerShare = pool.accBrushPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 brushReward = multiplier.mul(brushPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
            accBrushPerShare = accBrushPerShare.add(brushReward.mul(1e12).div(lpSupply));
        }
        return (user.amount.mul(accBrushPerShare).div(1e12).sub(user.rewardDebt)) / 2;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 brushReward = multiplier.mul(brushPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
        brush.mint(address(this), brushReward);
        pool.accBrushPerShare = pool.accBrushPerShare.add(brushReward.mul(1e12).div(lpSupply));
        pool.lastRewardTime = block.timestamp;
    }

    function distributePendingRewards(uint256 _pending) private {
        if (_pending > 0) {
            // Half of this is staked.
            uint256 halfPending = _pending / 2;
            if (_pending > 1) {
                artGallery.lock(msg.sender, halfPending);
                safeBrushTransfer(address(artGallery), halfPending);
            }

            safeBrushTransfer(msg.sender, _pending - halfPending);
        }
    }

    function universalApprove(IBEP20 token, address to, uint256 amount) internal {
        if (amount == 0) {
            token.safeApprove(to, 0);
            return;
        }

        uint256 allowance = token.allowance(address(this), to);
        if (allowance < amount) {
            if (allowance > 0) {
                token.safeApprove(to, 0);
            }
            token.safeApprove(to, amount);
        }
    }

    function buyBackAndBurn(address lpToken, uint amount) public {

        require (amount > 0);
        require (maxBurnAndBuyBackAmounts[IBEP20(lpToken)] >= amount);
        address token0 = IPancakePair(lpToken).token0();
        address token1 = IPancakePair(lpToken).token1();
        (uint removed0, uint removed1) = router.removeLiquidity (token0, token1, amount, 1, 1, address(this), block.timestamp + 1 minutes);

        // If none are brush, first convert one of them to wftm as there's no guarentee there will be a brush pair with it.
        uint extraToSwap = 0;
        uint extraBrushToBurn = 0;
        uint deadline = block.timestamp + 10000;
        bool oneIsBrush = token0 == address(brush) || token1 == address(brush); 
        if (!oneIsBrush) {
            address[] memory path;
            path = new address[](2);
            path[0] = (token0 == address(wftm)) ? token1 : token0;
            path[1] = wftm;
            uint[] memory inOut = router.swapExactTokensForTokens(
                (token0 == address(wftm)) ? removed1 : removed0,
                0,
                path,
                address(this),
                deadline
            );
            extraToSwap = inOut[1];
        } else {
            extraBrushToBurn = token0 == address(brush) ? removed0 : removed1; 
        }

        // Buy back brush
        address[] memory path;
        path = new address[](2);
        path[0] = ((oneIsBrush && token0 == address(brush)) || (!oneIsBrush && token1 == wftm)) ? token1 : token0;
        path[1] = address(brush);
        uint[] memory inOutBrush = router.swapExactTokensForTokens(
            (((oneIsBrush && token0 == address(brush)) || (!oneIsBrush && token1 == wftm)) ? removed1 : removed0) + extraToSwap,
            0,
            path,
            address(this),
            deadline
        );

        // Decrement the maximum that can be burnt
        maxBurnAndBuyBackAmounts[IBEP20(lpToken)] -= amount;

        // Now burn it, reducing the total supply
        brush.burn(inOutBrush[1] + extraBrushToBurn);
    }

    function buyBackAndBurnAll(address lpToken) public {
        buyBackAndBurn(lpToken, maxBurnAndBuyBackAmounts[IBEP20(lpToken)]);
    }

    // Deposit LP tokens to Decorator for BRUSH allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        require (!depositsDisabled);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accBrushPerShare).div(1e12).sub(user.rewardDebt);
            distributePendingRewards (pending);
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accBrushPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from Decorator.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accBrushPerShare).div(1e12).sub(user.rewardDebt);
        distributePendingRewards (pending);
        user.amount = user.amount.sub(_amount);
        uint256 withdrawFee = _withdraw (_pid, _amount, pool.lpToken);
        user.rewardDebt = user.amount.mul(pool.accBrushPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount.sub (withdrawFee));
    }

    function enterStaking(uint256 _amount) public {
        deposit (0, _amount);
    }

    function leaveStaking(uint256 _amount) public {
        withdraw (0, _amount);
    }

    function _withdraw(uint _pid, uint _amount, IBEP20 _lpToken) internal returns (uint withdrawFee) {
        if (_amount > 0) {
            if (_pid == 0) {
                // Withdrawing from single sided staking incurs a withdrawal fee which is burnt.
                withdrawFee = _amount / inverseWithdrawFeeSingle;

                // Transfer first, then burn it
                _lpToken.safeTransfer(address(msg.sender), _amount);
                if (withdrawFee > 0) {
                    brush.burn (msg.sender, withdrawFee);
                }
            } else {
                // Withdrawing from other pools incurs a withdrawal fee. Any brush is burnt and the rest is used to buy-back brush and burn it.
                withdrawFee = _amount / inverseWithdrawFeeLP;

                _lpToken.safeTransfer(address(msg.sender), _amount - withdrawFee);
                maxBurnAndBuyBackAmounts[_lpToken] += withdrawFee;
            }
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        uint withdrawFee = _withdraw(_pid, amount, pool.lpToken);
        emit EmergencyWithdraw(msg.sender, _pid, amount - withdrawFee);
    }

    // Safe brush transfer function, just in case if rounding error causes pool to not have enough BRUSHs.
    function safeBrushTransfer(address _to, uint256 _amount) internal {
        uint256 brushBal = brush.balanceOf(address(this));
        if (_amount > brushBal) {
            brush.transfer(_to, brushBal);
        } else {
            brush.transfer(_to, _amount);
        }
    }

    function setBrushPerSecondEmissionRate(uint256 _brushPerSecond) public onlyOwner {
        // This MUST be done or pool rewards will be calculated with new boo per second.
        // This could unfairly punish small pools that dont have frequent deposits/withdraws/harvests.
        massUpdatePools();
        brushPerSecond = _brushPerSecond;
    }

    function setStartTime(uint256 _startTime) public onlyOwner {
        require (_startTime > block.timestamp);
        require (startTime > block.timestamp);
        startTime = _startTime;
        for (uint i = 0; i < poolInfo.length; ++i) {
            poolInfo[i].lastRewardTime = startTime;
        }
    }

    function setDepositsDisabled(bool _depositsDisabled) public onlyOwner {
        depositsDisabled = _depositsDisabled;
    }

    function setInverseWithdrawFeeLP(uint _inverseWithdrawFee) public onlyOwner {
        require (_inverseWithdrawFee > 0);
        inverseWithdrawFeeLP = _inverseWithdrawFee;
    }

    function setInverseWithdrawFeeSingle(uint _inverseWithdrawFee) public onlyOwner {
        require (_inverseWithdrawFee > 0);        
        inverseWithdrawFeeSingle = _inverseWithdrawFee;
    }
}
