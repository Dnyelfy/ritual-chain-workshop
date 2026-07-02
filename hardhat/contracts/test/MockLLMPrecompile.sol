// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only stand-in for Ritual's LLM inference precompile (0x0802).
///         Its runtime bytecode is placed at address 0x0802 via hardhat_setCode.
///         Mirrors the real envelope:
///           raw = abi.encode(bytes simmedInput, bytes actualOutput)
///           actualOutput = abi.encode(
///             bool hasError, bytes completionData, bytes raw,
///             string errorMessage, ConvoHistory history
///           )
contract MockLLMPrecompile {
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        bytes memory completion = bytes(
            '{"winnerIndex":1,"ranking":[{"index":1,"score":94,"reason":"Best satisfies the rubric."}],"summary":"Submission 1 is the strongest answer."}'
        );

        bytes memory actualOutput = abi.encode(
            false,
            completion,
            bytes(""),
            "",
            ConvoHistory("", "", "")
        );

        return abi.encode(input, actualOutput);
    }
}
