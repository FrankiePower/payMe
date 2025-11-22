// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../../contracts/UserBalanceScanner.sol";

/**
 * @title UserBalanceScannerHarness
 * @notice Test harness to expose internal functions for testing
 */
contract UserBalanceScannerHarness is UserBalanceScanner {
    constructor(address _endpoint, address _owner) UserBalanceScanner(_endpoint, _owner) {}

    // Expose _lzReceive for testing
    function exposed_lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external {
        _lzReceive(_origin, _guid, _message, _executor, _extraData);
    }
}
