// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Minimal Sovereign Agent Consumer
/// @notice Calls the 0x080C precompile and receives Phase 2 results via callback.
contract SovereignAgentConsumer {
    address constant SOVEREIGN_AGENT = address(0x080C);
    address constant ASYNC_DELIVERY = 0x5A16214fF555848411544b005f7Ac063742f39F6;

    bytes32 public lastJobId;
    bytes public lastResult;

    event SovereignAgentResultDelivered(bytes32 indexed jobId, bytes result);

    function callSovereignAgent(bytes calldata input) external returns (bytes memory) {
        (bool ok, bytes memory output) = SOVEREIGN_AGENT.call(input);
        require(ok, "precompile call failed");
        return output;
    }

    function onSovereignAgentResult(bytes32 jobId, bytes calldata result) external {
        require(msg.sender == ASYNC_DELIVERY, "unauthorized callback sender");
        lastJobId = jobId;
        lastResult = result;
        emit SovereignAgentResultDelivered(jobId, result);
    }
}
