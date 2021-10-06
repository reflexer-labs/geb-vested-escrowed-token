pragma solidity 0.8.6;

// Original idea and credit:
// Curve Finance's veCRV
// https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/FeeDistributor.vy
// This is a Solidity version converted from Vyper by the Reflexer team
// Almost all of the logic / algorithms are the Curve team's

import "./openzeppelin/ERC20.sol";
import "./openzeppelin/ReentrancyGuard.sol";

abstract contract VotingEscrow {
    function user_point_epoch(address) virtual public view returns (uint256);
    function epoch() virtual public view returns (uint256);
    function user_point_history(address, uint256) virtual public view returns (int128, int128, uint256, uint256);
    function point_history(uint256) virtual public view returns (int128, int128, uint256, uint256);
    function checkpoint() virtual external;
}

contract veFeeDistributor is ReentrancyGuard {
    // --- Variables ---
    uint256 public constant WEEK = 7 * 86400; // all future times are rounded by week
    uint256 public constant TOKEN_CHECKPOINT_DEADLINE = 86400;
    address public constant ZERO_ADDRESS = address(0);

    uint256 public start_time;
    uint256 public time_cursor;
    uint256 public last_token_time;

    address public voting_escrow;
    address public token;

    uint256 public total_received;
    uint256 public token_last_balance;

    bool    public can_checkpoint_token;
    bool    public is_killed;

    address public admin;
    address public future_admin;
    address public emergency_return;

    mapping(address => uint256) public time_cursor_of;
    mapping(address => uint256) public user_epoch_of;
    mapping(uint256 => uint256) public tokens_per_week;
    mapping(uint256 => uint256) public ve_supply;

    // --- Structs ---
    // We cannot really do block numbers per se b/c slope is per time, not per block
    // and per block could be fairly bad b/c Ethereum changes blocktimes.
    // What we can do is to extrapolate ***At functions
    struct Point {
        int128 bias;
        int128 slope; // dweight / dt
        uint256 ts;
        uint256 blk; // block
    }

    // --- Events ---
    event CommitAdmin(address admin);
    event ApplyAdmin(address admin);
    event ToggleAllowCheckpointToken(bool toggle_flag);
    event CheckpointToken(uint256 time, uint256 tokens);
    event Claimed(address indexed recipient, uint256 amount, uint256 claim_epoch, uint256 max_epoch);

    /**
     * @notice Contract constructor
     * @param _voting_escrow VotingEscrow contract address
     * @param _start_time Epoch time for fee distribution to start
     * @param _token Fee token address (3CRV)
     * @param _admin Admin address
     * @param _emergency_return Address to transfer `_token` balance to if this contract is killed
    */
    constructor(
        address _voting_escrow,
        uint256 _start_time,
        address _token,
        address _admin,
        address _emergency_return
    ) public {
        uint256 t        = _start_time / WEEK * WEEK;
        start_time       = t;
        last_token_time  = t;
        time_cursor      = t;
        token            = _token;
        voting_escrow    = _voting_escrow;
        admin            = _admin;
        emergency_return = _emergency_return;
    }

    // --- Math ---
    function max(int128 x, int128 y) internal pure returns (int128 z) {
        z = (x >= y) ? x : y;
    }
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x <= y) ? x : y;
    }

    // --- Internal Logic ---
    function _checkpoint_token() internal {
        uint256 token_balance = ERC20(token).balanceOf(address(this));
        uint256 to_distribute = token_balance - token_last_balance;
        token_last_balance    = token_balance;

        uint256 t             = last_token_time;
        uint256 since_last    = block.timestamp - t;
        last_token_time       = block.timestamp;
        uint256 this_week     = t / WEEK * WEEK;
        uint256 next_week     = 0;

        for (uint i = 0; i < 20; i++) {
            next_week = this_week + WEEK;

            if (block.timestamp < next_week) {
                if (since_last == 0 && block.timestamp == t) {
                  tokens_per_week[this_week] += to_distribute;
                } else {
                  tokens_per_week[this_week] += to_distribute * (block.timestamp - t) / since_last;
                }
                break;
            } else {
              if (since_last == 0 && next_week == t) {
                tokens_per_week[this_week] += to_distribute;
              } else {
                tokens_per_week[this_week] += to_distribute * (next_week - t) / since_last;
              }
            }

            t         = next_week;
            this_week = next_week;
        }

        emit CheckpointToken(block.timestamp, to_distribute);
    }

    function _find_timestamp_epoch(address ve, uint256 _timestamp) internal returns (uint256) {
        uint256 _min = 0;
        uint256 _max = VotingEscrow(ve).epoch();
        uint256 _mid;

        for (uint i = 0; i < 128; i++) {
          if (_min >= _max) break;
          _mid = (_min + _max + 2) / 2;

          (,,uint256 ts,) = VotingEscrow(ve).point_history(_mid);
          if (ts <= _timestamp) {
            _min = _mid;
          } else {
            _max = _mid - 1;
          }
        }

        return _min;
    }

    function _find_timestamp_user_epoch(address ve, address user, uint256 _timestamp, uint256 max_user_epoch) internal returns (uint256) {
        uint256 _min = 0;
        uint256 _mid;
        uint256 _max = max_user_epoch;

        for (uint i = 0; i < 128; i++) {
          if (_min >= _max) break;

          _mid = (_min + _max + 2) / 2;
          (,,uint256 ts,) = VotingEscrow(ve).user_point_history(user, _mid);

          if (ts <= _timestamp) {
            _min = _mid;
          } else {
            _max = _mid - 1;
          }
        }

        return _min;
    }

    function _checkpoint_total_supply() internal {
        address ve = voting_escrow;
        uint256 t  = time_cursor;

        uint256 rounded_timestamp = block.timestamp / WEEK * WEEK;
        VotingEscrow(ve).checkpoint();

        for (uint i = 0; i < 20; i++) {
            if (t > rounded_timestamp) break;
            else {
              uint256 epoch = _find_timestamp_epoch(ve, t);
              int128  dt    = 0;
              (int128 bias, int128 slope, uint256 ts, ) = VotingEscrow(ve).point_history(epoch);

              if (t > ts) {
                dt = int128(int256(t - ts));
              }

              ve_supply[t] = uint256(int256(max(bias - slope * dt, 0)));
            }
            t += WEEK;
        }

        time_cursor = t;
    }

    function _claim(address addr, address ve, uint256 _last_token_time) internal returns (uint256) {
        // Minimal user_epoch is 0 (if user had no point)
        uint256 user_epoch     = 0;
        uint256 to_distribute  = 0;

        uint256 max_user_epoch = VotingEscrow(ve).user_point_epoch(addr);
        uint256 _start_time    = start_time;

        if (max_user_epoch == 0) {
          return 0;
        }

        uint256 week_cursor = time_cursor_of[addr];
        if (week_cursor == 0) {
          // Need to do the initial binary search
          user_epoch = _find_timestamp_user_epoch(ve, addr, _start_time, max_user_epoch);
        } else {
          user_epoch = user_epoch_of[addr];
        }

        if (user_epoch == 0) user_epoch = 1;

        // Initialize the user point
        Point memory user_point = getPoint(ve, addr, user_epoch);

        if (week_cursor == 0) {
          week_cursor = (user_point.ts + WEEK - 1) / WEEK * WEEK;
        }

        if (week_cursor >= _last_token_time) return 0;

        if (week_cursor < _start_time) {
          week_cursor = _start_time;
        }

        Point memory old_user_point;

        // Iterate over weeks
        for (uint i = 0; i < 50; i++) {
          if (week_cursor >= _last_token_time) {
            break;
          }

          if (week_cursor >= user_point.ts && user_epoch <= max_user_epoch) {
            user_epoch += 1;
            old_user_point = user_point;

            if (user_epoch > max_user_epoch) {
              user_point = Point(0, 0, 0, 0);
            } else {
              user_point = getPoint(ve, addr, user_epoch);
            }
          } else {
              // Calculations; + i * 2 is for rounding errors
              int128 dt          = int128(int256(week_cursor - old_user_point.ts));
              uint256 balance_of = uint256(int256(max(old_user_point.bias - dt * old_user_point.slope, 0)));

              if (balance_of == 0 && user_epoch > max_user_epoch) {
                  break;
              }
              if (balance_of > 0) {
                  to_distribute += balance_of * tokens_per_week[week_cursor] / ve_supply[week_cursor];
              }

              week_cursor += WEEK;
          }
        }

        user_epoch = min(max_user_epoch, user_epoch - 1);

        user_epoch_of[addr]  = user_epoch;
        time_cursor_of[addr] = week_cursor;

        emit Claimed(addr, to_distribute, user_epoch, max_user_epoch);

        return to_distribute;
    }

    function getPoint(address ve, address addr, uint256 user_epoch) internal view returns (Point memory) {
        (int128 bias, int128 slope, uint256 ts, uint256 blk) = VotingEscrow(ve).user_point_history(addr, user_epoch);
        return Point(bias, slope, ts, blk);
    }

    // --- Core Logic ---
    /**
     * @notice Update the token checkpoint
     * @dev Calculates the total number of tokens to be distributed in a given week.
     *      During setup for the initial distribution this function is only callable
     *      by the contract owner. Beyond initial distro, it can be enabled for anyone
     *      to call.
    */
    function checkpoint_token() external {
        require(msg.sender == admin || (can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE)));
        _checkpoint_token();
    }

    /**
     * @notice Get the veToken balance for `_user` at `_timestamp`
     * @param _user Address to query balance for
     * @param _timestamp Epoch time
     * @return uint256 veToken balance
    */
    function ve_for_at(address _user, uint256 _timestamp) external returns (uint256) {
        address ve             = voting_escrow;
        uint256 max_user_epoch = VotingEscrow(ve).user_point_epoch(_user);
        uint256 epoch          = _find_timestamp_user_epoch(ve, _user, _timestamp, max_user_epoch);

        (int128 bias, int128 slope, uint256 ts, ) = VotingEscrow(ve).user_point_history(_user, epoch);
        return uint256(int256(max(bias - slope * int128(int256(_timestamp - ts)), 0)));
    }

    /**
     * @notice Update the veToken total supply checkpoint
     * @dev The checkpoint is also updated by the first claimant each
     *      new epoch week. This function may be called independently
     *      of a claim, to reduce claiming gas costs.
     */
    function checkpoint_total_supply() external {
        _checkpoint_total_supply();
    }

    /**
     * @notice Claim fees for `_addr`
     * @dev Each call to claim look at a maximum of 50 user veToken points.
     *      For accounts with many veToken related actions, this function
     *      may need to be called more than once to claim all available
     *      fees. In the `Claimed` event that fires, if `claim_epoch` is
     *      less than `max_epoch`, the account may claim again.
     * @param _addr Address to claim fees for
     * @return uint256 Amount of fees claimed in the call
     */
    function claim(address _addr) external nonReentrant returns (uint256) {
        require(!is_killed, "veFeeDistributor/contract-killed");

        address _addr = msg.sender;

        if (block.timestamp >= time_cursor) {
            _checkpoint_total_supply();
        }

        uint256 last_token_time = last_token_time;
        if (can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE)) {
            _checkpoint_token();
            last_token_time = block.timestamp;
        }

        last_token_time = last_token_time / WEEK * WEEK;
        uint256 amount  = _claim(_addr, voting_escrow, last_token_time);

        if (amount != 0) {
            require(ERC20(token).transfer(_addr, amount), "");
            token_last_balance -= amount;
        }

        return amount;
    }

    /**
     * @notice Make multiple fee claims in a single call
     * @dev Used to claim for many accounts at once, or to make
     *      multiple claims for the same address when that address
     *      has significant veCRV history
     * @param _receivers List of addresses to claim for. Claiming
     *                   terminates at the first `ZERO_ADDRESS`.
     * @return bool success
     */
    function claim_many(address[20] calldata _receivers) external nonReentrant returns (bool) {
        require(!is_killed, "veFeeDistributor/contract-killed");

        if (block.timestamp >= time_cursor) {
            _checkpoint_total_supply();
        }

        uint256 last_token_time = last_token_time;

        if (can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE)) {
            _checkpoint_token();
            last_token_time = block.timestamp;
        }

        last_token_time = last_token_time / WEEK * WEEK;
        uint256 total;
        uint256 amount;

        for (uint i = 0; i < _receivers.length; i++) {
          if (_receivers[i] == address(0)) break;

          amount = _claim(_receivers[i], voting_escrow, last_token_time);
          if (amount != 0) {
              require(ERC20(token).transfer(_receivers[i], amount), "veFeeDistributor/cannot-transfer-token");
              total += amount;
          }
        }

        if (total != 0) {
            token_last_balance -= total;
        }

        return true;
    }

    /**
     * @notice Receive fees into the contract and trigger a token checkpoint
     * @param _coin Address of the coin being received
     * @return bool success
     */
    function burn(address _coin) external returns (bool) {
        require(_coin == token, "veFeeDistributor/invalid-coin");
        require(!is_killed, "veFeeDistributor/contract-killed");

        uint256 amount = ERC20(_coin).balanceOf(msg.sender);
        if (amount != 0) {
          ERC20(_coin).transferFrom(msg.sender, address(this), amount);
          if (can_checkpoint_token && (block.timestamp > last_token_time + TOKEN_CHECKPOINT_DEADLINE)) {
            _checkpoint_token();
          }
        }

        return true;
    }

    /**
     * @notice Commit transfer of ownership
     * @param _addr New admin address
     */
    function commit_admin(address _addr) external {
        require(msg.sender == admin, "veFeeDistributor/not-admin");
        future_admin = _addr;
        emit CommitAdmin(_addr);
    }

    /**
     * @notice Apply transfer of ownership
     */
    function apply_admin() external {
        require(msg.sender == admin, "veFeeDistributor/not-admin");
        require(future_admin != ZERO_ADDRESS, "veFeeDistributor/null-future-admin");
        admin = future_admin;
        emit ApplyAdmin(future_admin);
    }

    /**
     * @notice Toggle permission for checkpointing by any account
     */
    function toggle_allow_checkpoint_token() external {
        require(msg.sender == admin, "veFeeDistributor/not-admin");
        can_checkpoint_token = !can_checkpoint_token;
        emit ToggleAllowCheckpointToken(can_checkpoint_token);
    }

    /**
     * @notice Kill the contract
     * @dev Killing transfers the entire 3CRV balance to the emergency return address
     *      and blocks the ability to claim or burn. The contract cannot be unkilled.
     */
    function kill_me() external {
        require(msg.sender == admin, "veFeeDistributor/not-admin");
        require(!is_killed, "veFeeDistributor/contract-killed");

        require(ERC20(token).transfer(emergency_return, ERC20(token).balanceOf(address(this))), "veFeeDistributor/cannot-transfer");
    }
}
