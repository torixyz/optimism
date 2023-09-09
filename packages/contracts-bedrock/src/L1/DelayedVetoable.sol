// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Semver } from "../universal/Semver.sol";

contract DelayedVetoable is Semver {
    /// @notice Error for when attempting to forward too early.
    error ForwardingEarly();

    /// @notice Error for the target is not set.
    error TargetUnitialized();

    /// @notice Error for unauthorized calls.
    error Unauthorized(address expected, address actual);

    /// @notice An event that is emitted when a call is initiated.
    /// @param callHash The hash of the call data.
    /// @param data The data of the initiated call.
    event Initiated(bytes32 indexed callHash, bytes data);

    /// @notice An event that is emitted each time a call is forwarded.
    /// @param callHash The hash of the call data.
    /// @param data The data forwarded to the target.
    event Forwarded(bytes32 indexed callHash, bytes data);

    /// @notice An event that is emitted each time a call is vetoed.
    /// @param callHash The hash of the call data.
    /// @param data The data forwarded to the target.
    event Vetoed(bytes32 indexed callHash, bytes data);

    /// @notice The address that all calls are forwarded to after the delay.
    address internal _target;

    // TODO(maurelian): move this to the new SuperChainConfig contract
    /// @notice The address that can veto a call.
    address internal _vetoer;

    // TODO(maurelian): move this to the new SuperChainConfig contract
    /// @notice The address that can initiate a call.
    address internal _initiator;

    /// @notice The time that a call was initiated.
    mapping(bytes32 => uint256) internal _queuedAt;

    /// @notice The time to wait before forwarding a call.
    uint256 internal _delay;

    /// @notice A modifier that reverts if not called by the vetoer or by address(0) to allow
    ///         eth_call to interact with this proxy without needing to use low-level storage
    ///         inspection. We assume that nobody is able to trigger calls from address(0) during
    ///         normal EVM execution.
    modifier readOrHandle() {
        if (msg.sender == address(0)) {
            _;
        } else {
            // This WILL halt the call frame on completion.
            _handleCall();
        }
    }

    /// @custom:semver 0.0.1
    /// @notice Sets the target admin during contract deployment.
    /// @param vetoer_ Address of the vetoer.
    /// @param initiator_ Address of the initiator.
    /// @param target_ Address of the target.
    /// @param delay_ Address of the delay.
    constructor(address vetoer_, address initiator_, address target_, uint256 delay_) Semver(0, 0, 1) {
        _vetoer = vetoer_;
        _initiator = initiator_;
        _target = target_;
        _delay = delay_;
    }

    /// @notice Gets the initiator
    /// @return Initiator address.
    function initiator() external readOrHandle returns (address) {
        return _initiator;
    }

    //// @notice Queries the vetoer address.
    /// @return Vetoer address.
    function vetoer() external readOrHandle returns (address) {
        return _vetoer;
    }

    //// @notice Queries the target address.
    /// @return Target address.
    function target() external readOrHandle returns (address) {
        return _target;
    }

    /// @notice Gets the delay
    /// @return Delay address.
    function delay() external readOrHandle returns (uint256) {
        return _delay;
    }

    // TODO(maurelian): Remove this? The contract currently cannot handle forwarding ETH and I'm
    //   not sure the complexity is warranted.
    //   If we do allow it:
    //      1. the callHash will need to include the value
    //      2. forwarding will need to be done by passing the callHash, rather than the unhashed data
    /// @notice Used when no data is passed to the contract.
    receive() external payable {
        _handleCall();
    }

    /// @notice Used for all calls that pass data to the contract.
    fallback() external payable {
        _handleCall();
    }

    /// @notice Receives all calls other than those made by the vetoer.
    ///         This enables transparent initiation and forwarding of calls to the target and avoids
    ///         the need for additional layers of abi encoding.
    function _handleCall() internal {
        bytes32 callHash = keccak256(msg.data);

        // Case 1: The initiator is calling the contract to initiate a call.
        if (msg.sender == _initiator && _queuedAt[callHash] == 0) {
            _queuedAt[callHash] = block.timestamp;
            emit Initiated(callHash, msg.data);
            return;
        }

        // Case 2: The vetoer is calling the contract to veto a call.
        if (msg.sender == _vetoer && _queuedAt[callHash] != 0 && block.timestamp <= _queuedAt[callHash] + _delay) {
            delete _queuedAt[callHash];
            emit Vetoed(callHash, msg.data);
            return;
        }

        // Case 3: The call is from an unpermissioned actor. We'll forward the call if the delay has
        // passed.
        if (_queuedAt[callHash] == 0) {
            // The call has not been initiated, so we'll treat this is an unauthorized initiation attempt.
            revert Unauthorized(_initiator, msg.sender);
        }

        if (_queuedAt[callHash] + _delay < block.timestamp) {
            // Not enough time has passed, so we'll revert.
            revert ForwardingEarly();
        }

        // Delete the call to prevent replays
        delete _queuedAt[callHash];

        // Forward the call
        emit Forwarded(callHash, msg.data);
        (bool success,) = _target.call(msg.data);
        assembly {
            // Success == 0 means a revert. We'll revert too and pass the data up.
            if iszero(success) { revert(0x0, returndatasize()) }

            // Otherwise we'll just return and pass the data up.
            return(0x0, returndatasize())
        }
    }
}
